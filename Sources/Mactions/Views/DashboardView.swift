import AppKit
import MactionsCore
import SwiftUI

/// The dashboard window: a Pulse-style console for the runner fleet. A header
/// (state + online toggle), a capacity strip, and three tabs — **Runners** and
/// **History** are master/detail (a list on the left, an inline detail + log
/// console on the right), **Memory** is a live gauge + sparkline. Binds to the
/// shared `AppState`, so it's a live mirror of the menubar app.
///
/// Performance contract: everything slow (GitHub fetches, `ps`, VMX reads) runs
/// off the main actor — the views only ever read already-published state, so the
/// Mac UI never stutters while logs load or memory samples.
struct DashboardView: View {
  @EnvironmentObject private var app: AppState
  @State private var tab: Tab? = .setup

  enum Tab: String, CaseIterable, Identifiable {
    case setup = "Setup"
    case runners = "Runners"
    case history = "History"
    case memory = "Memory"
    var id: String { rawValue }

    var systemImage: String {
      switch self {
      case .setup: return "gearshape"
      case .runners: return "bolt.horizontal"
      case .history: return "clock.arrow.circlepath"
      case .memory: return "memorychip"
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      DashboardHeader()
      Divider()
      // Rune-style left sidebar: pick a pane on the left, it fills the detail.
      NavigationSplitView {
        List(Tab.allCases, selection: $tab) { item in
          Label(item.rawValue, systemImage: item.systemImage).tag(item)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
      } detail: {
        Group {
          switch tab ?? .setup {
          case .setup: SetupPane()
          case .runners: RunnersPane()
          case .history: HistoryPane()
          case .memory: MemoryPane()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 820, minHeight: 560)
    .onAppear { app.refreshWindowsPerVMGB() }
    // Live memory sampling is started/stopped by DashboardWindowController as the
    // window opens/closes — deterministic across the reused window, unlike a
    // view-anchored .task that wouldn't reliably cancel on close.
  }
}

// MARK: - Header

private struct DashboardHeader: View {
  @EnvironmentObject private var app: AppState

  var body: some View {
    HStack(spacing: 12) {
      AppLogoView(size: 30)
        .padding(4)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 10))
        .help("Mactions")
      Circle().fill(statusColor).frame(width: 10, height: 10)
      Text(stateSubtitle).font(.callout.weight(.medium)).fixedSize()
      Divider().frame(height: 20)
      capacityChips
      Spacer(minLength: 8)
      if let message = app.statusMessage {
        Text(message)
          .font(.caption).foregroundStyle(.secondary)
          .lineLimit(2).frame(maxWidth: 280, alignment: .trailing)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button {
        app.toggleOnline()
      } label: {
        Label(
          app.state == .offline ? "Go online" : "Go offline",
          systemImage: app.state == .offline ? "play.fill" : "stop.fill")
      }
      .glassProminentButton()
      .disabled(
        app.selectedRepos.isEmpty
          || !app.selectedOSes.contains(where: { $0.isImplemented })
          || app.windowsSetupBusy  // can't clone the base while it's being (re)built
          || app.state == .starting || app.state == .stopping)
      .help(
        app.windowsSetupBusy
          ? "Wait for the Windows base image to finish building before going online."
          : app.selectedRepos.isEmpty
            ? "Pick at least one repository in Setup first."
            : "Bring the configured runner fleet online / offline.")
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
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
      let n = app.runners.count
      return "Online · \(n) runner\(n == 1 ? "" : "s")"
    }
  }

  /// The capacity chips (Host RAM / live runners / Windows budget), folded into
  /// the header bar to save vertical space — a row of glass pills in the control
  /// layer, grouped so they batch-render + blend (Apple's guidance).
  private var capacityChips: some View {
    let cap = app.capacity
    return GlassGroup(spacing: 8) {
      HStack(spacing: 8) {
        chip("Host RAM", formatBytes(cap.hostRAMBytes), systemImage: "memorychip",
          help: "Total physical memory on this Mac.")
        chip("Live runners", "\(cap.liveMacRunners) macOS · \(cap.liveWindowsRunners) Win",
          systemImage: "bolt.fill", help: "Runners currently online.")
        chip("Windows budget",
          cap.windowsMaxConcurrentVMs > 0 ? "\(cap.windowsMaxConcurrentVMs) × \(cap.windowsPerVMGB) GB" : "—",
          systemImage: "cube.box",
          help: cap.windowsMaxConcurrentVMs > 0
            ? "Max concurrent Win11-ARM VMs this Mac's RAM allows (each ~\(cap.windowsPerVMGB) GB). The cap go-online enforces — not live usage (see the Memory tab)."
            : "No Windows base image yet, or not enough RAM to run one VM.")
      }
    }
  }

  private func chip(_ label: String, _ value: String, systemImage: String, help: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage).font(.caption).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 0) {
        Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).tracking(0.4).lineLimit(1)
        Text(value).font(.caption.weight(.medium)).monospacedDigit().lineLimit(1)
      }
    }
    .fixedSize()  // keep each chip one line → uniform height (no "1 macOS · 1 Win" wrap)
    .padding(.horizontal, 10).padding(.vertical, 6)
    .liquidGlass(in: RoundedRectangle(cornerRadius: 8))
    .help(help)
  }
}

// MARK: - Runners (master/detail)

private struct RunnersPane: View {
  @EnvironmentObject private var app: AppState
  @State private var selected: String?

  var body: some View {
    content.task {
      // Poll which of our runners GitHub reports as executing a job (`busy`) so
      // the activity ring spins only during a real job. Runs while this pane shows.
      while !Task.isCancelled {
        await app.refreshRunnerBusy()
        try? await Task.sleep(nanoseconds: 6_000_000_000)
      }
    }
  }

  @ViewBuilder private var content: some View {
    if app.runners.isEmpty {
      DashboardEmptyState(
        systemImage: "bolt.slash",
        title: app.state == .online ? "No runners up yet" : "No runners online",
        message: app.state == .online
          ? "Runners are being provisioned, or none came up — check repo permissions / labels."
          : "Go online to bring ephemeral runners up.")
    } else {
      HStack(spacing: 0) {
        List(selection: $selected) {
          ForEach(app.runners) { row in
            RunnerRow(row: row, busy: app.busyRunnerNames.contains(row.runner.id)).tag(row.id)
          }
        }
        .listStyle(.inset)
        .frame(width: 280)
        Divider()
        if let row = app.runners.first(where: { $0.id == selected }) {
          RunnerDetailView(row: row)
        } else {
          DashboardEmptyState(
            systemImage: "sidebar.right", title: "Select a runner",
            message: "Pick a live runner to see its current job and step progress.")
        }
      }
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
  @State private var spin = false

  private var color: Color {
    switch phase {
    case .online: return .green
    case .failed: return .red
    case .stopped: return .secondary
    default: return .orange
    }
  }

  var body: some View {
    ZStack {
      if busy {
        Circle()
          .trim(from: 0, to: 0.7)
          .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
          .frame(width: 13, height: 13)
          .rotationEffect(.degrees(spin ? 360 : 0))
          .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
          .onAppear { spin = true }
      }
      Circle().fill(color).frame(width: 7, height: 7)
    }
    .frame(width: 16, height: 16)
  }
}

private struct RunnerRow: View {
  let row: FleetRunnerRow
  let busy: Bool
  var body: some View {
    HStack(spacing: 9) {
      OSLogo(os: row.os, size: 14).frame(width: 16)
      RunnerActivityDot(phase: row.runner.phase, busy: busy)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.repoFullName).font(.callout).lineLimit(1).truncationMode(.middle)
        Text(row.runner.id).font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
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
          case .found(let job):
            jobSteps(job)
          case .notFound:
            VStack(alignment: .leading, spacing: 4) {
              Text("No job running on this runner right now.").font(.callout)
              Text("Ephemeral runners idle until GitHub assigns a job; the full log appears under History once it finishes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    // Poll the running job's steps while this runner is selected (off-main).
    .task(id: row.runner.id) {
      while !Task.isCancelled {
        await app.loadRunnerJob(for: row.runner.id, repo: row.repoFullName)
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
            Button(action: app.clearRunHistory) { Image(systemName: "trash") }
              .buttonStyle(.borderless).controlSize(.small).help("Clear run history")
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
  }
}

private struct HistoryRow: View {
  let record: RunRecord
  var body: some View {
    HStack(spacing: 9) {
      OSLogo(os: record.os, size: 13).frame(width: 16)
      Circle().fill(statusColor(record.resolvedStatus)).frame(width: 7, height: 7)
      VStack(alignment: .leading, spacing: 1) {
        Text(record.repo).font(.callout).lineLimit(1).truncationMode(.middle)
        Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.system(size: 10)).foregroundStyle(.secondary)
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
      Text("\(number)")
        .font(.system(size: 10).monospaced()).foregroundStyle(.tertiary)
        .frame(width: 44, alignment: .trailing)
      Text(line.isEmpty ? " " : line)
        .font(.system(size: 11).monospaced()).foregroundStyle(.primary)
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
      OSLogo(os: os, size: 16).frame(width: 20).help(os.displayName)
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

private struct DashboardEmptyState: View {
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
