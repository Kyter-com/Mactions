import XCTest

@testable import MactionsCore

/// The test suite must never write the user's real control-plane log: it
/// drives thousands of events, and rotation would push real history away.
final class ControlPlaneLogTests: XCTestCase {
  func testUnderTestsTheLogFileIsOutsideTheMactionsDirectory() {
    XCTAssertTrue(ControlPlaneLog.isRunningTests)
    let file = ControlPlaneLog.fileURL().standardizedFileURL.path
    XCTAssertFalse(file.hasPrefix(HostCleanup.mactionsRoot().standardizedFileURL.path), file)
    XCTAssertTrue(
      file.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path), file)
  }

  func testEventsStillReachTheTestLog() throws {
    let marker = "test.marker.\(UUID().uuidString)"
    ControlPlaneLog.log(marker, ["k": "v"])
    ControlPlaneLog.flush()
    let text = try String(contentsOf: ControlPlaneLog.fileURL(), encoding: .utf8)
    let line = try XCTUnwrap(text.split(separator: "\n").last { $0.contains(marker) })
    XCTAssertTrue(line.contains(#""k":"v""#))
  }
}
