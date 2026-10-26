import XCTest

@testable import MactionsCore

/// The orchestrator's side of `LaunchGate`: launches are asked for, failures and
/// first-online runners are reported, a trial is one runner, and a pause is
/// visible in the demand snapshot. The runners here never reach GitHub because
/// the fake control plane never lists them online — the shape of the
/// 2026-10-24 relaunch loop (VM network down, host network up).
@MainActor
final class OrchestratorLaunchGateTests: XCTestCase {
  /// A gate whose pauses last the whole test unless a test shortens them.
  private func makeGate(initialBackoff: TimeInterval = 3600) -> LaunchGate {
    let policy = LaunchGate.Policy(
      initialBackoff: initialBackoff, maxBackoff: max(initialBackoff, 3600),
      outstandingTimeout: 3600)
    return LaunchGate(policies: [.macOS: policy, .linux: policy, .windows: policy])
  }

  private func makeOrchestrator(
    gate: LaunchGate?,
    os: RunnerOS = .macOS,
    queued: Int = 1,
    maxRunners: Int = 1,
    budget: HostBudget? = nil,
    factory: RunnerProviderFactory = FakeFactory(),
    neverConfirmedReapInterval: TimeInterval = 0
  ) -> (RunnerOrchestrator, FakeControlPlane) {
    let cp = FakeControlPlane()
    cp.queuedJobs = Array(repeating: ["self-hosted"], count: queued)
    let config = FleetConfig(owner: "o", repo: "r", labels: ["self-hosted"], maxRunners: maxRunners)
    let orch = RunnerOrchestrator(
      controlPlane: cp, factory: factory, config: config, os: os, budget: budget,
      launchGate: gate, machinePrefix: "mactions-testmac",
      reconcileInterval: 30_000_000, idleReconcileInterval: 30_000_000,
      idleJITRefreshInterval: nil, launchFailureGraceInterval: 30,
      neverConfirmedReapInterval: neverConfirmedReapInterval)
    return (orch, cp)
  }

  private func waitFor(
    timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() >= deadline { return XCTFail("condition never held", file: file, line: line) }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func elapse(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }

  // MARK: The relaunch loop

  func testWithoutAGateRunnersThatNeverReachGitHubAreRelaunchedForever() async {
    // The control: the same fleet with no gate keeps minting and launching.
    let (orch, cp) = makeOrchestrator(gate: nil)
    await orch.start()
    await waitFor { cp.jitCount >= 6 }
    await orch.stop()
  }

  func testTheGateStopsRunnersThatNeverReachGitHubFromBeingRelaunched() async {
    let gate = makeGate()
    let (orch, cp) = makeOrchestrator(gate: gate)
    await orch.start()
    await waitFor { gate.pause(for: .macOS) != nil }
    let minted = cp.jitCount
    XCTAssertEqual(minted, 2, "two never-online runners pause the OS")
    XCTAssertEqual(
      gate.pause(for: .macOS)?.reason,
      "macOS runners registered but never reached GitHub within 0s.")

    await elapse(0.4)  // ~13 reconcile ticks
    XCTAssertEqual(cp.jitCount, minted, "no runner is minted or launched while paused")
    XCTAssertTrue(orch.runners.isEmpty)
    XCTAssertTrue(orch.demand.launchPaused, "the queued job is waiting on the pause")
    XCTAssertEqual(orch.demand.queuedMatching, 1)
    await orch.stop()
  }

  func testAProviderThatCannotStartPausesTheOS() async {
    let gate = makeGate()
    let (orch, cp) = makeOrchestrator(gate: gate, factory: ThrowingStartFactory())
    await orch.start()
    await waitFor { gate.pause(for: .macOS) != nil }
    XCTAssertTrue(orch.launchFailing)
    XCTAssertTrue(gate.pause(for: .macOS)?.reason.hasPrefix("macOS runners couldn't start: ") == true)
    let minted = cp.jitCount
    await elapse(0.3)
    XCTAssertEqual(cp.jitCount, minted)
    await orch.stop()
  }

  func testAnAgentThatDiesAtLaunchPausesTheOS() async {
    let gate = makeGate()
    let (orch, cp) = makeOrchestrator(gate: gate, factory: InstantExitFactory())
    await orch.start()
    await waitFor { gate.pause(for: .macOS) != nil }
    XCTAssertTrue(orch.launchFailing)
    XCTAssertEqual(
      gate.pause(for: .macOS)?.reason, "macOS runners exited during launch (status 1).")
    let minted = cp.jitCount
    await elapse(0.3)
    XCTAssertEqual(cp.jitCount, minted)
    await orch.stop()
  }

  // MARK: Trials and resuming

  func testATrialIsOneRunnerAndItReachingGitHubResumesTheFleet() async {
    // 200 ms between trials; runners are reaped 300 ms after launch if GitHub
    // never lists them online.
    let gate = makeGate(initialBackoff: 0.2)
    let (orch, cp) = makeOrchestrator(
      gate: gate, queued: 3, maxRunners: 3, neverConfirmedReapInterval: 0.3)
    await orch.start()
    XCTAssertEqual(cp.jitCount, 3, "demand of 3 launches 3")
    await waitFor { gate.pause(for: .macOS) != nil }
    let beforeTrial = cp.jitCount

    // The trial: exactly ONE runner, although three jobs are queued.
    await waitFor { orch.runners.count == 1 && cp.jitCount == beforeTrial + 1 }
    let trial = orch.runners[0]
    await elapse(0.1)
    XCTAssertEqual(cp.jitCount, beforeTrial + 1, "one trial at a time")

    // It reaches GitHub: the pause lifts and the fleet scales to the demand.
    cp.remote = [RemoteRunner(id: trial.remoteId!, name: trial.id, status: "online", busy: false)]
    await waitFor { gate.pause(for: .macOS) == nil }
    await waitFor { orch.runners.count == 3 }
    XCTAssertEqual(cp.jitCount, beforeTrial + 3)
    XCTAssertFalse(orch.demand.launchPaused)
    await orch.stop()
  }

  func testATrialThatCannotGetCapacityIsHandedBack() async {
    let gate = makeGate(initialBackoff: 0)
    gate.recordLaunchFailure(.macOS, reason: "a")
    gate.recordLaunchFailure(.macOS, reason: "b")
    let budget = HostBudget(limits: [.macOS: 0])
    let (orch, cp) = makeOrchestrator(gate: gate, budget: budget)
    await orch.start()
    XCTAssertEqual(cp.jitCount, 0)
    XCTAssertTrue(orch.demand.waitingForCapacity)
    let pause = gate.pause(for: .macOS)
    XCTAssertEqual(pause?.checking, false, "the trial tested nothing, so it is not outstanding")
    XCTAssertEqual(gate.decision(for: .macOS), .trial, "and the next tick may try it again")
    await orch.stop()
  }

  func testResumingByHandLaunchesAgainAtOnce() async {
    let gate = makeGate()
    let (orch, cp) = makeOrchestrator(gate: gate, neverConfirmedReapInterval: 3600)
    gate.recordLaunchFailure(.macOS, reason: "a")
    gate.recordLaunchFailure(.macOS, reason: "b")
    gate.onResume = { _ in orch.nudge() }
    await orch.start()
    XCTAssertEqual(cp.jitCount, 0)
    XCTAssertTrue(orch.demand.launchPaused)

    gate.resumeNow(.macOS)
    await waitFor { orch.runners.count == 1 }
    XCTAssertFalse(orch.demand.launchPaused)
    await orch.stop()
  }

  func testAPauseThatLiftsElsewhereClearsLaunchPaused() async {
    // The combo's shortfall closes while jobs are still queued, so it never asks
    // the gate again: only the snapshot carry-over can drop the flag.
    let gate = makeGate()
    let (orch, cp) = makeOrchestrator(
      gate: gate, queued: 1, maxRunners: 2, neverConfirmedReapInterval: 3600)
    await orch.start()
    XCTAssertEqual(orch.runners.count, 1)
    gate.recordLaunchFailure(.macOS, reason: "a")
    gate.recordLaunchFailure(.macOS, reason: "b")
    cp.queuedJobs = [["self-hosted"], ["self-hosted"]]
    await waitFor { orch.demand.launchPaused }

    gate.recordLaunchSuccess(.macOS)  // another combo's runner reached GitHub
    cp.queuedJobs = [["self-hosted"]]  // one job left, and one runner already up
    await waitFor { !orch.demand.launchPaused }
    XCTAssertEqual(orch.demand.queuedMatching, 1)
    XCTAssertEqual(cp.jitCount, 1, "nothing new needed launching")
    await orch.stop()
  }

  // MARK: Host-wide, per OS

  func testAPauseIsSharedByEveryComboOfThatOSAndNoOther() async {
    let gate = makeGate()
    let (first, firstCP) = makeOrchestrator(gate: gate)
    await first.start()
    await waitFor { gate.pause(for: .macOS) != nil }
    await first.stop()
    XCTAssertEqual(firstCP.jitCount, 2)

    // A second repo's macOS fleet does not burn its own failures to learn it.
    let (second, secondCP) = makeOrchestrator(gate: gate, neverConfirmedReapInterval: 3600)
    await second.start()
    XCTAssertEqual(secondCP.jitCount, 0)
    XCTAssertTrue(second.demand.launchPaused)

    // A Linux fleet on the same gate launches normally.
    let (linux, linuxCP) = makeOrchestrator(
      gate: gate, os: .linux, neverConfirmedReapInterval: 3600)
    await linux.start()
    XCTAssertEqual(linuxCP.jitCount, 1)
    XCTAssertFalse(linux.demand.launchPaused)
    await second.stop()
    await linux.stop()
  }

  func testALongLivedRunnerStayingOnlineDoesNotLiftAPause() async {
    // A runner that reached GitHub BEFORE the network broke says nothing about
    // whether a new one can: only a runner's first sighting online counts.
    let gate = makeGate()
    let (orch, cp) = makeOrchestrator(
      gate: gate, queued: 1, maxRunners: 2, neverConfirmedReapInterval: 3600)
    await orch.start()
    let first = try! XCTUnwrap(orch.runners.first)
    cp.remote = [RemoteRunner(id: first.remoteId!, name: first.id, status: "online", busy: true)]
    await elapse(0.1)  // seen online once

    gate.recordLaunchFailure(.macOS, reason: "a")
    gate.recordLaunchFailure(.macOS, reason: "b")
    await elapse(0.2)  // several ticks with the busy runner still online
    XCTAssertNotNil(gate.pause(for: .macOS))
    await orch.stop()
  }
}
