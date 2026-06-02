import MactionsCore
import SwiftUI

/// The entire UI: a single popover hung off the menubar item. Signed-out shows
/// the GitHub connect flow; signed-in shows a searchable multi-repo picker, the
/// online toggle, and live runners. Split into small subviews so the SwiftUI
/// type-checker stays fast.
struct MenuContentView: View {
  @EnvironmentObject private var app: AppState
  @State private var pat = ""
  @State private var repoFilter = ""
  @State private var confirmRebuild = false
  /// The repo picker is collapsed to a one-line summary; expanded only while the
  /// user is actively choosing (auto-expands when nothing is selected yet).
  @State private var showRepoPicker = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      if let message = app.statusMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      if app.isSignedIn {
        fleetSection
      } else {
        connectSection
      }

      Divider()
      footer
    }
    .padding(14)
    .task(id: app.isSignedIn) { await app.loadReposIfNeeded() }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 8) {
      Circle().fill(statusColor).frame(width: 9, height: 9)
      Text("Mactions").font(.headline)
      Spacer()
      Button {
        DashboardWindowController.shared.show()
      } label: {
        Image(systemName: "macwindow")
      }
      .buttonStyle(.borderless)
      .help("Open the dashboard window (runners, history, capacity)")
      Text(app.state.rawValue.capitalized)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
  }

  private var statusColor: Color {
    switch app.state {
    case .offline: return .secondary
    case .starting, .stopping: return .orange
    case .online: return .green
    }
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 8) {
      if app.isSignedIn {
        Button("Sign out", action: app.signOut)
        if app.state == .offline {
          Button("Remove cached agent", action: app.cleanUpHostFiles)
            .help(
              "Per-run files are wiped automatically after every job. This also removes the cached ~200 MB runner agent.")
        }
      }
      Spacer()
      Button("Quit") { NSApp.terminate(nil) }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  // MARK: Connect (signed out)

  private var connectSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Connect GitHub").font(.subheadline.weight(.semibold))

      if app.gitHubCLIAvailable {
        Button {
          app.signInWithGitHubCLI()
        } label: {
          Label("Use my GitHub CLI login", systemImage: "terminal").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        Text("Easiest — reuses your existing `gh` login. No token needed.")
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Divider()
        Text("Other ways to connect").font(.caption).foregroundStyle(.secondary)
      }

      if let code = app.pendingDeviceCode {
        VStack(alignment: .leading, spacing: 6) {
          Text("Enter this code at github.com/login/device (opened in your browser):")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(code.userCode)
            .font(.system(.title2, design: .monospaced).weight(.bold))
            .textSelection(.enabled)
          ProgressView().controlSize(.small)
        }
      } else {
        Button {
          app.signInWithDeviceFlow()
        } label: {
          Label("Sign in with GitHub", systemImage: "person.badge.key")
        }
        .buttonStyle(.bordered)
        .disabled(app.authBusy)
        Text("Device-flow sign-in needs an OAuth App client id. No client id yet? Paste a token instead.")
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      LabeledField("OAuth client id (optional)", text: $app.clientId, prompt: "Iv1.xxxxxxxx")
        .onChange(of: app.clientId) { _ in app.saveConfig() }

      Divider()

      Text("…or paste a token").font(.caption).foregroundStyle(.secondary)
      SecureField("ghp_… / github_pat_…", text: $pat)
        .textFieldStyle(.roundedBorder)
      Button("Use token") {
        app.signInWithToken(pat)
        pat = ""
      }
      .buttonStyle(.bordered)
      .disabled(pat.trimmingCharacters(in: .whitespaces).isEmpty)
      Text("Needs repo-admin (`repo` scope, or fine-grained Administration: read & write).")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: Fleet (signed in)

  private var filteredRepos: [RepoRef] {
    let query = repoFilter.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return app.availableRepos }
    return app.availableRepos.filter { $0.fullName.lowercased().contains(query) }
  }

  private var fleetSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      osSelector
      windowsArea
      repoSelector
      controlsRow

      Button {
        app.toggleOnline()
      } label: {
        Label(
          app.state == .offline ? "Go online" : "Go offline",
          systemImage: app.state == .offline ? "play.fill" : "stop.fill"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(
        app.selectedRepos.isEmpty
          || !app.selectedOSes.contains(where: { $0.isImplemented })
          || app.state == .starting || app.state == .stopping)

      if !app.runners.isEmpty { runnerList }
    }
    .onAppear {
      app.refreshWindowsPreflight()
      app.checkForWindowsImageUpdate()
      if app.selectedRepos.isEmpty { showRepoPicker = true }
    }
  }

  // MARK: OS selector (logo tiles)

  private var osSelector: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("RUNNER OS")
      HStack(spacing: 10) {
        osTile(.macOS)
        osTile(.windows)
        osTile(.linux)
        Spacer(minLength: 0)
      }
    }
  }

  /// One OS tile: the brand logo in a box whose border highlights (accent) when
  /// selected. Windows shows a download badge until its base image is built
  /// (tapping then starts setup) and a spinner while building; Linux is dimmed
  /// "soon". macOS/Windows toggle selection; the border IS the checkbox.
  private func osTile(_ os: RunnerOS) -> some View {
    // Windows reads as "selected" (accent border) ONLY once its image is built;
    // until then the tile shows just the download badge. A persisted-but-unready
    // .windows is harmless — goOnline also gates the Windows fleet on
    // windowsImageReady — and this avoids a contradictory border+badge state for a
    // migrated user.
    let selected =
      app.isOSSelected(os) && os.isImplemented && (os != .windows || app.windowsImageReady)
    let building = (os == .windows && app.windowsSetupBusy)
    let needsSetup = (os == .windows && !app.windowsImageReady && !building)
    let disabled = !os.isImplemented
    return Button {
      handleOSTap(os)
    } label: {
      VStack(spacing: 5) {
        ZStack {
          // SAME white (adaptive .primary) for ALL three marks — disabled (Linux)
          // and needs-setup (unbuilt Windows) dim via OPACITY only, never a
          // different gray hue, so the set always looks uniform.
          OSLogo(os: os, size: 24, tint: .primary)
            .opacity(building ? 0 : (disabled ? 0.45 : (needsSetup ? 0.5 : 1)))
          if building { ProgressView().controlSize(.small) }
        }
        .frame(width: 50, height: 46)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.10)))
        .overlay(
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
              selected ? Color.accentColor : Color.secondary.opacity(0.18),
              lineWidth: selected ? 2 : 1)
        )
        // Download badge sits OUTSIDE the box (top-trailing), so it never crowds
        // the logo inside the square.
        .overlay(alignment: .topTrailing) {
          if needsSetup {
            Image(systemName: "arrow.down.circle.fill")
              .font(.system(size: 13))
              .foregroundStyle(Color.accentColor, Color(NSColor.windowBackgroundColor))
              .offset(x: 5, y: -5)
          }
        }
        Text(os.displayName)
          .font(.system(size: 9, weight: selected ? .semibold : .regular))
          .foregroundStyle(disabled ? .tertiary : (selected ? .primary : .secondary))
        Text(os == .linux ? "soon" : " ")
          .font(.system(size: 8)).foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabled || building || app.state != .offline)
    .help(osTileHelp(os))
  }

  private func handleOSTap(_ os: RunnerOS) {
    switch os {
    case .macOS:
      app.toggleOS(.macOS)
    case .windows:
      if app.windowsImageReady { app.toggleOS(.windows) } else { app.setUpWindowsRunner() }
    case .linux:
      break
    }
  }

  private func osTileHelp(_ os: RunnerOS) -> String {
    switch os {
    case .macOS: return "Run a macOS runner fleet (local process per job)."
    case .windows:
      return app.windowsImageReady
        ? "Run a Windows runner fleet (throwaway Win11-ARM VM per job)."
        : "Tap to build the one-time Win11-ARM base image, then Windows fleets become available."
    case .linux: return "Linux runners are coming soon."
    }
  }

  /// Windows setup/management, shown contextually below the OS tiles: the live
  /// stepper while building; setup guidance + what's-missing while not built (so
  /// the prereq checks vanish once it's ready); the update nudge + a low-key
  /// rebuild once it's ready.
  @ViewBuilder
  private var windowsArea: some View {
    if app.windowsSetupBusy {
      windowsSetupStepper
    } else if !app.windowsImageReady, app.selectedOSes.contains(.windows) || windowsPrereqsIncomplete {
      VStack(alignment: .leading, spacing: 4) {
        WindowsPreflightChecklist(app: app)
        Text(
          app.windowsBackendAvailable
            ? "Tap the Windows tile to build the one-time base image (~30–40 min, resumable)."
            : "Install VMware Fusion (free, Broadcom portal), then tap Windows to build the base image."
        )
        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    } else if app.windowsImageReady {
      VStack(alignment: .leading, spacing: 4) {
        if let notice = app.windowsUpdateNotice {
          Label(notice, systemImage: "arrow.up.circle")
            .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        Button("Rebuild / update Windows image") { confirmRebuild = true }
          .buttonStyle(.borderless).controlSize(.small).font(.caption2)
          .disabled(app.state != .offline)
      }
      .confirmationDialog(
        "Rebuild the Windows base image?", isPresented: $confirmRebuild, titleVisibility: .visible
      ) {
        Button("Rebuild (re-downloads ~8 GB)", role: .destructive) { app.setUpWindowsRunner(force: true) }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Re-downloads the latest Win11 ARM64 ISO (~8 GB) and rebuilds the base VM headless — about 30–40 minutes. This replaces the existing base image.")
      }
    }
  }

  /// True when a prereq the Windows path needs is still missing (so the setup
  /// guidance is worth surfacing even before the Windows tile is selected).
  private var windowsPrereqsIncomplete: Bool {
    guard let r = app.windowsPreflight else { return false }
    return !(r.ready)
  }

  private func sectionLabel(_ text: String) -> some View {
    Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
  }

  // MARK: Repos (collapsed) + controls

  private var repoSelector: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) { showRepoPicker.toggle() }
      } label: {
        HStack(spacing: 6) {
          sectionLabel("REPOS")
          Text("· \(app.selectedRepos.count) selected").font(.caption2).foregroundStyle(.secondary)
          Spacer()
          Text(showRepoPicker ? "Done" : "Edit").font(.caption2)
          Image(systemName: showRepoPicker ? "chevron.up" : "chevron.right").font(.system(size: 9))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if showRepoPicker {
        repoPicker
      } else {
        Text(
          app.selectedRepos.isEmpty
            ? "No repositories selected — tap Edit to choose."
            : app.selectedRepos.map(\.name).joined(separator: ", ")
        )
        .font(.caption2)
        .foregroundStyle(app.selectedRepos.isEmpty ? Color.orange : Color.secondary)
        .lineLimit(2).truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// Runners-per-repo (common) + an Advanced disclosure holding the editable
  /// macOS label set (kept, but tucked away to declutter).
  private var controlsRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      Stepper("Runners per repo: \(app.runnersPerRepo)", value: $app.runnersPerRepo, in: 1...5)
        .font(.caption)
        .disabled(app.state != .offline)
      DisclosureGroup {
        LabeledField("macOS labels", text: $app.labelsText, prompt: "self-hosted,macOS,mactions")
          .disabled(app.state != .offline)
        Text("Windows fleets always register [self-hosted, Windows, mactions].")
          .font(.system(size: 9)).foregroundStyle(.tertiary)
      } label: {
        Text("Advanced").font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  /// Live progress for the long base-image build: an ordered checklist of the
  /// phases, with completed steps checked, the active step spinning + showing a
  /// sub-status (download/convert, install ticks, etc.), and pending steps dimmed.
  /// Driven by `AppState.windowsSetupStep` (streamed from the prep scripts).
  @ViewBuilder
  private var windowsSetupStepper: some View {
    if app.windowsSetupBusy, let current = app.windowsSetupStep {
      VStack(alignment: .leading, spacing: 5) {
        ForEach(WindowsSetupStep.allCases, id: \.self) { step in
          HStack(alignment: .top, spacing: 6) {
            stepIcon(step, current: current)
              .frame(width: 14, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
              Text(step.title)
                .font(.caption2)
                .fontWeight(step == current ? .semibold : .regular)
                .foregroundStyle(step <= current ? Color.primary : Color.secondary)
              if step == current {
                Text(app.windowsSetupDetail ?? step.hint)
                  .font(.system(size: 9))
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            Spacer(minLength: 0)
          }
        }
        Text("Safe to leave running — it survives network blips and resumes from the last step if interrupted.")
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
  }

  @ViewBuilder
  private func stepIcon(_ step: WindowsSetupStep, current: WindowsSetupStep) -> some View {
    if step < current {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption2)
    } else if step == current {
      ProgressView().controlSize(.mini)
    } else {
      Image(systemName: "circle").foregroundStyle(.secondary).font(.caption2)
    }
  }

  private var repoPicker: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        TextField("Filter repositories…", text: $repoFilter)
          .textFieldStyle(.roundedBorder)
        if app.reposLoading {
          ProgressView().controlSize(.small)
        } else {
          Button {
            Task { await app.loadRepos() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("Refresh repositories")
        }
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(filteredRepos) { repo in repoRow(repo) }
        }
        .padding(4)
      }
      .frame(height: 150)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
      .overlay(alignment: .center) {
        if app.availableRepos.isEmpty && !app.reposLoading {
          Text("No admin repos loaded — try Refresh.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func repoRow(_ repo: RepoRef) -> some View {
    Button {
      app.toggleRepo(repo)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: app.isSelected(repo) ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(app.isSelected(repo) ? Color.accentColor : Color.secondary)
        Text(repo.fullName).font(.caption).lineLimit(1).truncationMode(.middle)
        if repo.isPrivate {
          Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.secondary)
        }
        Spacer()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(app.state != .offline)
  }

  private var runnerList: some View {
    VStack(alignment: .leading, spacing: 4) {
      sectionLabel("LIVE RUNNERS")
      ForEach(app.runners) { row in
        HStack(spacing: 6) {
          OSLogo(os: row.os, size: 13)
            .frame(width: 14)
            .help(row.os.displayName)
          Circle()
            .fill(row.runner.phase == .online ? Color.green : Color.orange)
            .frame(width: 6, height: 6)
          Text(row.repoFullName).font(.caption2).foregroundStyle(.secondary)
          Text(row.runner.id).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
          Spacer()
          Text(row.runner.phase.rawValue).font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// Shows what's STILL MISSING for the Windows path (not a full ✓/✗ list — done
/// items are simply omitted, so the section empties out as prerequisites land and
/// disappears entirely once the base image is built). Plus a one-click installer
/// for the missing FREE brew deps (converter tools + xorriso). It never installs a
/// hypervisor (Fusion is a manual Broadcom-portal download) and never installs
/// Homebrew (points at brew.sh).
private struct WindowsPreflightChecklist: View {
  @ObservedObject var app: AppState

  var body: some View {
    // Until the first preflight scan publishes a report, render nothing rather
    // than treating everything as missing (which flashed "Homebrew/Fusion missing"
    // on machines that have them).
    if let report = app.windowsPreflight {
      checklist(report)
    }
  }

  @ViewBuilder
  private func checklist(_ report: WindowsPreflight.Report) -> some View {
    let missingConverters = report.missingConverterFormulae
    VStack(alignment: .leading, spacing: 3) {
      if !report.homebrewInstalled { missingRow("Homebrew — install from brew.sh") }
      if !report.hasHypervisor { missingRow("VMware Fusion — free, from the Broadcom portal") }
      if !missingConverters.isEmpty {
        missingRow("ISO converter tools — \(missingConverters.joined(separator: ", "))")
      }

      // Only show the installer when it can actually DO something (the `.install`
      // case). On `.homebrewMissing` it'd be a silent no-op — the "Homebrew —
      // install from brew.sh" missing row above already tells the user what to do.
      if case .install = WindowsPreflight.installPlan(for: report) {
        Button {
          app.installWindowsFreePrerequisites()
        } label: {
          HStack(spacing: 6) {
            if app.windowsPreflightBusy { ProgressView().controlSize(.small) }
            Label("Install free prerequisites", systemImage: "arrow.down.circle")
          }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(app.state != .offline || app.windowsPreflightBusy)
      }
    }
  }

  /// A single "still needed" row (only ever shown for things that ARE missing).
  private func missingRow(_ label: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: "exclamationmark.circle")
        .font(.system(size: 9)).foregroundStyle(.orange)
      Text(label).font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }
}

/// A label-over-field pair sized for the narrow popover.
private struct LabeledField: View {
  let title: String
  @Binding var text: String
  var prompt: String = ""

  init(_ title: String, text: Binding<String>, prompt: String = "") {
    self.title = title
    self._text = text
    self.prompt = prompt
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      TextField(prompt, text: $text).textFieldStyle(.roundedBorder)
    }
  }
}
