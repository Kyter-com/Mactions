import XCTest

@testable import MactionsCore

/// A probe the test answers by hand, so a test decides what the network check
/// finds and when (a real probe boots a container).
final class ScriptedProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var waiting: [CheckedContinuation<LaunchGate.ProbeResult, Never>] = []
  private var _calls = 0

  var calls: Int { synchronized { _calls } }
  var pending: Int { synchronized { waiting.count } }

  var probe: LaunchGate.Probe {
    { [self] in
      await withCheckedContinuation { continuation in
        synchronized {
          _calls += 1
          waiting.append(continuation)
        }
      }
    }
  }

  /// Answer the oldest probe still waiting.
  func answer(_ result: LaunchGate.ProbeResult) {
    let continuation = synchronized { waiting.isEmpty ? nil : waiting.removeFirst() }
    continuation?.resume(returning: result)
  }

  private func synchronized<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

@MainActor
final class TestClock {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
final class LaunchGateTests: XCTestCase {
  private static let unreachable = LaunchGate.ProbeResult(
    reachable: false, detail: "DNS lookup of github.com failed inside the Linux VM.")
  private static let reachable = LaunchGate.ProbeResult(reachable: true, detail: "ok")

  private func makeGate() -> (LaunchGate, TestClock) {
    let clock = TestClock()
    let gate = LaunchGate(clock: { clock.now })
    return (gate, clock)
  }

  /// Polls until `condition` holds, yielding so the probe's main-actor hop
  /// runs; fails the test if it never does.
  private func waitFor(
    timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() >= deadline { return XCTFail("condition never held", file: file, line: line) }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private func pauseWindows(_ gate: LaunchGate) {
    gate.recordLaunchFailure(.windows, reason: "never reached GitHub")
    gate.recordLaunchFailure(.windows, reason: "never reached GitHub")
  }

  // MARK: Pausing

  func testOneFailureDoesNotPause() {
    let (gate, _) = makeGate()
    gate.recordLaunchFailure(.linux, reason: "x")
    XCTAssertEqual(gate.decision(for: .linux), .allowed)
    XCTAssertNil(gate.pause(for: .linux))
  }

  func testTwoConsecutiveFailuresPauseTheOS() {
    let (gate, clock) = makeGate()
    gate.recordLaunchFailure(.windows, reason: "first")
    gate.recordLaunchFailure(.windows, reason: "Runner w-2 never reached GitHub")
    let pause = try! XCTUnwrap(gate.pause(for: .windows))
    XCTAssertEqual(pause.reason, "Runner w-2 never reached GitHub")
    XCTAssertEqual(pause.since, clock.now)
    XCTAssertFalse(pause.checking)
    XCTAssertFalse(pause.checksByProbe)
    // No probe for Windows: the first trial waits out the initial backoff.
    XCTAssertEqual(pause.nextCheckAt, clock.now.addingTimeInterval(5 * 60))
    XCTAssertEqual(gate.decision(for: .windows), .paused)
  }

  func testARunnerReachingGitHubBetweenFailuresResetsTheCount() {
    let (gate, _) = makeGate()
    gate.recordLaunchFailure(.linux, reason: "x")
    gate.recordLaunchSuccess(.linux)
    gate.recordLaunchFailure(.linux, reason: "x")
    XCTAssertEqual(gate.decision(for: .linux), .allowed)
  }

  func testPausesArePerOS() {
    let (gate, _) = makeGate()
    pauseWindows(gate)
    XCTAssertEqual(gate.decision(for: .windows), .paused)
    XCTAssertEqual(gate.decision(for: .linux), .allowed)
    XCTAssertEqual(gate.decision(for: .macOS), .allowed)
    XCTAssertEqual(gate.pauses.map(\.os), [.windows])
  }

  // MARK: Trials (no probe)

  func testATrialIsHandedOutOnceTheBackoffHasPassed() {
    let (gate, clock) = makeGate()
    pauseWindows(gate)
    clock.advance(5 * 60 - 1)
    XCTAssertEqual(gate.decision(for: .windows), .paused)
    clock.advance(1)
    XCTAssertEqual(gate.decision(for: .windows), .trial)
    // One trial at a time, however many fleets ask.
    XCTAssertEqual(gate.decision(for: .windows), .paused)
    XCTAssertEqual(gate.pause(for: .windows)?.checking, true)
    XCTAssertNil(gate.pause(for: .windows)?.nextCheckAt)
  }

  func testFailedTrialsDoubleTheBackoffUpToTheCap() {
    let (gate, clock) = makeGate()
    pauseWindows(gate)
    var waits: [TimeInterval] = []
    var last = clock.now
    for _ in 0..<5 {
      // Step a minute at a time until the trial is handed out.
      while gate.decision(for: .windows) != .trial { clock.advance(60) }
      waits.append(clock.now.timeIntervalSince(last))
      clock.advance(10)
      gate.recordLaunchFailure(.windows, reason: "trial never reached GitHub", trial: true)
      last = clock.now
    }
    // 5, then 10, then 20 minutes, then the 20-minute cap.
    XCTAssertEqual(waits[0], 5 * 60)
    XCTAssertEqual(waits[1], 10 * 60)
    XCTAssertEqual(waits[2], 20 * 60)
    XCTAssertEqual(waits[3], 20 * 60)
    XCTAssertEqual(waits[4], 20 * 60)
  }

  func testATrialReachingGitHubResumesLaunching() {
    let (gate, clock) = makeGate()
    pauseWindows(gate)
    clock.advance(5 * 60)
    XCTAssertEqual(gate.decision(for: .windows), .trial)
    gate.recordLaunchSuccess(.windows)
    XCTAssertEqual(gate.decision(for: .windows), .allowed)
    XCTAssertNil(gate.pause(for: .windows))
    // And the slate is clean: it takes two new failures to pause again.
    gate.recordLaunchFailure(.windows, reason: "x")
    XCTAssertEqual(gate.decision(for: .windows), .allowed)
  }

  func testAReleasedTrialIsHandedOutAgain() {
    let (gate, clock) = makeGate()
    pauseWindows(gate)
    clock.advance(5 * 60)
    XCTAssertEqual(gate.decision(for: .windows), .trial)
    gate.releaseTrial(.windows)  // e.g. the host budget had no room
    XCTAssertEqual(gate.decision(for: .windows), .trial)
  }

  func testAFailureFromARunnerLaunchedBeforeThePauseIsNotTheTrial() {
    let (gate, clock) = makeGate()
    pauseWindows(gate)
    clock.advance(5 * 60)
    XCTAssertEqual(gate.decision(for: .windows), .trial)
    gate.recordLaunchFailure(.windows, reason: "older runner reaped", trial: false)
    // The trial is still running, and its backoff did not grow.
    XCTAssertEqual(gate.pause(for: .windows)?.checking, true)
    clock.advance(30)
    gate.recordLaunchFailure(.windows, reason: "trial failed", trial: true)
    XCTAssertEqual(
      gate.pause(for: .windows)?.nextCheckAt, clock.now.addingTimeInterval(10 * 60),
      "one failed trial: the second wait, not a third")
  }

  func testAStragglerFailingWhilePausedDoesNotGrowTheBackoff() {
    let (gate, clock) = makeGate()
    pauseWindows(gate)
    let next = gate.pause(for: .windows)?.nextCheckAt
    clock.advance(30)
    gate.recordLaunchFailure(.windows, reason: "late", trial: false)
    XCTAssertEqual(gate.pause(for: .windows)?.nextCheckAt, next)
    XCTAssertEqual(gate.pause(for: .windows)?.reason, "late")
  }

  func testATrialThatNeverAnswersCountsAsFailed() {
    let (gate, clock) = makeGate()
    pauseWindows(gate)
    clock.advance(5 * 60)
    XCTAssertEqual(gate.decision(for: .windows), .trial)
    clock.advance(15 * 60 - 1)
    XCTAssertEqual(gate.decision(for: .windows), .paused)
    XCTAssertEqual(gate.pause(for: .windows)?.checking, true)
    clock.advance(1)
    XCTAssertEqual(gate.decision(for: .windows), .paused)
    XCTAssertEqual(gate.pause(for: .windows)?.checking, false)
    XCTAssertEqual(gate.pause(for: .windows)?.nextCheckAt, clock.now.addingTimeInterval(10 * 60))
  }

  // MARK: Probes

  func testAPausedOSWithAProbeIsCheckedAtOnce() async {
    let (gate, clock) = makeGate()
    let scripted = ScriptedProbe()
    gate.setProbe(scripted.probe, for: .linux)
    gate.recordLaunchFailure(.linux, reason: "a")
    gate.recordLaunchFailure(.linux, reason: "Runner l-2 never reached GitHub")
    XCTAssertEqual(gate.pause(for: .linux)?.nextCheckAt, clock.now)

    // The probe runs instead of a launch; the caller only sees `.paused`.
    XCTAssertEqual(gate.decision(for: .linux), .paused)
    XCTAssertEqual(gate.pause(for: .linux)?.checking, true)
    await waitFor { scripted.pending == 1 }
    scripted.answer(Self.unreachable)
    await waitFor { gate.pause(for: .linux)?.checking == false }

    let pause = gate.pause(for: .linux)
    XCTAssertEqual(pause?.checksByProbe, true)
    XCTAssertEqual(pause?.reason, Self.unreachable.detail, "the probe's finding is the reason")
    XCTAssertEqual(pause?.nextCheckAt, clock.now.addingTimeInterval(60))
    XCTAssertEqual(scripted.calls, 1)
  }

  func testFailingProbesBackOffAndNeverLaunch() async {
    let (gate, clock) = makeGate()
    let scripted = ScriptedProbe()
    gate.setProbe(scripted.probe, for: .linux)
    gate.recordLaunchFailure(.linux, reason: "a")
    gate.recordLaunchFailure(.linux, reason: "b")

    var waits: [TimeInterval] = []
    var last = clock.now
    for _ in 1...5 {
      // Step 15 s at a time until the gate starts a probe. (The probe itself
      // only runs once the test awaits: it is a main-actor task.)
      while true {
        XCTAssertEqual(gate.decision(for: .linux), .paused, "a probed OS never gets a trial")
        if gate.pause(for: .linux)?.checking == true { break }
        clock.advance(15)
      }
      waits.append(clock.now.timeIntervalSince(last))
      await waitFor { scripted.pending == 1 }
      scripted.answer(Self.unreachable)
      await waitFor { gate.pause(for: .linux)?.checking == false }
      last = clock.now
    }
    // At once, then 1, 2, 4 minutes, then the 5-minute cap.
    XCTAssertEqual(waits, [0, 60, 120, 240, 300])
    XCTAssertEqual(scripted.calls, 5)
  }

  func testAPassingProbeResumesAndTheNextFailurePausesAgainAfterABackoff() async {
    let (gate, clock) = makeGate()
    let scripted = ScriptedProbe()
    gate.setProbe(scripted.probe, for: .linux)
    var resumed: [RunnerOS] = []
    gate.onResume = { resumed.append($0) }
    gate.recordLaunchFailure(.linux, reason: "a")
    gate.recordLaunchFailure(.linux, reason: "b")

    XCTAssertEqual(gate.decision(for: .linux), .paused)
    await waitFor { scripted.pending == 1 }
    scripted.answer(Self.reachable)
    await waitFor { gate.pause(for: .linux) == nil }
    XCTAssertEqual(resumed, [.linux])
    XCTAssertEqual(gate.decision(for: .linux), .allowed)

    // The network was fine, so a runner that still fails is something else: one
    // failure pauses again, and this time the probe waits out a backoff
    // instead of turning straight back into a launch loop.
    gate.recordLaunchFailure(.linux, reason: "c")
    XCTAssertEqual(gate.pause(for: .linux)?.nextCheckAt, clock.now.addingTimeInterval(120))
    XCTAssertEqual(gate.decision(for: .linux), .paused)
    XCTAssertEqual(scripted.calls, 1)
  }

  func testAProbeAnswerAfterARunnerCameOnlineIsIgnored() async {
    let (gate, _) = makeGate()
    let scripted = ScriptedProbe()
    gate.setProbe(scripted.probe, for: .linux)
    gate.recordLaunchFailure(.linux, reason: "a")
    gate.recordLaunchFailure(.linux, reason: "b")
    XCTAssertEqual(gate.decision(for: .linux), .paused)
    await waitFor { scripted.pending == 1 }

    gate.recordLaunchSuccess(.linux)  // a runner launched before the pause made it
    scripted.answer(Self.unreachable)
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertNil(gate.pause(for: .linux))
    XCTAssertEqual(gate.decision(for: .linux), .allowed)
  }

  func testAProbeThatNeverAnswersIsLostAndALateAnswerIsIgnored() async {
    let (gate, clock) = makeGate()
    let scripted = ScriptedProbe()
    gate.setProbe(scripted.probe, for: .linux)
    gate.recordLaunchFailure(.linux, reason: "a")
    gate.recordLaunchFailure(.linux, reason: "b")
    XCTAssertEqual(gate.decision(for: .linux), .paused)
    await waitFor { scripted.pending == 1 }

    clock.advance(5 * 60)
    XCTAssertEqual(gate.decision(for: .linux), .paused)
    XCTAssertEqual(gate.pause(for: .linux)?.checking, false)
    XCTAssertEqual(gate.pause(for: .linux)?.nextCheckAt, clock.now.addingTimeInterval(60))

    // The lost probe finally answers "reachable": too late to count.
    scripted.answer(Self.reachable)
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertNotNil(gate.pause(for: .linux))
  }

  // MARK: Network changes and the user

  func testANetworkChangeBringsTheNextCheckForward() {
    let (gate, clock) = makeGate()
    pauseWindows(gate)
    clock.advance(30)
    XCTAssertEqual(gate.decision(for: .windows), .paused)
    gate.networkChanged()
    XCTAssertEqual(gate.pause(for: .windows)?.nextCheckAt, clock.now)
    XCTAssertEqual(gate.decision(for: .windows), .trial)
  }

  func testANetworkChangeDuringAProbeChecksAgainInsteadOfBackingOff() async {
    let (gate, clock) = makeGate()
    let scripted = ScriptedProbe()
    gate.setProbe(scripted.probe, for: .linux)
    gate.recordLaunchFailure(.linux, reason: "a")
    gate.recordLaunchFailure(.linux, reason: "b")
    XCTAssertEqual(gate.decision(for: .linux), .paused)
    await waitFor { scripted.pending == 1 }

    gate.networkChanged()  // e.g. the VPN dropped while the probe was booting
    scripted.answer(Self.unreachable)
    await waitFor { gate.pause(for: .linux)?.checking == false }
    XCTAssertEqual(gate.pause(for: .linux)?.nextCheckAt, clock.now)

    // The repeat check starts at once, and a second failure resumes the
    // backoff from where it was (the first wait), not past it.
    XCTAssertEqual(gate.decision(for: .linux), .paused)
    await waitFor { scripted.pending == 1 }
    XCTAssertEqual(scripted.calls, 2)
    scripted.answer(Self.unreachable)
    await waitFor { gate.pause(for: .linux)?.checking == false }
    XCTAssertEqual(gate.pause(for: .linux)?.nextCheckAt, clock.now.addingTimeInterval(60))
  }

  func testResumeNowLaunchesAgainAndKeepsTheBackoff() {
    let (gate, clock) = makeGate()
    var resumed: [RunnerOS] = []
    gate.onResume = { resumed.append($0) }
    pauseWindows(gate)
    gate.resumeNow(.windows)
    XCTAssertEqual(resumed, [.windows])
    XCTAssertEqual(gate.decision(for: .windows), .allowed)
    gate.recordLaunchFailure(.windows, reason: "still broken")
    XCTAssertEqual(
      gate.pause(for: .windows)?.nextCheckAt, clock.now.addingTimeInterval(10 * 60),
      "one more failure pauses again, one step further out than the first pause")
  }

  func testResumeNowIgnoresAProbeStillRunning() async {
    let (gate, _) = makeGate()
    let scripted = ScriptedProbe()
    gate.setProbe(scripted.probe, for: .linux)
    gate.recordLaunchFailure(.linux, reason: "a")
    gate.recordLaunchFailure(.linux, reason: "b")
    XCTAssertEqual(gate.decision(for: .linux), .paused)
    await waitFor { scripted.pending == 1 }
    gate.resumeNow(.linux)
    scripted.answer(Self.unreachable)  // the old check's answer arrives late
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertNil(gate.pause(for: .linux))
    XCTAssertEqual(gate.decision(for: .linux), .allowed)
  }

  func testOnChangeFiresWhenAPauseStartsAndEnds() {
    let (gate, clock) = makeGate()
    var changes = 0
    gate.onChange = { changes += 1 }
    gate.recordLaunchFailure(.windows, reason: "a")
    XCTAssertEqual(changes, 0)
    gate.recordLaunchFailure(.windows, reason: "b")
    XCTAssertEqual(changes, 1)
    clock.advance(5 * 60)
    _ = gate.decision(for: .windows)  // trial handed out
    XCTAssertEqual(changes, 2)
    gate.recordLaunchSuccess(.windows)
    XCTAssertEqual(changes, 3)
    gate.recordLaunchSuccess(.windows)  // nothing left to clear
    XCTAssertEqual(changes, 3)
  }

  // MARK: Policy

  func testStandardPolicies() {
    let linux = LaunchGate.Policy.standard(for: .linux)
    XCTAssertEqual(linux.failureThreshold, 2)
    XCTAssertEqual((0..<5).map { linux.backoff(level: $0) }, [60, 120, 240, 300, 300])
    XCTAssertEqual(LaunchGate.Policy.standard(for: .macOS), linux)
    let windows = LaunchGate.Policy.standard(for: .windows)
    XCTAssertEqual((0..<4).map { windows.backoff(level: $0) }, [300, 600, 1200, 1200])
    // A Windows trial outlives its own 10-minute never-confirmed reap.
    XCTAssertGreaterThan(
      windows.outstandingTimeout, RunnerOrchestrator.defaultNeverConfirmedReapInterval(for: .windows))
    XCTAssertGreaterThan(
      linux.outstandingTimeout, RunnerOrchestrator.defaultNeverConfirmedReapInterval(for: .linux))
  }

  func testPolicyBoundsItsInputs() {
    let policy = LaunchGate.Policy(
      failureThreshold: 0, initialBackoff: 30, maxBackoff: 10, outstandingTimeout: -1)
    XCTAssertEqual(policy.failureThreshold, 1)
    XCTAssertEqual(policy.maxBackoff, 30)
    XCTAssertEqual(policy.outstandingTimeout, 0)
    XCTAssertEqual(policy.backoff(level: 1_000), 30)
  }
}
