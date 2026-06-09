import XCTest

@testable import MactionsCore

/// Pure-logic tests for the local-process (macOS bare-host) provider. The env
/// dict is built inside `start()` (which launches a real agent), so we can't
/// assert it without a process — but the one bit worth locking is the
/// GitHub-hosted `ImageOS` token FORMAT, which is isolated as a pure helper.
final class ProvidersTests: XCTestCase {

  /// GitHub's macOS `ImageOS` is `macos` + bare major version, no separator/case
  /// (`macos14`/`macos15`/`macos26`). A drift to `macOS`, `macos-26`, etc. would
  /// be worse than unset — whitelist-validating setup-* actions hard-fail on a
  /// non-token value. Lock the exact shape.
  func testImageOSTokenMatchesGitHubHostedFormat() {
    XCTAssertEqual(LocalProcessProvider.imageOSToken(majorVersion: 14), "macos14")
    XCTAssertEqual(LocalProcessProvider.imageOSToken(majorVersion: 15), "macos15")
    XCTAssertEqual(LocalProcessProvider.imageOSToken(majorVersion: 26), "macos26")
    // No separator, no uppercase, no leading "v".
    let token = LocalProcessProvider.imageOSToken(majorVersion: 26)
    XCTAssertFalse(token.contains("-"))
    XCTAssertFalse(token.contains("_"))
    XCTAssertEqual(token, token.lowercased())
  }
}
