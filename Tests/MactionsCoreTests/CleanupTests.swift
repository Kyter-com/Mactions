import XCTest

@testable import MactionsCore

final class CleanupTests: XCTestCase {
  func testArtifactPathsNestUnderOneReapableRoot() {
    let root = HostCleanup.mactionsRoot()
    XCTAssertEqual(root.lastPathComponent, "Mactions")
    // Everything we write is under the one root, so purgeAll() reaps it all.
    XCTAssertTrue(HostCleanup.runsRoot().path.hasPrefix(root.path))
    XCTAssertTrue(HostCleanup.agentTemplateDirectory().path.hasPrefix(root.path))
    XCTAssertEqual(HostCleanup.runsRoot().lastPathComponent, "runs")
  }

  func testPurgeRunsIsIdempotentAndNonThrowing() {
    // Safe to call when nothing exists and twice in a row.
    HostCleanup.purgeRuns()
    HostCleanup.purgeRuns()
  }
}
