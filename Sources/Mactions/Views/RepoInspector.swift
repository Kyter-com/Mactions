import AppKit
import MactionsCore
import SwiftUI

/// The per-`(repo, platform)` combo editor — the right-hand panel on the live
/// window, shown when a repo (not a live runner) is selected in the grid. The
/// platforms are picked with **logo tiles** (a brand mark in a box whose border
/// highlights when that platform is enabled for this repo — the box IS the
/// checkbox), and each enabled platform gets its own card: runner count (macOS)
/// + a label editor with read-only "effective labels" chips. Everything is
/// offline-gated, matching the rest of the app — you configure while offline,
/// then watch the fleet you configured.
struct RepoInspector: View {
  @EnvironmentObject private var app: AppState
  /// The selected repo's id (`owner/name`), or nil when nothing is selected.
  let repoID: String?

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
  }

  @ViewBuilder
  private func content(_ repoPlan: RepoPlan) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: MactionsTheme.Spacing.section) {
        header(repoPlan)

        VStack(alignment: .leading, spacing: MactionsTheme.Spacing.tight) {
          SectionHeader("Platforms")
          HStack(spacing: MactionsTheme.Spacing.control) {
            osTile(.macOS, repoPlan: repoPlan)
            osTile(.windows, repoPlan: repoPlan)
            osTile(.linux, repoPlan: repoPlan)
            Spacer(minLength: 0)
          }
        }

        let enabled = repoPlan.enabledPlatforms
        if enabled.isEmpty {
          Banner(
            "No platforms enabled — tap a platform above to add a runner for this repo.",
            severity: .info)
        } else {
          ForEach(enabled) { os in
            platformDetail(repoPlan, os: os)
          }
        }

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
        Text("CONFIGURE").eyebrow()
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

  // MARK: Platform tiles (logo box + highlight = enabled for this repo)

  /// One platform tile. The accent border + fill ("selected") means the platform
  /// is enabled for THIS repo AND its image is ready — a persisted-but-unready
  /// combo shows the download badge instead of a contradictory highlight. Tapping
  /// a ready tile toggles it (offline only); an unready Windows/Linux tile opens
  /// the relevant Settings tab to build/pull its image.
  private func osTile(_ os: RunnerOS, repoPlan: RepoPlan) -> some View {
    let enabled = repoPlan.config(for: os)?.enabled ?? false
    let ready = isReady(os)
    let building = (os == .windows && app.windowsSetupBusy) || (os == .linux && app.linuxSetupBusy)
    let needsSetup = !ready && !building
    let selected = enabled && ready
    // Locked = the tap would no-op (toggling enable is offline-only; a building
    // tile is busy). We dim locked tiles so the disabled state is legible — a
    // `.plain` button doesn't dim on its own, which made an online tap read as a
    // frozen control. Unready tiles stay full-opacity: their tap still works (it
    // opens Settings).
    let locked = tileDisabled(ready: ready, building: building)
    return Button {
      handleTileTap(os, repoID: repoPlan.id, enabled: enabled, ready: ready)
    } label: {
      VStack(spacing: 5) {
        ZStack {
          // SAME white (adaptive .primary) for all three marks — needs-setup dims
          // via OPACITY only, never a different gray hue, so the set stays uniform.
          OSLogo(os: os, size: 26, tint: .primary)
            .opacity(building ? 0 : (needsSetup ? 0.5 : 1))
          if building { ProgressView().controlSize(.small) }
        }
        .frame(width: 66, height: 52)
        .background(
          RoundedRectangle(cornerRadius: MactionsTheme.Radius.inner)
            .fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)))
        .overlay(
          RoundedRectangle(cornerRadius: MactionsTheme.Radius.inner)
            .strokeBorder(
              selected ? Color.accentColor : Color.secondary.opacity(0.18),
              lineWidth: selected ? 2 : 1)
        )
        // A download badge (needs-setup) or a check (selected) sits OUTSIDE the
        // box so it never crowds the logo.
        .overlay(alignment: .topTrailing) {
          if needsSetup {
            Image(systemName: "arrow.down.circle.fill")
              .font(.system(size: 13))
              .foregroundStyle(Color.accentColor, Color(NSColor.windowBackgroundColor))
              .offset(x: 5, y: -5)
          } else if selected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 13))
              .foregroundStyle(Color.white, Color.accentColor)
              .offset(x: 5, y: -5)
          }
        }
        Text(os.displayName)
          .font(.system(size: 10, weight: selected ? .semibold : .regular))
          .foregroundStyle(selected ? .primary : .secondary)
      }
      .contentShape(Rectangle())
      .opacity(locked ? 0.5 : 1)
    }
    .buttonStyle(.plain)
    .disabled(locked)
    .help(tileHelp(os, ready: ready, enabled: enabled))
  }

  /// Toggling a ready tile is offline-gated; tapping an unready tile just opens
  /// Settings (navigation), so it stays live online. A building tile is locked.
  private func tileDisabled(ready: Bool, building: Bool) -> Bool {
    if building { return true }
    return ready ? app.state != .offline : false
  }

  private func handleTileTap(_ os: RunnerOS, repoID: String, enabled: Bool, ready: Bool) {
    if ready {
      app.setPlatform(os, enabled: !enabled, repoID: repoID)
    } else {
      // Not set up yet → jump to the Settings tab that builds/pulls its image.
      app.presentSettings(os == .linux ? .linux : .windows)
    }
  }

  private func tileHelp(_ os: RunnerOS, ready: Bool, enabled: Bool) -> String {
    // A ready tile can only be toggled offline — say so instead of an inviting
    // "tap to disable" the online tap won't honor.
    if ready, app.state != .offline {
      return "\(os.displayName) is \(enabled ? "enabled" : "off") — go offline to change this repo's platforms."
    }
    switch os {
    case .macOS:
      return enabled
        ? "macOS runners enabled — tap to disable."
        : "Run a macOS runner fleet (a local process per job)."
    case .windows:
      if !ready { return "Windows needs a one-time base image — opens Settings → Windows to build it." }
      return enabled ? "Windows enabled — tap to disable." : "Enable a throwaway Win11-ARM VM per job."
    case .linux:
      if !ready { return "Linux needs the runner image — opens Settings → Linux to pull it." }
      return enabled ? "Linux enabled — tap to disable." : "Enable a throwaway arm64 container per job."
    }
  }

  // MARK: One enabled platform's config card

  @ViewBuilder
  private func platformDetail(_ repoPlan: RepoPlan, os: RunnerOS) -> some View {
    let config = repoPlan.config(for: os)
    let ready = isReady(os)
    Card {
      HStack(spacing: MactionsTheme.Spacing.tight) {
        OSLogo(os: os, size: 15).frame(width: 18)
        Text(os.displayName).font(.callout.weight(.semibold))
        Spacer(minLength: 0)
      }

      if !ready {
        Banner(
          "\(os.displayName) isn't set up on this Mac — open Settings → \(os.displayName) to "
            + "\(os == .windows ? "build the base image" : "pull the runner image").",
          severity: .warning, icon: "wrench.and.screwdriver")
      }

      if os == .macOS {
        Stepper(
          "Runners: \(config?.count ?? app.plan.defaultMacOSCount)",
          value: countBinding(repoID: repoPlan.id), in: 1...5
        )
        .disabled(app.state != .offline)
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
          .disabled(app.state != .offline)
        if os != .macOS {
          Text("Derived from the OS (arch-explicit for Linux); not editable.")
            .font(.caption).foregroundStyle(.tertiary)
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
