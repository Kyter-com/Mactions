import XCTest

@testable import MactionsCore

/// Pins the pure `RunnerOS` model: label derivation, the "implemented" gate, and
/// rawValue stability (the UI persists the OS selection as `rawValue` strings, so
/// these must not drift or saved selections silently reset).
final class RunnerOSTests: XCTestCase {

  func testDefaultLabelsMatchTheCIMatrixArms() {
    XCTAssertEqual(RunnerOS.macOS.defaultLabels, ["self-hosted", "macOS", "mactions"])
    XCTAssertEqual(RunnerOS.windows.defaultLabels, ["self-hosted", "Windows", "mactions"])
    // Linux carries an explicit ARM64 arch label (host is Apple Silicon, but
    // ubuntu-latest is x64) so workflows opt in deliberately.
    XCTAssertEqual(RunnerOS.linux.defaultLabels, ["self-hosted", "Linux", "ARM64", "mactions"])
  }

  func testAllOSesAreImplemented() {
    XCTAssertTrue(RunnerOS.macOS.isImplemented)
    XCTAssertTrue(RunnerOS.windows.isImplemented)
    XCTAssertTrue(RunnerOS.linux.isImplemented)
  }

  func testRawValuesAreStableForPersistence() {
    // The popover persists `selectedOSes` as these exact strings; changing them
    // would silently drop a user's saved selection on the next launch.
    XCTAssertEqual(RunnerOS.macOS.rawValue, "macOS")
    XCTAssertEqual(RunnerOS.windows.rawValue, "windows")
    XCTAssertEqual(RunnerOS.linux.rawValue, "linux")
    for os in RunnerOS.allCases {
      XCTAssertEqual(RunnerOS(rawValue: os.rawValue), os)
    }
    XCTAssertNil(RunnerOS(rawValue: "freebsd"))  // unknown tokens drop cleanly
  }

  func testDisplayNameEqualsGithubLabel() {
    for os in RunnerOS.allCases {
      XCTAssertEqual(os.displayName, os.githubLabel)
    }
  }

  // MARK: Persisted-selection restore / migration (the highest-regression-risk bit)

  func testRestoreSelectionUsesSavedWhenPresent() {
    XCTAssertEqual(
      RunnerOS.restoreSelection(
        savedRawValues: ["macOS", "windows"], legacyWindowsEnabled: false, windowsImageReady: false),
      [.macOS, .windows])
    // A Windows-only saved selection is respected (not forced back to macOS).
    XCTAssertEqual(
      RunnerOS.restoreSelection(
        savedRawValues: ["windows"], legacyWindowsEnabled: false, windowsImageReady: true),
      [.windows])
    // Unknown tokens are dropped; an empty result floors to macOS so the picker
    // is never empty on launch.
    XCTAssertEqual(
      RunnerOS.restoreSelection(
        savedRawValues: ["freebsd"], legacyWindowsEnabled: false, windowsImageReady: false),
      [.macOS])
    XCTAssertEqual(
      RunnerOS.restoreSelection(
        savedRawValues: [], legacyWindowsEnabled: true, windowsImageReady: true),
      [.macOS])
  }

  func testRestoreSelectionMigratesLegacyWindowsEnabledOnlyWhenImageReady() {
    // No saved selection: migrate from the legacy flag — but seed Windows ONLY
    // when its base image is actually ready (else it'd be a phantom selection the
    // tile renders as "selected" but go-online ignores).
    XCTAssertEqual(
      RunnerOS.restoreSelection(savedRawValues: nil, legacyWindowsEnabled: true, windowsImageReady: true),
      [.macOS, .windows])
    XCTAssertEqual(
      RunnerOS.restoreSelection(savedRawValues: nil, legacyWindowsEnabled: true, windowsImageReady: false),
      [.macOS])
    XCTAssertEqual(
      RunnerOS.restoreSelection(savedRawValues: nil, legacyWindowsEnabled: false, windowsImageReady: true),
      [.macOS])
  }
}
