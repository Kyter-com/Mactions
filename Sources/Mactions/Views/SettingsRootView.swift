import AppKit
import MactionsCore
import SwiftUI

/// The Settings sheet's tabs. Used both by the `TabView` selection and by
/// `AppState.presentSettings(_:)` to deep-link a tab (e.g. a "needs setup" tap on
/// a platform tile opens straight to Windows / Linux).
enum SettingsTab: Hashable { case general, windows, linux }

/// The Settings surface — the home for everything set ONCE (per HIG, recurring
/// per-item config belongs on the live window's Configure panel, not here): the
/// GitHub connection, new-repo defaults + capacity, and the long Windows/Linux
/// base setup + maintenance flows that used to crowd the old Setup pane.
///
/// The content of the Settings window — a NON-MODAL companion window
/// (`SettingsWindowController`), not the macOS ⌘, preferences window (the
/// AppKit-hosted app can't reach `showSettingsWindow:`) and no longer a modal
/// sheet (which overlaid live runners + trapped a running base build). The user
/// asked for settings in the app; a companion window is the in-app form that
/// doesn't block the dashboard.
///
/// We deliberately do NOT use a macOS `TabView`: it draws its own full-width
/// tab-bar band (hairlines above AND below the pills) that read as a stray
/// "overlap bar". A single segmented `Picker` + `switch` gives the same tabbed
/// feel with chrome we control, and `AppState.settingsTab` lets a deep-link
/// (e.g. a platform tile's "needs setup" tap) land on the right tab. The window
/// titlebar provides the title + close, so no in-content header is needed.
struct SettingsRootView: View {
  @EnvironmentObject private var app: AppState

  var body: some View {
    VStack(spacing: 0) {
      Picker("", selection: $app.settingsTab) {
        Text("General").tag(SettingsTab.general)
        Text("Windows").tag(SettingsTab.windows)
        Text("Linux").tag(SettingsTab.linux)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Settings category")
      .padding(.horizontal, MactionsTheme.Spacing.section)
      .padding(.top, MactionsTheme.Spacing.control)
      .padding(.bottom, MactionsTheme.Spacing.control)
      Divider()
      Group {
        switch app.settingsTab {
        case .general: GeneralSettingsTab()
        case .windows: WindowsSettingsTab()
        case .linux: LinuxSettingsTab()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: 540, height: 600)
  }
}

// MARK: - General

private struct GeneralSettingsTab: View {
  @EnvironmentObject private var app: AppState
  @State private var pat = ""
  /// Local draft for the default-labels field — committed on Return / focus loss,
  /// so live typing isn't normalized away (same reason as LabelEditor's draft).
  @State private var labelsDraft = ""
  @FocusState private var labelsFocused: Bool

  var body: some View {
    Form {
      // The connect flow lives here now, and all auth feedback flows through
      // app.statusMessage — render it so a no-client-id / failed sign-in isn't
      // a silent dead button (the live window's status strip is a different window).
      if let message = app.statusMessage {
        Section { Banner(message, severity: .info) }
      }
      // The toggle/defaults below stage while online, but the restart bar lives
      // on the MAIN window (possibly behind this one) — without this banner an
      // edit here just looks applied. One banner for the whole tab: the flag is
      // global, and pendingRestart ⟹ online (no extra gating needed).
      if app.pendingRestart {
        Section {
          Banner(
            "Configuration changed — restart the fleet to apply.",
            severity: .warning, icon: "arrow.triangle.2.circlepath"
          ) {
            Button("Restart fleet") { app.restartFleet() }
              .disabled(app.isTransitioning)
          }
        }
      }
      if app.isSignedIn {
        accountSection
        scopeSection
        defaultsSection
      } else {
        connectSection
      }
      capacitySection  // reads only ProcessInfo — useful signed-out too
    }
    .formStyle(.grouped)
    .onAppear { labelsDraft = app.defaultMacOSLabelsText }
  }

  // MARK: Connect (signed out)

  @ViewBuilder
  private var connectSection: some View {
    Section("Connect GitHub") {
      if app.gitHubCLIAvailable {
        Button {
          app.signInWithGitHubCLI()
        } label: {
          Label("Use my GitHub CLI login", systemImage: "terminal")
        }
        Text("Easiest — reuses your existing `gh` login. No token needed.")
          .font(.caption).foregroundStyle(.secondary)
      }

      if let code = app.pendingDeviceCode {
        VStack(alignment: .leading, spacing: MactionsTheme.Spacing.tight) {
          Text("Enter this code at github.com/login/device (opened in your browser):")
            .font(.caption).foregroundStyle(.secondary)
          Text(code.userCode)
            .font(.system(.title2, design: .monospaced).weight(.bold)).textSelection(.enabled)
          ProgressView().controlSize(.small)
        }
      } else {
        Button {
          app.signInWithDeviceFlow()
        } label: {
          Label("Sign in with GitHub", systemImage: "person.badge.key")
        }
        .disabled(app.authBusy)
      }

      LabeledContent("OAuth client id") {
        TextField("Iv1.xxxxxxxx (optional)", text: $app.clientId)
          .onChange(of: app.clientId) { _ in app.saveConfig() }
      }
    }

    Section("…or paste a token") {
      SecureField("ghp_… / github_pat_…", text: $pat)
      Button("Use token") {
        app.signInWithToken(pat)
        pat = ""
      }
      .disabled(pat.trimmingCharacters(in: .whitespaces).isEmpty)
      Text("Needs repo-admin (`repo` scope, or fine-grained Administration: read & write).")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  // MARK: Account (signed in)

  private var accountSection: some View {
    Section("Account") {
      InfoRow("GitHub", systemImage: "checkmark.seal.fill") {
        Text("Signed in").font(.callout).foregroundStyle(.green)
      }
      Button("Sign out", action: app.signOut)
      Button("Remove cached agent", action: app.cleanUpHostFiles)
        .disabled(app.state != .offline)
        .help("Per-run files are wiped after every job. This also removes the cached ~200 MB runner agent.")
      Button("Reveal logs in Finder", action: app.revealLogsInFinder)
    }
  }

  // MARK: New-repo defaults

  private var defaultsSection: some View {
    Section {
      Toggle("macOS", isOn: defaultPlatformBinding(.macOS))
      Toggle("Windows", isOn: defaultPlatformBinding(.windows))
      Toggle("Linux", isOn: defaultPlatformBinding(.linux))
      Stepper(
        "Default max macOS runners: \(app.plan.defaultMacOSCount)",
        value: Binding(get: { app.plan.defaultMacOSCount }, set: { app.setDefaultMacOSCount($0) }),
        in: 1...5)
      LabeledContent("Default macOS labels") {
        TextField("self-hosted, macOS, mactions", text: $labelsDraft)
          .focused($labelsFocused)
          .onSubmit { app.setDefaultMacOSLabels(labelsDraft) }
          .onChange(of: labelsFocused) { focused in
            if !focused { app.setDefaultMacOSLabels(labelsDraft) }
          }
          .onChange(of: app.defaultMacOSLabelsText) { value in
            if !labelsFocused { labelsDraft = value }
          }
      }
    } header: {
      Text("Defaults for new repositories")
    } footer: {
      Text("Applied when you add a repo — and to repos discovered by “all repositories” mode. Per-repo platforms, max runners, and labels are tuned by selecting the repo on the main window.")
    }
  }

  // MARK: Scope (all-repos discovery)

  private var scopeSection: some View {
    Section {
      Toggle(
        "Watch all repositories I can admin",
        isOn: Binding(get: { app.plan.isAllRepos }, set: { app.setAllRepos($0) }))
        .disabled(app.isTransitioning)
    } header: {
      Text("Scope")
    } footer: {
      Text(
        "While online, queued jobs in any repository you administer spin up runners using the "
          + "defaults above (most recently pushed repos are watched; fleets retire when a repo "
          + "goes quiet). Explicitly added repositories always use their own settings. "
          + "Changes made while online take effect after a fleet restart.")
    }
  }

  private func defaultPlatformBinding(_ os: RunnerOS) -> Binding<Bool> {
    Binding(get: { app.isDefaultPlatform(os) }, set: { app.setDefaultPlatform(os, on: $0) })
  }

  // MARK: Capacity (the contextual home for the old top-bar chips)

  private var capacitySection: some View {
    Section {
      InfoRow("Host RAM", value: formatBytesGB(app.capacity.hostRAMBytes), systemImage: "memorychip")
      InfoRow(
        "Windows VM budget",
        value: app.capacity.windowsMaxConcurrentVMs > 0
          ? "\(app.capacity.windowsMaxConcurrentVMs) × \(app.capacity.windowsPerVMGB) GB"
          : "—",
        systemImage: "cube.box")
      InfoRow("Live runners", value: "\(app.runners.count)", systemImage: "bolt.fill")
    } header: {
      Text("Capacity")
    } footer: {
      Text("Max concurrent Win11-ARM VMs this Mac's RAM allows. Live memory is on the Memory tab.")
    }
  }
}

// MARK: - Windows

private struct WindowsSettingsTab: View {
  @EnvironmentObject private var app: AppState
  @State private var confirmRebuild = false
  @State private var showBuildOptions = false

  var body: some View {
    Form {
      if app.windowsSetupBusy {
        Section("Building base image") {
          SetupStepper(
            current: app.windowsSetupStep ?? .prerequisites,
            detail: app.windowsSetupDetail,
            note: "Safe to leave running — it survives network blips and resumes from the last step.",
            onCancel: { app.cancelWindowsSetup() })
        }
      } else if !app.windowsImageReady {
        notReadySection
      } else {
        readySection
      }
    }
    .formStyle(.grouped)
    .onAppear {
      app.refreshWindowsPreflight()
      app.checkForWindowsImageUpdate()
      app.refreshWindowsBaseInfo()
    }
  }

  private var notReadySection: some View {
    Section {
      if let failure = app.windowsSetupFailure {
        failureBanner(failure, external: app.windowsSetupFailureIsExternal)
      }
      WindowsPreflightChecklist(app: app)
      Text(
        app.windowsBackendAvailable
          ? "Build the one-time Win11-ARM base image (~30–40 min, resumable). Each Windows job then clones a throwaway VM."
          : "Install VMware Fusion (free, Broadcom portal), then build the base image."
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button {
        app.setUpWindowsRunner()
      } label: {
        Label("Build Windows base image", systemImage: "hammer")
      }
      .disabled(app.state != .offline || !app.windowsBackendAvailable)
      buildOptions
    } header: {
      Text("Windows runner image")
    }
  }

  private var readySection: some View {
    Section {
      if let failure = app.windowsSetupFailure {
        failureBanner(failure, external: app.windowsSetupFailureIsExternal)
      }
      if app.windowsMaintenance.needsRebuild, let notice = app.windowsUpdateNotice {
        Banner(notice, severity: .warning, icon: maintenanceIcon)
      }
      if let summary = app.windowsBaseSummary {
        InfoRow("Base", value: summary, systemImage: "cube.box")
      } else {
        InfoRow("Base image", value: app.windowsBaseImage, systemImage: "cube.box")
      }
      if let log = app.windowsBuildLogPath {
        logLink("Build log", path: log)
      }
      if let guestLog = app.windowsGuestLogPath {
        logLink("Guest provisioning log", path: guestLog)
      }
      rebuildButton
      buildOptions
      if !app.windowsBackendAvailable {
        Text("Install VMware Fusion to rebuild.").font(.caption).foregroundStyle(.tertiary)
      } else if app.state != .offline {
        Text("Go offline to rebuild.").font(.caption).foregroundStyle(.tertiary)
      }
    } header: {
      Text("Windows runner image")
    }
    .confirmationDialog(
      "Rebuild the Windows base image?", isPresented: $confirmRebuild, titleVisibility: .visible
    ) {
      Button(rebuildConfirmLabel, role: .destructive) { app.setUpWindowsRunner(force: true) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(rebuildDialogMessage)
    }
  }

  @ViewBuilder
  private var rebuildButton: some View {
    Button {
      confirmRebuild = true
    } label: {
      Label(
        app.windowsMaintenance.needsRebuild ? "Rebuild Windows image" : "Rebuild / update image",
        systemImage: "arrow.clockwise")
    }
    .disabled(app.state != .offline || !app.windowsBackendAvailable)
  }

  private var buildOptions: some View {
    DisclosureGroup("Build options", isExpanded: $showBuildOptions) {
      Toggle("Show the VM window during builds", isOn: $app.windowsBuildShowsWindow)
        .onChange(of: app.windowsBuildShowsWindow) { _ in app.saveConfig() }
      Toggle("Keep a failed build's disk for diagnosis", isOn: $app.windowsKeepFailedDisk)
        .onChange(of: app.windowsKeepFailedDisk) { _ in app.saveConfig() }
    }
    .disabled(app.windowsSetupBusy)
  }

  private func failureBanner(_ message: String, external: Bool) -> some View {
    Banner(
      message, severity: external ? .warning : .error,
      icon: external ? "wifi.exclamationmark" : nil
    ) {
      if let log = app.windowsBuildLogPath { logLink("View build log", path: log) }
    }
  }

  private var maintenanceIcon: String {
    switch app.windowsMaintenance {
    case .osBuildAvailable: return "arrow.up.circle"
    case .provisioningOutdated: return "wrench.and.screwdriver"
    case .both: return "exclamationmark.triangle"
    case .upToDate, .notBuilt: return "arrow.clockwise.circle"
    }
  }

  private var rebuildConfirmLabel: String {
    if case .provisioningOutdated = app.windowsMaintenance { return "Rebuild (reuses cached ISO)" }
    return "Rebuild (re-downloads ~8 GB)"
  }

  private var rebuildDialogMessage: String {
    if case .provisioningOutdated = app.windowsMaintenance {
      return "Rebuilds the base VM headless with the updated runner setup recipe — about 30–40 minutes. Reuses the cached Win11 ARM64 ISO (the Windows build is unchanged), so no large re-download. Replaces the existing base image."
    }
    return "Re-downloads the latest Win11 ARM64 ISO (~8 GB) and rebuilds the base VM headless — about 30–40 minutes. This replaces the existing base image."
  }
}

// MARK: - Linux

private struct LinuxSettingsTab: View {
  @EnvironmentObject private var app: AppState

  var body: some View {
    Form {
      if app.linuxSetupBusy {
        Section("Setting up") {
          SetupStepper(current: app.linuxSetupStep ?? .verifyDaemon, detail: app.linuxSetupDetail)
        }
      } else if app.linuxImageReady {
        readySection
      } else {
        notReadySection
      }
    }
    .formStyle(.grouped)
  }

  private var notReadySection: some View {
    Section {
      if let failure = app.linuxSetupFailure {
        failureBanner(failure, external: app.linuxSetupFailureIsExternal)
      }
      if let backend = app.linuxBackendName {
        Text("Pull the runner image (~seconds). Each Linux job then runs in a throwaway arm64 container. Runtime: \(backend).")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Button {
          app.setUpLinuxRunner()
        } label: {
          Label("Pull runner image", systemImage: "arrow.down.circle")
        }
        .disabled(app.state != .offline)
      } else {
        Text("Install a container runtime (free), then pull the image: Apple `container` from github.com/apple/container/releases (macOS 26+), or `brew install colima docker`.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    } header: {
      Text("Linux runner image")
    }
  }

  private var readySection: some View {
    Section {
      if let failure = app.linuxSetupFailure {
        failureBanner(failure, external: app.linuxSetupFailureIsExternal)
      }
      InfoRow("Image", value: app.linuxRunnerImage, systemImage: "shippingbox")
      InfoRow("Architecture", value: "arm64")
      if let backend = app.linuxBackendName {
        InfoRow("Runtime", value: backend)
      }
      if let log = app.linuxBuildLogPath {
        logLink("Pull log", path: log)
      }
      Button {
        app.setUpLinuxRunner(force: true)
      } label: {
        Label("Re-pull / update image", systemImage: "arrow.clockwise")
      }
      .disabled(app.state != .offline || !app.linuxBackendAvailable)
      if !app.linuxBackendAvailable {
        Text("Install a container runtime to re-pull.").font(.caption).foregroundStyle(.tertiary)
      } else if app.state != .offline {
        Text("Go offline to re-pull.").font(.caption).foregroundStyle(.tertiary)
      }
    } header: {
      Text("Linux runner image")
    }
  }

  private func failureBanner(_ message: String, external: Bool) -> some View {
    Banner(
      message, severity: external ? .warning : .error,
      icon: external ? "wifi.exclamationmark" : nil
    ) {
      if let log = app.linuxBuildLogPath { logLink("View pull log", path: log) }
    }
  }
}

// MARK: - Shared Settings helpers

/// A link-style button that opens a log file in the default viewer.
@MainActor
private func logLink(_ title: String, path: String) -> some View {
  Button {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  } label: {
    Label(title, systemImage: "doc.text.magnifyingglass")
  }
  .buttonStyle(.link)
  .help(path)
}

/// GB-rounded byte string for the capacity rows.
private func formatBytesGB(_ bytes: UInt64) -> String {
  let f = ByteCountFormatter()
  f.allowedUnits = [.useGB]
  f.countStyle = .memory
  return f.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
}
