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
  /// After a FAILED base build: a user-facing explanation that persists until the
  /// next build, so the Windows pane shows what went wrong instead of silently
  /// reverting to the maintenance nudge. `nil` when the last build succeeded / none
  /// ran / one is in progress. `windowsSetupFailureIsExternal` flags an upstream/
  /// network cause (UUP dump down, a 522) — "not your setup, safe to retry" — vs a
  /// local one, so the UI can frame + tint it accordingly.
  @Published var windowsSetupFailure: String?
  @Published var windowsSetupFailureIsExternal = false
  /// Build options (persisted): show the build VM's window in Fusion
  /// (`MACTIONS_BUILD_GUI`) and keep a failed build's disk for offline forensics
  /// (`MACTIONS_KEEP_FAILED`). The env knobs exist for CLI runs; these surface
  /// them in the GUI app, which can't set env vars any other way.
  @Published var windowsBuildShowsWindow = false
  @Published var windowsKeepFailedDisk = false
  /// Optional packages (catalog ids from `WindowsImage.packageCatalog`) to bake
  /// into the next base build — the "what GitHub's hosted windows-11-arm image
  /// has" picker. Persisted; compared against `windows-base.packages` (what the
  /// built base actually carries) to drive the "rebuild to apply" nudge.
  @Published var selectedWindowsPackages: Set<String> = []
  /// Durable transcript of the LAST base build, success or failure (the
  /// `prepare-windows-image-<stamp>.log` written after every attempt) — drives
  /// the "View build log" buttons. Restored on launch from the newest log on
  /// disk so it survives an app restart.
  @Published var windowsBuildLogPath: String?
  /// One-line "what's in my base" summary (Windows build · recipe · built date ·
  /// Tools · duration), composed from the recorded build/recipe/health files.
  /// `nil` when no base has been built. Refreshed when the pane appears + after
  /// a successful build.
  @Published var windowsBaseSummary: String?
  /// The guest's own `C:\setup\logs\bootstrap.log`, copied out by
  /// `fusion-windows-base` in the sentinel→power-off window. `nil` if the last
  /// build predates the capture or the copy didn't land.
  @Published var windowsGuestLogPath: String?
  /// Set by `cancelWindowsSetup()` so the result handler frames the (expected)
  /// "powered off without sentinel" script failure as a user cancel, not an error.
  private var windowsSetupCancelled = false
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
  /// The structured reason the base image needs a rebuild (or `.upToDate`). Drives
  /// the reason-aware banner + "rebuild needed" badge in the UI; distinct from
  /// `windowsUpdateNotice` (the rendered string) so the View can branch on the
  /// KIND of staleness — a newer OS build vs an updated provisioning recipe.
  @Published var windowsMaintenance: WindowsImage.MaintenanceReason = .upToDate
  /// Throttle the update check's network request so reopening the popover doesn't
  /// hit UUP dump every time. `nil` until the first check.
  private var lastWindowsUpdateCheck: Date?
  /// The last latest-GA build the network check learned, cached so a recipe-only
  /// recompute on a later `onAppear` can still weigh the OS dimension without
  /// re-hitting the network (the recipe check itself is local + unthrottled).
  private var lastKnownLatestBuild: String?

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
  /// Names of OUR runners GitHub reports as `busy` (executing a job right now).
  /// Polled by the Runners pane so the activity ring spins only during a real job,
  /// not for an idle-but-online runner. Empty when offline.
  @Published var busyRunnerNames: Set<String> = []
  @Published var statusMessage: String?
  /// Finished runs (newest first), surfaced in the dashboard window's history.
  /// Loaded from disk on launch and appended to as runners exit; persisted off
  /// the main actor. "Past runs since turning on" — and across restarts.
  @Published var runHistory: [RunRecord] = []

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
    windowsBuildShowsWindow = defaults.bool(forKey: "windowsBuildShowsWindow")
    windowsKeepFailedDisk = defaults.bool(forKey: "windowsKeepFailedDisk")
    selectedWindowsPackages = Set(defaults.stringArray(forKey: "windowsPackages") ?? [])
    // Re-point "View build log" at the newest transcript on disk (cheap dir
    // listing) and recompose the base summary — both survive restarts.
    windowsBuildLogPath = Self.latestBuildLogPath()
    refreshWindowsBaseInfo()
    // Restore the OS selection (pure logic in RunnerOS.restoreSelection, tested).
    // Back-compat: migrates a pre-OS-selection install from the legacy
    // `windowsEnabled` flag, seeding Windows only when its image is actually ready.
    selectedOSes = RunnerOS.restoreSelection(
      savedRawValues: defaults.stringArray(forKey: "selectedOSes"),
      legacyWindowsEnabled: defaults.bool(forKey: "windowsEnabled"),
      windowsImageReady: windowsImageReady)
    isSignedIn = TokenStore.load() != nil
    // Restore past-run history (small JSON; cheap synchronous read like the
    // token/config loads above) so the dashboard has it immediately on open.
    runHistory = RunHistoryStore.load()
    // Warm the per-VM footprint cache off the main actor (avoids a main-thread
    // VMX read during dashboard renders).
    refreshWindowsPerVMGB()
    // Reap anything a previous crash / force-quit left behind (orphaned runner
    // processes, leaked Windows VM clones) BEFORE the user does anything — not
    // just on go-online. Off the main actor so app launch isn't blocked on the
    // shell-outs. This is the backstop for clones the 6s quit budget couldn't
    // tear down in time.
    Task.detached { HostCleanup.sweepOrphans() }
  }

  func saveConfig() {
    defaults.set(selectedRepos.map(\.fullName), forKey: "selectedRepos")
    defaults.set(labelsText, forKey: "labels")
    defaults.set(runnersPerRepo, forKey: "runnersPerRepo")
    defaults.set(clientId, forKey: "clientId")
    defaults.set(windowsImageReady, forKey: "windowsImageReady")
    defaults.set(selectedOSes.map(\.rawValue), forKey: "selectedOSes")
    defaults.set(windowsBaseImage, forKey: "windowsBaseImage")
    defaults.set(windowsBuildShowsWindow, forKey: "windowsBuildShowsWindow")
    defaults.set(windowsKeepFailedDisk, forKey: "windowsKeepFailedDisk")
    defaults.set(selectedWindowsPackages.sorted(), forKey: "windowsPackages")
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
    // The Windows base image is mid-(re)build — going online would clone a base
    // that's being wiped/rebuilt. Make the UI disable a hard guard too.
    guard !windowsSetupBusy else {
      statusMessage = "Finish building the Windows base image before going online."
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
      // sweepOrphans clears local disk/clones + kills orphan agent processes,
      // but not the *remote* GitHub registration. A clean go-offline runs
      // stop()'s deregister, but a crash/force-quit skips it, leaving ghost
      // runners that GitHub only auto-prunes much later. Reap them now — before
      // provisioning, so every match under this machine's prefix is provably a
      // prior-session orphan, never a runner from this generation. Per-repo,
      // best-effort; scoped to our prefix so another Mac's runners are untouched.
      for repo in repos {
        guard fleetEpoch == myEpoch else { return }
        await deregisterOrphanRunners(GitHubClient(owner: repo.owner, repo: repo.name, token: token))
      }
      guard fleetEpoch == myEpoch else { return }
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
            let orch = RunnerOrchestrator(
              controlPlane: client, factory: factory, config: fleet, os: .macOS)
            orch.onChange = { [weak self] in self?.sync() }
            orch.onRunFinished = { [weak self] record in self?.recordRun(record) }
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
              controlPlane: winClient, factory: windowsFactory, config: winFleet, os: .windows)
            winOrch.onChange = { [weak self] in self?.sync() }
            winOrch.onRunFinished = { [weak self] record in self?.recordRun(record) }
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
    busyRunnerNames = []
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
    windowsSetupFailure = nil  // a fresh attempt clears the last failure banner
    windowsSetupCancelled = false  // …and any prior cancel
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
      // The persisted build options ride in as the env knobs the scripts already
      // honor — the GUI app's only way to set them.
      var extraEnv: [String: String] = [:]
      if windowsBuildShowsWindow { extraEnv["MACTIONS_BUILD_GUI"] = "1" }
      if windowsKeepFailedDisk { extraEnv["MACTIONS_KEEP_FAILED"] = "1" }
      // Always pass the selection (even empty): prepare-windows-image records it
      // verbatim into windows-base.packages, so deselecting everything after a
      // packaged build still rebuilds to a lean base and records the empty set.
      extraEnv["MACTIONS_WINDOWS_PACKAGES"] = selectedWindowsPackages.sorted().joined(separator: ",")
      let result = await Self.runPrepScript(script, name: image, extraEnv: extraEnv) {
        continuation.yield($0)
      }
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
      windowsBuildLogPath = buildLog ?? windowsBuildLogPath
      endWindowsSetup()
      // User cancelled (powered off the build VM): the script fails with a
      // "powered off without sentinel" error, but that's expected — don't show it
      // as a failure. Cancel left the host clean (fusion-windows-base's teardown ran).
      if windowsSetupCancelled {
        windowsSetupCancelled = false
        windowsSetupFailure = nil
        windowsImageReady = false
        saveConfig()
        statusMessage = "Windows setup cancelled. The base image is unchanged — re-run Rebuild when ready."
        return
      }
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
          refreshWindowsBaseInfo()  // pick up the fresh build/recipe/health stamps
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
        // Classify: an upstream/network cause (UUP dump down, a 522) isn't the
        // user's setup and is safe to retry (the ~8 GB download resumes); a local
        // cause (missing tool, Fusion absent) is theirs to fix. Drives a tinted
        // banner in the Windows pane so a failed rebuild doesn't just silently
        // revert to the maintenance nudge.
        let transient = WindowsSetupProgress.isLikelyTransientFailure(result?.stderr ?? "")
        windowsSetupFailureIsExternal = transient
        windowsSetupFailure =
          transient
          ? "The last rebuild hit a transient issue (an upstream service / network blip, or the flaky Win11 OOBE handoff stalling) — not a problem with your Mac or setup. It's safe to retry. (\(detail))"
          : "The last rebuild failed: \(detail)."
        statusMessage =
          (transient
            ? "Windows rebuild hit a transient issue — safe to retry."
            : "Windows setup failed: \(detail)")
          + (buildLog.map { " Log: \($0)" } ?? "")
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
    _ script: String, name: String, extraEnv: [String: String] = [:],
    onLine: @escaping @Sendable (String) -> Void
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
      // The UI build options (show the VM window / keep a failed disk) ride in
      // as the env knobs the scripts already honor.
      for (key, value) in extraEnv { env[key] = value }
      // Stream the output (for the live stepper) while still capturing the full
      // transcript for the durable log.
      return try? Shell.runStreaming(script, ["--name", name], environment: env, onLine: onLine)
    }.value
  }

  /// Newest persisted `prepare-windows-image-*.log` transcript, so "View build
  /// log" still works after an app restart (the @Published path only covers the
  /// current session). The stamp is `yyyyMMdd-HHmmss`, so lexicographic order IS
  /// chronological order.
  private static func latestBuildLogPath() -> String? {
    let dir = HostCleanup.logsRoot()
    let files =
      (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return
      files
      .map(\.lastPathComponent)
      .filter { $0.hasPrefix("prepare-windows-image-") && $0.hasSuffix(".log") }
      .sorted()
      .last
      .map { dir.appendingPathComponent($0).path }
  }

  /// Recompose the base summary line + guest-log pointer from the recorded
  /// build/recipe/health files. Cheap (three tiny file reads); called on launch,
  /// when the Setup pane appears, and after a successful build.
  func refreshWindowsBaseInfo() {
    var parts: [String] = []
    if let build = WindowsImage.recordedBaseImageBuild() { parts.append("Windows \(build)") }
    if let recipe = WindowsImage.recordedRecipeVersion() { parts.append("recipe v\(recipe)") }
    if let packages = WindowsImage.recordedPackages(), !packages.isEmpty {
      parts.append("\(packages.count) package\(packages.count == 1 ? "" : "s")")
    }
    if let health = WindowsImage.recordedBaseHealth() {
      if let built = health.builtAt { parts.append("built \(built.prefix(10))") }
      if health.toolsUp { parts.append("VMware Tools ✓") }
      if let secs = health.elapsedSecs, secs >= 60 { parts.append("\(secs / 60) min build") }
      // Only surface the guest log while it actually exists (purge-able).
      windowsGuestLogPath = health.guestLogPath.flatMap {
        FileManager.default.fileExists(atPath: $0) ? $0 : nil
      }
    } else {
      windowsGuestLogPath = nil
    }
    windowsBaseSummary = parts.isEmpty ? nil : parts.joined(separator: " · ")
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

  /// Abort an in-progress base build from the UI. Powers off the build VM via `vmrun`
  /// — the same clean teardown `fusion-windows-base` runs on its own timeout: its watch
  /// loop sees the power-off, takes its failure path (restores the prior base, cleans
  /// up) and returns, so no processes are orphaned and the host is left as it was. The
  /// `windowsSetupCancelled` flag makes the result handler report a cancel, not a
  /// failure. Worth having: a wedged OOBE build otherwise has no in-app stop.
  func cancelWindowsSetup() {
    guard windowsSetupBusy, !windowsSetupCancelled else { return }
    windowsSetupCancelled = true
    windowsSetupDetail = "Cancelling — powering off the build VM…"
    let vmx = HostCleanup.mactionsRoot()
      .appendingPathComponent("fusion", isDirectory: true)
      .appendingPathComponent("\(windowsBaseImage).vmx").path
    Task.detached {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: WindowsPreflight.vmrunPath)
      p.arguments = ["-T", "fusion", "stop", vmx, "hard"]
      try? p.run()
      p.waitUntilExit()
    }
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

  /// Drop any "needs rebuild" nudge and reset the throttle. Called right after a
  /// (re)build succeeds — the base now IS the latest build AND carries the current
  /// provisioning recipe, so a leftover nudge would be stale; clearing the
  /// throttle lets the next check recompute immediately instead of waiting out
  /// the 6h window.
  private func clearWindowsUpdateNudge() {
    windowsMaintenance = .upToDate
    windowsUpdateNotice = nil
    lastWindowsUpdateCheck = nil
    lastKnownLatestBuild = nil
    // A verified-ready base also clears any lingering failure banner (called from
    // both the fast-path + post-build success).
    windowsSetupFailure = nil
    windowsSetupFailureIsExternal = false
  }

  /// Recompute whether the base image needs a rebuild, and why. Two dimensions:
  ///   - PROVISIONING RECIPE staleness — a purely LOCAL file compare (recorded
  ///     recipe vs `WindowsImage.currentProvisioningRecipeVersion`). Surfaced
  ///     IMMEDIATELY on every `onAppear`, unthrottled, even offline — it's how a
  ///     bootstrap change (e.g. the MinGit→PortableGit/bash fix) reaches an
  ///     already-built base.
  ///   - OS BUILD staleness — needs a UUP-dump network call, so it stays
  ///     THROTTLED to 6h. A nil result (offline / not yet checked) never asserts
  ///     an OS update; it just leaves the recipe verdict standing.
  /// Pure compare + reason/notice logic lives in `WindowsImage`; this only wires
  /// it to the throttle + published state. Surfaced as the dedicated
  /// `windowsMaintenance`/`windowsUpdateNotice` (NOT `statusMessage` — see that
  /// property: this fires on every popover `onAppear`).
  func checkForWindowsImageUpdate() {
    guard windowsImageReady else { clearWindowsUpdateNudge(); return }
    // Recipe + package dimensions first — local, instant, every onAppear.
    applyMaintenance(
      WindowsImage.maintenanceReason(
        recordedBuild: WindowsImage.recordedBaseImageBuild(),
        recordedRecipe: WindowsImage.recordedRecipeVersion(),
        latestBuild: lastKnownLatestBuild,
        selectedPackages: selectedWindowsPackages,
        recordedPackages: WindowsImage.recordedPackages()))
    // OS dimension — networked, throttled.
    if let last = lastWindowsUpdateCheck, Date().timeIntervalSince(last) < 6 * 3600 { return }
    lastWindowsUpdateCheck = Date()
    Task {
      guard let latest = try? await WindowsImage.latestBuild() else { return }
      lastKnownLatestBuild = latest.build
      applyMaintenance(
        WindowsImage.maintenanceReason(
          recordedBuild: WindowsImage.recordedBaseImageBuild(),
          recordedRecipe: WindowsImage.recordedRecipeVersion(),
          latestBuild: latest.build,
          selectedPackages: selectedWindowsPackages,
          recordedPackages: WindowsImage.recordedPackages()))
    }
  }

  /// Toggle one optional Windows package (the picker checkboxes). Persists the
  /// selection and immediately recomputes the maintenance nudge, so checking a
  /// box on a built base instantly shows "rebuild to apply".
  func toggleWindowsPackage(_ id: String, on: Bool) {
    if on { selectedWindowsPackages.insert(id) } else { selectedWindowsPackages.remove(id) }
    saveConfig()
    checkForWindowsImageUpdate()
  }

  /// Apply a computed maintenance reason to published state: the structured
  /// reason (for UI branching) + the derived one-line notice (the banner text).
  private func applyMaintenance(_ reason: WindowsImage.MaintenanceReason) {
    windowsMaintenance = reason
    windowsUpdateNotice = WindowsImage.maintenanceNotice(for: reason)
  }

  /// Per-VM RAM footprint (GB) for the Windows budget: the base VMX's real
  /// `memsize` (which every linked clone inherits) when readable, else the
  /// default. Read off the main actor would be ideal, but it's a single tiny
  /// file read — cheap enough to do inline on the goOnline Task.
  nonisolated static func windowsPerVMGB(baseImage: String) -> Int {
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

  // MARK: Run history + capacity (dashboard window)

  /// Serializes history writes. Each `persistHistory` chains its save after the
  /// previous one's, so saves run in submission order (= main-actor record order)
  /// and the newest snapshot is always written last — two near-simultaneous runner
  /// exits can't let a stale snapshot win the file write. Main-actor state, so no
  /// locking. (The in-memory `runHistory` is the source of truth during a session;
  /// disk is only read on launch.)
  private var lastHistorySave = Task<Void, Never> {}

  /// Append a finished run to history (newest first), cap it, and persist off the
  /// main actor. Called on the main actor from an orchestrator's `onRunFinished`.
  private func recordRun(_ record: RunRecord) {
    runHistory.insert(record, at: 0)
    if runHistory.count > RunHistoryStore.maxRecords {
      runHistory.removeLast(runHistory.count - RunHistoryStore.maxRecords)
    }
    persistHistory()
  }

  /// Wipe the persisted run history (dashboard "Clear" button).
  func clearRunHistory() {
    runHistory = []
    persistHistory()
  }

  /// Persist the current history off the main actor, serialized behind any
  /// in-flight save (see `lastHistorySave`).
  private func persistHistory() {
    let snapshot = runHistory
    let previous = lastHistorySave
    lastHistorySave = Task.detached {
      _ = await previous.value  // run strictly after the prior save
      RunHistoryStore.save(snapshot)
    }
  }

  /// Open `~/.mactions/logs` in Finder — where durable build/run transcripts and
  /// the history JSON live. Creates it first so the reveal never no-ops.
  func revealLogsInFinder() {
    let dir = HostCleanup.logsRoot()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    NSWorkspace.shared.open(dir)
  }

  /// A read-only capacity snapshot for the dashboard. This is the STATIC budget
  /// `goOnline` uses (host RAM + the Windows VM cap), plus live runner counts —
  /// NOT live per-VM memory sampling (that's a later phase). Computed on demand.
  struct CapacitySnapshot {
    let hostRAMBytes: UInt64
    let windowsPerVMGB: Int
    /// Max concurrent Windows VMs the budget allows (0 if no image / too little
    /// RAM). Mirrors what `goOnline` enforces.
    let windowsMaxConcurrentVMs: Int
    let liveMacRunners: Int
    let liveWindowsRunners: Int
    /// RAM the *currently live* Windows VMs are budgeted to use (count × per-VM).
    var windowsCommittedGB: Int { liveWindowsRunners * windowsPerVMGB }
  }

  /// Cached per-VM RAM footprint (GB) so `capacity` — read during view renders —
  /// never does file IO on the main thread. The VMX read happens on a detached
  /// task; refreshed on launch + when the dashboard appears.
  @Published private(set) var windowsPerVMGBCached = WindowsVMBudget.defaultPerVMGB

  func refreshWindowsPerVMGB() {
    let image = windowsBaseImage
    Task {
      let gb = await Task.detached { Self.windowsPerVMGB(baseImage: image) }.value
      windowsPerVMGBCached = gb
    }
  }

  var capacity: CapacitySnapshot {
    let perVM = windowsPerVMGBCached
    let ram = ProcessInfo.processInfo.physicalMemory
    return CapacitySnapshot(
      hostRAMBytes: ram,
      windowsPerVMGB: perVM,
      windowsMaxConcurrentVMs: windowsImageReady
        ? WindowsVMBudget.maxConcurrentVMs(physicalMemoryBytes: ram, perVMGB: perVM)
        : 0,
      liveMacRunners: runners.filter { $0.os == .macOS }.count,
      liveWindowsRunners: runners.filter { $0.os == .windows }.count)
  }

  // MARK: Live memory sampling (dashboard Memory tab)

  /// Rolling buffer of live memory readings for the gauge + sparkline. Sampled
  /// ONLY while the dashboard window is open (started/stopped by the window
  /// controller), so there's no background cost when nobody's watching.
  @Published private(set) var memorySamples: [MemorySample] = []
  static let maxMemorySamples = 120

  var latestMemory: MemorySample? { memorySamples.last }

  private var memorySamplingTask: Task<Void, Never>?

  /// Start the live memory sampler. Driven by the dashboard window opening (see
  /// `DashboardWindowController`) rather than SwiftUI view lifecycle: the window is
  /// reused (`isReleasedWhenClosed = false`), so a view-anchored `.task` wouldn't
  /// reliably stop on close. Idempotent.
  func startMemorySampling() {
    guard memorySamplingTask == nil else { return }
    memorySamplingTask = Task { [weak self] in
      while !Task.isCancelled {
        // The ps + Mach sampling runs on a detached task; the `await` SUSPENDS the
        // main actor (never blocks it) and we only publish the result here.
        let sample = await Task.detached { MemorySampler.sample(runsRootPath: HostCleanup.runsRoot().path) }
          .value
        guard let self, !Task.isCancelled else { break }
        self.appendMemorySample(sample)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }
  }

  /// Stop the live memory sampler (window closed).
  func stopMemorySampling() {
    memorySamplingTask?.cancel()
    memorySamplingTask = nil
  }

  private func appendMemorySample(_ sample: MemorySample) {
    memorySamples.append(sample)
    if memorySamples.count > Self.maxMemorySamples {
      memorySamples.removeFirst(memorySamples.count - Self.maxMemorySamples)
    }
  }

  // MARK: GitHub Actions logs (inline, on-demand)

  /// In-app log view state for a past run, keyed by the runner name
  /// (`RunRecord.id`). Each ephemeral runner ran exactly one job, so this maps
  /// one run → one job's log.
  enum JobLogState: Sendable, Equatable {
    case loading
    case loaded(job: WorkflowJob?, lines: [String])
    case unavailable(String)
  }
  @Published var jobLogs: [String: JobLogState] = [:]

  /// Live-job lookup state for a currently-online runner, keyed by runner name.
  /// Used to show the running job's step checklist (GitHub doesn't expose a live
  /// log stream, but the Jobs API returns per-step status).
  enum RunnerJobState: Sendable, Equatable {
    case loading
    case found(WorkflowJob)
    case notFound
  }
  @Published var runnerJobs: [String: RunnerJobState] = [:]

  private func client(forRepo repo: String) -> GitHubClient? {
    guard let token = TokenStore.load() else { return nil }
    let parts = repo.split(separator: "/")
    guard parts.count == 2 else { return nil }
    return GitHubClient(owner: String(parts[0]), repo: String(parts[1]), token: token)
  }

  /// Fetch (and cache) a past run's GitHub Actions job log for inline display.
  /// Correlates by the unique runner name, then downloads the job log. Cheap to
  /// re-call: returns the cached result unless `force`.
  func loadJobLog(for record: RunRecord, force: Bool = false) async {
    if !force, let state = jobLogs[record.id], case .loaded = state { return }
    guard let client = client(forRepo: record.repo) else {
      jobLogs[record.id] = .unavailable("Sign in to GitHub to fetch logs.")
      return
    }
    jobLogs[record.id] = .loading
    // `findJob` / `fetchJobLog` are nonisolated async, so they run OFF the main
    // actor (the awaits suspend it, never block) AND respect cancellation: closing
    // the dashboard cancels this `.task`, which cancels the in-flight URLSession
    // calls. (Task.detached would have detached from that cancellation.)
    guard let job = await client.findJob(runnerName: record.id, since: record.startedAt) else {
      jobLogs[record.id] = .unavailable(
        "No matching job found on GitHub — it may have expired, or GitHub hasn't indexed it yet.")
      // Leave `jobConclusion` untouched: a transient indexing miss must not get
      // stamped as a permanent state — the row keeps its honest provisional status
      // and self-heals on the next fetch.
      return
    }
    let text = (try? await client.fetchJobLog(jobId: job.id)) ?? ""
    jobLogs[record.id] = .loaded(job: job, lines: await splitLines(text))
    // Back-fill the TRUE result so History stops trusting the agent exit code.
    updateRunConclusion(
      record.id,
      to: .resolve(status: job.status, conclusion: job.conclusion, exitStatus: record.exitStatus))
  }

  /// Patch the resolved GitHub conclusion onto a recorded run (in memory + disk).
  /// No-ops when unchanged so it never churns the history file. Re-persists through
  /// the existing serialized `persistHistory()` chain (no new queue).
  private func updateRunConclusion(_ id: String, to conclusion: RunRecord.JobConclusion) {
    guard let i = runHistory.firstIndex(where: { $0.id == id }),
      runHistory[i].jobConclusion != conclusion
    else { return }
    runHistory[i].jobConclusion = conclusion
    persistHistory()
  }

  /// Back-fill conclusions for the most recent unresolved runs so History rows
  /// show the true status without opening each one. Bounded + on-demand (driven by
  /// the History pane's `.task`), never a poller. Batched per repo: one recent-runs
  /// sweep resolves every pending runner from that repo, so it costs ~one sweep per
  /// repo rather than one per row.
  func resolveRecentConclusions(limit: Int = 12) async {
    let unresolved = runHistory.prefix(limit).filter { $0.jobConclusion == nil }
    guard !unresolved.isEmpty else { return }
    for (repo, records) in Dictionary(grouping: unresolved, by: { $0.repo }) {
      if Task.isCancelled { return }
      guard let client = client(forRepo: repo),
        let jobs = await client.recentJobs(since: records.map(\.startedAt).min() ?? Date())
      else { continue }
      for record in records {
        guard let job = GitHubClient.pickJob(jobs, runnerName: record.id) else { continue }
        updateRunConclusion(
          record.id,
          to: .resolve(status: job.status, conclusion: job.conclusion, exitStatus: record.exitStatus))
      }
    }
  }

  /// Split text into lines off the main actor (nonisolated async) so a large log
  /// never churns the main thread when it's stored/rendered.
  private nonisolated func splitLines(_ text: String) async -> [String] {
    text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  /// Look up the job a currently-online runner is executing (for the live step
  /// checklist). Re-callable on a poll; updates the cached entry in place.
  /// Poll GitHub for which of our runners are BUSY (executing a job) so the
  /// dashboard's activity ring spins only during a real job — not for an idle but
  /// online runner. Cheap: one `listRunners` per selected repo. Driven by the
  /// Runners pane's `.task` while it's visible; clears itself when offline.
  func refreshRunnerBusy() async {
    guard state == .online, let token = TokenStore.load() else {
      if !busyRunnerNames.isEmpty { busyRunnerNames = [] }
      return
    }
    var busy: Set<String> = []
    for repo in selectedRepos {
      let client = GitHubClient(owner: repo.owner, repo: repo.name, token: token)
      if let remote = try? await client.listRunners() {
        for runner in remote where runner.busy { busy.insert(runner.name) }
      }
    }
    busyRunnerNames = busy
  }

  func loadRunnerJob(for runnerName: String, repo: String) async {
    guard let client = client(forRepo: repo) else {
      runnerJobs[runnerName] = .notFound
      return
    }
    if runnerJobs[runnerName] == nil { runnerJobs[runnerName] = .loading }
    let since = Date().addingTimeInterval(-3 * 3600)  // runner came up recently
    // Structured await: off-main (nonisolated async) + cancels when the runner is
    // deselected / the dashboard closes.
    let job = await client.findJob(runnerName: runnerName, since: since)
    runnerJobs[runnerName] = job.map(RunnerJobState.found) ?? .notFound
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
