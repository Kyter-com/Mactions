import MactionsCore
import SwiftUI

/// View bits shared across the dashboard, inspector, and Settings surfaces —
/// the standardized component vocabulary (theme, rows, banners, steppers) plus a
/// few small primitives.

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
        .font(.caption).foregroundStyle(.orange)
      Text(label).font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }
}

// MARK: - MactionsTheme (the single source of truth for spacing/radius/type)

/// One spacing + radius + type scale so every surface reads as the same app —
/// the replacement for the ~15 ad-hoc `.font(.system(size: 8/9/10/11))` +
/// hand-tuned padding sites the redesign removed. Concentric radii: an inner
/// control inset in an outer card shares the same visual corner.
enum MactionsTheme {
  enum Spacing {
    static let window: CGFloat = 20
    static let section: CGFloat = 16
    static let card: CGFloat = 14
    static let control: CGFloat = 8
    static let tight: CGFloat = 6
  }
  enum Radius {
    static let outer: CGFloat = 12
    static let inner: CGFloat = 8
  }
}

extension Text {
  /// The one "eyebrow" recipe (small, tracked, secondary, all-caps) for section
  /// titles — the single replacement for the old size:9/10 ad-hoc section labels.
  func eyebrow() -> some View {
    self.font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .textCase(.uppercase)
      .tracking(0.5)
  }
}

// MARK: - SectionHeader

/// An eyebrow title with an optional trailing accessory (a button, count, etc.).
struct SectionHeader<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: Trailing

  init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: MactionsTheme.Spacing.tight) {
      Text(title).eyebrow()
      Spacer(minLength: 0)
      trailing
    }
  }
}

extension SectionHeader where Trailing == EmptyView {
  init(_ title: String) { self.init(title) { EmptyView() } }
}

// MARK: - InfoRow

/// A label-with-trailing-value row: an optional fixed-width SF Symbol, a label,
/// and a trailing value or accessory. One row height across the Memory
/// breakdown, run-detail meta, and the Settings base/summary/log rows.
struct InfoRow<Trailing: View>: View {
  var systemImage: String?
  let label: String
  @ViewBuilder var trailing: Trailing

  init(_ label: String, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing) {
    self.label = label
    self.systemImage = systemImage
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: MactionsTheme.Spacing.control) {
      if let systemImage {
        Image(systemName: systemImage).font(.callout).foregroundStyle(.secondary).frame(width: 18)
      }
      Text(label).font(.callout)
      Spacer(minLength: MactionsTheme.Spacing.control)
      trailing
    }
    .padding(.vertical, 3)
  }
}

/// The standard trailing value styling for an `InfoRow` (secondary, medium,
/// monospaced-digit) as a concrete type, so the value-based `InfoRow` init has a
/// fixed `Trailing`.
struct InfoValue: View {
  let text: String
  var body: some View {
    Text(text).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
  }
}

extension InfoRow where Trailing == InfoValue {
  /// Plain "label … value" row (value is secondary + monospaced-digit).
  init(_ label: String, value: String, systemImage: String? = nil) {
    self.init(label, systemImage: systemImage) { InfoValue(text: value) }
  }
}

// MARK: - Banner

/// The single inline-message component (info / warning / error). One tint
/// convention: blue = info, orange = warning / external-transient, red = local
/// failure. Replaces `windowsFailureBanner` + `linuxFailureBanner` (two
/// near-identical blocks), the maintenance `Label`, and the orange "no repos"
/// text. An optional trailing/below action (e.g. a "View log" link).
struct Banner<Action: View>: View {
  enum Severity {
    case info, warning, error
    var tint: Color {
      switch self {
      case .info: return .blue
      case .warning: return .orange
      case .error: return .red
      }
    }
    var defaultIcon: String {
      switch self {
      case .info: return "info.circle"
      case .warning: return "exclamationmark.triangle"
      case .error: return "exclamationmark.octagon.fill"
      }
    }
  }

  let text: String
  var severity: Severity = .info
  /// Overrides `severity.defaultIcon` (e.g. `wifi.exclamationmark` for a network blip).
  var icon: String?
  @ViewBuilder var action: Action

  init(
    _ text: String, severity: Severity = .info, icon: String? = nil,
    @ViewBuilder action: () -> Action
  ) {
    self.text = text
    self.severity = severity
    self.icon = icon
    self.action = action()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: MactionsTheme.Spacing.tight) {
      HStack(alignment: .top, spacing: MactionsTheme.Spacing.tight) {
        Image(systemName: icon ?? severity.defaultIcon).font(.callout)
        Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .foregroundStyle(severity.tint)
      action
    }
    .padding(MactionsTheme.Spacing.control)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: MactionsTheme.Radius.inner)
        .fill(severity.tint.opacity(0.12)))
  }
}

extension Banner where Action == EmptyView {
  init(_ text: String, severity: Severity = .info, icon: String? = nil) {
    self.init(text, severity: severity, icon: icon) { EmptyView() }
  }
}

// MARK: - Card

/// One content container: a rounded rect with a PLAIN secondary fill (NOT Liquid
/// Glass — per WWDC25, glass stays on the control layer, never on content/cards).
/// Replaces `SetupPane`'s glass-on-content `card()` and the ad-hoc
/// `RoundedRectangle` fills.
struct Card<Content: View>: View {
  var spacing: CGFloat = MactionsTheme.Spacing.control
  @ViewBuilder var content: Content

  init(spacing: CGFloat = MactionsTheme.Spacing.control, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) { content }
      .padding(MactionsTheme.Spacing.card)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: MactionsTheme.Radius.outer)
          .fill(Color.secondary.opacity(0.07)))
  }
}

// MARK: - SetupStepper

/// Abstracts the two setup-phase enums (`WindowsSetupStep` / `LinuxSetupStep`)
/// so one stepper view drives both. Both are already `Int`-backed,
/// `CaseIterable`, `Comparable` enums with `title`/`hint`.
protocol SetupStepProtocol: CaseIterable, Comparable, Hashable {
  var title: String { get }
  var hint: String { get }
}
extension WindowsSetupStep: SetupStepProtocol {}
extension LinuxSetupStep: SetupStepProtocol {}

/// One ordered checklist: ✓ done · spinner active (+ sub-status) · ○ pending,
/// with an optional note and Cancel. Collapses the duplicated
/// `windowsSetupStepper` + `linuxSetupStepper` (and their `stepIcon`s).
struct SetupStepper<Step: SetupStepProtocol>: View where Step.AllCases: RandomAccessCollection {
  let current: Step
  var detail: String?
  var note: String?
  var onCancel: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: MactionsTheme.Spacing.tight) {
      ForEach(Array(Step.allCases), id: \.self) { step in
        HStack(alignment: .top, spacing: MactionsTheme.Spacing.tight) {
          icon(for: step).frame(width: 16, alignment: .center)
          VStack(alignment: .leading, spacing: 1) {
            Text(step.title)
              .font(.callout)
              .fontWeight(step == current ? .semibold : .regular)
              .foregroundStyle(step <= current ? Color.primary : Color.secondary)
            if step == current {
              Text(detail ?? step.hint)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          Spacer(minLength: 0)
        }
      }
      if let note {
        Text(note).font(.caption).foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let onCancel {
        HStack {
          Spacer(minLength: 0)
          Button(role: .cancel, action: onCancel) { Text("Cancel build") }
            .controlSize(.small)
        }
      }
    }
    .padding(MactionsTheme.Spacing.control)
    .background(
      RoundedRectangle(cornerRadius: MactionsTheme.Radius.inner)
        .fill(Color.secondary.opacity(0.08)))
  }

  @ViewBuilder
  private func icon(for step: Step) -> some View {
    if step < current {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
    } else if step == current {
      ProgressView().controlSize(.mini)
    } else {
      Image(systemName: "circle").foregroundStyle(.secondary).font(.callout)
    }
  }
}

// MARK: - LabelEditor

/// The anti-typo control for a combo's `runs-on` labels: an editable CSV field
/// (macOS combos) plus a read-only "Registers:" chip row showing the EFFECTIVE
/// label set. Windows/Linux pass `editable: false` (their labels are derived) so
/// only the chips show. Per-combo editable labels are the top silent-failure
/// risk, so the chips make the result legible.
///
/// The TextField edits a LOCAL `draft`, not the bound `text` directly — `text`'s
/// setter normalizes (parse → store → re-join), so binding the field straight to
/// it would delete a trailing comma/space the instant it's typed, making a second
/// label impossible to enter. The draft is committed back to `text` (which
/// persists) only on Return or focus loss; external changes reseed it only while
/// the field is idle.
struct LabelEditor: View {
  @Binding var text: String
  var editable: Bool = true
  var onCommit: () -> Void = {}

  @State private var draft = ""
  @FocusState private var focused: Bool

  /// Parse whichever source is authoritative for the chips: the live draft while
  /// editing, else the bound (normalized) text.
  private var labels: [String] {
    (editable ? draft : text)
      .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: MactionsTheme.Spacing.tight) {
      if editable {
        TextField("self-hosted, macOS, mactions", text: $draft)
          .textFieldStyle(.roundedBorder)
          .focused($focused)
          .onSubmit { commit() }
          .onChange(of: focused) { isFocused in if !isFocused { commit() } }
          .onAppear { draft = text }
          .onChange(of: text) { newValue in if !focused { draft = newValue } }
          // Backstop: committing on focus loss covers tabbing/clicking away, but
          // selecting another repo destroys this view synchronously — the focus
          // event may not land first. Commit on disappear so a mid-edit draft
          // (e.g. typing a label, then clicking a different repo) isn't lost.
          // No-op when unchanged, so a normal dismiss costs nothing.
          .onDisappear { commit() }
      }
      HStack(spacing: 4) {
        Text("Registers").eyebrow()
        ChipRow(labels: labels)
      }
    }
  }

  private func commit() {
    if text != draft { text = draft }  // triggers the bound setter (persist) once
    onCommit()
  }
}

/// A wrapping-ish row of label chips. Kept linear (HStack) — runner label sets
/// are short (2–4 tokens); a full flow layout would be overkill.
struct ChipRow: View {
  let labels: [String]
  var body: some View {
    HStack(spacing: 4) {
      if labels.isEmpty {
        Text("— none —").font(.caption).foregroundStyle(.orange)
      } else {
        ForEach(labels, id: \.self) { label in
          Text(label)
            .font(.system(size: 10, weight: .medium)).monospaced()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
      }
      Spacer(minLength: 0)
    }
  }
}

// MARK: - StatusStrip

/// The thin bottom strip on the primary window: the live fleet summary on the
/// left, and a budget-cap note on the right shown ONLY when a platform is
/// actually capped (the contextual home for what the old capacity chips carried).
struct StatusStrip: View {
  let message: String
  var capNote: String?

  var body: some View {
    HStack(spacing: MactionsTheme.Spacing.control) {
      Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: MactionsTheme.Spacing.control)
      if let capNote {
        HStack(spacing: 4) {
          Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
          Text(capNote).font(.caption).lineLimit(1)
        }
        .foregroundStyle(.orange)
      }
    }
    .padding(.horizontal, MactionsTheme.Spacing.section)
    .padding(.vertical, MactionsTheme.Spacing.tight)
    .frame(maxWidth: .infinity)
  }
}
