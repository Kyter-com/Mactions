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
    VStack(alignment: .leading, spacing: 10) {
      repoPicker
      LabeledField("Labels", text: $app.labelsText, prompt: "self-hosted,macOS")
        .disabled(app.state != .offline)
      Stepper("Runners per repo: \(app.runnersPerRepo)", value: $app.runnersPerRepo, in: 1...5)
        .disabled(app.state != .offline)

      windowsSection

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
      .disabled(app.selectedRepos.isEmpty || app.state == .starting || app.state == .stopping)

      if !app.runners.isEmpty { runnerList }
    }
  }

  // MARK: Windows (opt-in)

  /// Windows support is OFF by default. The "Set up Windows runner" button is the
  /// ONLY trigger for any ISO download / base-image build — nothing heavy ever
  /// happens automatically. Once an image is built, a toggle adds a Windows fleet
  /// (labels `[self-hosted, Windows, mactions]`) alongside the macOS one.
  private var windowsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider()
      Text("Windows runner (experimental)")
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

      WindowsPreflightChecklist(app: app)

      if app.windowsImageReady {
        Toggle(isOn: Binding(
          get: { app.windowsEnabled },
          set: { app.setWindowsEnabled($0) }
        )) {
          Text("Add a Windows fleet ([self-hosted, Windows, mactions])").font(.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(app.state != .offline)
        Button("Rebuild / update Windows image") { app.setUpWindowsRunner() }
          .buttonStyle(.bordered).controlSize(.small)
          .disabled(app.state != .offline || app.windowsSetupBusy)
      } else {
        Button {
          app.setUpWindowsRunner()
        } label: {
          HStack(spacing: 6) {
            if app.windowsSetupBusy { ProgressView().controlSize(.small) }
            Label("Set up Windows runner", systemImage: "pc")
          }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(app.state != .offline || app.windowsSetupBusy)
        Text(
          app.windowsBackendAvailable
            ? "Clones a throwaway Win11 ARM64 base VM per job and destroys it after (multi-GB base build, one time). Proven end to end on VMware Fusion."
            : "Install VMware Fusion (free, from the Broadcom portal) — the proven Win11-ARM backend — then this downloads the latest Win11 ARM64 ISO + builds the one-time base VM."
        )
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear {
      app.refreshWindowsPreflight()
      app.checkForWindowsImageUpdate()
    }
  }

  private var repoPicker: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Repositories (\(app.selectedRepos.count) selected)")
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
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
      TextField("Filter repositories…", text: $repoFilter)
        .textFieldStyle(.roundedBorder)
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
      Text("Runners").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      ForEach(app.runners) { row in
        HStack(spacing: 6) {
          Image(systemName: "circle.fill")
            .font(.system(size: 6))
            .foregroundStyle(row.runner.phase == .online ? Color.green : Color.orange)
          Text(row.repoFullName).font(.caption2).foregroundStyle(.secondary)
          Text(row.runner.id).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
          Spacer()
          Text(row.runner.phase.rawValue).font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// The prerequisite checklist + auto-install button. Split into its own subview
/// so the SwiftUI type-checker stays fast and `windowsSection` doesn't balloon.
/// Shows ✓/✗ for Homebrew, VMware Fusion, and the UUP-dump converter tools, plus
/// a one-click installer for the MISSING FREE brew deps (converter tools +
/// xorriso). It never installs a hypervisor (Fusion is a manual Broadcom-portal
/// download) and never installs Homebrew (points at brew.sh).
private struct WindowsPreflightChecklist: View {
  @ObservedObject var app: AppState

  var body: some View {
    let report = app.windowsPreflight
    VStack(alignment: .leading, spacing: 3) {
      checkRow("Homebrew", ok: report?.homebrewInstalled ?? false)
      checkRow(
        hypervisorLabel(report),
        ok: report?.hasHypervisor ?? false)
      checkRow(
        converterLabel(report),
        ok: (report?.missingConverterFormulae.isEmpty ?? false))

      if let report, !(WindowsPreflight.installPlan(for: report) == .nothingToInstall) {
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
        Text(
          (report.homebrewInstalled)
            ? "Installs only the missing FREE tools (ISO converter tools + xorriso) via Homebrew. VMware Fusion is a separate, free manual download (Broadcom portal)."
            : "Install Homebrew first: https://brew.sh — then this installs the free tools."
        )
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func checkRow(_ label: String, ok: Bool) -> some View {
    HStack(spacing: 5) {
      Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
        .font(.system(size: 9))
        .foregroundStyle(ok ? Color.green : Color.secondary)
      Text(label).font(.caption2).foregroundStyle(.secondary)
      Spacer()
    }
  }

  /// Name the installed hypervisor (free-first recommended) so the user sees
  /// which backend is in play; otherwise prompt for the free default.
  private func hypervisorLabel(_ report: WindowsPreflight.Report?) -> String {
    if let backend = report?.recommendedBackend {
      return "Hypervisor: \(backend.displayName)"
    }
    return "Hypervisor (VMware Fusion recommended — free, proven Win11-ARM)"
  }

  private func converterLabel(_ report: WindowsPreflight.Report?) -> String {
    let missing = report?.missingConverterFormulae ?? []
    if missing.isEmpty { return "ISO converter tools" }
    return "ISO converter tools (missing: \(missing.joined(separator: ", ")))"
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
