import XCTest

@testable import MactionsCore

/// Pins `Shell.run(timeout:)`: a bounded command returns its output when it
/// finishes in time, and otherwise the CALLER gets control back within the
/// timeout plus the documented graces, whatever the command or its children do.
final class ShellTimeoutTests: XCTestCase {
  func testBoundedRunReturnsTheOutputOfACommandThatFinishes() throws {
    let result = try Shell.run(
      "/bin/sh", ["-c", "printf out; printf err >&2; exit 3"], timeout: 10)
    XCTAssertEqual(result.status, 3)
    XCTAssertEqual(result.stdout, "out")
    XCTAssertEqual(result.stderr, "err")
  }

  func testBoundedRunCapturesOutputLargerThanAPipeBuffer() throws {
    // 256 KiB on each stream: more than a pipe holds, so a reader that waited
    // for exit before draining would deadlock against the writer.
    let script =
      "head -c 262144 /dev/zero | tr '\\0' a; head -c 262144 /dev/zero | tr '\\0' b >&2"
    let result = try Shell.run("/bin/sh", ["-c", script], timeout: 20)
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.stdout.count, 262_144)
    XCTAssertEqual(result.stderr.count, 262_144)
  }

  func testBoundedRunStopsACommandThatOutlivesItsTimeout() throws {
    let pidFile = try temporaryPIDFile()
    let started = Date()
    XCTAssertThrowsError(
      try Shell.run("/bin/sh", ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 30"], timeout: 0.5)
    ) { error in
      guard case Shell.ShellError.timedOut(_, let seconds)? = error as? Shell.ShellError else {
        return XCTFail("expected timedOut, got \(error)")
      }
      XCTAssertEqual(seconds, 0.5)
    }
    // SIGTERM ends sleep at once; the bound is the timeout, not the 30 s sleep.
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    try assertProcessIsGone(pidFile)
  }

  func testBoundedRunEscalatesToSIGKILLWhenSIGTERMIsIgnored() throws {
    let pidFile = try temporaryPIDFile()
    let started = Date()
    XCTAssertThrowsError(
      try Shell.run(
        "/bin/sh",
        ["-c", "echo $$ > '\(pidFile.path)'; trap '' TERM; while :; do sleep 0.1; done"],
        timeout: 0.5))
    let elapsed = Date().timeIntervalSince(started)
    // 0.5 s timeout + 2 s SIGTERM grace, then SIGKILL; far below the loop's
    // unbounded lifetime.
    XCTAssertGreaterThanOrEqual(elapsed, 0.5 + Shell.terminationGrace - 0.2)
    XCTAssertLessThan(elapsed, 0.5 + Shell.terminationGrace + 3)
    // Returning on time is not enough: the shell that ignored SIGTERM must be dead.
    try assertProcessIsGone(pidFile)
  }

  func testBoundedRunDoesNotWaitForAGrandchildThatHoldsThePipe() throws {
    // The shell exits at once, but the backgrounded sleep inherited stdout and
    // keeps it open for 8 s. An unbounded read-to-EOF would wait all 8 s.
    let started = Date()
    let result = try Shell.run("/bin/sh", ["-c", "sleep 8 & echo started"], timeout: 20)
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.stdout, "started\n")
    XCTAssertLessThan(Date().timeIntervalSince(started), Shell.drainGrace + 3)
  }

  func testBoundedRunRethrowsALaunchFailure() {
    XCTAssertThrowsError(try Shell.run("/nonexistent/binary", [], timeout: 5))
  }

  func testUnboundedRunIsUnchanged() throws {
    let result = try Shell.run("/bin/sh", ["-c", "printf hi; exit 2"])
    XCTAssertEqual(result.status, 2)
    XCTAssertEqual(result.stdout, "hi")
  }

  private func temporaryPIDFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mactions-shell-\(UUID().uuidString).pid")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  /// The command wrote its own PID; after the bounded run it must not exist
  /// (ESRCH). Polls briefly because reaping happens on Foundation's queue.
  private func assertProcessIsGone(
    _ pidFile: URL, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let text = try String(contentsOf: pidFile, encoding: .utf8)
    let pid = try XCTUnwrap(
      pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), file: file, line: line)
    let deadline = Date().addingTimeInterval(2)
    while kill(pid, 0) == 0, Date() < deadline { usleep(20_000) }
    XCTAssertNotEqual(kill(pid, 0), 0, "pid \(pid) is still alive", file: file, line: line)
  }

  func testRunCheckedPassesTheTimeoutThrough() {
    let started = Date()
    XCTAssertThrowsError(try Shell.runChecked("/bin/sleep", ["30"], timeout: 0.5)) { error in
      guard case Shell.ShellError.timedOut? = error as? Shell.ShellError else {
        return XCTFail("expected timedOut, got \(error)")
      }
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
  }
}
