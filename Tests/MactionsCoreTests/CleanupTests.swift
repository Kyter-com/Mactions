import XCTest

@testable import MactionsCore

final class CleanupTests: XCTestCase {
  func testArtifactPathsNestUnderOneReapableRoot() {
    let root = HostCleanup.mactionsRoot()
    // A dot-dir in $HOME with no spaces (the Actions runner breaks on spaces).
    XCTAssertEqual(root.lastPathComponent, ".mactions")
    XCTAssertFalse(root.path.contains(" "), "runner work path must be space-free")
    // Everything we write is under the one root, so cleanup reaps it all.
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
