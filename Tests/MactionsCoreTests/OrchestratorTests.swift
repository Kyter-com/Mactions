import XCTest

@testable import MactionsCore

// MARK: Fakes

final class FakeControlPlane: RunnerControlPlane, @unchecked Sendable {
  struct Failure: Error {}

  private(set) var jitCount = 0
  private(set) var deleted: [Int] = []
  var remote: [RemoteRunner] = []
  /// Label sets of the jobs currently queued — the scale-from-zero demand signal.
  var queuedJobs: [[String]] = []
  /// When true, `listQueuedJobLabels` throws (a failed poll must HOLD the fleet).
  var failQueuedPoll = false
  /// When true, `listRunners` throws (busy-ness unknown: scale up only, never trim).
  var failListRunners = false
  /// Runner ids whose delete throws — GitHub's 422 for a runner that is
  /// currently running a job (the server-side trim-race guard).
  var failDeletes: Set<Int> = []

  func generateJITConfig(name: String, labels: [String]) async throws -> JITConfig {
    jitCount += 1
    return JITConfig(encodedConfig: "jit-\(name)", runnerId: jitCount, runnerName: name)
  }
  func listRunners() async throws -> [RemoteRunner] {
    if failListRunners { throw Failure() }
    return remote
  }
  /// Ids whose delete was ATTEMPTED (recorded at entry, before delay/throw) —
  /// lets tests interleave an exit with an in-flight delete await.
  private(set) var deleteAttempts: [Int] = []
  var deleteDelayNanos: UInt64 = 0
  private(set) var queuePollCount = 0
  var queueDelayNanos: UInt64 = 0

  func deleteRunner(id: Int) async throws {
    deleteAttempts.append(id)
    if deleteDelayNanos > 0 { try? await Task.sleep(nanoseconds: deleteDelayNanos) }
    if failDeletes.contains(id) { throw Failure() }
    deleted.append(id)
  }
  func listQueuedJobLabels() async throws -> [[String]] {
    queuePollCount += 1
    if queueDelayNanos > 0 { try? await Task.sleep(nanoseconds: queueDelayNanos) }
    if failQueuedPoll { throw Failure() }
    return queuedJobs
  }
}

final class FakeProvider: RunnerProvider, @unchecked Sendable {
  let id: String
  private var onExit: ((Int32) -> Void)?
  private(set) var started = false
  private(set) var stopped = false
  init(id: String) { self.id = id }
  var isRunning: Bool { started && !stopped }
  func start(jitConfig: String, onExit: @escaping @Sendable (Int32) -> Void) throws {
    started = true
    self.onExit = onExit
  }
  func stop() { stopped = true }
  func fireExit(_ status: Int32 = 0) { onExit?(status) }
}

final class FakeFactory: RunnerProviderFactory {
  let kind = "fake"
  private(set) var made: [FakeProvider] = []
  func makeProvider(name: String) -> RunnerProvider {
    let provider = FakeProvider(id: name)
    made.append(provider)
    return provider
  }
}

/// An agent that dies the instant it launches: onExit fires synchronously from
/// start() — the rare exit-beats-append ordering `provisionOne` discards.
final class InstantExitProvider: RunnerProvider, @unchecked Sendable {
  let id: String
  init(id: String) { self.id = id }
  var isRunning: Bool { false }
  func start(jitConfig: String, onExit: @escaping @Sendable (Int32) -> Void) throws { onExit(1) }
  func stop() {}
}

final class InstantExitFactory: RunnerProviderFactory {
  let kind = "instant-exit"
  func makeProvider(name: String) -> RunnerProvider { InstantExitProvider(id: name) }
}

/// An agent that dies shortly AFTER launch — the COMMON dead-container-daemon
/// shape (`run` exits ms after spawn, well after the slot was appended), which
/// must route through handleExit's launch-failure branch, not the early-exit
/// discard.
final class DelayedExitProvider: RunnerProvider, @unchecked Sendable {
  let id: String
  let delay: TimeInterval
  init(id: String, delay: TimeInterval) {
    self.id = id
    self.delay = delay
  }
  var isRunning: Bool { false }
  func start(jitConfig: String, onExit: @escaping @Sendable (Int32) -> Void) throws {
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { onExit(1) }
  }
  func stop() {}
}

final class DelayedExitFactory: RunnerProviderFactory {
  let kind = "delayed-exit"
  let delay: TimeInterval
  init(delay: TimeInterval) { self.delay = delay }
  func makeProvider(name: String) -> RunnerProvider {
    DelayedExitProvider(id: name, delay: delay)
  }
}

/// A provider whose stop() BLOCKS until the test releases it — a wedged
/// `vmrun stop` stand-in for the detached-teardown budget-release path.
final class GatedStopProvider: RunnerProvider, @unchecked Sendable {
  let id: String
  private let lock = NSLock()
  private var canStop = false
  init(id: String) { self.id = id }
  var isRunning: Bool { false }
  func start(jitConfig: String, onExit: @escaping @Sendable (Int32) -> Void) throws {}
  func allowStop() {
    lock.lock()
    canStop = true
    lock.unlock()
  }
  func stop() {
    while true {
      lock.lock()
      let go = canStop
      lock.unlock()
      if go { return }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }
}

final class GatedStopFactory: RunnerProviderFactory {
  let kind = "gated-stop"
  private(set) var made: [GatedStopProvider] = []
  func makeProvider(name: String) -> RunnerProvider {
    let provider = GatedStopProvider(id: name)
    made.append(provider)
    return provider
  }
}

/// Collects the run records an orchestrator emits via `onRunFinished` (main-actor
/// isolated, so the callback can append without Sendable gymnastics).
@MainActor
final class RecordCollector {
  var records: [RunRecord] = []
}

// MARK: Tests

@MainActor
final class OrchestratorTests: XCTestCase {
  /// `queued: nil` seeds one matching queued job per requested runner, so tests
  /// that just need N runners up don't stage the queue themselves (under
  /// scale-from-zero, runners exist only when queued jobs demand them).
  private func makeOrchestrator(
    count: Int,
    labels: [String] = ["self-hosted"],
    queued: [[String]]? = nil,
    budget: HostBudget? = nil,
    reconcileInterval: UInt64 = 30_000_000_000,
    remoteRegistrationGraceInterval: TimeInterval = 5 * 60,
    idleJITRefreshInterval: TimeInterval? = 8 * 60,
    idleTrimGraceInterval: TimeInterval = 90,
    trimConfirmInterval: TimeInterval = 0.01,  // tests: one 50ms tick elapses it
    launchFailureGraceInterval: TimeInterval = 0  // tests: disabled unless opted in
  ) -> (RunnerOrchestrator, FakeControlPlane, FakeFactory) {
    let cp = FakeControlPlane()
    cp.queuedJobs = queued ?? Array(repeating: labels, count: count)
    let factory = FakeFactory()
    let config = FleetConfig(owner: "o", repo: "r", labels: labels, maxRunners: count)
    // Fixed machine prefix so teardown scoping is deterministic (not host-dependent).
    let orch = RunnerOrchestrator(
      controlPlane: cp, factory: factory, config: config, budget: budget,
      machinePrefix: "mactions-testmac",
      reconcileInterval: reconcileInterval,
      idleReconcileInterval: reconcileInterval,  // tests tick at one pace
      remoteRegistrationGraceInterval: remoteRegistrationGraceInterval,
      idleJITRefreshInterval: idleJITRefreshInterval,
      idleTrimGraceInterval: idleTrimGraceInterval,
      trimConfirmInterval: trimConfirmInterval,
      launchFailureGraceInterval: launchFailureGraceInterval)
    return (orch, cp, factory)
  }

  /// Let queued MainActor tasks (the exit -> recycle hops) run.
  private func settle() async {
    try? await Task.sleep(nanoseconds: 80_000_000)
  }

  /// Polls `condition` until it holds or `timeout` elapses, yielding between
  /// checks so the background reconcile loop and exit→recycle hops can run.
  /// Replaces fixed `Task.sleep` waits that raced the reconcile cadence: returns
  /// the instant the fleet converges (faster than a fixed sleep on success) and
  /// only waits out the timeout on a genuine regression — the assertion that
  /// follows still reports the failure. This is what de-flakes the suite under
  /// CI scheduler jitter, where a fixed 160–300ms budget didn't reliably cover
  /// the expected number of reconcile ticks.
  @discardableResult
  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() >= deadline { return false }
      try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
    }
    return true
  }

  // MARK: Demand-driven provisioning (scale-from-zero)

  func testStartProvisionsOnePerQueuedJob() async {
    let (orch, cp, factory) = makeOrchestrator(count: 3)  // 3 queued jobs seeded
    await orch.start()
    XCTAssertEqual(orch.state, .online)
    XCTAssertEqual(orch.runners.count, 3)
    XCTAssertEqual(cp.jitCount, 3)
    XCTAssertEqual(factory.made.count, 3)
    XCTAssertTrue(factory.made.allSatisfy { $0.started })
  }

  func testEmptyQueueStartsAtZeroRunners() async {
    let (orch, cp, factory) = makeOrchestrator(count: 3, queued: [])
    await orch.start()
    XCTAssertEqual(orch.state, .online, "zero runners is the NORMAL armed state")
    XCTAssertTrue(orch.runners.isEmpty)
    XCTAssertEqual(cp.jitCount, 0)
    XCTAssertTrue(factory.made.isEmpty)
    await orch.stop()
  }

  func testDemandIsCappedByMaxRunners() async {
    let (orch, _, _) = makeOrchestrator(
      count: 2, queued: Array(repeating: ["self-hosted"], count: 5))
    await orch.start()
    XCTAssertEqual(orch.runners.count, 2)
    await orch.stop()
  }

  /// GitHub's routing rule: every job label must be present on the runner
  /// (cumulative, case-insensitive); extra runner labels are fine.
  func testJobLabelsMustBeSubsetOfComboLabels() async {
    let (orch, _, _) = makeOrchestrator(
      count: 3, labels: ["self-hosted", "Windows", "mactions"],
      queued: [
        ["self-hosted", "windows"],  // subset, case-insensitive → match
        ["self-hosted", "windows", "gpu"],  // needs a label we don't carry → no
        ["ubuntu-latest"],  // hosted-runner job → no
      ])
    await orch.start()
    XCTAssertEqual(orch.runners.count, 1)
    await orch.stop()
  }

  func testEphemeralExitRecyclesWhileDemandRemains() async {
    let (orch, _, factory) = makeOrchestrator(count: 2)  // 2 queued jobs seeded
    await orch.start()
    XCTAssertEqual(orch.runners.count, 2)

    // One runner finishes its single job and exits; the queue still shows
    // demand (the fake keeps 2 queued), so the fleet replenishes.
    factory.made.first?.fireExit(0)
    await settle()

    XCTAssertEqual(orch.runners.count, 2)
    XCTAssertEqual(factory.made.count, 3)
    XCTAssertEqual(orch.state, .online)
  }

  /// THE scale-from-zero payoff: a runner whose job was the last one queued is
  /// NOT replaced — the fleet returns to zero instead of keeping warm spares.
  func testExitWithEmptyQueueIsNotReplaced() async {
    let (orch, cp, factory) = makeOrchestrator(count: 2, queued: [["self-hosted"]])
    let collector = RecordCollector()
    orch.onRunFinished = { collector.records.append($0) }
    await orch.start()
    XCTAssertEqual(orch.runners.count, 1)

    cp.queuedJobs = []  // its job is the one it just ran
    factory.made.first?.fireExit(0)
    await settle()

    XCTAssertEqual(collector.records.count, 1, "the run itself still records")
    XCTAssertTrue(orch.runners.isEmpty, "…but nothing replaces it")
    XCTAssertEqual(cp.jitCount, 1)
    await orch.stop()
  }

  /// Busy runners can't take new work, so target = busy + queued (capped).
  func testBusyRunnerPlusQueuedJobScalesUp() async {
    let (orch, cp, _) = makeOrchestrator(
      count: 2, queued: [["self-hosted"]], reconcileInterval: 50_000_000,
      idleJITRefreshInterval: nil)
    await orch.start()
    XCTAssertEqual(orch.runners.count, 1)
    let runner = try! XCTUnwrap(orch.runners.first)

    // The runner picks its job up (busy on GitHub) and a NEW job queues.
    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: true)
    ]
    cp.queuedJobs = [["self-hosted"]]
    await waitUntil { orch.runners.count == 2 }

    XCTAssertEqual(orch.runners.count, 2)
    XCTAssertEqual(cp.jitCount, 2)
    await orch.stop()
  }

  // MARK: Scale-down (trim)

  /// A provisioned runner whose queued job vanished (taken by another runner,
  /// or cancelled) is trimmed back to zero: deregistered FIRST, then stopped —
  /// and the trim is fleet maintenance, never a recorded run.
  func testQueueEmptyingTrimsIdleRunnerToZero() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 2, queued: [["self-hosted"]], reconcileInterval: 50_000_000,
      idleJITRefreshInterval: nil, idleTrimGraceInterval: 0)
    let collector = RecordCollector()
    orch.onRunFinished = { collector.records.append($0) }
    await orch.start()
    let runner = try! XCTUnwrap(orch.runners.first)

    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]
    cp.queuedJobs = []  // the job vanished
    await waitUntil { orch.runners.isEmpty }

    XCTAssertTrue(orch.runners.isEmpty)
    XCTAssertTrue(factory.made[0].stopped)
    XCTAssertTrue(cp.deleted.contains(runner.remoteId!))
    // The SIGTERM'd agent's terminationHandler still fires onExit.
    factory.made[0].fireExit(143)
    await settle()
    XCTAssertTrue(collector.records.isEmpty, "a trim is maintenance, not a run")
    XCTAssertEqual(cp.jitCount, 1, "must not re-provision against an empty queue")
    await orch.stop()
  }

  /// deleteRunner throwing == GitHub's 422 for a busy runner: the runner won a
  /// job between our snapshot and the trim. Server-side protection — keep it.
  func testTrimKeepsRunnerWhoseDeleteFails() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 1, queued: [["self-hosted"]], reconcileInterval: 50_000_000,
      idleJITRefreshInterval: nil, idleTrimGraceInterval: 0)
    await orch.start()
    let runner = try! XCTUnwrap(orch.runners.first)

    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]
    cp.failDeletes = [runner.remoteId!]
    cp.queuedJobs = []
    try? await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertEqual(orch.runners.count, 1)
    XCTAssertFalse(factory.made[0].stopped)
    await orch.stop()
  }

  /// A busy runner is never a trim candidate, even with an empty queue.
  func testTrimNeverTouchesBusyRunner() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 1, queued: [["self-hosted"]], reconcileInterval: 50_000_000,
      idleJITRefreshInterval: nil, idleTrimGraceInterval: 0)
    await orch.start()
    let runner = try! XCTUnwrap(orch.runners.first)

    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: true)
    ]
    cp.queuedJobs = []  // mid-job: queue empty but the runner is working
    try? await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertEqual(orch.runners.count, 1)
    XCTAssertFalse(factory.made[0].stopped)
    XCTAssertTrue(cp.deleted.isEmpty)
    await orch.stop()
  }

  /// listRunners failing must never trim (busy-ness unknown), but real queued
  /// demand still scales UP — assuming every current slot is busy (target =
  /// slots + demand, clamped): persistent demand alongside genuinely idle
  /// runners doesn't happen, so queued jobs need new runners.
  func testListRunnersFailureScalesUpAssumingBusyAndNeverTrims() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 2, queued: [["self-hosted"]], reconcileInterval: 50_000_000,
      idleJITRefreshInterval: nil, idleTrimGraceInterval: 0)
    await orch.start()
    XCTAssertEqual(orch.runners.count, 1)
    let runner = try! XCTUnwrap(orch.runners.first)

    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]
    cp.failListRunners = true
    // One job persists in the queue: with busy unknown, the existing slot is
    // assumed busy → scale up to slots(1) + demand(1) = 2, clamped at cap 2.
    await waitUntil { orch.runners.count == 2 }

    XCTAssertEqual(orch.runners.count, 2, "scale-up must not stall on a runners-list failure")
    XCTAssertTrue(cp.deleted.isEmpty, "never trim blind")
    XCTAssertFalse(factory.made[0].stopped)
    await orch.stop()
  }

  /// The two-snapshot rule is TIME-based: with a confirmation window the test
  /// never satisfies, a surplus-idle runner is marked but never deleted, no
  /// matter how many reconcile passes (incl. exit-triggered ones) elapse.
  func testTrimWaitsOutTheConfirmationWindow() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 2, queued: [["self-hosted"]], reconcileInterval: 40_000_000,
      idleJITRefreshInterval: nil, idleTrimGraceInterval: 0,
      trimConfirmInterval: 10)  // never elapses within this test
    await orch.start()
    let runner = try! XCTUnwrap(orch.runners.first)

    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]
    cp.queuedJobs = []
    try? await Task.sleep(nanoseconds: 300_000_000)  // many passes

    XCTAssertEqual(orch.runners.count, 1, "marked, but the window never elapsed")
    XCTAssertTrue(cp.deleted.isEmpty)
    XCTAssertFalse(factory.made[0].stopped)
    await orch.stop()
  }

  /// Demand returning mid-window unmarks the slot — the confirmation clock
  /// restarts from zero when the queue empties again.
  func testRestoredDemandRestartsTrimConfirmationClock() async {
    let (orch, cp, _) = makeOrchestrator(
      count: 2, queued: [["self-hosted"]], reconcileInterval: 40_000_000,
      idleJITRefreshInterval: nil, idleTrimGraceInterval: 0,
      trimConfirmInterval: 0.3)
    await orch.start()
    let runner = try! XCTUnwrap(orch.runners.first)
    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]

    cp.queuedJobs = []  // mark
    try? await Task.sleep(nanoseconds: 100_000_000)
    cp.queuedJobs = [["self-hosted"]]  // demand back → unmark
    try? await Task.sleep(nanoseconds: 100_000_000)
    cp.queuedJobs = []  // re-mark: clock restarts here
    try? await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertTrue(
      cp.deleted.isEmpty,
      "only ~150ms since the RE-mark — the original mark must not carry over")

    try? await Task.sleep(nanoseconds: 350_000_000)  // now past the 300ms window
    XCTAssertTrue(cp.deleted.contains(runner.remoteId!))
    XCTAssertTrue(orch.runners.isEmpty)
    await orch.stop()
  }

  /// An exit landing while the trim's deregister call is in flight must not
  /// record a phantom failed run — `reaped` is set BEFORE the delete await.
  func testExitDuringTrimDeleteIsNotRecorded() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 2, queued: [["self-hosted"]], reconcileInterval: 40_000_000,
      idleJITRefreshInterval: nil, idleTrimGraceInterval: 0)
    let collector = RecordCollector()
    orch.onRunFinished = { collector.records.append($0) }
    await orch.start()
    let runner = try! XCTUnwrap(orch.runners.first)
    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]
    cp.deleteDelayNanos = 300_000_000
    cp.queuedJobs = []

    // Wait until the trim is INSIDE the slow deleteRunner call…
    for _ in 0..<100 where cp.deleteAttempts.isEmpty {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertFalse(cp.deleteAttempts.isEmpty, "trim never reached the delete")
    // …then the SIGTERM'd agent's terminationHandler fires mid-await.
    factory.made[0].fireExit(143)
    try? await Task.sleep(nanoseconds: 400_000_000)

    XCTAssertTrue(collector.records.isEmpty, "a trim reap mid-delete is not a run")
    XCTAssertTrue(orch.runners.isEmpty)
    await orch.stop()
  }

  /// The COMMON dead-daemon shape: the agent dies ms AFTER launch (post-append).
  /// That must be a LAUNCH failure — no phantom failed run, no hot mint→die
  /// loop (the periodic tick paces the retry), registration cleaned up.
  func testAsyncLaunchDeathDoesNotRecordOrHotLoop() async {
    let cp = FakeControlPlane()
    cp.queuedJobs = [["self-hosted"]]
    let budget = HostBudget(limits: [.macOS: 1])
    let config = FleetConfig(owner: "o", repo: "r", labels: ["self-hosted"], maxRunners: 1)
    let orch = RunnerOrchestrator(
      controlPlane: cp, factory: DelayedExitFactory(delay: 0.03), config: config,
      budget: budget, machinePrefix: "mactions-testmac",
      reconcileInterval: 10_000_000_000,  // no tick retry inside this test
      launchFailureGraceInterval: 30)
    let collector = RecordCollector()
    orch.onRunFinished = { collector.records.append($0) }
    await orch.start()
    await waitUntil { orch.runners.isEmpty && cp.deleted.contains(1) }

    XCTAssertTrue(collector.records.isEmpty, "a launch death is not a run")
    XCTAssertEqual(cp.jitCount, 1, "no hot-loop replacement before the next tick")
    XCTAssertTrue(orch.runners.isEmpty)
    XCTAssertEqual(budget.inUse(.macOS), 0)
    XCTAssertTrue(cp.deleted.contains(1), "the never-connected registration is cleaned up")
    await orch.stop()
  }

  /// The reconcile loop's pace flag: idle-at-zero only when BOTH the queue and
  /// the fleet are empty; a failed poll keeps the previous pace.
  func testIdlePaceFlagTracksDemandAndHoldsOnFailedPoll() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 1, queued: [], reconcileInterval: 40_000_000, idleJITRefreshInterval: nil)
    await orch.start()
    XCTAssertTrue(orch.idleAtZero, "empty queue + zero runners = idle pace")

    cp.queuedJobs = [["self-hosted"]]
    await waitUntil { !orch.idleAtZero }
    XCTAssertFalse(orch.idleAtZero, "demand flips to the active pace")

    cp.failQueuedPoll = true
    cp.queuedJobs = []
    try? await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertFalse(orch.idleAtZero, "a failed poll must keep the previous pace")

    cp.failQueuedPoll = false
    factory.made.last?.fireExit(0)
    await waitUntil { orch.idleAtZero }
    XCTAssertTrue(orch.idleAtZero, "back to zero + empty queue = idle pace")
    await orch.stop()
  }

  /// A transient queue-poll failure must HOLD the fleet — never read a flaky
  /// API call as "queue is empty" and reap a runner about to be assigned work.
  func testFailedQueuePollHoldsFleet() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 1, queued: [["self-hosted"]], reconcileInterval: 50_000_000,
      idleJITRefreshInterval: nil, idleTrimGraceInterval: 0)
    await orch.start()
    let runner = try! XCTUnwrap(orch.runners.first)

    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]
    cp.failQueuedPoll = true
    try? await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertEqual(orch.runners.count, 1)
    XCTAssertFalse(factory.made[0].stopped)
    XCTAssertTrue(cp.deleted.isEmpty)
    await orch.stop()
  }

  // MARK: Shared host budget

  /// An agent that dies the instant it launches (the dead-container-daemon
  /// mode: `run` fails async, not at start()) fires onExit BEFORE provisionOne
  /// records the slot. The stillborn slot must be discarded — not appended as
  /// a zombie that reads as a live runner and pins a budget unit for the
  /// 5-minute unhealth grace.
  func testAgentDyingDuringLaunchLeavesNoZombieSlotAndNoBudgetLeak() async {
    let cp = FakeControlPlane()
    cp.queuedJobs = [["self-hosted"]]
    let budget = HostBudget(limits: [.macOS: 1])
    let config = FleetConfig(owner: "o", repo: "r", labels: ["self-hosted"], maxRunners: 1)
    let orch = RunnerOrchestrator(
      controlPlane: cp, factory: InstantExitFactory(), config: config, budget: budget,
      machinePrefix: "mactions-testmac")
    await orch.start()
    await settle()

    XCTAssertTrue(orch.runners.isEmpty, "a dead-on-arrival agent must not occupy a slot")
    XCTAssertEqual(budget.inUse(.macOS), 0, "its budget unit must be refunded")
    await orch.stop()
  }

  /// A budget-denied provision must SAY so (DemandSnapshot.waitingForCapacity)
  /// — "N queued · starting…" would be a lie — and the flag must clear when
  /// demand drains.
  func testBudgetDenialSurfacesWaitingForCapacity() async {
    let budget = HostBudget(limits: [.macOS: 1])
    let (orch, cp, _) = makeOrchestrator(
      count: 5, queued: Array(repeating: ["self-hosted"], count: 2), budget: budget,
      reconcileInterval: 50_000_000, idleJITRefreshInterval: nil)
    await orch.start()
    XCTAssertEqual(orch.runners.count, 1)
    XCTAssertTrue(orch.demand.waitingForCapacity, "the second job's provision was denied")

    cp.queuedJobs = []  // demand drains → nothing is waiting any more
    await waitUntil { !orch.demand.waitingForCapacity }
    XCTAssertFalse(orch.demand.waitingForCapacity)
    await orch.stop()
  }

  /// Two consecutive launch deaths flip `launchFailing` (the badge's "runner
  /// failing to launch"); a runner reaching GitHub clears it.
  func testRepeatedLaunchDeathsFlipLaunchFailing() async {
    let cp = FakeControlPlane()
    cp.queuedJobs = [["self-hosted"]]
    let config = FleetConfig(owner: "o", repo: "r", labels: ["self-hosted"], maxRunners: 1)
    let orch = RunnerOrchestrator(
      controlPlane: cp, factory: DelayedExitFactory(delay: 0.02), config: config,
      machinePrefix: "mactions-testmac",
      reconcileInterval: 60_000_000, idleReconcileInterval: 60_000_000,
      launchFailureGraceInterval: 30)
    let collector = RecordCollector()
    orch.onRunFinished = { collector.records.append($0) }
    await orch.start()
    XCTAssertFalse(orch.launchFailing, "one death isn't a pattern yet")
    await waitUntil { orch.launchFailing }

    XCTAssertTrue(orch.launchFailing)
    XCTAssertNotNil(orch.lastError)
    XCTAssertTrue(collector.records.isEmpty, "launch deaths never flood history")
    await orch.stop()
  }

  /// The teardown's budget release must NOT route through the orchestrator: a
  /// discovery-reaped combo can deallocate while a wedged VM teardown is still
  /// in flight, and the SHARED budget unit must still come back — otherwise
  /// every future provision of that OS is silently denied all session.
  func testBudgetReleasedAfterTeardownEvenIfOrchestratorIsGone() async {
    let budget = HostBudget(limits: [.macOS: 1])
    let cp = FakeControlPlane()
    cp.queuedJobs = [["self-hosted"]]
    let factory = GatedStopFactory()
    let config = FleetConfig(owner: "o", repo: "r", labels: ["self-hosted"], maxRunners: 1)
    var orch: RunnerOrchestrator? = RunnerOrchestrator(
      controlPlane: cp, factory: factory, config: config, budget: budget,
      machinePrefix: "mactions-testmac",
      reconcileInterval: 40_000_000, idleReconcileInterval: 40_000_000,
      idleJITRefreshInterval: nil, idleTrimGraceInterval: 0, trimConfirmInterval: 0.01)
    await orch!.start()
    let runner = try! XCTUnwrap(orch!.runners.first)
    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]
    cp.queuedJobs = []  // job vanished → trim begins; provider.stop blocks

    for _ in 0..<100 where cp.deleted.isEmpty {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertFalse(cp.deleted.isEmpty, "the trim never deregistered the runner")
    XCTAssertEqual(budget.inUse(.macOS), 1, "unit held until the substrate is actually gone")

    // The discovery reap drops the orchestrator's last strong ref mid-teardown…
    orch = nil
    // …and only then does the wedged stop() return.
    factory.made.first?.allowStop()
    try? await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(
      budget.inUse(.macOS), 0,
      "the SHARED budget must be refunded even though its orchestrator is gone")
  }

  func testSharedBudgetCapsProvisioningAndRefundsOnExit() async {
    let budget = HostBudget(limits: [.macOS: 1])
    let (orch, _, factory) = makeOrchestrator(
      count: 5, queued: Array(repeating: ["self-hosted"], count: 3), budget: budget)
    await orch.start()
    XCTAssertEqual(orch.runners.count, 1, "budget of 1 beats demand of 3")
    XCTAssertEqual(budget.inUse(.macOS), 1)

    factory.made[0].fireExit(0)
    await settle()
    XCTAssertEqual(orch.runners.count, 1, "freed unit re-spent on remaining demand")
    XCTAssertEqual(budget.inUse(.macOS), 1)

    await orch.stop()
    XCTAssertEqual(budget.inUse(.macOS), 0, "teardown refunds every held unit")
  }

  // MARK: Prune / refresh (unchanged maintenance semantics)

  func testReconcileReplacesRunnerMissingFromGitHubAfterGrace() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 1, reconcileInterval: 100_000_000, remoteRegistrationGraceInterval: 0,
      idleJITRefreshInterval: nil)
    await orch.start()
    XCTAssertEqual(cp.jitCount, 1)
    let runner = try! XCTUnwrap(orch.runners.first)

    await waitUntil {
      cp.jitCount >= 2 && factory.made[0].stopped && cp.deleted.contains(runner.remoteId!)
        && orch.runners.count == 1 && orch.runners.first?.id != runner.id
    }

    XCTAssertGreaterThanOrEqual(cp.jitCount, 2)
    XCTAssertTrue(factory.made[0].stopped)
    XCTAssertTrue(cp.deleted.contains(runner.remoteId!))
    XCTAssertEqual(orch.runners.count, 1)
    XCTAssertNotEqual(orch.runners.first?.id, runner.id)
    await orch.stop()
  }

  /// A prune/refresh reap must NOT land in run history. The Local/Linux
  /// providers' stop() SIGTERMs the agent, whose terminationHandler still fires
  /// onExit — before the `reaped` flag, every routine idle refresh was recorded
  /// as a `failed` run (exit 143/15), flooding history with phantom failures
  /// (observed live 2026-06-09). The reap must still replace the runner while
  /// its queued job waits; only the RECORD is suppressed.
  func testIdleRefreshReapIsNotRecordedAsAFailedRun() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 1, reconcileInterval: 50_000_000, remoteRegistrationGraceInterval: 0,
      idleJITRefreshInterval: 0)
    let collector = RecordCollector()
    orch.onRunFinished = { collector.records.append($0) }
    await orch.start()
    let runner = try! XCTUnwrap(orch.runners.first)

    // Online + idle → the zero-interval refresh reaps it on the next tick
    // (the seeded queued job keeps demand at 1, so it's replaced, not trimmed).
    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]
    await waitUntil {
      cp.jitCount >= 2 && factory.made[0].stopped && orch.runners.count == 1
        && orch.runners.first?.id != runner.id
    }
    XCTAssertTrue(factory.made[0].stopped)
    // The SIGTERM'd agent's terminationHandler fires onExit — like
    // LocalProcessProvider/LinuxContainerProvider after a real stop().
    factory.made[0].fireExit(143)
    await settle()

    XCTAssertTrue(
      collector.records.isEmpty,
      "a refresh reap is fleet maintenance, not a run — got \(collector.records)")
    XCTAssertGreaterThanOrEqual(cp.jitCount, 2, "the reaped runner must still be replaced")

    // A NATURAL exit (the orchestrator didn't initiate it) still records.
    cp.remote = []
    if let fresh = factory.made.last, fresh !== factory.made[0] { fresh.fireExit(0) }
    await settle()
    XCTAssertEqual(collector.records.count, 1)
    XCTAssertEqual(collector.records.first?.outcome, .completed)
    await orch.stop()
  }

  func testReconcileKeepsBusyRunnerPastIdleRefreshWindow() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 1, reconcileInterval: 100_000_000, remoteRegistrationGraceInterval: 0,
      idleJITRefreshInterval: 0)
    await orch.start()
    let runner = try! XCTUnwrap(orch.runners.first)
    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: true)
    ]
    cp.queuedJobs = []  // it took the job; nothing else queued

    try? await Task.sleep(nanoseconds: 220_000_000)

    XCTAssertEqual(cp.jitCount, 1)
    XCTAssertFalse(factory.made[0].stopped)
    XCTAssertEqual(orch.runners.first?.id, runner.id)
    await orch.stop()
  }

  /// A TRANSIENT offline blip must NOT prune a runner — only SUSTAINED unhealth
  /// (≥ grace) does. Grace is 10 s while the whole test runs in ~250 ms, so the
  /// runner is never offline long enough to be reaped even though it blips offline
  /// for a tick. This is the guard that stops a mid-job runner being torn down on
  /// a momentary GitHub eventual-consistency hiccup (which would orphan the job).
  func testReconcileToleratesTransientOfflineBlipWithinGrace() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 1, reconcileInterval: 40_000_000, remoteRegistrationGraceInterval: 10,
      idleJITRefreshInterval: nil)
    await orch.start()
    let runner = try! XCTUnwrap(orch.runners.first)

    // Blip offline briefly…
    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "offline", busy: false)
    ]
    try? await Task.sleep(nanoseconds: 120_000_000)
    // …then recover, well within the 10 s grace.
    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]
    try? await Task.sleep(nanoseconds: 120_000_000)

    XCTAssertEqual(cp.jitCount, 1)
    XCTAssertFalse(factory.made[0].stopped)
    XCTAssertEqual(orch.runners.first?.id, runner.id)
    await orch.stop()
  }

  /// The flip side: a runner OFFLINE for the whole grace window is a dead agent —
  /// even if GitHub still flags it `busy` (the offline-but-busy "ghost" a
  /// sleep/crash/force-quit leaves, which used to sit forever holding a stuck
  /// job). It must be reaped, DEREGISTERED, and replaced — not protected. Grace 0
  /// → reaped on the first sustained-unhealthy tick.
  func testReconcileReapsSustainedOfflineBusyGhost() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 1, reconcileInterval: 50_000_000, remoteRegistrationGraceInterval: 0,
      idleJITRefreshInterval: nil)
    await orch.start()
    let runner = try! XCTUnwrap(orch.runners.first)

    // offline + busy == the orphan signature (agent died mid-job).
    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "offline", busy: true)
    ]
    await waitUntil {
      cp.jitCount >= 2 && factory.made[0].stopped && cp.deleted.contains(runner.remoteId!)
        && orch.runners.count == 1 && orch.runners.first?.id != runner.id
    }

    XCTAssertTrue(factory.made[0].stopped)
    XCTAssertTrue(cp.deleted.contains(runner.remoteId!))
    XCTAssertGreaterThanOrEqual(cp.jitCount, 2)
    await orch.stop()
  }

  func testReconcileRefreshesIdleOnlineRunnerBeforeJITExpires() async {
    let (orch, cp, factory) = makeOrchestrator(
      count: 1, reconcileInterval: 100_000_000, remoteRegistrationGraceInterval: 0,
      idleJITRefreshInterval: 0)
    await orch.start()
    let runner = try! XCTUnwrap(orch.runners.first)
    cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]

    await waitUntil {
      cp.jitCount >= 2 && factory.made[0].stopped && cp.deleted.contains(runner.remoteId!)
        && orch.runners.count == 1 && orch.runners.first?.id != runner.id
    }

    XCTAssertGreaterThanOrEqual(cp.jitCount, 2)
    XCTAssertTrue(factory.made[0].stopped)
    XCTAssertTrue(cp.deleted.contains(runner.remoteId!))
    XCTAssertEqual(orch.runners.count, 1)
    XCTAssertNotEqual(orch.runners.first?.id, runner.id)
    await orch.stop()
  }

  // MARK: Teardown

  /// stop() deregisters exactly the runners THIS orchestrator owns — never a
  /// machine-prefix sweep. Sibling combos share the machine prefix and (under
  /// all-repos discovery) keep running while one combo stops: a prefix sweep
  /// here would deregister a sibling's live runner out from under it.
  func testStopDeregistersOnlyItsOwnRunners() async {
    let (orch, cp, factory) = makeOrchestrator(count: 2)
    cp.remote = [
      // SAME machine prefix, same repo — a sibling combo's runner. Must survive.
      RemoteRunner(id: 99, name: "mactions-testmac-sibling", status: "online", busy: false),
      RemoteRunner(id: 11, name: "someone-elses-runner", status: "online", busy: false),
    ]
    await orch.start()
    let ownIds = Set(orch.runners.compactMap(\.remoteId))
    XCTAssertEqual(ownIds.count, 2)
    await orch.stop()

    XCTAssertEqual(orch.state, .offline)
    XCTAssertTrue(orch.runners.isEmpty)
    XCTAssertTrue(factory.made.allSatisfy { $0.stopped })
    XCTAssertEqual(Set(cp.deleted), ownIds, "own slots deregistered, nothing else")
    XCTAssertFalse(cp.deleted.contains(99), "the sibling combo's runner must survive")
  }

  /// Exact-prefix teardown deletes only runners under THIS machine's prefix
  /// (regardless of status), leaving strangers and other Macs alone.
  func testDeregisterOrphanRunnersScopesToPrefix() async {
    let cp = FakeControlPlane()
    cp.remote = [
      RemoteRunner(id: 1, name: "mactions-testmac-aaa", status: "offline", busy: false),
      RemoteRunner(id: 2, name: "mactions-testmac-bbb", status: "online", busy: false),
      RemoteRunner(id: 3, name: "mactions-othermac-ccc", status: "offline", busy: false),
      RemoteRunner(id: 4, name: "someone-else", status: "offline", busy: false),
    ]
    await deregisterOrphanRunners(cp, prefix: "mactions-testmac")
    XCTAssertEqual(Set(cp.deleted), [1, 2])
  }

  func testDeregisterOrphanRunnersCanSweepOfflineMactionsGhosts() async {
    let cp = FakeControlPlane()
    cp.remote = [
      RemoteRunner(id: 1, name: "mactions-testmac-aaa", status: "offline", busy: false),
      RemoteRunner(id: 2, name: "mactions-othermac-offline", status: "offline", busy: false),
      RemoteRunner(id: 3, name: "mactions-othermac-online", status: "online", busy: false),
      RemoteRunner(id: 4, name: "mactions-othermac-busy", status: "offline", busy: true),
      RemoteRunner(id: 5, name: "someone-else", status: "offline", busy: false),
    ]
    await deregisterOrphanRunners(
      cp, prefix: "mactions-testmac", includeOfflineMactionsRunners: true)
    XCTAssertEqual(Set(cp.deleted), [1, 2])
  }

  // MARK: Run history

  func testCleanExitWhileOnlineRecordsCompleted() async {
    let (orch, _, factory) = makeOrchestrator(count: 1)
    let collector = RecordCollector()
    orch.onRunFinished = { collector.records.append($0) }
    await orch.start()
    factory.made.first?.fireExit(0)  // ran its one job, exited cleanly
    await settle()

    XCTAssertEqual(collector.records.count, 1)
    let rec = collector.records[0]
    XCTAssertEqual(rec.outcome, .completed)
    XCTAssertEqual(rec.repo, "o/r")
    XCTAssertEqual(rec.exitStatus, 0)
    XCTAssertEqual(rec.os, .macOS)  // default descriptor
    XCTAssertFalse(rec.id.isEmpty)
  }

  func testNonZeroExitWhileOnlineRecordsFailed() async {
    let (orch, _, factory) = makeOrchestrator(count: 1)
    let collector = RecordCollector()
    orch.onRunFinished = { collector.records.append($0) }
    await orch.start()
    factory.made.first?.fireExit(1)
    await settle()

    XCTAssertEqual(collector.records.last?.outcome, .failed)
    XCTAssertEqual(collector.records.last?.exitStatus, 1)
  }

  func testExitAfterTeardownIsNotRecorded() async {
    let (orch, _, factory) = makeOrchestrator(count: 1)
    let collector = RecordCollector()
    orch.onRunFinished = { collector.records.append($0) }
    await orch.start()
    let provider = factory.made.first
    await orch.stop()  // user went offline: state -> .offline, epoch bumped
    // A late exit arriving after teardown is a reap, not a real run — and in the
    // app the orchestrator is dropped right after stop(), so this async callback
    // would no-op via [weak self] anyway. Either way: nothing recorded.
    provider?.fireExit(0)
    await settle()

    XCTAssertTrue(collector.records.isEmpty)
  }

  func testWindowsDescriptorStampsRecordOS() async {
    let cp = FakeControlPlane()
    cp.queuedJobs = [["self-hosted"]]
    let factory = FakeFactory()
    let config = FleetConfig(owner: "o", repo: "r", labels: ["self-hosted"], maxRunners: 1)
    let orch = RunnerOrchestrator(
      controlPlane: cp, factory: factory, config: config, os: .windows,
      machinePrefix: "mactions-testmac")
    let collector = RecordCollector()
    orch.onRunFinished = { collector.records.append($0) }
    await orch.start()
    factory.made.first?.fireExit(0)
    await settle()

    XCTAssertEqual(collector.records.last?.os, .windows)
  }
}
