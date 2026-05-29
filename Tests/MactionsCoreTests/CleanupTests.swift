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

  // NOTE: we deliberately do NOT call purgeRuns()/purgeAll() from tests. They
  // operate on the real ~/.mactions and, when the suite runs *inside* a
  // Mactions-managed runner, the job itself lives in ~/.mactions/runs — so a
  // purge would delete the running job out from under itself. Their logic is a
  // one-line FileManager.removeItem; the path test above covers the addressing.
}
