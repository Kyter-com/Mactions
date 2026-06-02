import MactionsCore
import SwiftUI

/// View bits shared between the dashboard panes (DashboardView) and the Setup
/// pane (SetupPane) — moved out of the old menubar popover / DashboardView so
/// both surfaces can use them without duplicating symbols.

/// A label-over-field pair. Sized comfortably for a real window pane.
struct LabeledField: View {
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

/// A small tracked all-caps section label (e.g. "RUNNER OS", "REPOS").
@MainActor
func sectionLabel(_ text: String) -> some View {
  Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
}

/// A tinted status pill (Liquid Glass on macOS 26+, tinted fill otherwise).
struct Badge: View {
  let label: String
  let color: Color
  var body: some View {
    Text(label)
      .font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
      .padding(.horizontal, 7).padding(.vertical, 2)
      .liquidGlassTinted(color, in: Capsule())
  }
}

/// Groups nested Liquid Glass effects so they batch + can morph together (Apple's
/// guidance: always wrap multiple `.glassEffect` views in a container). Passes
/// content through unchanged on < macOS 26.
@MainActor @ViewBuilder
func GlassGroup<Content: View>(
  spacing: CGFloat = 8, @ViewBuilder _ content: () -> Content
) -> some View {
  if #available(macOS 26.0, *) {
    GlassEffectContainer(spacing: spacing, content: content)
  } else {
    content()
  }
}

/// Shows what's STILL MISSING for the Windows path (not a full ✓/✗ list — done
/// items are simply omitted, so the section empties out as prerequisites land and
/// disappears entirely once the base image is built). Plus a one-click installer
/// for the missing FREE brew deps (converter tools + xorriso). It never installs a
/// hypervisor (Fusion is a manual Broadcom-portal download) and never installs
/// Homebrew (points at brew.sh).
struct WindowsPreflightChecklist: View {
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
