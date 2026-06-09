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

  // Config. The whole per-(repo,platform) plan is ONE published value, persisted
  // as JSON under `fleetPlanV2`; `selectedRepos` is derived from it. This replaces
  // the old flat globals (selectedRepos/selectedOSes/labelsText/runnersPerRepo),
  // which only ever applied one uniform combo to every repo.
  @Published var plan = FleetPlan()
  /// The configured repos (derived from the plan) — for call sites that just need
  /// the repo list (orphan reaping, busy polling, the add-repo picker's checkmarks).
  var selectedRepos: [RepoRef] { plan.repos.map(\.repo) }
  /// OAuth App client id for device-flow sign-in. Optional.
  @Published var clientId = ""

  // Windows runner (OPT-IN — nothing heavy happens until the user clicks the
  // "Set up Windows runner" button). All persisted to UserDefaults.
  /// Set once the one-time base-image build has succeeded. Gates the Windows OS
  /// tile: Windows isn't selectable until an image exists.
  @Published var windowsImageReady = false
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

  // Linux runner (OPT-IN — like Windows, nothing heavy happens until the user
  // taps the Linux tile to set it up). Each ephemeral runner is a throwaway
  // container; "setup" is just pulling the official runner image (seconds), not a
  // 30–40 min base build. All persisted to UserDefaults.
  /// Set once the runner image is pulled AND a container daemon is up. Gates the
  /// Linux OS tile: Linux isn't selectable until the image is ready.
  @Published var linuxImageReady = false
  /// The runner container image (official `ghcr.io/actions/actions-runner`,
  /// multi-arch; the native arm64 variant runs on Apple Silicon). Persisted;
  /// defaults to the `:latest` tag.
  @Published var linuxRunnerImage = LinuxRunnerImage.imageRef()
  /// True while the image pull is running. Disables the tile so it can't double-fire.
  @Published var linuxSetupBusy = false
  /// The current phase of Linux setup (verify daemon → pull image), driven by
  /// streaming the pull output (`LinuxSetupProgress`). `nil` when none is running.
  @Published var linuxSetupStep: LinuxSetupStep?
  @Published var linuxSetupDetail: String?
  /// After a FAILED setup: a user-facing explanation that persists until the next
  /// attempt. `linuxSetupFailureIsExternal` flags a transient registry/network
  /// blip ("not your setup — retry") vs a local cause (no daemon / no runtime).
  @Published var linuxSetupFailure: String?
  @Published var linuxSetupFailureIsExternal = false
  /// Durable transcript of the last image pull (drives a "View pull log" button).
  @Published var linuxBuildLogPath: String?

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

  /// Map a GitHub Actions API failure to a user-facing reason. A 403/404 on the
  /// runs/jobs endpoints almost always means the signed-in token can register
  /// runners (Administration scope) but can't READ Actions — the single most
  /// common cause of "steps/logs never show". Surfaced instead of being swallowed
  /// as a silent "no job".
  static func actionsErrorMessage(_ error: Error) -> String {
    if case let GitHubClient.ClientError.http(code, _) = error, code == 403 || code == 404 {
      return
        "GitHub returned \(code) reading this repo's Actions. The signed-in token can register runners but may lack \"Actions: read\" — reconnect with a classic token that has the `repo` scope, or a fine-grained token with Actions: Read-only."
    }
    return "Couldn't reach GitHub Actions: \(error.localizedDescription)"
  }
  @Published var statusMessage: String?
  /// Finished runs (newest first), surfaced in the dashboard window's history.
  /// Loaded from disk on launch and appended to as runners exit; persisted off
  /// the main actor. "Past runs since turning on" — and across restarts.
  @Published var runHistory: [RunRecord] = []

  // In-app Settings presentation. The primary window is an AppKit-hosted
  // NSWindow, so the SwiftUI `Settings` scene's `showSettingsWindow:` action
  // never reaches a responder from here — the old toolbar gear was a dead button.
  // Instead we present `SettingsRootView` in our own NON-MODAL companion window
  // (SettingsWindowController), so settings live IN the app (the user's ask) yet
  // don't overlay the live runner list or trap a running base build the way a
  // modal sheet did.
  /// Which Settings tab to open on present — lets a "needs setup" tap on a
  /// platform tile jump straight to the Windows / Linux tab.
  @Published var settingsTab: SettingsTab = .general

  /// Open the Settings window, optionally on a specific tab.
  func presentSettings(_ tab: SettingsTab = .general) {
    settingsTab = tab
    SettingsWindowController.shared.show()
  }

  /// A persistent, dismissible error for BLOCKING failures (sign-in failed,
  /// go-online refused). `statusMessage` is transient — the next action
  /// overwrites it and it's invisible behind windows — so a failure the user must
  /// act on would otherwise vanish unseen. This stays until dismissed or the next
  /// attempt clears it. Shown as a banner at the top of the dashboard.
  @Published var errorBanner: String?

  /// Surface a blocking failure both as the persistent banner and the status line.
  private func reportBlockingError(_ message: String) {
    errorBanner = message
    statusMessage = message
  }

  /// One orchestrator per combo, keyed `<owner/name>#<RunnerOS.rawValue>`.
  private var orchestrators: [String: RunnerOrchestrator] = [:]
  /// The OS each orchestrator key belongs to, so the live runner list can show
  /// the right logo. Same keys as `orchestrators`; cleared together.
  private var fleetOS: [String: RunnerOS] = [:]
  /// The bare `owner/name` each orchestrator key belongs to, so `sync()` maps a
  /// runner back to its repo without parsing the key. Same keys; cleared together.
  private var fleetRepo: [String: String] = [:]
  /// Bumped on every goOnline/goOffline so a slow goOnline Task (e.g. blocked
  /// on the agent download) can detect that the user went offline meanwhile and
  /// abort instead of reviving a dead fleet.
  private var fleetEpoch = 0
  private let defaults = UserDefaults.standard

  init() {
    clientId = defaults.string(forKey: "clientId") ?? ""
    windowsImageReady = defaults.bool(forKey: "windowsImageReady")
    windowsBaseImage = defaults.string(forKey: "windowsBaseImage") ?? windowsBaseImage
    windowsBuildShowsWindow = defaults.bool(forKey: "windowsBuildShowsWindow")
    windowsKeepFailedDisk = defaults.bool(forKey: "windowsKeepFailedDisk")
    linuxImageReady = defaults.bool(forKey: "linuxImageReady")
    linuxRunnerImage = defaults.string(forKey: "linuxRunnerImage") ?? linuxRunnerImage
    linuxBuildLogPath = Self.latestLinuxPullLogPath()
    // Re-point "View build log" at the newest transcript on disk (cheap dir
    // listing) and recompose the base summary — both survive restarts.
    windowsBuildLogPath = Self.latestBuildLogPath()
    refreshWindowsBaseInfo()
    // Load the per-(repo,platform) plan. New key `fleetPlanV2` (JSON); if absent
    // (upgrade from the flat model), migrate the four legacy flat keys into one
    // FleetPlan that reproduces today's exact go-online fleet, then persist it
    // once. The legacy keys are LEFT in place for one release (downgrade-safe).
    if let data = defaults.data(forKey: "fleetPlanV2"),
      let decoded = try? JSONDecoder().decode(FleetPlan.self, from: data)
    {
      plan = decoded
    } else {
      let oses = RunnerOS.restoreSelection(
        savedRawValues: defaults.stringArray(forKey: "selectedOSes"),
        legacyWindowsEnabled: defaults.bool(forKey: "windowsEnabled"),
        windowsImageReady: windowsImageReady)
      plan = FleetPlan.migrate(
        repoFullNames: defaults.stringArray(forKey: "selectedRepos") ?? [],
        oses: oses,
        labels: Self.parseLabels(defaults.string(forKey: "labels") ?? ""),
        runnersPerRepo: max(1, defaults.integer(forKey: "runnersPerRepo")),
        windowsImageReady: windowsImageReady,
        linuxImageReady: linuxImageReady)
      defaults.set(try? JSONEncoder().encode(plan), forKey: "fleetPlanV2")
    }
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
    defaults.set(try? JSONEncoder().encode(plan), forKey: "fleetPlanV2")
    defaults.set(clientId, forKey: "clientId")
    defaults.set(windowsImageReady, forKey: "windowsImageReady")
    defaults.set(windowsBaseImage, forKey: "windowsBaseImage")
    defaults.set(windowsBuildShowsWindow, forKey: "windowsBuildShowsWindow")
    defaults.set(windowsKeepFailedDisk, forKey: "windowsKeepFailedDisk")
    defaults.set(linuxImageReady, forKey: "linuxImageReady")
    defaults.set(linuxRunnerImage, forKey: "linuxRunnerImage")
  }

  /// Parse a comma-separated label string into a trimmed, non-empty token list.
  static func parseLabels(_ text: String) -> [String] {
    text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  // MARK: Plan mutation (the per-(repo,platform) config)
  //
  // Per-combo edits (enable/count/labels) are allowed WHILE ONLINE: the live
  // orchestrators snapshot the plan at go-online and don't re-read it, so editing
  // can't race them — it just won't take effect until the fleet restarts. We mark
  // `pendingRestart` so the UI offers a one-click "restart fleet to apply" instead
  // of forcing a full manual offline→edit→online cycle for a one-character label
  // fix. Repo ADD/REMOVE stays offline-only: the live grid is keyed off
  // `plan.repos`, so removing a repo online would hide a still-running runner.

  /// Set true when a per-combo edit lands while the fleet is live (not offline),
  /// so the change is staged but not yet applied. Cleared on go-online/go-offline.
  @Published var pendingRestart = false

  /// Content for the dashboard "a runner base needs a rebuild" banner — the
  /// prominent, always-visible analog of `pendingRestart`, so a stale base is
  /// noticeable on the dashboard instead of buried in the Settings pane. The
  /// fleet keeps running on the existing base (non-blocking), so this is a nudge,
  /// not a gate; the action deep-links to the pane that rebuilds it.
  struct RebuildNotice: Equatable {
    let text: String
    /// SF Symbol (data, not a view) matching the reason — keeps the dashboard
    /// bar and the Settings banner visually consistent.
    let icon: String
    /// Where "Rebuild…" jumps so the user lands on the actual rebuild controls.
    let tab: SettingsTab
  }

  /// The active rebuild nudge, or `nil` when every runner base is current.
  ///
  /// Only Windows has a rebuild lifecycle today: its base image is the one
  /// cached/auto-refreshed artifact, so it can drift (a newer Win11 build, or an
  /// updated provisioning recipe). macOS runs the agent on the bare host and
  /// refreshes the cached template automatically on go-online, and Linux pulls
  /// the official runner image (no recipe to drift) — neither surfaces a rebuild
  /// nudge. New rebuildable bases plug their own branch in here and the dashboard
  /// banner renders them with no further wiring.
  var rebuildNotice: RebuildNotice? {
    if windowsMaintenance.needsRebuild, let notice = windowsUpdateNotice {
      let icon: String
      switch windowsMaintenance {
      case .osBuildAvailable: icon = "arrow.up.circle"
      case .provisioningOutdated: icon = "wrench.and.screwdriver"
      case .both: icon = "exclamationmark.triangle"
      case .upToDate, .notBuilt: icon = "arrow.clockwise.circle"
      }
      return RebuildNotice(text: notice, icon: icon, tab: .windows)
    }
    return nil
  }

  func isSelected(_ repo: RepoRef) -> Bool { plan.repos.contains { $0.repo == repo } }

  /// Add (with default platforms) or remove a repo. Used by the add-repo picker.
  /// Offline-only: the live grid is keyed off `plan.repos`, so changing membership
  /// online would desync the displayed fleet from the running one.
  func toggleRepo(_ repo: RepoRef) {
    guard state == .offline else { return }
    if isSelected(repo) { plan.removeRepo(id: repo.fullName) } else { plan.addRepo(repo) }
    saveConfig()
  }

  func addRepo(_ repo: RepoRef) {
    guard state == .offline else { return }
    plan.addRepo(repo)
    saveConfig()
  }

  func removeRepo(id: String) {
    guard state == .offline else { return }
    plan.removeRepo(id: id)
    saveConfig()
  }

  /// Note a per-combo edit: persist, and if the fleet is live flag a pending
  /// restart so the change is applied on the next go-online. Gated to the STABLE
  /// `.online` state (not just `!= .offline`): edits are UI-disabled during the
  /// transient `.starting`/`.stopping` restart window (see `isTransitioning`), so
  /// an edit can't land after goOnline snapshots the plan yet before it clears the
  /// flag — which would silently strand the edit (unapplied but not flagged).
  /// Invariant: `pendingRestart == true` ⟹ `state == .online`.
  private func noteComboEdit() {
    saveConfig()
    if state == .online { pendingRestart = true }
  }

  /// True during the brief go-online / go-offline transition. Config edit controls
  /// disable on it (like the Go-online button) so nothing races the snapshot.
  var isTransitioning: Bool { state == .starting || state == .stopping }

  /// Enable/disable a `(repo, platform)` combo (the inspector's platform toggle).
  func setPlatform(_ os: RunnerOS, enabled: Bool, repoID: String) {
    plan.setPlatform(os, enabled: enabled, in: repoID)
    noteComboEdit()
  }

  /// Set a combo's runner count (any platform; go-online's RAM/CPU budget still
  /// caps the live Windows/Linux total).
  func setCount(_ count: Int, os: RunnerOS, repoID: String) {
    plan.setCount(count, os: os, in: repoID)
    noteComboEdit()
  }

  /// Set a combo's labels from a comma-separated string.
  func setLabels(_ text: String, os: RunnerOS, repoID: String) {
    plan.setLabels(Self.parseLabels(text), os: os, in: repoID)
    noteComboEdit()
  }

  /// Apply staged per-combo edits to the live fleet: take it offline, then back
  /// online (which re-reads the plan). The one-click form of the manual cycle.
  func restartFleet() {
    guard state != .offline else { return }
    Task {
      await goOfflineAndWait()
      goOnline()
    }
  }

  // MARK: New-repo defaults (Settings → General)

  var defaultMacOSLabelsText: String { plan.defaultMacOSLabels.joined(separator: ", ") }

  func setDefaultMacOSLabels(_ text: String) {
    plan.defaultMacOSLabels = Self.parseLabels(text)
    saveConfig()
  }

  func setDefaultMacOSCount(_ count: Int) {
    plan.defaultMacOSCount = max(1, min(5, count))
    saveConfig()
  }

  /// Whether a platform is auto-enabled on a freshly-added repo.
  func isDefaultPlatform(_ os: RunnerOS) -> Bool { plan.defaultPlatforms.contains(os.rawValue) }

  func setDefaultPlatform(_ os: RunnerOS, on: Bool) {
    var set = Set(plan.defaultPlatforms)
    if on { set.insert(os.rawValue) } else { set.remove(os.rawValue) }
    plan.defaultPlatforms = RunnerOS.allCases.map(\.rawValue).filter { set.contains($0) }
    saveConfig()
  }

  // MARK: Auth

  var gitHubCLIAvailable: Bool { GitHubCLIAuth.isAvailable() }

  func signInWithGitHubCLI() {
    do {
      let token = try GitHubCLIAuth.currentToken()
      try TokenStore.save(token)
      isSignedIn = true
      errorBanner = nil
      statusMessage = "Signed in via GitHub CLI."
      Task { await loadRepos() }
    } catch {
      reportBlockingError("Couldn't use the GitHub CLI login: \(error.localizedDescription)")
    }
  }

  func signInWithDeviceFlow() {
    guard !clientId.isEmpty else {
      reportBlockingError("Add an OAuth client id in Settings, or paste a token below.")
      return
    }
    authBusy = true
    statusMessage = nil
    errorBanner = nil
    Task {
      do {
        let code = try await GitHubAuth.requestDeviceCode(clientId: clientId)
        pendingDeviceCode = code
        NSWorkspace.shared.open(code.verificationURI)
        let token = try await GitHubAuth.pollForToken(clientId: clientId, deviceCode: code)
        try TokenStore.save(token)
        isSignedIn = true
        errorBanner = nil
        statusMessage = "Signed in."
        await loadRepos()
      } catch {
        reportBlockingError("Sign-in failed: \(error.localizedDescription)")
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
      errorBanner = nil
      statusMessage = "Token saved."
      Task { await loadRepos() }
    } catch {
      reportBlockingError("Couldn't store the token: \(error.localizedDescription)")
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
      // Drop any configured repo the account can no longer admin.
      let admin = Set(repos)
      let before = plan.repos.count
      plan.repos.removeAll { !admin.contains($0.repo) }
      if plan.repos.count != before { saveConfig() }
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
    errorBanner = nil  // a fresh attempt clears any prior blocking error
    guard let token = TokenStore.load() else { reportBlockingError("Sign in to GitHub first."); return }
    guard !plan.repos.isEmpty else { reportBlockingError("Add a repository first."); return }
    let combos = plan.enabledCombos()
    guard !combos.isEmpty else {
      reportBlockingError("Enable at least one platform for a repo (select it on the left to configure).")
      return
    }
    // Per-combo editable labels are the top silent-failure risk — a combo whose
    // labels are empty or drop `self-hosted` would register a runner no workflow
    // can target. Hard-block here rather than let the job hang unmatched.
    let invalid = plan.invalidCombos()
    guard invalid.isEmpty else {
      let names = invalid.map { "\($0.repo.name) (\($0.os.displayName))" }.joined(separator: ", ")
      reportBlockingError(
        "Fix labels for: \(names). Each combo's labels must be non-empty and include `self-hosted`.")
      return
    }
    // The Windows base image is mid-(re)build — going online would clone a base
    // that's being wiped/rebuilt. Make the UI disable a hard guard too.
    guard !windowsSetupBusy else {
      reportBlockingError("Finish building the Windows base image before going online.")
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
      // provisioning, so this machine's prefix is provably a prior-session
      // orphan. Also delete offline/non-busy `mactions-*` ghosts from older
      // host-name generations; online or busy runners from another Mac are kept.
      // Per-repo, best-effort.
      for repo in repos {
        guard fleetEpoch == myEpoch else { return }
        await deregisterOrphanRunners(
          GitHubClient(owner: repo.owner, repo: repo.name, token: token),
          includeOfflineMactionsRunners: true)
      }
      guard fleetEpoch == myEpoch else { return }
      var created: [RunnerOrchestrator] = []
      do {
        let wantsMac = combos.contains { $0.os == .macOS }
        let windowsCombos = combos.filter { $0.os == .windows }
        let linuxCombos = combos.filter { $0.os == .linux }
        // Total runners ASKED for per OS (Σ per-combo counts) — the denominator
        // for the "limited to X/Y" status when the budget caps below the plan.
        let windowsRequested = windowsCombos.reduce(0) { $0 + $1.config.count }
        let linuxRequested = linuxCombos.reduce(0) { $0 + $1.config.count }
        // Only fetch the macOS agent template when a macOS combo is actually
        // wanted — a Windows/Linux-only plan needs no local agent.
        let factory: LocalProcessProviderFactory?
        if wantsMac {
          let template = try await RunnerInstaller.ensureInstalled(token: token)
          guard fleetEpoch == myEpoch else { return }  // went offline during download
          factory = LocalProcessProviderFactory(
            templateDirectory: template, runsRoot: HostCleanup.runsRoot())
        } else {
          factory = nil
        }
        // Windows fleet: only when a Windows combo exists AND a base image exists
        // AND VMware Fusion is installed. Never spun up automatically. Fusion is
        // the sole backend (the proven Win11-ARM path).
        let windowsFactory: WindowsVMProviderFactory? =
          (!windowsCombos.isEmpty && windowsImageReady)
          ? WindowsVMProviderFactory.detectInstalledCLI().map {
            WindowsVMProviderFactory(baseImage: windowsBaseImage, cli: $0)
          }
          : nil
        // Cap concurrent Windows VMs to what this Mac's RAM can run without
        // thrashing — each clone is a full VM, so N combos each booting one would
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
        // Linux fleet: only when a Linux combo exists, a container runtime is
        // installed, AND it's actually ready right now. Re-verify ready() (daemon
        // up + image present) here because the persisted linuxImageReady can be
        // stale (image pruned / daemon stopped) — and a dead-daemon `<cli> run`
        // fails ASYNC (not a throw from start()), so without this gate the
        // orchestrator would churn JIT configs retrying a failing container. The
        // probe shells out, so run it off the main actor.
        let linuxImg = linuxRunnerImage
        let linuxCLI =
          (!linuxCombos.isEmpty && linuxImageReady)
          ? LinuxContainerProviderFactory.detectInstalledCLI() : nil
        var linuxReady = false
        if let lxCLI = linuxCLI {
          linuxReady = await Task.detached { [lxCLI, linuxImg] in
            LinuxContainerProviderFactory.ready(image: linuxImg, cli: lxCLI)
          }.value
        }
        guard fleetEpoch == myEpoch else { return }  // went offline during the probe
        let linuxFactory: LinuxContainerProviderFactory? =
          linuxReady ? linuxCLI.map { LinuxContainerProviderFactory(image: linuxImg, cli: $0) } : nil
        // Containers are far lighter than a Fusion VM (sub-second start, shared
        // kernel), so the cap is CPU/RAM-driven and looser than the Windows VM
        // budget. 0 => host can't fit even one safely (skip Linux + say so).
        let maxLinux =
          linuxFactory == nil
          ? 0
          : LinuxContainerBudget.maxConcurrentContainers(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount)
        var linuxStamped = 0

        // Stand up one orchestrator per combo, keyed `<owner/name>#<os>` so the
        // live list maps cleanly back to repo + OS (no fragile suffix parsing).
        @MainActor func addOrchestrator(
          repo: RepoRef, os: RunnerOS, factory: RunnerProviderFactory,
          labels: [String], count: Int
        ) async {
          let client = GitHubClient(owner: repo.owner, repo: repo.name, token: token)
          let fleet = FleetConfig(
            owner: repo.owner, repo: repo.name, labels: labels, desiredCount: count)
          let orch = RunnerOrchestrator(
            controlPlane: client, factory: factory, config: fleet, os: os)
          orch.onChange = { [weak self] in self?.sync() }
          orch.onRunFinished = { [weak self] record in self?.recordRun(record) }
          let key = "\(repo.fullName)#\(os.rawValue)"
          orchestrators[key] = orch
          fleetOS[key] = os
          fleetRepo[key] = repo.fullName
          created.append(orch)
          await orch.start()
        }

        for combo in combos {
          guard fleetEpoch == myEpoch else { break }
          switch combo.os {
          case .macOS:
            guard wantsMac, let factory else { continue }
            await addOrchestrator(
              repo: combo.repo, os: .macOS, factory: factory,
              labels: combo.config.labels, count: combo.config.count)
          case .windows:
            guard let windowsFactory else { continue }
            // Grant up to this combo's requested count, bounded by the RAM
            // budget's remaining headroom (shared across every Windows combo).
            // 0 left ⇒ skip this combo (the status line reports the shortfall).
            let grant = min(combo.config.count, maxWindowsVMs - windowsVMsStamped)
            guard grant > 0 else { continue }
            windowsVMsStamped += grant
            await addOrchestrator(
              repo: combo.repo, os: .windows, factory: windowsFactory,
              labels: combo.config.labels, count: grant)
          case .linux:
            guard let linuxFactory else { continue }
            let grant = min(combo.config.count, maxLinux - linuxStamped)
            guard grant > 0 else { continue }
            linuxStamped += grant
            await addOrchestrator(
              repo: combo.repo, os: .linux, factory: linuxFactory,
              labels: combo.config.labels, count: grant)
          }
        }
        guard fleetEpoch == myEpoch else {
          for orch in created { await orch.stop() } // user went offline; undo
          return
        }
        state = .online
        errorBanner = nil  // came online cleanly — clear any prior blocking error
        pendingRestart = false  // the live fleet now matches the plan
        sync()
        let live = orchestrators.values.reduce(0) { $0 + $1.runners.count }
        let repoCount = Set(combos.map { $0.repo.fullName }).count
        statusMessage =
          live == 0
          ? "Online, but no runners came up — check repo permissions / labels."
          : "Online: \(live) runner\(live == 1 ? "" : "s") across \(repoCount) repo\(repoCount == 1 ? "" : "s")."
        // If the RAM budget kept some Windows runners from coming up, say so
        // (silent under-provisioning reads as a bug). Denominator = total Windows
        // runners the plan asked for (Σ per-combo counts), not all repos.
        if windowsFactory != nil, windowsVMsStamped < windowsRequested {
          let why =
            maxWindowsVMs == 0
            ? "this Mac's RAM can't safely run a \(perVMGB) GB Windows VM"
            : "RAM budget allows \(maxWindowsVMs) at once"
          statusMessage =
            (statusMessage ?? "")
            + " Windows runners limited to \(windowsVMsStamped)/\(windowsRequested) (\(why))."
        }
        if linuxFactory != nil, linuxStamped < linuxRequested {
          let why =
            maxLinux == 0
            ? "this Mac can't safely run a Linux container"
            : "capacity allows \(maxLinux) at once"
          statusMessage =
            (statusMessage ?? "")
            + " Linux runners limited to \(linuxStamped)/\(linuxRequested) (\(why))."
        }
        // A Windows combo was enabled but no base image / Fusion → say so instead
        // of silently skipping it.
        if !windowsCombos.isEmpty, windowsFactory == nil {
          statusMessage =
            (statusMessage ?? "")
            + (windowsImageReady
              ? " Windows skipped — install VMware Fusion (Settings → Windows)."
              : " Windows skipped — build the base image (Settings → Windows).")
        }
        // A Linux combo was enabled but the runtime/image isn't ready → say which.
        if !linuxCombos.isEmpty, linuxFactory == nil {
          let detail: String
          if !linuxImageReady {
            detail = "pull the runner image (Settings → Linux)"
          } else if linuxCLI == nil {
            detail = "install a container runtime (Settings → Linux)"
          } else {
            detail = "start the container daemon or re-pull (Settings → Linux)"
          }
          statusMessage = (statusMessage ?? "") + " Linux skipped — \(detail)."
        }
      } catch {
        guard fleetEpoch == myEpoch else { return }
        reportBlockingError("Failed to start: \(error.localizedDescription)")
        state = .offline
        // Back offline (nothing live) — keep the invariant that a restart bar
        // only shows online. The edits are still in the plan and apply on the
        // next go-online; the error banner explains the failure.
        pendingRestart = false
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
    fleetRepo.removeAll()
    // Each run wipes its own working copy; sweep again defensively.
    HostCleanup.purgeRuns()
    runners = []
    busyRunnerNames = []
    pendingRestart = false  // nothing live to be out of sync with
    errorBanner = nil  // a prior blocking error is moot once we're cleanly offline
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
          let purgedBackups = await Task.detached { HostCleanup.purgeWindowsBaseBackups() }.value
          refreshWindowsBaseInfo()  // pick up the fresh build/recipe/health stamps
          statusMessage =
            "Windows base image '\(image)' is ready."
            + (purgedBackups > 0
              ? " Cleaned up \(purgedBackups) old base backup\(purgedBackups == 1 ? "" : "s")."
              : "")
        } else {
          windowsImageReady = false  // never persist a stale-true
          saveConfig()
          statusMessage =
            "Windows prep finished. Complete the one-time install per the printed steps, shut the VM down, then run \"Set up Windows runner\" again to confirm."
        }
      } else {
        refreshWindowsBaseInfo()
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

  /// Fixed guest-provisioning transcript paths written by `fusion-windows-base`.
  /// These are removed at the start of each build and re-copied while VMware
  /// Tools is up, so if they exist they describe the latest attempt.
  private static func latestGuestBuildLogPath() -> String? {
    let dir = HostCleanup.logsRoot()
    for name in ["base-build-bootstrap.log", "base-build-bootstrap-timeout.log"] {
      let path = dir.appendingPathComponent(name).path
      if FileManager.default.fileExists(atPath: path) { return path }
    }
    return nil
  }

  /// Recompose the base summary line + guest-log pointer from the recorded
  /// build/recipe/health files. Cheap (three tiny file reads); called on launch,
  /// when the Setup pane appears, and after a successful build.
  func refreshWindowsBaseInfo() {
    var parts: [String] = []
    if let build = WindowsImage.recordedBaseImageBuild() { parts.append("Windows \(build)") }
    if let recipe = WindowsImage.recordedRecipeVersion() { parts.append("recipe v\(recipe)") }
    if let health = WindowsImage.recordedBaseHealth() {
      if let built = health.builtAt { parts.append("built \(built.prefix(10))") }
      if health.toolsUp { parts.append("VMware Tools ✓") }
      if let secs = health.elapsedSecs, secs >= 60 { parts.append("\(secs / 60) min build") }
      // Only surface the guest log while it actually exists (purge-able).
      windowsGuestLogPath = health.guestLogPath.flatMap {
        FileManager.default.fileExists(atPath: $0) ? $0 : nil
      } ?? Self.latestGuestBuildLogPath()
    } else {
      windowsGuestLogPath = Self.latestGuestBuildLogPath()
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
    // Recipe dimension first — local, instant, every onAppear.
    applyMaintenance(
      WindowsImage.maintenanceReason(
        recordedBuild: WindowsImage.recordedBaseImageBuild(),
        recordedRecipe: WindowsImage.recordedRecipeVersion(),
        latestBuild: lastKnownLatestBuild))
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
          latestBuild: latest.build))
    }
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

  // MARK: Linux runner (opt-in)

  /// True if a container runtime — Apple `container` (macOS 26+) or a `docker`
  /// CLI (typically Colima-managed) — is installed. Linux runners aren't
  /// offerable without one. Presence-only, like `windowsBackendAvailable`.
  var linuxBackendAvailable: Bool { LinuxContainerProviderFactory.detectInstalledCLI() != nil }

  /// Human name of the detected container backend (for the preflight line), or
  /// `nil` if none is installed.
  var linuxBackendName: String? { LinuxContainerProviderFactory.detectInstalledCLI()?.displayName }

  /// Set up the Linux runner: confirm a container daemon is up (starting it
  /// idempotently if needed), then pull the official runner image. FAST — the
  /// pull is seconds, not the Windows base build's 30–40 min, so the stepper is
  /// just verify-daemon → pull-image. `force: true` (the "Re-pull / update image"
  /// button) re-pulls even if the image is already recorded; `force: false` (the
  /// initial tile tap) fast-paths when the image is already present + daemon up.
  func setUpLinuxRunner(force: Bool = false) {
    guard state == .offline else { statusMessage = "Go offline first."; return }
    guard !linuxSetupBusy else { return }
    guard let cli = LinuxContainerProviderFactory.detectInstalledCLI() else {
      statusMessage =
        "No container runtime found. Install one (free): Apple container from github.com/apple/container/releases (macOS 26+), or `brew install colima docker`. Then tap Linux again."
      return
    }
    let image = linuxRunnerImage
    // FAST PATH (non-forced): image already present + daemon up → flip ready
    // directly, so a stray re-tap doesn't re-pull. A forced "update image"
    // deliberately re-pulls.
    if !force, LinuxContainerProviderFactory.ready(image: image, cli: cli) {
      linuxImageReady = true
      saveConfig()
      linuxSetupFailure = nil
      statusMessage = "Linux runner image '\(image)' is ready (\(cli.displayName))."
      return
    }
    linuxSetupBusy = true
    linuxSetupStep = .verifyDaemon
    linuxSetupDetail = nil
    linuxSetupFailure = nil
    statusMessage = "Setting up the Linux runner…"
    Task {
      // 1) Ensure the daemon is up; start it if down. Apple `container` starts
      //    via its own `system start` (daemonStartArgs); the docker CLI has NO
      //    daemon-start verb (its daemonStartArgs is empty), so start Colima if
      //    installed — Docker Desktop / OrbStack must be started by the user.
      //    Off the main actor; these can block briefly.
      var daemonUp = await Task.detached {
        (try? Shell.run(cli.executable, cli.daemonStatusArgs()))?.ok ?? false
      }.value
      if !daemonUp {
        linuxSetupDetail = "Starting the container daemon…"
        let startArgs = cli.daemonStartArgs()
        await Task.detached {
          if !startArgs.isEmpty {
            _ = try? Shell.run(cli.executable, startArgs)
          } else if let colima = Shell.which("colima") {
            _ = try? Shell.run(colima, ["start"])
          }
        }.value
        daemonUp = await Task.detached {
          (try? Shell.run(cli.executable, cli.daemonStatusArgs()))?.ok ?? false
        }.value
      }
      guard daemonUp else {
        linuxSetupFailureIsExternal = false
        linuxSetupFailure =
          "The container daemon (\(cli.displayName)) isn't running and couldn't be started. Start it manually, then retry."
        statusMessage = "Linux setup failed: container daemon not running."
        endLinuxSetup()
        return
      }

      // 1b) One-time backend prep: Apple `container` needs a default Linux kernel
      // installed before any container can run (`system start` only prompts for
      // it). Runs only when needed (gated so the non-idempotent kernel download
      // isn't repeated). Docker/Colima need nothing here. Slow (~one download).
      if cli.daemonPrepareNeeded() {
        linuxSetupDetail = "Installing the container runtime kernel (one-time)…"
        _ = await Task.detached { try? Shell.run(cli.executable, cli.daemonPrepareArgs()) }.value
      }

      // 2) Pull the runner image, streaming progress into the live stepper.
      linuxSetupStep = .pullImage
      let (lines, continuation) = AsyncStream<String>.makeStream()
      let progress = Task { @MainActor in
        for await line in lines { self.applyLinuxSetupProgress(line) }
      }
      let result = await Self.runLinuxImagePull(cli, image: image) { continuation.yield($0) }
      continuation.finish()
      _ = await progress.value

      // Persist the pull transcript so a failure is diagnosable from disk.
      let pullLog = HostCleanup.writeLog(
        name: "linux-image-pull", stamp: Self.logStamp(),
        contents:
          "image=\(image)\nexit=\(result.map { String($0.status) } ?? "nil (could not launch)")\n\n"
          + "=== stdout ===\n\(result?.stdout ?? "")\n\n=== stderr ===\n\(result?.stderr ?? "")\n")
      linuxBuildLogPath = pullLog ?? linuxBuildLogPath
      endLinuxSetup()

      let isReady = await Task.detached {
        LinuxContainerProviderFactory.ready(image: image, cli: cli)
      }.value
      if let result, result.ok, isReady {
        LinuxRunnerImage.recordImageRef(image)
        linuxImageReady = true
        saveConfig()
        linuxSetupFailure = nil
        statusMessage = "Linux runner image '\(image)' is ready (\(cli.displayName))."
      } else {
        linuxImageReady = false  // never persist a stale-true
        saveConfig()
        // Classify: a registry/network blip isn't the user's setup and is safe to
        // retry; a local cause (daemon/runtime) is theirs to fix.
        let transient = LinuxSetupProgress.isLikelyTransientFailure(result?.stderr ?? "")
        linuxSetupFailureIsExternal = transient
        linuxSetupFailure =
          transient
          ? "The image pull hit a transient registry/network issue — not a problem with your Mac or setup. It's safe to retry."
          : "Couldn't pull the runner image '\(image)'. Check the container runtime and try again."
        statusMessage =
          (transient
            ? "Linux image pull hit a transient issue — safe to retry."
            : "Linux setup failed — see the pull log.")
          + (pullLog.map { " Log: \($0)" } ?? "")
      }
    }
  }

  /// Tear down the live Linux setup indicator. Paired with every exit from
  /// `setUpLinuxRunner` so the stepper never lingers.
  private func endLinuxSetup() {
    linuxSetupBusy = false
    linuxSetupStep = nil
    linuxSetupDetail = nil
  }

  /// Advance the Linux setup stepper from a line of pull output (FORWARD-ONLY) and
  /// refresh the sub-status. Called on the MainActor as the pull streams.
  private func applyLinuxSetupProgress(_ line: String) {
    if let step = LinuxSetupProgress.step(for: line) {
      linuxSetupStep = max(linuxSetupStep ?? step, step)
    }
    if let detail = LinuxSetupProgress.detail(for: line) {
      linuxSetupDetail = detail
    }
  }

  /// Run the image pull off the main actor, streaming combined output to `onLine`
  /// (for the live stepper) while capturing the full transcript for the log.
  private nonisolated static func runLinuxImagePull(
    _ cli: LinuxContainerCLI, image: String, onLine: @escaping @Sendable (String) -> Void
  ) async -> Shell.Result? {
    await Task.detached {
      try? Shell.runStreaming(cli.executable, cli.pullArgs(image: image), onLine: onLine)
    }.value
  }

  /// Newest persisted `linux-image-pull-*.log`, so "View pull log" still works
  /// after an app restart (the @Published path only covers the current session).
  private static func latestLinuxPullLogPath() -> String? {
    let dir = HostCleanup.logsRoot()
    let files =
      (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return
      files
      .map(\.lastPathComponent)
      .filter { $0.hasPrefix("linux-image-pull-") && $0.hasSuffix(".log") }
      .sorted()
      .last
      .map { dir.appendingPathComponent($0).path }
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
    /// GitHub's runner API reports the runner busy, but the jobs API hasn't
    /// published the matching job/steps yet (normal indexing lag right after a
    /// job is assigned). Distinct from `.notFound` so the detail pane shows a
    /// "running" state matching the spinner instead of "No job running".
    case running
    case found(WorkflowJob)
    case notFound
    /// The Actions API call failed (e.g. the token lacks `Actions: read`). Carries
    /// the user-facing reason so the pane explains it instead of looking idle.
    case error(String)
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
    let job: WorkflowJob?
    do {
      job = try await client.findJob(runnerName: record.id, since: record.startedAt)
    } catch {
      // A hard Actions-read failure (e.g. missing `Actions: read` scope) — surface
      // the real reason instead of an indexing-miss message. Leave `jobConclusion`
      // untouched so the row self-heals once access is fixed.
      jobLogs[record.id] = .unavailable(Self.actionsErrorMessage(error))
      return
    }
    guard let job else {
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

  /// `busy` is GitHub's runner-API verdict for this runner (from `busyRunnerNames`):
  /// it decides whether an unmatched lookup reads as `.running` (busy → job just
  /// not indexed yet) or `.notFound` (idle ephemeral runner). When the jobs API
  /// itself reports an in-progress job, the runner is also added to
  /// `runnersWithLiveJob` so the activity ring spins even if the runner API lagged.
  func loadRunnerJob(for runnerName: String, repo: String, busy: Bool) async {
    guard let client = client(forRepo: repo) else {
      runnerJobs[runnerName] = .error("Sign in to GitHub to see the running job's steps.")
      return
    }
    if runnerJobs[runnerName] == nil { runnerJobs[runnerName] = .loading }
    let since = Date().addingTimeInterval(-3 * 3600)  // runner came up recently
    // Structured await: off-main (nonisolated async) + cancels when the runner is
    // deselected / the dashboard closes. findJob throws on an Actions-read failure
    // (e.g. missing scope) so we surface it instead of mislabeling it "no job".
    do {
      let job = try await client.findJob(runnerName: runnerName, since: since)
      // No job matched yet: if the runner API says it's busy, the job just isn't
      // indexed yet (`.running`, consistent with the spinning ring); otherwise the
      // ephemeral runner is genuinely idle (`.notFound`).
      runnerJobs[runnerName] = job.map(RunnerJobState.found) ?? (busy ? .running : .notFound)
    } catch {
      runnerJobs[runnerName] = .error(Self.actionsErrorMessage(error))
    }
  }

  private func sync() {
    // Only mirror the live runner list here. We deliberately do NOT re-stamp
    // orch.lastError onto statusMessage on every change — that clobbered the
    // status line and made a single transient error look permanent.
    var rows: [FleetRunnerRow] = []
    for (key, orch) in orchestrators {
      let os = fleetOS[key] ?? .macOS
      // Map back to the bare repo via fleetRepo (the OS is conveyed by the row's
      // logo) — no fragile suffix parsing, so every OS groups under its repo.
      let repoName = fleetRepo[key] ?? key
      for runner in orch.runners {
        rows.append(FleetRunnerRow(os: os, repoFullName: repoName, runner: runner))
      }
    }
    runners = rows.sorted { $0.id < $1.id }
  }
}
