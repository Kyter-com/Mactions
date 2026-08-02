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

  // MARK: Run-scoped teardown

  /// Spawn a long-lived process whose executable path lives under `directory`,
  /// the way the real agent tree does (`<runDir>/bin/Runner.Worker`).
  ///
  /// A SYMLINK to /bin/sleep, deliberately, after two dead ends:
  ///   - a shell script exits by itself the moment `cleanup()` unlinks it, so
  ///     the test passes with or without the fix;
  ///   - a COPY of /bin/sleep is SIGKILLed at exec (copying breaks the platform
  ///     binary's code signature), so it never runs at all.
  /// A symlink keeps argv[0] under the run directory (what `pkill -f` matches)
  /// while exec'ing the signed original, and it keeps running after `rm -rf` —
  /// exactly like the real orphaned Runner.Worker processes, which survived for
  /// hours after their run directory was deleted.
  private func spawnSleeper(under directory: URL) throws -> Process {
    let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    let sleeper = binDirectory.appendingPathComponent("Runner.Worker")
    try? FileManager.default.removeItem(at: sleeper)
    try FileManager.default.createSymbolicLink(
      at: sleeper, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))

    let process = Process()
    process.executableURL = sleeper
    process.arguments = ["300"]
    try process.run()

    // Wait until it is actually visible to pgrep, so teardown cannot race the
    // spawn and "pass" by killing nothing.
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if let found = try? Shell.run("/usr/bin/pgrep", ["-f", directory.path]), found.ok { break }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return process
  }

  private func waitForExit(_ process: Process, timeout: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
  }

  /// `Process.terminate()` only signals our direct child (`run.sh`), so the
  /// Runner.Listener/Runner.Worker grandchildren survive a stop or a reap,
  /// reparent to launchd, and then spin at ~100% CPU once their working copy is
  /// deleted underneath them. Observed live 2026-08-01: five orphaned workers
  /// burning ~5 of 14 cores, one per `sustained_unhealthy` reap, each leak
  /// slowing the next job enough to trigger the next reap.
  /// Drives the REAL teardown path (`stop()` → `cleanup()`), not just the helper,
  /// so deleting the kill from `cleanup()` fails this test rather than silently
  /// reintroducing the leak.
  func testStopKillsSurvivingAgentDescendantsBeforeDeletingTheClone() throws {
    let runsRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("mactions-test-runs-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: runsRoot) }
    let id = "mactions-test-agent"
    let runDirectory = runsRoot.appendingPathComponent(id, isDirectory: true)

    let provider = LocalProcessProvider(
      id: id,
      templateDirectory: runsRoot.appendingPathComponent("template", isDirectory: true),
      runsRoot: runsRoot)

    // Stand in for the Runner.Listener/Runner.Worker grandchildren that outlive
    // the SIGTERM `stop()` sends to run.sh. `start()` was never called, so
    // `stop()` takes the no-process branch straight into `cleanup()`.
    let sleeper = try spawnSleeper(under: runDirectory)
    defer { if sleeper.isRunning { sleeper.terminate() } }
    XCTAssertTrue(sleeper.isRunning, "precondition: the stand-in agent is running")

    provider.stop()

    // stop() returns once nothing matches, but the parent still has to reap the
    // zombie before isRunning flips.
    waitForExit(sleeper)
    XCTAssertFalse(sleeper.isRunning, "a surviving agent descendant must be killed, not orphaned")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: runDirectory.path),
      "the per-run clone must still be deleted after the descendants are killed")
  }

  /// The scoping guarantee, and the reason this is NOT
  /// `HostCleanup.killOrphanRunnerProcesses()` (which matches the whole `runs/`
  /// root and is therefore only safe before going online): tearing one run down
  /// must never touch a CONCURRENT run's agents.
  func testKillProcessesUnderLeavesOtherRunsAlone() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mactions-test-scope-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let doomed = root.appendingPathComponent("run-doomed", isDirectory: true)
    let bystander = root.appendingPathComponent("run-bystander", isDirectory: true)

    let doomedProcess = try spawnSleeper(under: doomed)
    let bystanderProcess = try spawnSleeper(under: bystander)
    defer {
      if doomedProcess.isRunning { doomedProcess.terminate() }
      if bystanderProcess.isRunning { bystanderProcess.terminate() }
    }

    LocalProcessProvider.killProcesses(under: doomed.path)

    waitForExit(doomedProcess)
    XCTAssertFalse(doomedProcess.isRunning, "the targeted run must be torn down")
    XCTAssertTrue(
      bystanderProcess.isRunning, "a concurrent run must survive another run's teardown")
  }
}
