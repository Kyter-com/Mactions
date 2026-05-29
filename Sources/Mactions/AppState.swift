import AppKit
import MactionsCore
import SwiftUI

/// One row in the live runner list: which repo a runner belongs to + its state.
struct FleetRunnerRow: Identifiable {
  let repoFullName: String
  let runner: ManagedRunner
  var id: String { "\(repoFullName)#\(runner.id)" }
}

/// The app's single source of truth. Owns auth + config, drives one
/// `RunnerOrchestrator` per selected repo, and republishes to SwiftUI. A
/// singleton so the `AppDelegate` can reach it during termination.
@MainActor
final class AppState: ObservableObject {
  static let shared = AppState()

  // Config (persisted to UserDefaults).
  @Published var selectedRepos: [RepoRef] = []
  @Published var labelsText = "self-hosted,macOS,mactions"
  @Published var runnersPerRepo = 1
  /// OAuth App client id for device-flow sign-in. Optional.
  @Published var clientId = ""

  // Windows runner (OPT-IN — nothing heavy happens until the user clicks the
  // "Set up Windows runner" button). All persisted to UserDefaults.
  /// Set once the one-time base-image build has succeeded. Gates the Windows
  /// toggle: no Windows fleet is offerable until an image exists.
  @Published var windowsImageReady = false
  /// When on (and an image is ready), go-online also brings up a Windows fleet
  /// labeled `[self-hosted, Windows, mactions]` for each selected repo.
  @Published var windowsEnabled = false
  /// Name of the base VM `prepare-windows-image` built (what we clone per job).
  @Published var windowsBaseImage = "win11-runner-base"
  /// True while the (long, multi-GB) image-prep flow is running. Disables the
  /// button so it can't be double-fired.
  @Published var windowsSetupBusy = false
  /// Latest prerequisite scan (Homebrew, hypervisor, converter tools). Drives the
  /// preflight checklist; refreshed when the Windows section appears + after an
  /// install. `nil` until the first scan.
  @Published var windowsPreflight: WindowsPreflight.Report?
  /// True while the free-deps installer (`brew install …`) is running. Disables
  /// the "Install free prerequisites" button so it can't be double-fired.
  @Published var windowsPreflightBusy = false

  // Repo discovery (for the searchable picker).
  @Published var availableRepos: [RepoRef] = []
  @Published var reposLoading = false

  // Auth.
  @Published var isSignedIn = false
  @Published var authBusy = false
  @Published var pendingDeviceCode: GitHubAuth.DeviceCode?

  // Fleet runtime.
  @Published var state: FleetState = .offline
  @Published var runners: [FleetRunnerRow] = []
  @Published var statusMessage: String?

  /// One orchestrator per repo, keyed by `owner/name`.
  private var orchestrators: [String: RunnerOrchestrator] = [:]
  /// Bumped on every goOnline/goOffline so a slow goOnline Task (e.g. blocked
  /// on the agent download) can detect that the user went offline meanwhile and
  /// abort instead of reviving a dead fleet.
  private var fleetEpoch = 0
  private let defaults = UserDefaults.standard

  init() {
    selectedRepos = (defaults.stringArray(forKey: "selectedRepos") ?? []).compactMap(RepoRef.init(fullName:))
    labelsText = defaults.string(forKey: "labels") ?? labelsText
    runnersPerRepo = max(1, defaults.integer(forKey: "runnersPerRepo"))
    clientId = defaults.string(forKey: "clientId") ?? ""
    windowsImageReady = defaults.bool(forKey: "windowsImageReady")
    windowsEnabled = defaults.bool(forKey: "windowsEnabled")
    windowsBaseImage = defaults.string(forKey: "windowsBaseImage") ?? windowsBaseImage
    isSignedIn = TokenStore.load() != nil
  }

  var menuBarSymbol: String {
    switch state {
    case .offline: return "bolt.slash"
    case .starting, .stopping: return "bolt.badge.clock"
    case .online: return "bolt.fill"
    }
  }

  func saveConfig() {
    defaults.set(selectedRepos.map(\.fullName), forKey: "selectedRepos")
    defaults.set(labelsText, forKey: "labels")
    defaults.set(runnersPerRepo, forKey: "runnersPerRepo")
    defaults.set(clientId, forKey: "clientId")
    defaults.set(windowsImageReady, forKey: "windowsImageReady")
    defaults.set(windowsEnabled, forKey: "windowsEnabled")
    defaults.set(windowsBaseImage, forKey: "windowsBaseImage")
  }

  var labels: [String] {
    labelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  func isSelected(_ repo: RepoRef) -> Bool { selectedRepos.contains(repo) }

  func toggleRepo(_ repo: RepoRef) {
    guard state == .offline else { return }
    if let index = selectedRepos.firstIndex(of: repo) {
      selectedRepos.remove(at: index)
    } else {
      selectedRepos.append(repo)
    }
    saveConfig()
  }

  // MARK: Auth

  var gitHubCLIAvailable: Bool { GitHubCLIAuth.isAvailable() }

  func signInWithGitHubCLI() {
    do {
      let token = try GitHubCLIAuth.currentToken()
      try TokenStore.save(token)
      isSignedIn = true
      statusMessage = "Signed in via GitHub CLI."
      Task { await loadRepos() }
    } catch {
      statusMessage = "\(error)"
    }
  }

  func signInWithDeviceFlow() {
    guard !clientId.isEmpty else {
      statusMessage = "Add an OAuth client id in Settings, or paste a token below."
      return
    }
    authBusy = true
    statusMessage = nil
    Task {
      do {
        let code = try await GitHubAuth.requestDeviceCode(clientId: clientId)
        pendingDeviceCode = code
        NSWorkspace.shared.open(code.verificationURI)
        let token = try await GitHubAuth.pollForToken(clientId: clientId, deviceCode: code)
        try TokenStore.save(token)
        isSignedIn = true
        statusMessage = "Signed in."
        await loadRepos()
      } catch {
        statusMessage = "Sign-in failed: \(error)"
      }
      pendingDeviceCode = nil
      authBusy = false
    }
  }

  func signInWithToken(_ token: String) {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      try TokenStore.save(trimmed)
      isSignedIn = true
      statusMessage = "Token saved."
      Task { await loadRepos() }
    } catch {
      statusMessage = "Couldn't store the token: \(error)"
    }
  }

  func signOut() {
    Task { await goOfflineAndWait() }
    try? TokenStore.clear()
    isSignedIn = false
    availableRepos = []
    statusMessage = "Signed out."
  }

  // MARK: Repo discovery

  func loadReposIfNeeded() async {
    guard isSignedIn, availableRepos.isEmpty, !reposLoading else { return }
    await loadRepos()
  }

  func loadRepos() async {
    guard let token = TokenStore.load() else { return }
    guard !reposLoading else { return } // dedupe concurrent loads
    reposLoading = true
    defer { reposLoading = false }
    do {
      let repos = try await GitHubRepoLister(token: token).listAdminRepos()
      availableRepos = repos
      // Drop any persisted selection the account can no longer admin.
      let admin = Set(repos)
      selectedRepos = selectedRepos.filter { admin.contains($0) }
      if repos.isEmpty {
        statusMessage = "No repos you can administer were found for this account."
      }
    } catch is CancellationError {
      // The popover closed mid-load; not worth surfacing.
    } catch let error as URLError where error.code == .cancelled {
      // Request cancelled (popover dismissed / superseded). Ignore.
    } catch {
      statusMessage = "Couldn't load repos: \(error.localizedDescription)"
    }
  }

  // MARK: Fleet

  func toggleOnline() {
    state == .offline ? goOnline() : goOffline()
  }

  func goOnline() {
    guard let token = TokenStore.load() else { statusMessage = "Sign in first."; return }
    guard !selectedRepos.isEmpty else { statusMessage = "Pick at least one repository."; return }
    saveConfig()
    HostCleanup.sweepOrphans()
    fleetEpoch += 1
    let myEpoch = fleetEpoch
    state = .starting
    statusMessage = "Preparing runner agent…"
    let repos = selectedRepos
    Task {
      var created: [RunnerOrchestrator] = []
      do {
        let template = try await RunnerInstaller.ensureInstalled(token: token)
        guard fleetEpoch == myEpoch else { return } // went offline during download
        let factory = LocalProcessProviderFactory(
          templateDirectory: template, runsRoot: HostCleanup.runsRoot())
        // Windows fleet (opt-in): only when the user enabled it AND a base image
        // exists AND a hypervisor CLI is installed. Never spun up automatically.
        // Default backend is FREE-FIRST (UTM if present, else an existing
        // Parallels) to match the free-first prerequisite policy.
        let windowsFactory: WindowsVMProviderFactory? =
          (windowsEnabled && windowsImageReady)
          ? WindowsVMProviderFactory.detectFreeFirstCLI().map {
            WindowsVMProviderFactory(baseImage: windowsBaseImage, cli: $0)
          }
          : nil
        for repo in repos {
          guard fleetEpoch == myEpoch else { break }
          let client = GitHubClient(owner: repo.owner, repo: repo.name, token: token)
          let fleet = FleetConfig(
            owner: repo.owner, repo: repo.name, labels: labels, desiredCount: runnersPerRepo)
          let orch = RunnerOrchestrator(controlPlane: client, factory: factory, config: fleet)
          orch.onChange = { [weak self] in self?.sync() }
          orchestrators[repo.fullName] = orch
          created.append(orch)
          await orch.start()

          if let windowsFactory {
            let winClient = GitHubClient(owner: repo.owner, repo: repo.name, token: token)
            let winFleet = FleetConfig(
              owner: repo.owner, repo: repo.name, labels: windowsLabels, desiredCount: 1)
            let winOrch = RunnerOrchestrator(
              controlPlane: winClient, factory: windowsFactory, config: winFleet)
            winOrch.onChange = { [weak self] in self?.sync() }
            orchestrators["\(repo.fullName) (Windows)"] = winOrch
            created.append(winOrch)
            await winOrch.start()
          }
        }
        guard fleetEpoch == myEpoch else {
          for orch in created { await orch.stop() } // user went offline; undo
          return
        }
        state = .online
        sync()
        let live = orchestrators.values.reduce(0) { $0 + $1.runners.count }
        statusMessage =
          live == 0
          ? "Online, but no runners came up — check repo permissions / labels."
          : "Online: \(live) runner\(live == 1 ? "" : "s") across \(repos.count) repo\(repos.count == 1 ? "" : "s")."
      } catch {
        guard fleetEpoch == myEpoch else { return }
        statusMessage = "Failed to start: \(error.localizedDescription)"
        state = .offline
      }
    }
  }

  func goOffline() {
    Task { await goOfflineAndWait() }
  }

  func goOfflineAndWait() async {
    guard !orchestrators.isEmpty || state != .offline else { return }
    fleetEpoch += 1 // invalidate any in-flight goOnline
    state = .stopping
    sync()
    for orch in orchestrators.values { await orch.stop() }
    orchestrators.removeAll()
    // Each run wipes its own working copy; sweep again defensively.
    HostCleanup.purgeRuns()
    runners = []
    state = .offline
    statusMessage = "Offline."
  }

  /// Remove everything Mactions wrote to disk (cached agent + run files).
  func cleanUpHostFiles() {
    guard state == .offline else { statusMessage = "Go offline first."; return }
    HostCleanup.purgeAll()
    statusMessage = "Removed the cached agent and all run files."
  }

  // MARK: Windows runner (opt-in)

  /// True only if a Windows-capable hypervisor CLI (Parallels `prlctl`, or UTM
  /// `utmctl`) is installed. Windows runners aren't offerable without one.
  var windowsBackendAvailable: Bool { WindowsVMProviderFactory.detectInstalledCLI() != nil }

  /// Run the prerequisite scan and publish it for the checklist. Cheap
  /// (filesystem probes only), so it's safe to call on `onAppear`.
  func refreshWindowsPreflight() {
    windowsPreflight = WindowsPreflight.detect()
  }

  /// Install ONLY the missing FREE prerequisites (the free UTM hypervisor cask +
  /// the missing converter formulae) via Homebrew. NEVER installs Parallels
  /// (paid) and NEVER installs Homebrew itself — if `brew` is absent we point at
  /// brew.sh. Button-triggered only; the long-blocking `brew install` runs off
  /// the main actor so the popover stays responsive.
  func installWindowsFreePrerequisites() {
    guard state == .offline else { statusMessage = "Go offline first."; return }
    guard !windowsPreflightBusy else { return }
    let report = windowsPreflight ?? WindowsPreflight.detect()
    windowsPreflight = report
    switch WindowsPreflight.installPlan(for: report) {
    case let .homebrewMissing(message):
      statusMessage = message
      return
    case .nothingToInstall:
      statusMessage = "All free Windows prerequisites are already installed."
      return
    case .install:
      break
    }
    windowsPreflightBusy = true
    statusMessage = "Installing free Windows prerequisites (UTM + converter tools via Homebrew)…"
    Task {
      let result = await Self.runFreeInstall(report)
      windowsPreflightBusy = false
      windowsPreflight = WindowsPreflight.detect()  // reflect what landed
      switch result {
      case .installed:
        statusMessage = "Installed the free Windows prerequisites."
      case .nothingToInstall:
        statusMessage = "All free Windows prerequisites are already installed."
      case let .homebrewMissing(message):
        statusMessage = message
      case let .failed(command, stderr):
        statusMessage = "Install failed (`\(command)`): \(stderr.isEmpty ? "see Homebrew output" : stderr)"
      }
    }
  }

  /// Run the free-deps installer off the main actor (it shells out to `brew`).
  private nonisolated static func runFreeInstall(_ report: WindowsPreflight.Report) async
    -> WindowsPreflight.InstallResult
  {
    await Task.detached { WindowsPreflight.runInstall(for: report) }.value
  }

  /// Labels a Windows fleet registers with. Mirrors the macOS arm of a CI
  /// matrix: `runs-on: [self-hosted, Windows, mactions]`.
  private let windowsLabels = ["self-hosted", "Windows", "mactions"]

  /// The ONLY trigger for any Windows ISO download / base-image build. Nothing
  /// heavy ever happens automatically — this runs `scripts/prepare-windows-image`
  /// (which auto-downloads the latest Win11 ARM64 ISO if none is supplied, then
  /// builds the base VM) and surfaces progress in `statusMessage`.
  ///
  /// EXPERIMENTAL + LONG: the conversion/install is multi-GB and multi-minute,
  /// and the live VM path is not yet verified end to end. The button only kicks
  /// off the prep; a human still completes the one-time install per the script's
  /// printed next steps.
  func setUpWindowsRunner() {
    guard state == .offline else { statusMessage = "Go offline first."; return }
    guard !windowsSetupBusy else { return }
    guard let script = Self.prepareWindowsImageScript() else {
      statusMessage = "Couldn't find scripts/prepare-windows-image."
      return
    }
    // Preflight FIRST: if the free prerequisites (hypervisor + converter tools)
    // are missing, auto-install the FREE ones (UTM + converter formulae) via
    // Homebrew before the ISO download / base-image build. NEVER installs
    // Parallels (paid); if brew is absent we stop with the brew.sh hint.
    let report = WindowsPreflight.detect()
    windowsPreflight = report
    let image = windowsBaseImage
    windowsSetupBusy = true
    statusMessage = "Checking Windows prerequisites…"
    Task {
      // 1) Install missing FREE deps (off the main actor — it may shell out).
      if case .install = WindowsPreflight.installPlan(for: report) {
        statusMessage = "Installing free Windows prerequisites (UTM + converter tools via Homebrew)…"
        let install = await Self.runFreeInstall(report)
        windowsPreflight = WindowsPreflight.detect()
        switch install {
        case .installed, .nothingToInstall:
          break  // proceed to the build
        case let .homebrewMissing(message):
          statusMessage = message
          windowsSetupBusy = false
          return
        case let .failed(command, stderr):
          statusMessage =
            "Couldn't install prerequisites (`\(command)`): \(stderr.isEmpty ? "see Homebrew output" : stderr)"
          windowsSetupBusy = false
          return
        }
      } else if case let .homebrewMissing(message) = WindowsPreflight.installPlan(for: report) {
        statusMessage = message
        windowsSetupBusy = false
        return
      }

      // 2) Confirm a hypervisor backend is now present before the long build.
      guard WindowsVMProviderFactory.detectInstalledCLI() != nil else {
        statusMessage =
          "No Windows hypervisor available. Install UTM (free) via \"Install free prerequisites\", or open Parallels if you have it, then try again."
        windowsSetupBusy = false
        return
      }

      // 3) Build the base image. prepare-windows-image auto-resolves + downloads
      // the latest Win11 ARM64 ISO (UUP dump) when no --iso is passed, then
      // drives the base-VM build. The blocking shell-out runs off the main actor.
      statusMessage = "Setting up the Windows runner (downloading + building the base image — this takes a while)…"
      let result = await Self.runPrepScript(script, name: image)
      windowsSetupBusy = false
      if let result, result.ok {
        // Exit 0 means the prep RAN, not that a bootable base VM exists: the UTM
        // path only prints manual steps, and even on Parallels the unattended OS
        // install happens on first boot. Only flip ready when a powered-off base
        // VM is actually verifiable, so goOnline never clones a missing/running VM.
        let cli = WindowsVMProviderFactory.detectFreeFirstCLI()
        if let cli, WindowsVMProviderFactory.baseImagePoweredOff(name: image, cli: cli) {
          windowsImageReady = true
          saveConfig()
          statusMessage = "Windows base image '\(image)' is ready."
        } else {
          windowsImageReady = false  // never persist a stale-true
          saveConfig()
          statusMessage =
            "Windows prep finished. Complete the one-time install per the printed steps, shut the VM down, then run \"Set up Windows runner\" again to confirm."
        }
      } else {
        if let result {
          NSLog(
            "prepare-windows-image failed (status \(result.status))\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
          )
        }
        // The script tags its own failures via die(): `error: <msg>`. Surface the
        // first such line (a concise human summary); never echo a raw Python
        // traceback or set -e abort into the one-line status — the full transcript
        // is in Console.app via the NSLog above.
        let stderr = result?.stderr ?? ""
        let errorLine =
          stderr
          .split(whereSeparator: \.isNewline)
          .map(String.init)
          .first { $0.hasPrefix("error: ") }
        let detail =
          errorLine.map { String($0.dropFirst("error: ".count)).trimmingCharacters(in: .whitespaces) }
          ?? "the prep script failed — see Console.app for details"
        statusMessage = "Windows setup failed: \(detail)"
      }
    }
  }

  /// Run the (long-blocking) prep script off the main actor so the popover stays
  /// responsive, returning the result back on the caller's actor.
  private nonisolated static func runPrepScript(_ script: String, name: String) async
    -> Shell.Result?
  {
    await Task.detached {
      // A Finder/login-item launched .app inherits a launchd PATH WITHOUT
      // /opt/homebrew/bin, so the script's own `command -v` checks for python3 +
      // the converter tools (aria2c/cabextract/wimlib-imagex/mkisofs/chntpw) would
      // miss and it would die before downloading anything. Prepend the Homebrew
      // bins (matching Shell.which / WindowsPreflight) while preserving the rest
      // of the inherited env.
      var env = ProcessInfo.processInfo.environment
      let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
      let have = Set(existing.split(separator: ":").map(String.init))
      let prepend = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        .filter { !have.contains($0) }
      env["PATH"] = (prepend + [existing]).joined(separator: ":")
      return try? Shell.run(script, ["--name", name], environment: env)
    }.value
  }

  func setWindowsEnabled(_ on: Bool) {
    guard state == .offline else { return }
    windowsEnabled = on
    saveConfig()
  }

  /// Check whether a newer Win11 ARM64 build is available than the one the base
  /// image was built from, and surface it (the auto-update nudge). Pure compare
  /// logic lives in `WindowsImage`; this just wires it to the status line.
  func checkForWindowsImageUpdate() {
    guard windowsImageReady else { return }
    Task {
      guard let latest = try? await WindowsImage.latestBuild() else { return }
      let installed = WindowsImage.recordedBaseImageBuild()
      if WindowsImage.updateAvailable(installed: installed, latest: latest.build) {
        statusMessage =
          "A newer Windows 11 ARM64 build (\(latest.build)) is available — re-run \"Set up Windows runner\" to rebuild the base image."
      }
    }
  }

  /// Locate `scripts/prepare-windows-image`. In `swift run` dev the cwd is the
  /// package root; in a bundled app it'd ship in Resources. Search both.
  static func prepareWindowsImageScript() -> String? {
    let candidates = [
      FileManager.default.currentDirectoryPath + "/scripts/prepare-windows-image",
      Bundle.main.path(forResource: "prepare-windows-image", ofType: nil) ?? "",
      Bundle.main.bundlePath + "/Contents/Resources/scripts/prepare-windows-image",
    ]
    return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
  }

  private func sync() {
    // Only mirror the live runner list here. We deliberately do NOT re-stamp
    // orch.lastError onto statusMessage on every change — that clobbered the
    // status line and made a single transient error look permanent.
    var rows: [FleetRunnerRow] = []
    for (fullName, orch) in orchestrators {
      for runner in orch.runners {
        rows.append(FleetRunnerRow(repoFullName: fullName, runner: runner))
      }
    }
    runners = rows.sorted { $0.id < $1.id }
  }
}
