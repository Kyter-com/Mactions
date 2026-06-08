import MactionsCore
import SwiftUI

/// The per-`(repo, platform)` combo editor — the trailing inspector on the live
/// window (a real `.inspector` on macOS 14+, a trailing pane on 13; see
/// `DashboardView`). Bound to the repo selected in the grid: a segmented
/// platform picker, then that platform's enable toggle, runner count (macOS
/// only), and label editor with read-only "effective labels" chips. Everything
/// is offline-gated, matching the rest of the app — you configure while offline,
/// then watch the fleet you configured.
struct RepoInspector: View {
  @EnvironmentObject private var app: AppState
  /// The selected repo's id (`owner/name`), or nil when nothing is selected.
  let repoID: String?

  @State private var platform: RunnerOS = .macOS

  private var repoPlan: RepoPlan? {
    guard let repoID else { return nil }
    return app.plan.repos.first { $0.id == repoID }
  }

  var body: some View {
    Group {
      if let repoPlan {
        content(repoPlan)
      } else {
        DashboardEmptyState(
          systemImage: "slider.horizontal.3", title: "No repo selected",
          message: "Select a repository in the list to configure its platforms, runner count, and labels.")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // Keep the platform tab in sync with the selected repo: land on its first
    // enabled platform (or macOS) so the inspector opens on something meaningful.
    .onChange(of: repoID) { _ in platform = repoPlan?.enabledPlatforms.first ?? .macOS }
    .onAppear { platform = repoPlan?.enabledPlatforms.first ?? .macOS }
  }

  @ViewBuilder
  private func content(_ repoPlan: RepoPlan) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: MactionsTheme.Spacing.section) {
        header(repoPlan)

        Picker("Platform", selection: $platform) {
          ForEach(RunnerOS.allCases) { os in
            Text(os.displayName).tag(os)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(app.state != .offline)

        platformForm(repoPlan, os: platform)
          .disabled(app.state != .offline)

        if app.state != .offline {
          Banner("Go offline to change configuration.", severity: .info)
        }
      }
      .padding(MactionsTheme.Spacing.section)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func header(_ repoPlan: RepoPlan) -> some View {
    HStack(spacing: MactionsTheme.Spacing.control) {
      VStack(alignment: .leading, spacing: 1) {
        Text(repoPlan.repo.name).font(.headline).lineLimit(1).truncationMode(.middle)
        Text(repoPlan.repo.owner).font(.caption).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 0)
      Button(role: .destructive) {
        app.removeRepo(id: repoPlan.id)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .disabled(app.state != .offline)
      .help("Remove this repository")
    }
  }

  // MARK: One platform's form

  @ViewBuilder
  private func platformForm(_ repoPlan: RepoPlan, os: RunnerOS) -> some View {
    let config = repoPlan.config(for: os)
    let enabled = config?.enabled ?? false
    let ready = isReady(os)
    VStack(alignment: .leading, spacing: MactionsTheme.Spacing.control) {
      if !ready {
        Banner(
          "\(os.displayName) needs a one-time setup before it can run here.",
          severity: .warning, icon: "wrench.and.screwdriver")
        Text("Open Settings → \(os.displayName) to \(os == .windows ? "build the base image" : "pull the runner image").")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Toggle("Enable \(os.displayName)", isOn: enabledBinding(repoID: repoPlan.id, os: os))
        .disabled(!ready)

      if enabled {
        if os == .macOS {
          Stepper(
            "Runners: \(config?.count ?? app.plan.defaultMacOSCount)",
            value: countBinding(repoID: repoPlan.id), in: 1...5)
        } else {
          InfoRow(
            "One throwaway \(os == .windows ? "VM" : "container") per job",
            systemImage: os == .windows ? "cube.box" : "shippingbox"
          ) {
            Text("RAM-capped").font(.caption).foregroundStyle(.secondary)
          }
        }

        VStack(alignment: .leading, spacing: MactionsTheme.Spacing.tight) {
          SectionHeader("Labels")
          LabelEditor(
            text: labelsBinding(repoPlan: repoPlan, os: os),
            editable: os == .macOS)
          if os != .macOS {
            Text("Derived from the OS (arch-explicit for Linux); not editable.")
              .font(.caption).foregroundStyle(.tertiary)
          }
        }
      }
    }
  }

  // MARK: Readiness

  private func isReady(_ os: RunnerOS) -> Bool {
    switch os {
    case .macOS: return true
    case .windows: return app.windowsImageReady
    case .linux: return app.linuxImageReady
    }
  }

  // MARK: Bindings (each write goes through the offline-gated AppState mutators)

  private func enabledBinding(repoID: String, os: RunnerOS) -> Binding<Bool> {
    Binding(
      get: { app.plan.repos.first { $0.id == repoID }?.config(for: os)?.enabled ?? false },
      set: { app.setPlatform(os, enabled: $0, repoID: repoID) })
  }

  private func countBinding(repoID: String) -> Binding<Int> {
    Binding(
      get: {
        app.plan.repos.first { $0.id == repoID }?.config(for: .macOS)?.count
          ?? app.plan.defaultMacOSCount
      },
      set: { app.setCount($0, os: .macOS, repoID: repoID) })
  }

  /// macOS: a two-way binding through `setLabels`. Windows/Linux: a read-only
  /// view of the effective (derived) labels for the chip row.
  private func labelsBinding(repoPlan: RepoPlan, os: RunnerOS) -> Binding<String> {
    let current = repoPlan.config(for: os)?.labels ?? defaultLabels(for: os)
    let joined = current.joined(separator: ", ")
    guard os == .macOS else { return .constant(joined) }
    return Binding(
      get: {
        (app.plan.repos.first { $0.id == repoPlan.id }?.config(for: .macOS)?.labels
          ?? app.plan.defaultMacOSLabels).joined(separator: ", ")
      },
      set: { app.setLabels($0, os: .macOS, repoID: repoPlan.id) })
  }

  private func defaultLabels(for os: RunnerOS) -> [String] {
    os == .macOS ? app.plan.defaultMacOSLabels : os.defaultLabels
  }
}
