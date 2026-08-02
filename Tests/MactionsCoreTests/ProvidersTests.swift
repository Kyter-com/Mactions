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
  /// `ignoresTermination` makes the stand-in survive SIGTERM, so the SIGKILL
  /// escalation is actually exercised. Without it every stand-in dies on the
  /// first signal and the escalation branch is dead code in the suite.
  private func spawnSleeper(under directory: URL, ignoresTermination: Bool = false) throws
    -> Process
  {
    let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    let sleeper = binDirectory.appendingPathComponent("Runner.Worker")
    try? FileManager.default.removeItem(at: sleeper)
    // perl, not a shell script: a script exits on its own the moment the
    // directory is unlinked, and a COPY of a system binary is SIGKILLed at exec
    // because copying breaks the platform binary's code signature. A symlink
    // keeps argv[0] under the run directory (what `pkill -f` matches) while
    // exec'ing the signed original, and it keeps running after `rm -rf` —
    // exactly like the real orphans, which outlived their directory by hours.
    // perl also lets us ignore SIGTERM inside ONE process, with no child to leak.
    let target = ignoresTermination ? "/usr/bin/perl" : "/bin/sleep"
    try FileManager.default.createSymbolicLink(
      at: sleeper, withDestinationURL: URL(fileURLWithPath: target))

    let process = Process()
    process.executableURL = sleeper
    process.arguments =
      ignoresTermination ? ["-e", "$SIG{TERM}='IGNORE'; sleep 300"] : ["300"]
    try process.run()

    // Wait until it is actually visible to pgrep, so teardown cannot race the
    // spawn and "pass" by killing nothing. Assert it: a stand-in that never
    // started would make every assertion below vacuous.
    let pattern = LocalProcessProvider.escapeForExtendedRegex(directory.path) + "(/|[[:space:]]|$)"
    var visible = false
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if let found = try? Shell.run("/usr/bin/pgrep", ["-f", pattern]), found.ok {
        visible = true
        break
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    XCTAssertTrue(visible, "stand-in agent never became visible to pgrep under \(directory.path)")
    return process
  }

  private func waitForExit(_ process: Process, timeout: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
  }

  /// `Process.terminate()` only signals our direct child (`run.sh`), so a
  /// `Runner.Worker` can outlive a stop or a reap, reparent to launchd, and spin
  /// at ~100% CPU once its working copy is deleted underneath it. Observed live
  /// 2026-08-01: five orphaned workers at PPID=1, one per `sustained_unhealthy`
  /// reap, every run directory already gone.
  ///
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
  ///
  /// Uses `run-1` / `run-10` on purpose. That is the REAL hazard: a bare
  /// `pkill -f .../run-1` also kills `.../run-10` (verified by hand). Production
  /// ids end in a fixed-length hex suffix so it cannot bite today, but the helper
  /// must not depend on its caller's naming to be safe, so the pattern is
  /// anchored. Names that merely differ (`doomed` / `bystander`) would pass even
  /// with an unanchored match and prove nothing.
  func testKillProcessesUnderLeavesAPrefixCollidingRunAlone() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mactions-test-scope-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let doomed = root.appendingPathComponent("run-1", isDirectory: true)
    let bystander = root.appendingPathComponent("run-10", isDirectory: true)

    let doomedProcess = try spawnSleeper(under: doomed)
    defer { if doomedProcess.isRunning { doomedProcess.terminate() } }
    let bystanderProcess = try spawnSleeper(under: bystander)
    defer { if bystanderProcess.isRunning { bystanderProcess.terminate() } }

    LocalProcessProvider.killProcesses(under: doomed.path)

    waitForExit(doomedProcess)
    XCTAssertFalse(doomedProcess.isRunning, "the targeted run must be torn down")
    XCTAssertTrue(
      bystanderProcess.isRunning, "a prefix-colliding concurrent run must not be killed")
  }

  /// A descendant that ignores SIGTERM must still die. Without this the 20-poll
  /// loop and the `pkill -9` line are dead code: a plain `sleep` exits on the
  /// first signal, so the escalation never runs and could be deleted with the
  /// suite still green. The wedged `Runner.Worker` this whole fix targets is
  /// precisely a process that is not responding normally.
  func testKillProcessesEscalatesToSIGKILLForATermIgnoringDescendant() throws {
    let runDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mactions-test-stubborn-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: runDirectory) }

    let stubborn = try spawnSleeper(under: runDirectory, ignoresTermination: true)
    defer { if stubborn.isRunning { stubborn.terminate() } }

    LocalProcessProvider.killProcesses(under: runDirectory.path)

    waitForExit(stubborn)
    XCTAssertFalse(stubborn.isRunning, "a SIGTERM-ignoring descendant must be SIGKILLed")
  }

  /// An empty runner id collapses `runsRoot.appendingPathComponent("")` to the
  /// runs root, which would turn a run-scoped kill into a host-wide SIGKILL of
  /// every concurrent runner. Teardown must refuse rather than do that.
  func testTeardownRefusesToKillTheEntireRunsRoot() throws {
    let runsRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("mactions-test-root-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: runsRoot) }

    // A runner belonging to some OTHER run, sitting directly under the root.
    let sibling = runsRoot.appendingPathComponent("mactions-other-abc123", isDirectory: true)
    let siblingProcess = try spawnSleeper(under: sibling)
    defer { if siblingProcess.isRunning { siblingProcess.terminate() } }

    let provider = LocalProcessProvider(
      id: "",
      templateDirectory: runsRoot.appendingPathComponent("template", isDirectory: true),
      runsRoot: runsRoot)
    provider.stop()

    XCTAssertTrue(
      siblingProcess.isRunning,
      "an empty id must not let teardown sweep the whole runs root")
  }

  /// The ERE escaping the anchored pattern depends on. A path containing regex
  /// metacharacters (`.mactions` alone has one) must match literally.
  func testEscapeForExtendedRegexEscapesMetacharacters() {
    XCTAssertEqual(
      LocalProcessProvider.escapeForExtendedRegex("/Users/x/.mactions/runs/a+b"),
      "/Users/x/\\.mactions/runs/a\\+b")
    // `/` is an ordinary character in ERE; escaping it is undefined per POSIX.
    XCTAssertFalse(LocalProcessProvider.escapeForExtendedRegex("/a/b").contains("\\/"))
  }
}
