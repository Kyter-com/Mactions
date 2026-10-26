import XCTest

@testable import MactionsCore

/// `stop(interruption:)`: a runner GitHub last reported busy has its job cut
/// off by the teardown, so it is recorded as an interrupted run with the
/// reason; idle runners and runners that already finished are not.
@MainActor
final class OrchestratorInterruptionTests: XCTestCase {
  private struct Fleet {
    let orch: RunnerOrchestrator
    let cp: FakeControlPlane
    let factory: FakeFactory
    let collector: RecordCollector
  }

  private func makeFleet(queued: Int) -> Fleet {
    let cp = FakeControlPlane()
    cp.queuedJobs = Array(repeating: ["self-hosted"], count: queued)
    let factory = FakeFactory()
    let config = FleetConfig(owner: "o", repo: "r", labels: ["self-hosted"], maxRunners: queued)
    let orch = RunnerOrchestrator(
      controlPlane: cp, factory: factory, config: config, os: .linux,
      machinePrefix: "mactions-testmac",
      reconcileInterval: 20_000_000, idleReconcileInterval: 20_000_000,
      idleJITRefreshInterval: nil, launchFailureGraceInterval: 0,
      neverConfirmedReapInterval: 3600)
    let collector = RecordCollector()
    orch.onRunFinished = { collector.records.append($0) }
    return Fleet(orch: orch, cp: cp, factory: factory, collector: collector)
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

  /// Let two more reconcile passes read GitHub's runner list.
  private func letTwoPassesRun(_ fleet: Fleet) async {
    let polls = fleet.cp.queuePollCount
    await waitFor { fleet.cp.queuePollCount >= polls + 2 }
  }

  /// Two runners up; GitHub reports the first one busy with a job.
  private func startTwoRunnersOneBusy() async -> (Fleet, ManagedRunner) {
    let fleet = makeFleet(queued: 2)
    await fleet.orch.start()
    XCTAssertEqual(fleet.orch.runners.count, 2)
    let busy = fleet.orch.runners[0]
    let idle = fleet.orch.runners[1]
    fleet.cp.remote = [
      RemoteRunner(id: busy.remoteId!, name: busy.id, status: "online", busy: true),
      RemoteRunner(id: idle.remoteId!, name: idle.id, status: "online", busy: false),
    ]
    fleet.cp.queuedJobs = [["self-hosted"]]  // one job taken, one still queued
    await letTwoPassesRun(fleet)
    return (fleet, busy)
  }

  func testStoppingRecordsTheBusyRunnerAsInterrupted() async {
    let (fleet, busy) = await startTwoRunnersOneBusy()
    await fleet.orch.stop(interruption: .sleep)
    XCTAssertEqual(fleet.collector.records.count, 1, "only the runner running a job is recorded")
    guard let record = fleet.collector.records.first else { return }
    XCTAssertEqual(record.id, busy.id)
    XCTAssertEqual(record.interruption, .sleep)
    XCTAssertEqual(record.outcome, .failed)
    XCTAssertNil(record.exitStatus)
    XCTAssertEqual(record.remoteId, busy.remoteId)
    XCTAssertEqual(record.repo, "o/r")
    XCTAssertEqual(record.os, .linux)
    XCTAssertEqual(record.startedAt, busy.startedAt)
  }

  func testTheDefaultReasonIsGoingOffline() async {
    let (fleet, _) = await startTwoRunnersOneBusy()
    await fleet.orch.stop()
    XCTAssertEqual(fleet.collector.records.map(\.interruption), [.offline])
  }

  func testNothingIsRecordedWhenNoRunnerIsBusy() async {
    let fleet = makeFleet(queued: 1)
    await fleet.orch.start()
    let runner = fleet.orch.runners[0]
    fleet.cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]
    await letTwoPassesRun(fleet)
    await fleet.orch.stop(interruption: .sleep)
    XCTAssertTrue(fleet.collector.records.isEmpty)
  }

  /// The 18:45 case: the runner took its job after the last runner-list read,
  /// so only GitHub refusing to delete it as busy says the job is cut off.
  func testARunnerGitHubRefusesToDeleteAsBusyIsRecorded() async {
    let fleet = makeFleet(queued: 1)
    await fleet.orch.start()
    let runner = fleet.orch.runners[0]
    fleet.cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]
    await letTwoPassesRun(fleet)
    fleet.cp.busyDeletes = [runner.remoteId!]  // picked up a job since that read
    await fleet.orch.stop(interruption: .sleep)
    XCTAssertEqual(fleet.collector.records.map(\.id), [runner.id])
    XCTAssertEqual(fleet.collector.records.map(\.interruption), [.sleep])
  }

  func testADeleteThatFailsForAnotherReasonRecordsNothing() async {
    // No answer from GitHub (the network dropped) says nothing about a job.
    let fleet = makeFleet(queued: 1)
    await fleet.orch.start()
    let runner = fleet.orch.runners[0]
    fleet.cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: false)
    ]
    await letTwoPassesRun(fleet)
    fleet.cp.failDeletes = [runner.remoteId!]
    await fleet.orch.stop(interruption: .sleep)
    XCTAssertTrue(fleet.collector.records.isEmpty)
  }

  func testARunnerBusyByBothSignalsIsRecordedOnce() async {
    let (fleet, busy) = await startTwoRunnersOneBusy()
    fleet.cp.busyDeletes = [busy.remoteId!]
    await fleet.orch.stop(interruption: .quit)
    XCTAssertEqual(fleet.collector.records.map(\.id), [busy.id])
    XCTAssertEqual(fleet.collector.records.map(\.interruption), [.quit])
  }

  func testOnlyA422IsABusyRefusal() {
    XCTAssertTrue(isBusyRunnerRefusal(GitHubClient.ClientError.http(422, "busy")))
    XCTAssertFalse(isBusyRunnerRefusal(GitHubClient.ClientError.http(404, "gone")))
    XCTAssertFalse(isBusyRunnerRefusal(GitHubClient.ClientError.http(500, "")))
    XCTAssertFalse(isBusyRunnerRefusal(URLError(.notConnectedToInternet)))
  }

  func testARunnerThatFinishedBeforeTheStopIsNotRecordedAgain() async {
    let fleet = makeFleet(queued: 1)
    await fleet.orch.start()
    let runner = fleet.orch.runners[0]
    fleet.cp.remote = [
      RemoteRunner(id: runner.remoteId!, name: runner.id, status: "online", busy: true)
    ]
    await letTwoPassesRun(fleet)
    // The job finishes and the ephemeral runner exits on its own.
    fleet.cp.queuedJobs = []
    fleet.factory.made[0].fireExit(0)
    await waitFor { fleet.orch.runners.isEmpty }
    await fleet.orch.stop(interruption: .sleep)
    XCTAssertEqual(fleet.collector.records.map(\.outcome), [.completed])
    XCTAssertEqual(fleet.collector.records.map(\.interruption), [nil])
  }
}
