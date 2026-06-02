import Foundation

/// The operating systems a runner fleet can target. Drives the popover's OS
/// selector (logo tiles) and which provider/labels each go-online fleet uses.
/// Pure model so the selection + label logic stays UI-free and testable.
///
/// - macOS: the `LocalProcessProvider` path (default, always available).
/// - windows: the `WindowsVMProvider` path — available only once the Win11-ARM
///   base image is built (gated by `windowsImageReady`) + VMware Fusion present.
/// - linux: not implemented yet ("soon"); shown disabled in the UI.
public enum RunnerOS: String, CaseIterable, Codable, Sendable, Identifiable {
  case macOS
  case windows
  case linux

  public var id: String { rawValue }

  /// Human label + the GitHub `runs-on` label this OS registers with. The fleet
  /// labels are `[self-hosted, <githubLabel>, mactions]` (mirrors a CI matrix's
  /// per-OS arm). macOS's set is user-editable in the UI; the rest derive here.
  public var displayName: String {
    switch self {
    case .macOS: return "macOS"
    case .windows: return "Windows"
    case .linux: return "Linux"
    }
  }

  /// The OS token used in the `runs-on` label set.
  public var githubLabel: String { displayName }

  /// Whether this OS can actually bring runners online today. Linux is a
  /// placeholder ("soon") until a Linux provider is wired up.
  public var isImplemented: Bool { self != .linux }

  /// Default fleet labels for this OS: `[self-hosted, <OS>, mactions]`.
  public var defaultLabels: [String] { ["self-hosted", githubLabel, "mactions"] }

  /// Reconstruct the persisted OS selection on launch (pure → unit-testable; this
  /// is the highest-regression-risk bit of the OS-selection migration).
  ///   - `savedRawValues`: the stored selection (`nil` if never saved).
  ///   - `legacyWindowsEnabled` / `windowsImageReady`: only used to migrate a
  ///     pre-OS-selection install. Windows is seeded ONLY when its base image is
  ///     actually ready, so a stale legacy flag can't leave a phantom Windows
  ///     selection the tile would render as "selected" but go-online ignores.
  /// macOS is the floor: an empty/unparseable saved set falls back to `[.macOS]`
  /// so the picker is never empty on launch.
  public static func restoreSelection(
    savedRawValues: [String]?,
    legacyWindowsEnabled: Bool,
    windowsImageReady: Bool
  ) -> Set<RunnerOS> {
    if let saved = savedRawValues {
      let oses = Set(saved.compactMap(RunnerOS.init(rawValue:)))
      return oses.isEmpty ? [.macOS] : oses
    }
    return (legacyWindowsEnabled && windowsImageReady) ? [.macOS, .windows] : [.macOS]
  }
}
