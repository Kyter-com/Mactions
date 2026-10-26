import XCTest

@testable import MactionsCore

/// A hung `container` daemon must not hold go-online, teardown or the host
/// budget: every quick verb is time-limited. A fake CLI script hangs on the
/// verb under test; the limits here are half a second so the tests stay fast.
final class ContainerCommandTimeoutTests: XCTestCase {
  func testTheDefaultLimitIsGenerousButFinite() {
    // Each verb measured well under a second live; 30 s only bounds a hang.
    XCTAssertEqual(LinuxContainerProvider.commandTimeout, 30)
  }

  func testReadinessCallsAHungDaemonUnavailable() throws {
    let cli = try fakeCLI(statusBody: "exec sleep 30")
    let started = Date()
    let readiness = LinuxContainerProviderFactory.readiness(image: "img", cli: cli, timeout: 0.5)
    XCTAssertEqual(readiness, .daemonUnavailable)
    XCTAssertLessThan(Date().timeIntervalSince(started), 4)
  }

  func testStopDoesNotWaitOnAHungDelete() throws {
    let cli = try fakeCLI(deleteBody: "exec sleep 30")
    let provider = LinuxContainerProvider(id: "mactions-x", image: "img", cli: cli, commandTimeout: 0.5)
    let started = Date()
    provider.stop()  // releases the host budget unit once it returns
    XCTAssertLessThan(Date().timeIntervalSince(started), 4)
  }

  func testTheOrphanSweepGivesUpOnAHungDeleteAndMovesOn() throws {
    let log = temporaryFile("calls.log")
    let cli = try fakeCLI(
      listBody: "printf 'mactions-a\\nsomeone-else\\nmactions-b\\n'",
      deleteBody: """
        echo "delete $3" >> '\(log.path)'
        if [ "$3" = "mactions-a" ]; then exec sleep 30; fi
        """)
    let started = Date()
    HostCleanup.purgeStrayLinuxContainers(cli: cli, timeout: 0.5)
    XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    let calls = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    XCTAssertEqual(
      calls.split(separator: "\n"), ["delete mactions-a", "delete mactions-b"],
      "the hung delete is abandoned and the next container is still removed")
  }

  func testTheOrphanSweepGivesUpOnAHungStatus() throws {
    let cli = try fakeCLI(statusBody: "exec sleep 30")
    let started = Date()
    HostCleanup.purgeStrayLinuxContainers(cli: cli, timeout: 0.5)
    XCTAssertLessThan(Date().timeIntervalSince(started), 4)
  }

  // MARK: Fake CLI

  /// A `container` stand-in. Each verb runs its body; by default status,
  /// image inspect and delete succeed and list prints nothing.
  private func fakeCLI(
    statusBody: String = "exit 0", listBody: String = "exit 0", deleteBody: String = "exit 0"
  ) throws -> ContainerCLI {
    let script = temporaryFile("container")
    let contents = """
      #!/bin/sh
      case "$1 $2" in
        "system status") \(statusBody) ;;
        "image inspect") exit 0 ;;
        "list --all") \(listBody) ;;
        "delete --force") \(deleteBody) ;;
      esac
      exit 0
      """
    try contents.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    // macOS checks a new executable the first time it runs, which can take
    // longer than the half-second limits below; run it once up front so the
    // limits time the verb, not that check.
    try Shell.run(script.path, ["warm-up"])
    return ContainerCLI(executable: script.path)
  }

  private func temporaryFile(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("mactions-timeout-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir.appendingPathComponent(name)
  }
}
