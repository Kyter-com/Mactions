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

  @State private var confirmRemove = false

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

        // Runners for this repo repeatedly dying during launch (dead container
        // daemon, broken base image): the badge says "failing to launch"; the
        // actual error is only useful HERE, where the user is looking at the
        // repo. Without this, the failure loop is invisible diagnostically.
        if let launchError = app.repoLaunchFailure[repoPlan.repo.fullName] {
          Banner(launchError, severity: .warning, icon: "exclamationmark.triangle")
        }

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
        // Edits are allowed while the fleet is live and staged until restart; the
        // dashboard's global "restart to apply" bar carries the message + action,
        // so we don't duplicate it here.
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
        confirmRemove = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .disabled(app.state != .offline)
      .help(app.state == .offline ? "Remove this repository" : MactionsTheme.Copy.offlineToManageRepos)
      .accessibilityLabel("Remove repository")
      .confirmationDialog(
        "Remove \(repoPlan.repo.name)?", isPresented: $confirmRemove, titleVisibility: .visible
      ) {
        Button("Remove", role: .destructive) { app.removeRepo(id: repoPlan.id) }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This repository and all of its platform configuration will be removed.")
      }
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
    // Locked while this platform's image is building (the tap would fight the
    // build) OR during a go-online/offline transition (so an edit can't race the
    // plan snapshot mid-restart). Toggling is allowed in the stable online state —
    // it stages a pending restart. A locked tile dims so it reads as busy.
    let locked = building || app.isTransitioning
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
          .font(.caption2.weight(selected ? .semibold : .regular))
          .foregroundStyle(selected ? .primary : .secondary)
          .lineLimit(1)
      }
      .contentShape(Rectangle())
      .opacity(locked ? 0.5 : 1)
    }
    .buttonStyle(.plain)
    .disabled(locked)
    .help(tileHelp(os, ready: ready, enabled: enabled))
    // The tile is an image-only control; spell out which OS and its state for
    // VoiceOver (otherwise just "button, image").
    .accessibilityLabel(os.displayName)
    .accessibilityValue(enabled ? "enabled" : (needsSetup ? "needs setup" : "off"))
    .accessibilityHint(tileHelp(os, ready: ready, enabled: enabled))
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

      let defaultCount = os == .macOS ? app.plan.defaultMacOSCount : 1
      Stepper(
        "Max runners: \(config?.count ?? defaultCount)",
        value: countBinding(repoID: repoPlan.id, os: os), in: 1...5)
        .disabled(app.isTransitioning)
      // Scale-from-zero: the count is a CEILING, not a warm pool — runners
      // start when matching jobs queue and retire when the queue empties.
      Text(
        os == .macOS
          ? "Runners start on demand when jobs queue — up to this many at once."
          : "Runners start on demand when jobs queue — up to this many throwaway "
            + "\(os == .windows ? "VMs" : "containers") at once, further capped by "
            + "this Mac's \(os == .windows ? "RAM" : "RAM/CPU").")
        .font(.caption).foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: MactionsTheme.Spacing.tight) {
        SectionHeader("Labels")
        LabelEditor(
          text: labelsBinding(repoPlan: repoPlan, os: os),
          editable: os == .macOS)
          .disabled(app.isTransitioning)
        // Surface the SAME rule goOnline() hard-blocks on (non-empty + must
        // include `self-hosted`) right here, so a bad label set is caught while
        // editing instead of as a cryptic blocked "Go online" later. Only macOS
        // labels are editable; the derived Windows/Linux sets are always valid.
        if os == .macOS, let problem = labelProblem(repoPlan) {
          Banner(problem, severity: .error)
        }
        if os != .macOS {
          Text("Derived from the OS (arch-explicit for Linux); not editable.")
            .font(.caption).foregroundStyle(.tertiary)
        }
      }
    }
  }

  /// The label-validity message for this repo's macOS combo, or nil when valid —
  /// mirrors `FleetPlan.invalidCombos()` (the go-online hard block).
  private func labelProblem(_ repoPlan: RepoPlan) -> String? {
    let labels = repoPlan.config(for: .macOS)?.labels ?? app.plan.defaultMacOSLabels
    if labels.isEmpty { return "Add at least one label, including `self-hosted`." }
    if !labels.contains("self-hosted") {
      return "Labels must include `self-hosted`, or no workflow will match these runners."
    }
    return nil
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

  private func countBinding(repoID: String, os: RunnerOS) -> Binding<Int> {
    let fallback = os == .macOS ? app.plan.defaultMacOSCount : 1
    return Binding(
      get: {
        app.plan.repos.first { $0.id == repoID }?.config(for: os)?.count ?? fallback
      },
      set: { app.setCount($0, os: os, repoID: repoID) })
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
