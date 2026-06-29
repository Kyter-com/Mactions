import AppKit
import MactionsCore
import SwiftUI

private let allRepositoriesSelectionID = "__mactions_all_repositories__"

/// The dashboard window — now LIVE-FIRST: the primary surface is the runner
/// fleet (repo-grouped), with **History** and **Memory** alongside it in the
/// sidebar. Configuration is no longer a tab: per-(repo,platform) combos are
/// edited in the **Configure** panel that opens when you select a repo (bound to
/// that repo), and global set-once setup lives in the in-app Settings sheet. A
/// slim header carries the live state + the controls; a bottom strip carries
/// contextual capacity.
///
/// Performance contract: everything slow (GitHub fetches, `ps`, VMX reads) runs
/// off the main actor — the views only ever read already-published state, so the
/// Mac UI never stutters while logs load or memory samples.
struct DashboardView: View {
  @EnvironmentObject private var app: AppState
  @State private var tab: Tab? = .runners
  @State private var confirmRestart = false
  /// The Runners grid selection — a repo header id (`owner/name`) or a runner
  /// child id (`owner/name#runner`). Lifted here so the Configure panel can bind
  /// to whichever repo is in focus. Selecting a repo opens its config on the
  /// right; selecting a live runner shows that runner's job detail.
  @State private var selection: String?

  enum Tab: String, CaseIterable, Identifiable {
    case runners = "Runners"
    case history = "History"
    case memory = "Memory"
    var id: String { rawValue }

    var systemImage: String {
      switch self {
      case .runners: return "bolt.horizontal"
      case .history: return "clock.arrow.circlepath"
      case .memory: return "memorychip"
      }
    }
  }

  /// The repo the Configure panel edits — derived from the grid selection
  /// (everything before the first `#`, so a runner child resolves to its repo).
  private var selectedRepoID: String? {
    guard selection != allRepositoriesSelectionID else { return nil }
    return selection?.split(separator: "#", maxSplits: 1).first.map(String.init)
  }

  var body: some View {
    VStack(spacing: 0) {
      headerBar
      Divider()
      if let error = app.errorBanner {
        errorBar(error)
        Divider()
      }
      if app.pendingRestart {
        restartBar
        Divider()
      }
      if let setup = app.setupNotice {
        actionNoticeBar(setup)
        Divider()
      }
      if let rebuild = app.rebuildNotice {
        actionNoticeBar(rebuild)
        Divider()
      }
      NavigationSplitView {
        List(Tab.allCases, selection: $tab) { item in
          Label(item.rawValue, systemImage: item.systemImage).tag(item)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
      } detail: {
        Group {
          switch tab ?? .runners {
          case .runners:
            RunnersPane(selection: $selection, selectedRepoID: selectedRepoID)
          case .history: HistoryPane()
          case .memory: MemoryPane()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      StatusStrip(message: statusText, capNote: capNote, liveNote: liveNote)
    }
    .frame(minWidth: 900, minHeight: 560)
    .onAppear {
      app.refreshWindowsPerVMGB()
      app.refreshLinuxAvailability()
      // Recompute the rebuild nudge so the dashboard banner reflects a stale base
      // immediately — previously this only ran on the Settings pane's onAppear, so
      // the banner didn't appear until the user opened Settings. Cheap: the recipe
      // dimension is a local file compare; the OS-build check is throttled to 6h.
      app.checkForWindowsImageUpdate()
    }
  }

  // MARK: Header bar (slim, native — no logo / status-dot-only / capacity chips)

  private var headerBar: some View {
    HStack(spacing: MactionsTheme.Spacing.control) {
      Circle().fill(statusColor).frame(width: 9, height: 9)
      Text(stateSubtitle).font(.callout.weight(.medium)).fixedSize()
      buildIndicator
      Spacer(minLength: MactionsTheme.Spacing.control)

      Button {
        app.presentSettings()
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .help("GitHub account, Windows/Linux base setup, and defaults (⌘,).")

      Button {
        app.toggleOnline()
      } label: {
        Label(
          app.state == .offline ? "Go online" : "Go offline",
          systemImage: app.state == .offline ? "play.fill" : "stop.fill")
      }
      .glassProminentButton()
      .keyboardShortcut("o", modifiers: .command)
      .disabled(
        // The empty-combos gate only blocks GOING online — never disable "Go
        // offline" (you can disable every platform while online now, which would
        // otherwise strand the fleet on). ALL-REPOS mode needs no explicit
        // combos: discovery finds demand across every admin repo.
        (app.state == .offline && !hasWatchableFleet)
          || app.windowsSetupBusy  // can't clone the base while it's being (re)built
          || app.state == .starting || app.state == .stopping)
      .help(
        app.windowsSetupBusy
          ? "Wait for the Windows base image to finish building before going online."
          : app.state == .offline && !hasWatchableFleet
            ? (app.plan.isAllRepos
              ? "Enable at least one default platform for all repositories."
              : "Add a repo and select it on the left to enable a platform first.")
            : app.state == .offline
              ? "Start watching for queued jobs — runners start on demand (⌘O)."
              : "Stop watching and tear down any live runners (⌘O).")
    }
    .padding(.horizontal, MactionsTheme.Spacing.section)
    .padding(.vertical, MactionsTheme.Spacing.control)
  }

  private var hasWatchableFleet: Bool {
    !app.plan.enabledCombos().isEmpty || (app.plan.isAllRepos && !app.plan.defaultPlatforms.isEmpty)
  }

  /// A persistent in-window indicator while a base image is building, so the
  /// 30–40 min Windows build (or the Linux pull) is never invisible once the
  /// Settings window is closed. Tapping reopens Settings to watch; Windows also
  /// carries the Cancel here (the build's only abort control otherwise lives in
  /// Settings).
  @ViewBuilder private var buildIndicator: some View {
    if app.windowsSetupBusy || app.linuxSetupBusy {
      let isWindows = app.windowsSetupBusy
      let text = isWindows ? "Building Windows base…" : "Setting up Linux…"
      HStack(spacing: 6) {
        Button {
          app.presentSettings(isWindows ? .windows : .linux)
        } label: {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .buttonStyle(.plain)
        .help("Open Settings to watch progress")
        .accessibilityLabel(text)
        .accessibilityHint("Opens Settings to watch progress")
        if isWindows {
          Button {
            app.cancelWindowsSetup()
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .help("Cancel the Windows base build")
          .accessibilityLabel("Cancel Windows base build")
        }
      }
      .padding(.horizontal, MactionsTheme.Spacing.control)
      .padding(.vertical, 3)
      .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
  }

  /// A persistent, dismissible error bar for blocking failures (sign-in /
  /// go-online) — they used to flash once in the bottom strip and vanish.
  private func errorBar(_ message: String) -> some View {
    HStack(alignment: .top, spacing: MactionsTheme.Spacing.tight) {
      Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
      Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: MactionsTheme.Spacing.control)
      Button {
        app.errorBanner = nil
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("Dismiss")
      .accessibilityLabel("Dismiss error")
    }
    .padding(.horizontal, MactionsTheme.Spacing.section)
    .padding(.vertical, MactionsTheme.Spacing.control)
    .background(Color.red.opacity(0.12))
  }

  /// Shown while the live fleet's config has been edited but not yet applied —
  /// edits are allowed online and staged, and this is the one-click way to apply
  /// them (restart = go offline, then back online reading the fresh plan).
  /// Restarting with LIVE runners is destructive (deregistration fails their
  /// in-flight jobs on GitHub, and they are NOT re-queued), so it confirms
  /// first — gated on `app.runners`, not `busyRunnerNames` (the busy poll only
  /// runs while the Runners pane is visible; this bar shows on every tab).
  private var restartBar: some View {
    HStack(spacing: MactionsTheme.Spacing.tight) {
      Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
      Text("Configuration changed — restart the fleet to apply.")
        .font(.callout).foregroundStyle(.orange)
      Spacer(minLength: MactionsTheme.Spacing.control)
      Button("Restart fleet") {
        if app.runners.isEmpty { app.restartFleet() } else { confirmRestart = true }
      }
      .controlSize(.small)
      .disabled(app.state == .starting || app.state == .stopping)
    }
    .padding(.horizontal, MactionsTheme.Spacing.section)
    .padding(.vertical, MactionsTheme.Spacing.control)
    .background(Color.orange.opacity(0.12))
    .confirmationDialog(
      "Restart the fleet now?", isPresented: $confirmRestart, titleVisibility: .visible
    ) {
      Button("Restart and cancel running jobs", role: .destructive) { app.restartFleet() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Restarting deregisters the live runners, and GitHub fails any job they are "
          + "running. Failed jobs are not re-queued — re-run them from GitHub afterward.")
    }
  }

  /// Shown when a runner substrate needs attention — e.g. a stale Windows base
  /// image or Linux runtime/image repair. Non-blocking: the fleet can still run
  /// the platforms that are currently armed, and the button deep-links to the
  /// Settings pane that owns the fix.
  private func actionNoticeBar(_ notice: AppState.ActionNotice) -> some View {
    HStack(spacing: MactionsTheme.Spacing.tight) {
      Image(systemName: notice.icon).foregroundStyle(.orange)
      Text(notice.text)
        .font(.callout).foregroundStyle(.orange)
      Spacer(minLength: MactionsTheme.Spacing.control)
      Button(notice.actionTitle) { app.presentSettings(notice.tab) }
        .controlSize(.small)
    }
    .padding(.horizontal, MactionsTheme.Spacing.section)
    .padding(.vertical, MactionsTheme.Spacing.control)
    .background(Color.orange.opacity(0.12))
  }

  private var statusColor: Color {
    switch app.state {
    case .offline: return .secondary
    case .starting, .stopping: return .orange
    case .online: return .green
    }
  }

  private var stateSubtitle: String {
    switch app.state {
    case .offline: return "Offline"
    case .starting: return "Starting…"
    case .stopping: return "Stopping…"
    case .online:
      // Scale-from-zero: zero live runners is the NORMAL armed state — say
      // "watching", not a runner count that reads like a failure to start.
      let n = app.runners.count
      let queued = app.repoQueuedJobs.values.reduce(0, +)
      if n == 0 {
        // All-repos arms orchestrators LAZILY (per queued job, reaped when
        // quiet), so a live count would flutter and undercount the scope.
        if app.plan.isAllRepos {
          return queued > 0 ? "Online · watching all repos · \(queued) queued"
            : "Online · watching all repos"
        }
        let repos = app.watchedRepoCount
        guard repos > 0 else {
          // Combos were configured (the gate blocks otherwise) but every one
          // was skipped — the status strip carries the "skipped — …" reason.
          return "Online — nothing armed (see status below)"
        }
        let base = "Online · watching \(repos) repo\(repos == 1 ? "" : "s")"
        return queued > 0 ? "\(base) · \(queued) queued" : base
      }
      let base = "Online · \(n) runner\(n == 1 ? "" : "s")"
      return queued > 0 ? "\(base) · \(queued) queued" : base
    }
  }

  /// Bottom-strip left text: the detailed status line if present, else a terse
  /// configured-repos summary.
  private var statusText: String {
    if let message = app.statusMessage { return message }
    let repoCount = app.plan.repos.count
    let comboCount = app.plan.enabledCombos().count
    if app.plan.isAllRepos {
      let overrideText =
        repoCount == 0
        ? "no repository overrides"
        : "\(repoCount) repository override\(repoCount == 1 ? "" : "s")"
      return "All repositories scope · \(overrideText)."
    }
    if repoCount == 0 { return "No repositories configured — add one to begin." }
    return "\(repoCount) repo\(repoCount == 1 ? "" : "s") · \(comboCount) platform combo\(comboCount == 1 ? "" : "s") configured."
  }

  /// Bottom-strip right note: shown ONLY when Windows VMs are actually capped
  /// below what the plan could demand (the contextual home for the old budget
  /// chip). Compares the Σ of per-combo MAX counts — under scale-from-zero a
  /// burst of queued jobs is what would hit this ceiling. All-repos discovery
  /// draws on the same budget with no explicit combos, so a 0 budget must warn
  /// whenever discovery could route Windows jobs here at all.
  private var capNote: String? {
    guard app.state == .online, app.windowsImageReady else { return nil }
    let requested = app.plan.enabledCombos().filter { $0.os == .windows }
      .reduce(0) { $0 + $1.config.count }
    let discoveryWantsWindows = app.plan.isAllRepos && app.isDefaultPlatform(.windows)
    let budget = app.capacity.windowsMaxConcurrentVMs
    guard requested > budget || (discoveryWantsWindows && budget == 0) else { return nil }
    return budget == 0
      ? "Windows paused — not enough RAM for a VM"
      : "Windows VMs capped at \(budget) (RAM budget)"
  }

  /// Live budget-pressure readout: "Windows VMs n/max" whenever any are up —
  /// orange at the ceiling, where a queued job is genuinely WAITING on
  /// capacity. (capacity is computed over the published `runners`, so this
  /// updates live with no extra plumbing.)
  private var liveNote: (text: String, isWarning: Bool)? {
    guard app.state == .online, app.capacity.liveWindowsRunners > 0 else { return nil }
    let live = app.capacity.liveWindowsRunners
    let max = app.capacity.windowsMaxConcurrentVMs
    return ("Windows VMs \(live)/\(max)", live >= max)
  }
}

// MARK: - Runners (repo-grouped outline + Configure/detail panel)

private struct RunnersPane: View {
  @EnvironmentObject private var app: AppState
  @Binding var selection: String?
  let selectedRepoID: String?
  /// Repos whose runner children are collapsed in the outline (default: expanded).
  @State private var collapsed: Set<String> = []
  @State private var showAddRepo = false

  /// One repo's row in the outline: its configured platforms + plan summary +
  /// its live runners.
  private struct RepoGroup: Identifiable {
    let repo: RepoRef
    let summary: String
    let enabledPlatforms: [RunnerOS]
    let runners: [FleetRunnerRow]
    let activeCount: Int
    var id: String { repo.fullName }
  }

  private var groups: [RepoGroup] {
    let byRepo = Dictionary(grouping: app.runners, by: { $0.repoFullName })
    var seen = Set<String>()
    var result = app.plan.repos.map { plan -> RepoGroup in
      seen.insert(plan.repo.fullName)
      let rs = byRepo[plan.repo.fullName] ?? []
      let active = rs.filter { app.busyRunnerNames.contains($0.runner.id) }.count
      return RepoGroup(
        repo: plan.repo, summary: app.plan.isAllRepos ? "Override · \(plan.summary())" : plan.summary(),
        enabledPlatforms: plan.enabledPlatforms,
        runners: rs, activeCount: active)
    }
    // Repos picked up by ALL-REPOS discovery: ARMED orchestrators (watching /
    // spinning up) and any runner rows, with no plan entry. They must be
    // visible — an invisible fleet reads as a leak. Stable name order.
    let discovered = Set(byRepo.keys).union(app.watchedRepos).subtracting(seen)
    for repoName in discovered.sorted() {
      guard let ref = RepoRef(fullName: repoName) else { continue }
      let rs = byRepo[repoName] ?? []
      let active = rs.filter { app.busyRunnerNames.contains($0.runner.id) }.count
      result.append(
        RepoGroup(
          repo: ref, summary: "Discovered — all repositories", enabledPlatforms: [],
          runners: rs, activeCount: active))
    }
    return result
  }

  var body: some View {
    HStack(spacing: 0) {
      gridColumn.frame(width: 340)
      Divider()
      rightPanel.frame(maxWidth: .infinity)
    }
    // Poll which of our runners GitHub reports as executing a job (`busy`) so the
    // activity ring spins only during a real job. Runs while this pane shows.
    .task {
      while !Task.isCancelled {
        await app.refreshRunnerBusy()
        try? await Task.sleep(nanoseconds: 6_000_000_000)
      }
    }
    .onAppear {
      if app.plan.isAllRepos && selection == nil {
        selection = allRepositoriesSelectionID
      }
    }
    .onChange(of: app.plan.isAllRepos) { isAllRepos in
      if isAllRepos, selection == nil {
        selection = allRepositoriesSelectionID
      } else if !isAllRepos, selection == allRepositoriesSelectionID {
        selection = nil
      }
    }
    .sheet(isPresented: $showAddRepo) { AddRepoSheet() }
  }

  // MARK: Left — the repo-grouped outline

  @ViewBuilder private var gridColumn: some View {
    VStack(spacing: 0) {
      // Discovered (all-repos) groups can exist with an EMPTY explicit plan —
      // the list must render whenever any group does, or watched fleets hide.
      if !app.plan.isAllRepos && app.plan.repos.isEmpty && groups.isEmpty {
        VStack(spacing: MactionsTheme.Spacing.section) {
          if app.isSignedIn, app.plan.isAllRepos {
            DashboardEmptyState(
              systemImage: "antenna.radiowaves.left.and.right",
              title: "Watching all repositories",
              message: app.state == .online
                ? "No queued jobs discovered yet — a repo appears here the moment one of its jobs queues. Add a repository explicitly to pin its own settings."
                : "All-repositories mode is on. Go online to start watching every repo you admin for queued jobs — or add a repository explicitly to pin its own settings.")
            Button {
              showAddRepo = true
            } label: {
              Label("Add repository…", systemImage: "plus")
            }
            .glassProminentButton()
            .keyboardShortcut("n", modifiers: .command)
            .disabled(app.state != .offline)
          } else if app.isSignedIn {
            DashboardEmptyState(
              systemImage: "tray", title: "No repositories",
              message: "Add a repository to manage its self-hosted runners. Then pick a platform for it on the right.")
            Button {
              showAddRepo = true
            } label: {
              Label("Add repository…", systemImage: "plus")
            }
            .glassProminentButton()
            .keyboardShortcut("n", modifiers: .command)
            .disabled(app.state != .offline)
          } else {
            // Cold start: sign-in lives in Settings, so a signed-out user with no
            // repos would otherwise hit a dead end (the add sheet shows "no admin
            // repos"). Point them straight at the connect flow instead.
            DashboardEmptyState(
              systemImage: "person.crop.circle.badge.questionmark", title: "Sign in to GitHub",
              message: "Connect your GitHub account to see the repositories you can add self-hosted runners to.")
            Button {
              app.presentSettings(.general)
            } label: {
              Label("Sign in to GitHub…", systemImage: "person.badge.key")
            }
            .glassProminentButton()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(selection: $selection) {
          if app.plan.isAllRepos {
            allRepositoriesHeader.tag(allRepositoriesSelectionID)
          }
          ForEach(groups) { group in
            repoHeader(group).tag(group.repo.fullName)
            // Live runners nest under the repo and are collapsible. Offline there
            // are none, so the disclosure chevron is hidden (no dead control) and
            // the configured platforms show as logo chips in the header instead.
            if !group.runners.isEmpty, !collapsed.contains(group.id) {
              ForEach(group.runners) { row in
                RunnerRow(row: row, busy: app.busyRunnerNames.contains(row.runner.id))
                  .tag(row.id)
                  .padding(.leading, 18)
              }
            }
          }
        }
        .listStyle(.inset)
        // The add/manage gutter only when there's a list — the empty state has
        // its own prominent "Add repository…" button, so showing the gutter too
        // would be a redundant second control in the same spot.
        Divider()
        gutter
      }
    }
  }

  /// The source-list bottom gutter: add / manage repositories. Labeled (not a
  /// bare "+") so it's clear how to add repos; explains the offline gate.
  private var gutter: some View {
    HStack(spacing: MactionsTheme.Spacing.tight) {
      Button {
        showAddRepo = true
      } label: {
        Label(app.plan.isAllRepos ? "Add override" : "Add repository", systemImage: "plus")
      }
      .buttonStyle(.borderless)
      .keyboardShortcut("n", modifiers: .command)
      .disabled(app.state != .offline)
      .help(app.state == .offline ? addRepoHelp : MactionsTheme.Copy.offlineToManageRepos)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, MactionsTheme.Spacing.control)
    .padding(.vertical, MactionsTheme.Spacing.tight)
  }

  private var addRepoHelp: String {
    app.plan.isAllRepos ? "Add or remove repository overrides (⌘N)" : "Add or remove repositories (⌘N)"
  }

  private var allRepositoriesHeader: some View {
    HStack(spacing: MactionsTheme.Spacing.tight) {
      Image(systemName: "antenna.radiowaves.left.and.right")
        .font(.caption)
        .foregroundStyle(app.state == .online ? Color.green : Color.secondary)
        .frame(width: 12)
      Circle()
        .fill(app.state == .online ? Color.green.opacity(0.35) : Color.secondary)
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text("All repositories").font(.callout.weight(.medium)).lineLimit(1)
        Text(allRepositoriesSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: MactionsTheme.Spacing.tight)
      if app.state == .online {
        Text(allRepositoriesBadge).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }

  private var allRepositoriesSummary: String {
    let parts = RunnerOS.allCases.compactMap { os -> String? in
      guard app.isDefaultPlatform(os) else { return nil }
      let count = app.defaultCount(for: os)
      return count > 1 ? "\(os.displayName) ×\(count)" : os.displayName
    }
    return parts.isEmpty ? "No default platforms" : "Defaults · " + parts.joined(separator: " · ")
  }

  private var allRepositoriesBadge: String {
    let watched = app.watchedRepos.count
    let queued = app.repoQueuedJobs.values.reduce(0, +)
    if queued > 0 { return "\(queued) queued" }
    return watched > 0 ? "\(watched) active" : "watching"
  }

  /// A selectable repo header: a status dot, name + combo summary, configured-
  /// platform logo chips, and an aggregate runner badge. A disclosure chevron is
  /// shown ONLY when there are live runners to reveal (so it's never a no-op).
  /// Selecting the row opens the repo's Configure panel on the right.
  private func repoHeader(_ group: RepoGroup) -> some View {
    let hasRunners = !group.runners.isEmpty
    return HStack(spacing: MactionsTheme.Spacing.tight) {
      // Chevron only when there's something to expand (live runners). Offline it
      // would toggle nothing, so we render a fixed-width spacer to keep the rows
      // aligned instead.
      if hasRunners {
        Button {
          if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
        } label: {
          Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down")
            .font(.caption2).foregroundStyle(.secondary).frame(width: 12)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Live runners")
        .accessibilityHint(collapsed.contains(group.id) ? "Expand" : "Collapse")
      } else {
        Color.clear.frame(width: 12, height: 1)
      }
      // Decorative: the badge text + summary already convey runner state, so keep
      // the color-only dot out of VoiceOver rather than announcing a bare "image".
      // Solid green = live runners; faded green = ARMED and watching (this repo
      // actually has an orchestrator — global .online isn't enough, a skipped
      // combo's repo is not watching anything); grey = offline / not armed.
      Circle()
        .fill(
          hasRunners
            ? Color.green
            : (app.state == .online && app.watchedRepos.contains(group.repo.fullName)
              ? Color.green.opacity(0.35) : Color.secondary)
        )
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(group.repo.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
        Text(group.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: MactionsTheme.Spacing.tight)
      // Configured platforms at a glance — the chips make it clear which combos
      // are selected for this repo even when offline (nothing is running yet).
      // The summary text already names the platforms, so hide the chips from
      // VoiceOver to avoid reading each OS twice.
      if !group.enabledPlatforms.isEmpty {
        HStack(spacing: 3) {
          ForEach(group.enabledPlatforms) { os in
            OSLogo(os: os, size: 11).frame(width: 13).help(os.displayName)
          }
        }
        .accessibilityHidden(true)
      }
      if !badge(group).isEmpty {
        Text(badge(group)).font(.caption2).foregroundStyle(badgeColor(group)).monospacedDigit()
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }

  /// Aggregate badge per repo. Under scale-from-zero an online repo with no
  /// runners is healthy — it reads "watching" (or "N queued · starting…" while
  /// runners spin up for detected demand) — and the failure states that would
  /// make "starting…" a lie get their own words: budget exhaustion, repeated
  /// launch deaths, and a failing queue poll (unknown ≠ quiet).
  private func badge(_ group: RepoGroup) -> String {
    let n = group.runners.count
    let repoName = group.repo.fullName
    let queued = app.repoQueuedJobs[repoName] ?? 0
    if n == 0 {
      guard app.state == .online else { return "" }
      guard app.watchedRepos.contains(repoName) else {
        // Configured but no orchestrator armed (image not built / budget 0) —
        // the status strip carries the reason.
        return "not armed"
      }
      if app.repoLaunchFailure[repoName] != nil {
        return "\(queued) queued · runner failing to launch"
      }
      if app.repoWaitingForCapacity.contains(repoName) {
        return "\(queued) queued · waiting for capacity"
      }
      if app.repoPollFailing.contains(repoName) { return "watching · poll failing" }
      return queued > 0 ? "\(queued) queued · starting…" : "watching"
    }
    if group.activeCount > 0 { return "\(n) · \(group.activeCount) active" }
    return queued > 0 ? "\(n) · \(queued) queued" : "\(n)"
  }

  /// Warning states read orange (the capNote vocabulary); everything else stays
  /// secondary.
  private func badgeColor(_ group: RepoGroup) -> Color {
    let repoName = group.repo.fullName
    guard app.state == .online, group.runners.isEmpty else { return .secondary }
    if app.repoLaunchFailure[repoName] != nil
      || app.repoWaitingForCapacity.contains(repoName)
      || app.repoPollFailing.contains(repoName)
    {
      return .orange
    }
    return .secondary
  }

  // MARK: Right — the selected runner's live detail OR the repo's Configure panel

  @ViewBuilder private var rightPanel: some View {
    // A live runner is selected → show its job/step detail.
    if let id = selection, id.contains("#"),
      let row = app.runners.first(where: { $0.id == id })
    {
      RunnerDetailView(row: row)
    } else if selection == allRepositoriesSelectionID || (selection == nil && app.plan.isAllRepos) {
      AllRepositoriesInspector()
    } else if let repoID = selectedRepoID, app.plan.repos.contains(where: { $0.id == repoID }) {
      // A repo is selected → configure its platform/count override.
      RepoInspector(repoID: repoID)
    } else if let repoID = selectedRepoID, groups.contains(where: { $0.id == repoID }) {
      // A DISCOVERED repo (all-repos mode): it runs on the default platform
      // settings and has no per-repo config to edit until added explicitly.
      // Name the repo and the offline gate: this panel only shows while
      // online, where "Add repository" is disabled — and going offline clears
      // the discovered row, so the user needs the name to find it again.
      VStack(spacing: MactionsTheme.Spacing.section) {
        DashboardEmptyState(
          systemImage: "antenna.radiowaves.left.and.right", title: "Discovered repository",
          message:
            "All-repositories mode spun this up from a queued job using your default platform "
            + "settings; its fleet retires when the repo goes quiet. Go offline, then add "
            + "\(repoID) explicitly to override platforms and max runners. "
            + MactionsTheme.Copy.offlineToManageRepos)
        if let launchError = app.repoLaunchFailure[repoID] {
          Banner(launchError, severity: .warning, icon: "exclamationmark.triangle")
            .padding(.horizontal, MactionsTheme.Spacing.section)
        }
      }
    } else {
      DashboardEmptyState(
        systemImage: "slider.horizontal.3", title: "Select a repository",
        message: app.plan.repos.isEmpty
          ? "Add a repository on the left, then pick a platform for it here."
          : "Pick a repository on the left to choose its platforms and runner count.")
    }
  }
}

/// A status dot with a GitHub-style spinning ring around it WHILE the runner is
/// executing a job (`busy`, from GitHub's runner API), echoing the GH Actions
/// in-progress spinner. Idle/online runners show a plain centered dot; the color
/// reflects the runner's phase. Ring + dot share the ZStack center (concentric).
private struct RunnerActivityDot: View {
  let phase: ManagedRunner.Phase
  let busy: Bool

  private var color: Color {
    switch phase {
    case .online: return .green
    case .failed: return .red
    case .stopped: return .secondary
    default: return .orange
    }
  }

  /// Spoken state — the dot conveys phase by color alone, so give VoiceOver words.
  private var label: String {
    let base = phase.rawValue.capitalized
    return busy ? "\(base), running a job" : base
  }

  var body: some View {
    ZStack {
      if busy {
        // GitHub-style spinning arc, driven by Core Animation (see SpinningRing).
        // The rotation runs on the render server, independent of the main thread,
        // so the spin costs zero SwiftUI/main-thread work per frame however many
        // runners are busy. We deliberately avoid two tempting-but-broken paths:
        //   • `.rotationEffect` + `.animation(.repeatForever)` re-evaluates the
        //     animated attribute every display frame, forcing the window's single
        //     NSHostingView to relayout ~60×/s while ANY runner is busy — under an
        //     all-repos fleet that starves the main thread and paints blank frames.
        //   • a native circular `ProgressView` silently FREEZES (renders a static
        //     spoke wheel) once its NSProgressIndicator is recycled inside this
        //     virtualized List. SpinningRing re-arms its animation on every
        //     re-entry to a window, so it can't freeze.
        SpinningRing(color: color)
          .frame(width: 13, height: 13)
      }
      Circle().fill(color).frame(width: 7, height: 7)
    }
    .frame(width: 16, height: 16)
    .accessibilityElement()
    .accessibilityLabel(label)
  }
}

/// A GitHub-style indeterminate spinner: a 70% circular arc that rotates forever.
/// The rotation is a `CABasicAnimation` on `transform.rotation`, which Core
/// Animation runs on the render server independent of the main thread — so it
/// costs no SwiftUI/main-thread work per frame regardless of how many runners
/// are busy (the reason we don't drive it with SwiftUI's `.repeatForever`). The
/// CA animation keeps its phase across List-row recycling and self-heals if the
/// NSView is ever rebuilt, so it can't fall into the static-spoke-wheel freeze
/// that a recycled `ProgressView(.circular)` hits here. Honors Reduce Motion
/// (a full, still ring, no spin).
private struct SpinningRing: NSViewRepresentable {
  var color: Color
  var lineWidth: CGFloat = 1.5

  func makeNSView(context: Context) -> SpinningRingView {
    SpinningRingView(color: NSColor(color), lineWidth: lineWidth)
  }

  func updateNSView(_ view: SpinningRingView, context: Context) {
    view.update(color: NSColor(color), lineWidth: lineWidth)
  }
}

private final class SpinningRingView: NSView {
  private static let spinKey = "mactions.spin"
  private let ring = CAShapeLayer()
  private var ringColor: NSColor
  private var ringLineWidth: CGFloat

  init(color: NSColor, lineWidth: CGFloat) {
    self.ringColor = color
    self.ringLineWidth = lineWidth
    super.init(frame: .zero)
    wantsLayer = true
    ring.fillColor = NSColor.clear.cgColor
    ring.lineCap = .round
    layer?.addSublayer(ring)
    // The SwiftUI ZStack owns this dot's VoiceOver label; don't double-announce.
    setAccessibilityElement(false)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(accessibilityOptionsChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

  override var intrinsicContentSize: NSSize { NSSize(width: 13, height: 13) }

  func update(color: NSColor, lineWidth: CGFloat) {
    ringColor = color
    ringLineWidth = lineWidth
    needsLayout = true
    applyStyle()
  }

  override func layout() {
    super.layout()
    // No implicit animations on geometry/style — only the explicit spin animates.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let side = min(bounds.width, bounds.height)
    let square = CGRect(x: 0, y: 0, width: side, height: side)
    ring.bounds = square
    ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)   // rotate about the ring's center
    ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
    let inset = ringLineWidth / 2 + 0.5
    ring.path = CGPath(ellipseIn: square.insetBy(dx: inset, dy: inset), transform: nil)
    ring.contentsScale = window?.backingScaleFactor ?? 2
    CATransaction.commit()
    applyStyle()
    armAnimationIfNeeded()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    // A CA animation runs on an absolute-time clock, so it keeps its phase across a
    // detach/re-attach (List row scrolled offscreen and back) and simply resumes —
    // no freeze. We re-arm only if it's actually missing (e.g. SwiftUI rebuilt the
    // NSView); force-removing a live animation would snap the ring back to 0° (a
    // visible jump on every recycle), so we don't.
    ring.contentsScale = window?.backingScaleFactor ?? 2
    armAnimationIfNeeded()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyStyle()   // re-resolve the stroke color for the new light/dark appearance
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    ring.contentsScale = window?.backingScaleFactor ?? 2
  }

  @objc private func accessibilityOptionsChanged() {
    DispatchQueue.main.async { [weak self] in
      self?.applyStyle()
      self?.armAnimationIfNeeded()
    }
  }

  private var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private func applyStyle() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.lineWidth = ringLineWidth
    // Resolve the (possibly dynamic) color against THIS view's appearance so the
    // arc tracks light/dark exactly like the SwiftUI dot beside it.
    var stroke = ringColor.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance { stroke = ringColor.cgColor }
    ring.strokeColor = stroke
    ring.strokeStart = 0
    // Reduce Motion: a full, still ring still reads as "active" without spinning.
    ring.strokeEnd = reduceMotion ? 1.0 : 0.7
    CATransaction.commit()
  }

  private func armAnimationIfNeeded() {
    if reduceMotion {
      ring.removeAnimation(forKey: Self.spinKey)
      return
    }
    guard window != nil, ring.animation(forKey: Self.spinKey) == nil else { return }
    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0
    spin.toValue = -Double.pi * 2      // clockwise (y-up layer), matching the old SwiftUI ring
    spin.duration = 1
    spin.repeatCount = .infinity
    spin.isRemovedOnCompletion = false
    spin.timingFunction = CAMediaTimingFunction(name: .linear)   // constant angular speed
    ring.add(spin, forKey: Self.spinKey)
  }
}

private struct RunnerRow: View {
  let row: FleetRunnerRow
  let busy: Bool
  var body: some View {
    HStack(spacing: 9) {
      OSLogo(os: row.os, size: 14).frame(width: 16).accessibilityLabel(row.os.displayName)
      RunnerActivityDot(phase: row.runner.phase, busy: busy)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.repoFullName).font(.callout).lineLimit(1).truncationMode(.middle)
        Text(row.runner.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
  }
}

private struct RunnerDetailView: View {
  let row: FleetRunnerRow
  @EnvironmentObject private var app: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      DetailHeader(
        os: row.os, title: row.repoFullName, subtitle: row.runner.id,
        trailing: AnyView(
          Text(row.runner.phase.rawValue.capitalized).font(.caption.weight(.medium))
            .foregroundStyle(.secondary)))
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          switch app.runnerJobs[row.runner.id] {
          case .loading, .none:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking up the current job on GitHub…").font(.caption).foregroundStyle(.secondary) }
          case .running:
            // GitHub says the runner is busy, but the jobs API hasn't published the
            // matching job/steps yet — show a running state consistent with the
            // spinning ring (not a contradictory "no job"), and set expectations
            // that there's no live log for an in-progress job.
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Running a job — waiting for GitHub to publish its steps…").font(.callout)
              }
              Text("Live logs aren't available while a job is in progress; the full log appears under History once it finishes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
          case .found(let job):
            jobSteps(job)
          case .notFound:
            VStack(alignment: .leading, spacing: 4) {
              Text("No job running on this runner right now.").font(.callout)
              Text("This runner was started for a queued job and is waiting for GitHub to assign it; if the job went elsewhere, the fleet retires it shortly. The full log appears under History once a job finishes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
          case .error(let message):
            Banner(message, severity: .warning, icon: "wifi.exclamationmark")
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    // Poll the running job's steps while this runner is selected (off-main).
    .task(id: row.runner.id) {
      while !Task.isCancelled {
        await app.loadRunnerJob(
          for: row.runner.id, repo: row.repoFullName,
          busy: app.busyRunnerNames.contains(row.runner.id))
        try? await Task.sleep(nanoseconds: 4_000_000_000)
      }
    }
  }

  @ViewBuilder
  private func jobSteps(_ job: WorkflowJob) -> some View {
    HStack(spacing: 8) {
      ConclusionBadge(status: job.status, conclusion: job.conclusion)
      Text(job.name).font(.headline)
      Spacer()
      if let url = job.htmlURL.flatMap(URL.init) {
        Link(destination: url) { Label("GitHub", systemImage: "arrow.up.forward.square") }.font(.caption)
      }
    }
    if let steps = job.steps, !steps.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(steps) { step in
          HStack(spacing: 8) {
            let icon = stepIcon(status: step.status, conclusion: step.conclusion)
            Image(systemName: icon.name).foregroundStyle(icon.color).font(.caption)
            Text(step.name).font(.callout).foregroundStyle(step.status == "completed" ? .primary : .secondary)
            Spacer(minLength: 0)
          }
        }
      }
    } else {
      Text("Waiting for steps…").font(.caption).foregroundStyle(.secondary)
    }
  }
}

// MARK: - History (master/detail + log console)

private struct HistoryPane: View {
  @EnvironmentObject private var app: AppState
  @State private var selected: String?
  @State private var search = ""
  @State private var filter: OutcomeFilter = .all
  @State private var confirmClear = false

  enum OutcomeFilter: String, CaseIterable, Identifiable {
    case all = "All", passed = "Passed", failed = "Failed"
    var id: String { rawValue }
  }

  private var filtered: [RunRecord] {
    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
    return app.runHistory.filter { rec in
      // Filter on the RESOLVED status (true GitHub conclusion), not the agent exit
      // — a failed job must land under "Failed", not "Passed". Unresolved rows show
      // only under "All", since we can't honestly bucket them yet.
      let matchesFilter: Bool
      switch filter {
      case .all: matchesFilter = true
      case .passed: matchesFilter = rec.resolvedStatus == .passed
      case .failed: matchesFilter = rec.resolvedStatus == .failed
      }
      let matchesSearch =
        q.isEmpty || rec.repo.lowercased().contains(q) || rec.id.lowercased().contains(q)
      return matchesFilter && matchesSearch
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
          TextField("Filter runs…", text: $search).textFieldStyle(.plain).font(.callout)
          if !app.runHistory.isEmpty {
            Button { confirmClear = true } label: { Image(systemName: "trash") }
              .buttonStyle(.borderless).controlSize(.small)
              .help("Clear run history")
              .accessibilityLabel("Clear run history")
          }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .liquidGlass(in: Capsule())  // search field = control layer
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
        Picker("", selection: $filter) {
          ForEach(OutcomeFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.bottom, 6)
        Divider()
        if filtered.isEmpty {
          DashboardEmptyState(
            systemImage: "clock.arrow.circlepath", title: "No runs",
            message: app.runHistory.isEmpty
              ? "Finished runs appear here as runners complete."
              : "No runs match the current filter.")
        } else {
          List(selection: $selected) {
            ForEach(filtered) { record in HistoryRow(record: record).tag(record.id) }
          }
          .listStyle(.inset)
        }
      }
      .frame(width: 300)
      Divider()
      // Resolve from the VISIBLE filtered list, so a selection that's been
      // filtered out doesn't show detail for a row that isn't in the list.
      if let record = filtered.first(where: { $0.id == selected }) {
        RunDetailView(record: record)
      } else {
        DashboardEmptyState(
          systemImage: "sidebar.right", title: "Select a run",
          message: "Pick a run to view its GitHub Actions job log inline.")
      }
    }
    // Back-fill the true GitHub conclusion for recent rows so their status is
    // correct without opening each one. Bounded + on-appear only (not a poller).
    .task { await app.resolveRecentConclusions() }
    // Clearing history is irreversible and a single small-icon tap — confirm it.
    .confirmationDialog(
      "Clear all run history?", isPresented: $confirmClear, titleVisibility: .visible
    ) {
      Button("Clear", role: .destructive) { app.clearRunHistory() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently deletes all recorded runs and their cached logs. This can't be undone.")
    }
  }
}

private struct HistoryRow: View {
  let record: RunRecord
  var body: some View {
    HStack(spacing: 9) {
      OSLogo(os: record.os, size: 13).frame(width: 16).accessibilityLabel(record.os.displayName)
      Circle().fill(statusColor(record.resolvedStatus)).frame(width: 7, height: 7)
        .accessibilityLabel(record.statusLabel)
      VStack(alignment: .leading, spacing: 1) {
        Text(record.repo).font(.callout).lineLimit(1).truncationMode(.middle)
        Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Text(durationString(record.duration)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
    }
    .padding(.vertical, 2)
  }
}

private struct RunDetailView: View {
  let record: RunRecord
  @EnvironmentObject private var app: AppState
  @State private var logSearch = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      DetailHeader(
        os: record.os, title: record.repo, subtitle: record.id,
        trailing: AnyView(OutcomeBadge(record: record)))
      meta
      Divider()
      content
    }
    .task(id: record.id) { await app.loadJobLog(for: record) }
  }

  private var meta: some View {
    HStack(spacing: 14) {
      metaItem("Started", record.startedAt.formatted(date: .abbreviated, time: .shortened))
      // Runner lifetime (launch → exit), NOT the job's runtime — labeled so the two
      // aren't conflated (an idle-then-recycled runner's uptime includes its wait).
      metaItem("Agent uptime", durationString(record.duration))
        .help("How long the runner process was alive (launch → exit) — not the job's runtime.")
      // The job's actual runtime, from the fetched job (no extra call). Shown only
      // when it's meaningfully shorter than agent uptime, so it doesn't just echo it.
      if case .loaded(let job?, _) = app.jobLogs[record.id],
        let s = job.startedAt, let e = job.completedAt,
        record.duration - e.timeIntervalSince(s) > 5
      {
        metaItem("Job time", durationString(e.timeIntervalSince(s)))
      }
      // The AGENT process exit, not the job result. Misleading once we know the job
      // conclusion (it's ~always 0), so show it only when it's diagnostic: a crash
      // (non-zero) or while the conclusion is still unresolved.
      if let code = record.exitStatus, code != 0 || record.jobConclusion == nil {
        metaItem("Agent exit", "\(code)")
      }
      Spacer()
      if case .loaded(let job, _) = app.jobLogs[record.id], let url = job?.htmlURL.flatMap(URL.init) {
        Link(destination: url) { Label("GitHub", systemImage: "arrow.up.forward.square") }.font(.caption)
      }
      Button {
        Task { await app.loadJobLog(for: record, force: true) }
      } label: { Image(systemName: "arrow.clockwise") }
        .glassButton().controlSize(.small).help("Re-fetch the log from GitHub")
        .accessibilityLabel("Re-fetch log from GitHub")
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
  }

  private func metaItem(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).tracking(0.4)
      Text(value).font(.caption.weight(.medium)).monospacedDigit()
    }
  }

  @ViewBuilder
  private var content: some View {
    switch app.jobLogs[record.id] {
    case .loading, .none:
      VStack(spacing: 8) {
        ProgressView()
        Text("Fetching the job log from GitHub…").font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let job, let lines):
      if lines.isEmpty {
        emptyLogState(job: job)
      } else {
        LogConsole(lines: lines, search: $logSearch)
      }
    case .unavailable(let message):
      DashboardEmptyState(systemImage: "exclamationmark.triangle", title: "Log unavailable", message: message)
    }
  }

  /// The job was found but its log came back empty (deleted, still running, or past
  /// retention). Read the resolved conclusion so the message is honest about WHY,
  /// instead of a flat "No log available" for a job we know failed.
  @ViewBuilder
  private func emptyLogState(job: WorkflowJob?) -> some View {
    switch record.jobConclusion {
    case .failure, .timedOut:
      let timedOut = record.jobConclusion == .timedOut
      DashboardEmptyState(
        systemImage: "xmark.octagon",
        title: timedOut ? "Job timed out" : "Job failed",
        message:
          "GitHub confirms the job \(timedOut ? "timed out" : "failed"), but its log isn't "
          + "downloadable (deleted, or past GitHub's retention).")
    case .cancelled:
      DashboardEmptyState(
        systemImage: "minus.circle", title: "Job cancelled",
        message: "The run was cancelled or deleted, so there's no log to show.")
    case .inProgress:
      DashboardEmptyState(
        systemImage: "clock", title: "Job still running",
        message: "The job is still executing or GitHub is indexing it — re-fetch in a moment.")
    default:
      DashboardEmptyState(
        systemImage: "doc.plaintext", title: "No log available",
        message: job == nil
          ? "Found no matching job on GitHub."
          : "The job was found, but its log isn't downloadable (still running, or past GitHub's retention).")
    }
  }
}

// MARK: - Pulse-style log console

private struct LogConsole: View {
  let lines: [String]
  @Binding var search: String

  /// One matched line, identified by its original index in the full log.
  struct IndexedLine: Identifiable { let id: Int; let text: String }

  // Memoized filter results: recomputed ONLY when the search text or the log
  // changes (onAppear / onChange), never on every body re-render. Without this,
  // the 2s memory-sample re-render of the parent would re-filter the whole log
  // each tick — an O(n) main-thread cost that the user explicitly wants avoided.
  @State private var matches: [IndexedLine] = []

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.secondary)
        TextField("Search in log…", text: $search).textFieldStyle(.plain).font(.caption)
        Text(search.isEmpty ? "\(lines.count) lines" : "\(matches.count) match\(matches.count == 1 ? "" : "es")")
          .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        Button { copyAll() } label: { Image(systemName: "doc.on.doc") }
          .buttonStyle(.borderless).controlSize(.small).help("Copy the full log")
          .accessibilityLabel("Copy the full log")
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .liquidGlass(in: Capsule())  // search field = control layer
      .padding(.horizontal, 10).padding(.vertical, 6)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(matches) { item in LogLineRow(number: item.id + 1, line: item.text) }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(Color(nsColor: .textBackgroundColor))
      .textSelection(.enabled)
    }
    .onAppear { recompute() }
    .onChange(of: search) { _ in recompute() }
    .onChange(of: lines.count) { _ in recompute() }
  }

  private func recompute() {
    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
    if q.isEmpty {
      matches = lines.enumerated().map { IndexedLine(id: $0.offset, text: $0.element) }
    } else {
      matches = lines.enumerated().compactMap {
        $0.element.lowercased().contains(q) ? IndexedLine(id: $0.offset, text: $0.element) : nil
      }
    }
  }

  private func copyAll() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
  }
}

/// One log line, Pulse-style: a dim line-number gutter + monospaced content.
private struct LogLineRow: View {
  let number: Int
  let line: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      // Line numbers are identifiers users read off — .secondary (not .tertiary)
      // keeps them legible in dark mode; a semantic font scales with Dynamic Type.
      Text("\(number)")
        .font(.caption2.monospaced()).foregroundStyle(.secondary)
        .frame(width: 44, alignment: .trailing)
      Text(line.isEmpty ? " " : line)
        .font(.caption.monospaced()).foregroundStyle(.primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12).padding(.vertical, 1)
  }
}

// MARK: - Memory tab

private struct MemoryPane: View {
  @EnvironmentObject private var app: AppState

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let sample = app.latestMemory {
          gauge(sample)
          sparkline
          breakdown(sample)
          Text("“In use” = wired + active + compressed (tracks memory pressure, like Activity Monitor's Memory Used). Per-bucket figures are summed live from process RSS.")
            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        } else {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Sampling memory…").font(.caption).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 120)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func gauge(_ s: MemorySample) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Memory in use").font(.headline)
        Spacer()
        Text("\(formatBytes(s.usedBytes)) / \(formatBytes(s.totalBytes)) · \(Int(s.usedFraction * 100))%")
          .font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
      }
      MemoryBar(fraction: s.usedFraction)
    }
  }

  private var sparkline: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Last \(app.memorySamples.count) samples").font(.caption2).foregroundStyle(.secondary)
      // The sparkline is CONTENT (data viz), not a control — per Apple, keep glass
      // off the content layer; a subtle material fill instead.
      Sparkline(values: app.memorySamples.map(\.usedFraction))
        .padding(6)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
  }

  private func breakdown(_ s: MemorySample) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("BREAKDOWN").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
        .padding(.bottom, 6)
      row("Windows VMs", s.windowsVMBytes, systemImage: "cube.box")
      row("Local runners", s.localRunnerBytes, systemImage: "bolt")
      row("Mactions app", s.appBytes, systemImage: "app")
      row("Wired", s.wiredBytes, systemImage: "lock")
      row("Compressed", s.compressedBytes, systemImage: "arrow.down.right.and.arrow.up.left")
      row("Free", s.freeBytes, systemImage: "circle.dashed")
    }
  }

  private func row(_ label: String, _ bytes: UInt64, systemImage: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage).font(.caption).foregroundStyle(.secondary).frame(width: 18)
      Text(label).font(.callout)
      Spacer()
      Text(formatBytes(bytes)).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
  }
}

private struct MemoryBar: View {
  let fraction: Double
  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15))
        RoundedRectangle(cornerRadius: 5).fill(color)
          .frame(width: max(4, geo.size.width * fraction))
      }
    }
    .frame(height: 12)
  }
  private var color: Color { fraction > 0.85 ? .red : (fraction > 0.65 ? .orange : .green) }
}

private struct Sparkline: View {
  let values: [Double]
  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width, h = geo.size.height
      if values.count >= 2 {
        let maxIndex = Double(values.count - 1)
        let points = values.enumerated().map { i, v in
          CGPoint(x: w * Double(i) / maxIndex, y: h * (1 - max(0, min(1, v))))
        }
        ZStack {
          Path { p in
            p.move(to: CGPoint(x: 0, y: h))
            for pt in points { p.addLine(to: pt) }
            p.addLine(to: CGPoint(x: w, y: h))
            p.closeSubpath()
          }
          .fill(Color.accentColor.opacity(0.15))
          Path { p in
            p.move(to: points[0])
            for pt in points.dropFirst() { p.addLine(to: pt) }
          }
          .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
      } else {
        Text("Collecting…").font(.caption2).foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

// MARK: - Shared bits

private struct DetailHeader: View {
  let os: RunnerOS
  let title: String
  let subtitle: String
  let trailing: AnyView

  var body: some View {
    HStack(spacing: 10) {
      OSLogo(os: os, size: 16).frame(width: 20).help(os.displayName).accessibilityLabel(os.displayName)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
        Text(subtitle).font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
      }
      Spacer()
      trailing
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
  }
}

private struct OutcomeBadge: View {
  let record: RunRecord
  var body: some View {
    Badge(label: record.statusLabel, color: statusColor(record.resolvedStatus))
  }
}

/// Color for a resolved run status — shared by the History badge and the row
/// circle. `unknownCompleted` is amber (NOT green): the agent exited cleanly but
/// we haven't confirmed the result against GitHub yet.
private func statusColor(_ status: RunRecord.ResolvedStatus) -> Color {
  switch status {
  case .passed: return .green
  case .failed: return .red
  case .neutral: return .secondary
  case .running: return .blue
  case .unknownCompleted: return .orange
  }
}

private struct ConclusionBadge: View {
  let status: String
  let conclusion: String?
  var body: some View { Badge(label: label, color: conclusionColor(conclusion, status: status)) }
  private var label: String {
    if status != "completed" { return status == "in_progress" ? "Running" : status.capitalized }
    return (conclusion ?? "done").capitalized
  }
}

struct DashboardEmptyState: View {
  let systemImage: String
  let title: String
  let message: String
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage).font(.system(size: 30)).foregroundStyle(.tertiary)
      Text(title).font(.headline).foregroundStyle(.secondary)
      Text(message).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        .frame(maxWidth: 320)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
  }
}

// MARK: - Free helpers

private func formatBytes(_ bytes: UInt64) -> String {
  let f = ByteCountFormatter()
  f.allowedUnits = [.useGB, .useMB]
  f.countStyle = .memory
  return f.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
}

/// Compact "1h 4m" / "3m 12s" / "47s" from a duration in seconds.
private func durationString(_ seconds: TimeInterval) -> String {
  let total = max(0, Int(seconds.rounded()))
  if total < 60 { return "\(total)s" }
  let m = total / 60, s = total % 60
  if m < 60 { return s == 0 ? "\(m)m" : "\(m)m \(s)s" }
  let h = m / 60, mm = m % 60
  return mm == 0 ? "\(h)h" : "\(h)h \(mm)m"
}

private func conclusionColor(_ conclusion: String?, status: String) -> Color {
  if status != "completed" { return .orange }
  switch conclusion {
  case "success": return .green
  case "failure", "timed_out": return .red
  case "cancelled", "skipped", "neutral": return .secondary
  default: return .orange
  }
}

private func stepIcon(status: String, conclusion: String?) -> (name: String, color: Color) {
  if status != "completed" { return ("circle.dotted", .orange) }
  switch conclusion {
  case "success": return ("checkmark.circle.fill", .green)
  case "skipped": return ("minus.circle", .secondary)
  case "failure", "timed_out": return ("xmark.circle.fill", .red)
  default: return ("circle", .secondary)
  }
}

// MARK: - Liquid Glass (macOS 26+) with graceful fallback

extension View {
  /// Liquid Glass in `shape` on macOS 26+, else a subtle material fill. The
  /// deployment target is macOS 13, so glass is availability-guarded everywhere.
  @ViewBuilder
  func liquidGlass<S: Shape>(in shape: S) -> some View {
    if #available(macOS 26.0, *) {
      self.glassEffect(.regular, in: shape)
    } else {
      self.background(shape.fill(Color.secondary.opacity(0.10)))
    }
  }

  /// Tinted Liquid Glass (for status pills), else a tinted fill.
  @ViewBuilder
  func liquidGlassTinted<S: Shape>(_ tint: Color, in shape: S) -> some View {
    if #available(macOS 26.0, *) {
      self.glassEffect(.regular.tint(tint.opacity(0.28)), in: shape)
    } else {
      self.background(shape.fill(tint.opacity(0.15)))
    }
  }

  /// Prominent Liquid Glass button on macOS 26+, else borderedProminent.
  @ViewBuilder
  func glassProminentButton() -> some View {
    if #available(macOS 26.0, *) {
      self.buttonStyle(.glassProminent)
    } else {
      self.buttonStyle(.borderedProminent)
    }
  }

  /// Interactive Liquid Glass button on macOS 26+, else bordered. For standalone
  /// control-layer actions (NOT ones nested inside another glass surface).
  @ViewBuilder
  func glassButton() -> some View {
    if #available(macOS 26.0, *) {
      self.buttonStyle(.glass)
    } else {
      self.buttonStyle(.bordered)
    }
  }
}
