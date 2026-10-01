import XCTest

@testable import MactionsCore

@MainActor
final class FleetLifecycleTests: XCTestCase {
  /// Holds teardown at an actual suspension point, without sleeping the host or
  /// touching a provider. All access remains on the main actor.
  @MainActor
  private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
      guard !isOpen else { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
      isOpen = true
      let pending = waiters
      waiters.removeAll()
      pending.forEach { $0.resume() }
    }
  }

  private func settleTasks() async {
    for _ in 0..<50 { await Task.yield() }
  }

  private func waitFor(
    _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline { await Task.yield() }
    XCTAssertTrue(condition(), "transition did not complete", file: file, line: line)
  }

  func testWakeWaitsForTeardownAndDuplicateWakeResumesOnce() async {
    let lifecycle = FleetLifecycle()
    let teardown = Gate()
    var events: [String] = []
    lifecycle.willSleep(wasRunning: true) {
      events.append("stop")
      await teardown.wait()
      events.append("stopped")
    }
    XCTAssertTrue(lifecycle.isSleeping)
    XCTAssertFalse(lifecycle.allowsStart)
    lifecycle.didWake { events.append("resume") }
    lifecycle.didWake { events.append("duplicate") }
    await waitFor { events.count >= 1 }
    XCTAssertEqual(events, ["stop"])
    XCTAssertFalse(lifecycle.isSleeping)
    XCTAssertFalse(lifecycle.allowsStart, "wake alone must not permit startup")

    teardown.open()
    await waitFor { events.count >= 3 }
    XCTAssertEqual(events, ["stop", "stopped", "resume"])
    XCTAssertTrue(lifecycle.allowsStart)
    lifecycle.didWake { events.append("late duplicate") }
    await settleTasks()
    XCTAssertEqual(events, ["stop", "stopped", "resume"])
  }

  func testConcurrentShutdownCallersShareTeardownAndBothWait() async {
    let lifecycle = FleetLifecycle()
    let teardown = Gate()
    var stopCalls = 0
    var completions = 0
    var callers = 0
    let operation: @MainActor () async -> Void = {
      stopCalls += 1
      await teardown.wait()
    }
    let first = Task {
      callers += 1
      await lifecycle.shutDown(operation)
      completions += 1
    }
    let second = Task {
      callers += 1
      await lifecycle.shutDown(operation)
      completions += 1
    }
    await waitFor { stopCalls >= 1 && callers == 2 }
    XCTAssertEqual(stopCalls, 1)
    XCTAssertEqual(completions, 0)

    teardown.open()
    await first.value
    await second.value
    XCTAssertEqual(completions, 2)
    await lifecycle.shutDown { stopCalls += 1 }
    XCTAssertEqual(stopCalls, 2, "a later fleet must get its own teardown")
  }

  func testAnotherSleepRevokesPendingWakeButPreservesResumeIntent() async {
    let lifecycle = FleetLifecycle()
    let teardown = Gate()
    var stopCalls = 0
    var resumes = 0
    let suspend: @MainActor () async -> Void = {
      stopCalls += 1
      await teardown.wait()
    }
    lifecycle.willSleep(wasRunning: true, suspend: suspend)
    lifecycle.didWake { resumes += 1 }
    await settleTasks()
    lifecycle.willSleep(wasRunning: false, suspend: suspend)
    await settleTasks()
    XCTAssertEqual(stopCalls, 1)

    teardown.open()
    await settleTasks()
    XCTAssertEqual(resumes, 0, "the Mac is asleep again")
    lifecycle.didWake { resumes += 1 }
    await waitFor { resumes >= 1 }
    XCTAssertEqual(resumes, 1)
  }

  func testOfflineOrQuitCancelsAutomaticResumeWithoutCancellingTeardown() async {
    let lifecycle = FleetLifecycle()
    let teardown = Gate()
    var stopped = false
    var resumes = 0
    lifecycle.willSleep(wasRunning: true) {
      await teardown.wait()
      stopped = true
    }
    lifecycle.didWake { resumes += 1 }
    await settleTasks()
    lifecycle.cancelResume()
    teardown.open()
    await waitFor { stopped }
    lifecycle.didWake { resumes += 1 }
    await settleTasks()
    XCTAssertTrue(stopped)
    XCTAssertEqual(resumes, 0)
  }

  func testOfflineFleetStaysOfflineAcrossSleepAndWake() async {
    let lifecycle = FleetLifecycle()
    var stopCalls = 0
    var resumes = 0
    lifecycle.willSleep(wasRunning: false) { stopCalls += 1 }
    lifecycle.didWake { resumes += 1 }
    await settleTasks()
    XCTAssertEqual(stopCalls, 0)
    XCTAssertEqual(resumes, 0)
  }

  func testCompletedSleepCycleCanBeRepeated() async {
    let lifecycle = FleetLifecycle()
    var events: [String] = []
    for cycle in 0..<2 {
      lifecycle.willSleep(wasRunning: true) { events.append("stop") }
      await waitFor { events.count >= cycle * 2 + 1 }
      lifecycle.didWake { events.append("resume") }
      await waitFor { events.count >= (cycle + 1) * 2 }
    }
    XCTAssertEqual(events, ["stop", "resume", "stop", "resume"])
  }

  func testSleepDuringExplicitRestartDefersResumeUntilWake() async {
    let lifecycle = FleetLifecycle()
    let teardown = Gate()
    var resumes = 0
    let suspend: @MainActor () async -> Void = {
      await teardown.wait()
    }
    lifecycle.restart(suspend: suspend) { resumes += 1 }
    await settleTasks()
    // AppState is already .stopping when the sleep notification arrives.
    lifecycle.willSleep(wasRunning: false, suspend: suspend)
    await settleTasks()
    teardown.open()
    await settleTasks()
    XCTAssertEqual(resumes, 0)

    lifecycle.didWake { resumes += 1 }
    await waitFor { resumes >= 1 }
    XCTAssertEqual(resumes, 1)
  }

  func testExplicitOfflineCancelsPendingRestart() async {
    let lifecycle = FleetLifecycle()
    let teardown = Gate()
    var resumes = 0
    lifecycle.restart(suspend: { await teardown.wait() }) { resumes += 1 }
    await settleTasks()
    lifecycle.cancelResume()
    teardown.open()
    await settleTasks()
    XCTAssertEqual(resumes, 0)
  }

  func testExplicitRestartWaitsForShutdownBeforeResuming() async {
    let lifecycle = FleetLifecycle()
    let teardown = Gate()
    var events: [String] = []
    lifecycle.restart {
      events.append("stop")
      await teardown.wait()
      events.append("stopped")
    } resume: {
      events.append("resume")
    }
    await waitFor { events.count >= 1 }
    XCTAssertEqual(events, ["stop"])
    teardown.open()
    await waitFor { events.count >= 3 }
    XCTAssertEqual(events, ["stop", "stopped", "resume"])
  }
}
