import Foundation

/// The operating systems a runner fleet can target. Drives the popover's OS
/// selector (logo tiles) and which provider/labels each go-online fleet uses.
/// Pure model so the selection + label logic stays UI-free and testable.
///
/// - macOS: the `LocalProcessProvider` path (default, always available).
/// - windows: the `WindowsVMProvider` path — available only once the Win11-ARM
///   base image is built (gated by `windowsImageReady`) + VMware Fusion present.
/// - linux: the `LinuxContainerProvider` path — available once the runner image
///   is pulled (gated by `linuxImageReady`) + Apple `container` is installed and
///   running.
public enum RunnerOS: String, CaseIterable, Codable, Sendable, Identifiable {
  case macOS
  case windows
  case linux

  public var id: String { rawValue }

  /// Human label + the GitHub `runs-on` label this OS registers with. The fleet
  /// labels are `[self-hosted, <githubLabel>, mactions]` (mirrors a CI matrix's
  /// per-OS arm), with Linux adding `ARM64`.
  public var displayName: String {
    switch self {
    case .macOS: return "macOS"
    case .windows: return "Windows"
    case .linux: return "Linux"
    }
  }

  /// The OS token used in the `runs-on` label set.
  public var githubLabel: String { displayName }

  /// Whether this OS can actually bring runners online today. All three are
  /// implemented now (macOS local-process, Windows VM, Linux container).
  public var isImplemented: Bool { true }

  /// Default fleet labels for this OS: `[self-hosted, <OS>, mactions]`.
  ///
  /// Linux additionally carries `ARM64`: the host is Apple Silicon, but
  /// `ubuntu-latest` is x64, so a Mactions Linux runner is a genuinely different
  /// architecture (`RUNNER_ARCH=ARM64`). Declaring the arch in the label set
  /// makes workflows opt in deliberately (`runs-on: [self-hosted, Linux, ARM64,
  /// mactions]`) instead of mis-targeting an x64-expecting job at an arm64 runner.
  /// macOS/Windows keep their arch-less sets (their fleets aren't a hosted-runner
  /// arch substitute the way the Linux container is).
  public var defaultLabels: [String] {
    switch self {
    case .linux: return ["self-hosted", githubLabel, "ARM64", "mactions"]
    case .macOS, .windows: return ["self-hosted", githubLabel, "mactions"]
    }
  }

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
