import AppKit
import MactionsCore
import SwiftUI

/// One row in the live runner list: which OS + repo a runner belongs to + state.
struct FleetRunnerRow: Identifiable {
  let os: RunnerOS
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
  /// Set once the one-time base-image build has succeeded. Gates the Windows OS
  /// tile: Windows isn't selectable until an image exists.
  @Published var windowsImageReady = false
  /// Which OSes the user picked to run fleets for (the OS tiles). macOS is the
  /// default; Windows is selectable only once `windowsImageReady`; Linux is not
  /// implemented yet. On go-online each SELECTED + implemented OS gets a fleet per
  /// repo (macOS via the local provider, Windows via the VM provider).
  @Published var selectedOSes: Set<RunnerOS> = [.macOS]
  /// Name of the base VM `prepare-windows-image` built (what we clone per job).
  @Published var windowsBaseImage = "win11-runner-base"
  /// True while the (long, multi-GB) image-prep flow is running. Disables the
  /// button so it can't be double-fired.
  @Published var windowsSetupBusy = false
  /// The current phase of the running base-image build, driven by streaming the
  /// prep scripts' output (`WindowsSetupProgress`). `nil` when no build is
  /// running. Powers the live stepper in the popover.
  @Published var windowsSetupStep: WindowsSetupStep?
  /// A short sub-status under the active step (install ticks, milestones, resume
  /// notice). `nil` clears it.
  @Published var windowsSetupDetail: String?
  /// Latest prerequisite scan (Homebrew, hypervisor, converter tools). Drives the
  /// preflight checklist; refreshed when the Windows section appears + after an
  /// install. `nil` until the first scan.
  @Published var windowsPreflight: WindowsPreflight.Report?
  /// True while the free-deps installer (`brew install …`) is running. Disables
  /// the "Install free prerequisites" button so it can't be double-fired.
  @Published var windowsPreflightBusy = false
  /// A "newer Windows build available — rebuild" nudge, surfaced in the Windows
  /// section as its OWN line. Deliberately NOT folded into `statusMessage`: the
  /// check fires on every popover `onAppear`, and writing the status line there
  /// clobbered the live "Online: N runners…" line just because the menu reopened.
  @Published var windowsUpdateNotice: String?
  /// Throttle the update check's network request so reopening the popover doesn't
  /// hit UUP dump every time. `nil` until the first check.
  private var lastWindowsUpdateCheck: Date?

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

  /// One orchestrator per repo×OS, keyed by `owner/name` (macOS) or
  /// `owner/name (Windows)`.
  private var orchestrators: [String: RunnerOrchestrator] = [:]
  /// The OS each orchestrator key belongs to, so the live runner list can show
  /// the right logo. Same keys as `orchestrators`; cleared together.
  private var fleetOS: [String: RunnerOS] = [:]
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
    windowsBaseImage = defaults.string(forKey: "windowsBaseImage") ?? windowsBaseImage
    // Restore the OS selection (pure logic in RunnerOS.restoreSelection, tested).
    // Back-compat: migrates a pre-OS-selection install from the legacy
    // `windowsEnabled` flag, seeding Windows only when its image is actually ready.
    selectedOSes = RunnerOS.restoreSelection(
      savedRawValues: defaults.stringArray(forKey: "selectedOSes"),
      legacyWindowsEnabled: defaults.bool(forKey: "windowsEnabled"),
      windowsImageReady: windowsImageReady)
    isSignedIn = TokenStore.load() != nil
    // Reap anything a previous crash / force-quit left behind (orphaned runner
    // processes, leaked Windows VM clones) BEFORE the user does anything — not
    // just on go-online. Off the main actor so app launch isn't blocked on the
    // shell-outs. This is the backstop for clones the 6s quit budget couldn't
    // tear down in time.
    Task.detached { HostCleanup.sweepOrphans() }
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
    defaults.set(selectedOSes.map(\.rawValue), forKey: "selectedOSes")
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
    guard selectedOSes.contains(where: { $0.isImplemented }) else {
      statusMessage = "Pick at least one runner OS."
      return
    }
    saveConfig()
    fleetEpoch += 1
    let myEpoch = fleetEpoch
    state = .starting
    statusMessage = "Preparing runner agent…"
    let repos = selectedRepos
    Task {
      // Reap a prior crash/force-quit's orphans OFF the main actor — sweepOrphans
      // shells out (pkill + `vmrun stop hard`/`deleteVM` + `rm -rf`), which can
      // block for seconds with leftover clones and would otherwise stall the UI
      // (the launch-time sweep is detached for the same reason). Sequenced BEFORE
      // any provisioning so a stale clone can't survive into this generation.
      await Task.detached { HostCleanup.sweepOrphans() }.value
      guard fleetEpoch == myEpoch else { return }  // went offline during the sweep
      var created: [RunnerOrchestrator] = []
      do {
        let wantsMac = selectedOSes.contains(.macOS)
        // Only fetch the macOS agent template when a macOS fleet is actually
        // wanted — a Windows-only selection needs no local agent.
        let factory: LocalProcessProviderFactory?
        if wantsMac {
          let template = try await RunnerInstaller.ensureInstalled(token: token)
          guard fleetEpoch == myEpoch else { return }  // went offline during download
          factory = LocalProcessProviderFactory(
            templateDirectory: template, runsRoot: HostCleanup.runsRoot())
        } else {
          factory = nil
        }
        // Windows fleet: only when the Windows OS tile is selected AND a base image
        // exists AND VMware Fusion is installed. Never spun up automatically.
        // Fusion is the sole backend (the proven Win11-ARM path).
        let windowsFactory: WindowsVMProviderFactory? =
          (selectedOSes.contains(.windows) && windowsImageReady)
          ? WindowsVMProviderFactory.detectInstalledCLI().map {
            WindowsVMProviderFactory(baseImage: windowsBaseImage, cli: $0)
          }
          : nil
        // Cap concurrent Windows VMs to what this Mac's RAM can run without
        // thrashing — each clone is a full VM, so N repos each booting one would
        // otherwise swamp the host. 0 => not enough RAM to run any safely (we then
        // skip Windows entirely and say so, rather than lag the Mac). The per-VM
        // footprint is the base VMX's real `memsize` (linked clones inherit it),
        // so a non-default `--ram` base stays in sync with the budget — not a
        // hardcoded 8 GB. Falls back to the default when the VMX can't be read.
        let perVMGB = Self.windowsPerVMGB(baseImage: windowsBaseImage)
        let maxWindowsVMs =
          windowsFactory == nil
          ? 0
          : WindowsVMBudget.maxConcurrentVMs(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, perVMGB: perVMGB)
        var windowsVMsStamped = 0
        for repo in repos {
          guard fleetEpoch == myEpoch else { break }
          if wantsMac, let factory {
            let client = GitHubClient(owner: repo.owner, repo: repo.name, token: token)
            let fleet = FleetConfig(
              owner: repo.owner, repo: repo.name, labels: labels, desiredCount: runnersPerRepo)
            let orch = RunnerOrchestrator(controlPlane: client, factory: factory, config: fleet)
            orch.onChange = { [weak self] in self?.sync() }
            orchestrators[repo.fullName] = orch
            fleetOS[repo.fullName] = .macOS
            created.append(orch)
            await orch.start()
          }

          if let windowsFactory, windowsVMsStamped < maxWindowsVMs {
            let winClient = GitHubClient(owner: repo.owner, repo: repo.name, token: token)
            let winFleet = FleetConfig(
              owner: repo.owner, repo: repo.name, labels: windowsLabels, desiredCount: 1)
            let winOrch = RunnerOrchestrator(
              controlPlane: winClient, factory: windowsFactory, config: winFleet)
            winOrch.onChange = { [weak self] in self?.sync() }
            let winKey = "\(repo.fullName) (Windows)"
            orchestrators[winKey] = winOrch
            fleetOS[winKey] = .windows
            created.append(winOrch)
            windowsVMsStamped += 1
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
        // If the RAM budget kept some repos from getting a Windows runner, say so
        // (silent under-provisioning reads as a bug).
        if windowsFactory != nil, windowsVMsStamped < repos.count {
          let why =
            maxWindowsVMs == 0
            ? "this Mac's RAM can't safely run a \(perVMGB) GB Windows VM"
            : "RAM budget allows \(maxWindowsVMs) at once"
          statusMessage =
            (statusMessage ?? "")
            + " Windows runners limited to \(windowsVMsStamped)/\(repos.count) repos (\(why))."
        }
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
    fleetOS.removeAll()
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

  /// True only if VMware Fusion is installed (the sole Windows backend — the
  /// PROVEN Win11-ARM path; `mactions-fusion-vm` helper + `vmrun`). Windows
  /// runners aren't offerable without it.
  var windowsBackendAvailable: Bool { WindowsVMProviderFactory.detectInstalledCLI() != nil }

  /// Run the prerequisite scan and publish it for the checklist. Cheap
  /// (filesystem probes only), so it's safe to call on `onAppear`.
  func refreshWindowsPreflight() {
    windowsPreflight = WindowsPreflight.detect()
  }

  /// Install ONLY the missing FREE prerequisites (the UUP-dump converter tools +
  /// xorriso for the no-prompt boot ISO) via Homebrew. NEVER installs a
  /// hypervisor — VMware Fusion is a manual Broadcom-portal download — and NEVER
  /// installs Homebrew itself (if `brew` is absent we point at brew.sh).
  /// Button-triggered only; the long-blocking `brew install` runs off the main
  /// actor so the popover stays responsive.
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
    statusMessage = "Installing free Windows prerequisites (ISO converter tools + xorriso via Homebrew)…"
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

  /// Labels a Windows fleet registers with: `[self-hosted, Windows, mactions]`.
  /// Sourced from the model (not a duplicated literal) so it can't drift.
  private let windowsLabels = RunnerOS.windows.defaultLabels

  /// The ONLY trigger for any Windows ISO download / base-image build. Nothing
  /// heavy ever happens automatically — this runs `scripts/prepare-windows-image`
  /// (which auto-downloads the latest Win11 ARM64 ISO if none is supplied, then
  /// builds the base VM) and surfaces progress in `statusMessage`.
  ///
  /// EXPERIMENTAL + LONG: the conversion/install is multi-GB and multi-minute,
  /// and the live VM path is not yet verified end to end. The button only kicks
  /// off the prep; a human still completes the one-time install per the script's
  /// printed next steps.
  /// `force: true` (the "Rebuild / update Windows image" button) skips the
  /// already-built fast-path and rebuilds from scratch — that's how a newer
  /// Windows build actually gets installed once `checkForWindowsImageUpdate`
  /// flags one. `force: false` (initial "Set up Windows runner") fast-paths when
  /// a ready base already exists, so a stray re-click doesn't re-download GBs.
  func setUpWindowsRunner(force: Bool = false) {
    guard state == .offline else { statusMessage = "Go offline first."; return }
    guard !windowsSetupBusy else { return }
    guard let script = Self.prepareWindowsImageScript() else {
      statusMessage = "Couldn't find scripts/prepare-windows-image."
      return
    }
    let image = windowsBaseImage
    // FAST PATH (non-forced only): if the base VM exists AND is powered off, the
    // prep script has nothing useful to do — flip windowsImageReady on directly,
    // so a stray re-click doesn't re-trigger the multi-GB UUP download + ~30-40
    // min convert just to confirm a powered-off VM exists. A FORCED rebuild
    // (update to a newer Windows) deliberately skips this and rebuilds.
    if !force, let cli = WindowsVMProviderFactory.detectInstalledCLI(),
      WindowsVMProviderFactory.baseImagePoweredOff(name: image, cli: cli)
    {
      windowsImageReady = true
      saveConfig()
      clearWindowsUpdateNudge()
      statusMessage = "Windows base image '\(image)' is ready."
      return
    }
    // Preflight FIRST: auto-install the FREE brew-able prerequisites (the
    // UUP-dump converter tools + xorriso) before the ISO download / base-image
    // build. VMware Fusion itself is a MANUAL Broadcom-portal install (the guard
    // below stops with a hint if it's absent); if brew is absent we stop with
    // the brew.sh hint.
    let report = WindowsPreflight.detect()
    windowsPreflight = report
    windowsSetupBusy = true
    windowsSetupStep = .prerequisites
    windowsSetupDetail = nil
    statusMessage = "Checking Windows prerequisites…"
    Task {
      // 1) Install missing FREE deps (off the main actor — it may shell out).
      if case .install = WindowsPreflight.installPlan(for: report) {
        statusMessage = "Installing free Windows prerequisites (ISO converter tools + xorriso via Homebrew)…"
        let install = await Self.runFreeInstall(report)
        windowsPreflight = WindowsPreflight.detect()
        switch install {
        case .installed, .nothingToInstall:
          break  // proceed to the build
        case let .homebrewMissing(message):
          statusMessage = message
          endWindowsSetup()
          return
        case let .failed(command, stderr):
          statusMessage =
            "Couldn't install prerequisites (`\(command)`): \(stderr.isEmpty ? "see Homebrew output" : stderr)"
          endWindowsSetup()
          return
        }
      } else if case let .homebrewMissing(message) = WindowsPreflight.installPlan(for: report) {
        statusMessage = message
        endWindowsSetup()
        return
      }

      // 2) Confirm VMware Fusion is present before the long build.
      guard WindowsVMProviderFactory.detectInstalledCLI() != nil else {
        statusMessage =
          "VMware Fusion isn't installed. Get it free from the Broadcom portal (it's the proven Win11-ARM backend, and not brew-installable), then try again."
        endWindowsSetup()
        return
      }

      // 3) Build the base image. prepare-windows-image auto-resolves + downloads
      // the latest Win11 ARM64 ISO (UUP dump) when no --iso is passed, then
      // drives the base-VM build. The blocking shell-out runs off the main actor.
      statusMessage = "Setting up the Windows runner (downloading + building the base image — this takes a while)…"
      // Stream the prep scripts' phase markers into the live stepper as the build
      // runs. The continuation is Sendable (safe to yield from the script's drain
      // threads); we consume on the MainActor and advance the stepper forward-only.
      let (lines, continuation) = AsyncStream<String>.makeStream()
      let progress = Task { @MainActor in
        for await line in lines { self.applySetupProgress(line) }
      }
      let result = await Self.runPrepScript(script, name: image) { continuation.yield($0) }
      continuation.finish()
      _ = await progress.value
      // Persist the FULL build transcript to ~/.mactions/logs so a failure is
      // diagnosable from disk (survives the ephemeral clone; no Console.app
      // spelunking). Both success + failure, so a "succeeded but didn't verify"
      // case is inspectable too.
      let buildLog = HostCleanup.writeLog(
        name: "prepare-windows-image", stamp: Self.logStamp(),
        contents:
          "exit=\(result.map { String($0.status) } ?? "nil (could not launch)")\n\n"
          + "=== stdout ===\n\(result?.stdout ?? "")\n\n=== stderr ===\n\(result?.stderr ?? "")\n")
      endWindowsSetup()
      if let result, result.ok {
        // Exit 0 means the prep RAN, not that a bootable base VM exists — the
        // unattended OS install + bootstrap happen on the first headless boot.
        // Only flip ready when a powered-off base VM is actually verifiable, so
        // goOnline never clones a missing/running VM.
        let cli = WindowsVMProviderFactory.detectInstalledCLI()
        if let cli, WindowsVMProviderFactory.baseImagePoweredOff(name: image, cli: cli) {
          windowsImageReady = true
          saveConfig()
          // A just-built base IS the latest — drop any stale "newer build
          // available" nudge and reset the throttle so the next popover open
          // re-checks against the freshly recorded build rather than waiting 6h.
          clearWindowsUpdateNudge()
          statusMessage = "Windows base image '\(image)' is ready."
        } else {
          windowsImageReady = false  // never persist a stale-true
          saveConfig()
          statusMessage =
            "Windows prep finished. Complete the one-time install per the printed steps, shut the VM down, then run \"Set up Windows runner\" again to confirm."
        }
      } else {
        // The script tags its own failures via die(): `error: <msg>`. Surface the
        // first such line (a concise human summary); never echo a raw Python
        // traceback or set -e abort into the one-line status — the full transcript
        // is the durable log written above.
        let stderr = result?.stderr ?? ""
        let errorLine =
          stderr
          .split(whereSeparator: \.isNewline)
          .map(String.init)
          .first { $0.hasPrefix("error: ") }
        let detail =
          errorLine.map { String($0.dropFirst("error: ".count)).trimmingCharacters(in: .whitespaces) }
          ?? "the prep script failed"
        statusMessage =
          "Windows setup failed: \(detail)" + (buildLog.map { " (log: \($0))" } ?? "")
      }
    }
  }

  /// Run the (long-blocking) prep script off the main actor so the popover stays
  /// responsive, returning the result back on the caller's actor.
  /// Filename-safe timestamp for durable log names (no colons).
  static func logStamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date())
  }

  private nonisolated static func runPrepScript(
    _ script: String, name: String, onLine: @escaping @Sendable (String) -> Void
  ) async -> Shell.Result? {
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
      // Stream the output (for the live stepper) while still capturing the full
      // transcript for the durable log.
      return try? Shell.runStreaming(script, ["--name", name], environment: env, onLine: onLine)
    }.value
  }

  /// Advance the live setup stepper from a line of build output (FORWARD-ONLY, so
  /// a duplicate/late marker can't regress it) and refresh the sub-status. Called
  /// on the MainActor as the prep scripts stream.
  private func applySetupProgress(_ line: String) {
    if let step = WindowsSetupProgress.step(for: line) {
      windowsSetupStep = max(windowsSetupStep ?? step, step)
    }
    if let detail = WindowsSetupProgress.detail(for: line) {
      windowsSetupDetail = detail
    }
  }

  /// Tear down the live setup indicator (the build finished or aborted). Paired
  /// with every exit from `setUpWindowsRunner` so the stepper never lingers.
  private func endWindowsSetup() {
    windowsSetupBusy = false
    windowsSetupStep = nil
    windowsSetupDetail = nil
  }

  /// Toggle an OS tile on/off. No-op while online, for an unimplemented OS
  /// (Linux), or for Windows before its base image is ready (the UI routes that
  /// tap to `setUpWindowsRunner` instead).
  func toggleOS(_ os: RunnerOS) {
    guard state == .offline, os.isImplemented else { return }
    if os == .windows && !windowsImageReady { return }
    if selectedOSes.contains(os) {
      selectedOSes.remove(os)
    } else {
      selectedOSes.insert(os)
    }
    saveConfig()
  }

  func isOSSelected(_ os: RunnerOS) -> Bool { selectedOSes.contains(os) }

  /// Check whether a newer Win11 ARM64 build is available than the one the base
  /// image was built from, and surface it as the dedicated `windowsUpdateNotice`
  /// (NOT `statusMessage` — see that property). Pure compare logic lives in
  /// `WindowsImage`. Throttled so reopening the popover doesn't re-hit the
  /// network; the nudge is informational and a stale-by-hours result is fine.
  /// Drop any "newer build available" nudge and reset the throttle. Called right
  /// after a (re)build succeeds — the base now IS the latest, so a leftover nudge
  /// would be stale, and clearing the throttle lets the next check recompute
  /// immediately instead of waiting out the 6h window.
  private func clearWindowsUpdateNudge() {
    windowsUpdateNotice = nil
    lastWindowsUpdateCheck = nil
  }

  func checkForWindowsImageUpdate() {
    guard windowsImageReady else { windowsUpdateNotice = nil; return }
    if let last = lastWindowsUpdateCheck, Date().timeIntervalSince(last) < 6 * 3600 {
      return  // checked recently — keep any existing notice, skip the request
    }
    lastWindowsUpdateCheck = Date()
    Task {
      guard let latest = try? await WindowsImage.latestBuild() else { return }
      let installed = WindowsImage.recordedBaseImageBuild()
      windowsUpdateNotice =
        WindowsImage.updateAvailable(installed: installed, latest: latest.build)
        ? "A newer Windows 11 ARM64 build (\(latest.build)) is available — click \"Rebuild / update Windows image\" to rebuild the base."
        : nil
    }
  }

  /// Per-VM RAM footprint (GB) for the Windows budget: the base VMX's real
  /// `memsize` (which every linked clone inherits) when readable, else the
  /// default. Read off the main actor would be ideal, but it's a single tiny
  /// file read — cheap enough to do inline on the goOnline Task.
  static func windowsPerVMGB(baseImage: String) -> Int {
    let vmx = HostCleanup.mactionsRoot()
      .appendingPathComponent("fusion", isDirectory: true)
      .appendingPathComponent("\(baseImage).vmx", isDirectory: false)
    if let contents = try? String(contentsOf: vmx, encoding: .utf8),
      let gb = WindowsVMBudget.perVMGB(fromVMX: contents)
    {
      return gb
    }
    return WindowsVMBudget.defaultPerVMGB
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
    for (key, orch) in orchestrators {
      let os = fleetOS[key] ?? .macOS
      // The Windows fleet is keyed "<repo> (Windows)"; show just the repo (the OS
      // is conveyed by the row's logo now).
      let suffix = " (Windows)"
      let repoName = key.hasSuffix(suffix) ? String(key.dropLast(suffix.count)) : key
      for runner in orch.runners {
        rows.append(FleetRunnerRow(os: os, repoFullName: repoName, runner: runner))
      }
    }
    runners = rows.sorted { $0.id < $1.id }
  }
}
