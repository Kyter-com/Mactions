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

  func testWindowsBaseBackupDirectoriesOnlyMatchesBackupDirs() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mactions-cleanup-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in [
      ".win11-runner-base.bak.1",
      ".win11-runner-base.bak.2",
      "mactions-live-clone",
      "win11-runner-base.vmx",
    ] {
      let url = root.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try "file".write(
      to: root.appendingPathComponent(".win11-runner-base.bak.file"),
      atomically: true, encoding: .utf8)

    XCTAssertEqual(
      HostCleanup.windowsBaseBackupDirectories(in: root).map(\.lastPathComponent),
      [".win11-runner-base.bak.1", ".win11-runner-base.bak.2"])
  }

  // NOTE: we deliberately do NOT call purgeRuns()/purgeAll() from tests. They
  // operate on the real ~/.mactions and, when the suite runs *inside* a
  // Mactions-managed runner, the job itself lives in ~/.mactions/runs — so a
  // purge would delete the running job out from under itself. Their logic is a
  // one-line FileManager.removeItem; the path test above covers the addressing.
}
