import XCTest

@testable import MactionsCore

// MARK: Fakes

final class FakeControlPlane: RunnerControlPlane, @unchecked Sendable {
  private(set) var jitCount = 0
  private(set) var deleted: [Int] = []
  var remote: [RemoteRunner] = []

  func generateJITConfig(name: String, labels: [String]) async throws -> JITConfig {
    jitCount += 1
    return JITConfig(encodedConfig: "jit-\(name)", runnerId: jitCount, runnerName: name)
  }
  func listRunners() async throws -> [RemoteRunner] { remote }
  func deleteRunner(id: Int) async throws { deleted.append(id) }
}

final class FakeProvider: RunnerProvider {
  let id: String
  private var onExit: ((Int32) -> Void)?
  private(set) var started = false
  private(set) var stopped = false
  init(id: String) { self.id = id }
  var isRunning: Bool { started && !stopped }
  func start(jitConfig: String, onExit: @escaping (Int32) -> Void) throws {
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

/// Collects the run records an orchestrator emits via `onRunFinished` (main-actor
/// isolated, so the callback can append without Sendable gymnastics).
@MainActor
final class RecordCollector {
  var records: [RunRecord] = []
}

// MARK: Tests

@MainActor
final class OrchestratorTests: XCTestCase {
  private func makeOrchestrator(count: Int) -> (RunnerOrchestrator, FakeControlPlane, FakeFactory) {
    let cp = FakeControlPlane()
    let factory = FakeFactory()
    let config = FleetConfig(owner: "o", repo: "r", labels: ["self-hosted"], desiredCount: count)
    // Fixed machine prefix so teardown scoping is deterministic (not host-dependent).
    let orch = RunnerOrchestrator(
      controlPlane: cp, factory: factory, config: config, machinePrefix: "mactions-testmac")
    return (orch, cp, factory)
  }

  /// Let queued MainActor tasks (the exit -> recycle hops) run.
  private func settle() async {
    try? await Task.sleep(nanoseconds: 80_000_000)
  }

  func testStartProvisionsDesiredCount() async {
    let (orch, cp, factory) = makeOrchestrator(count: 3)
    await orch.start()
    XCTAssertEqual(orch.state, .online)
    XCTAssertEqual(orch.runners.count, 3)
    XCTAssertEqual(cp.jitCount, 3)
    XCTAssertEqual(factory.made.count, 3)
    XCTAssertTrue(factory.made.allSatisfy { $0.started })
  }

  func testEphemeralExitRecyclesWhileOnline() async {
    let (orch, _, factory) = makeOrchestrator(count: 2)
    await orch.start()
    XCTAssertEqual(orch.runners.count, 2)

    // One runner finishes its single job and exits.
    factory.made.first?.fireExit(0)
    await settle()

    // Fleet is replenished back to 2, and a fresh provider was created.
    XCTAssertEqual(orch.runners.count, 2)
    XCTAssertEqual(factory.made.count, 3)
    XCTAssertEqual(orch.state, .online)
  }

  func testStopTearsDownAndDeregisters() async {
    let (orch, cp, factory) = makeOrchestrator(count: 2)
    cp.remote = [
      RemoteRunner(id: 10, name: "mactions-testmac-aaa", status: "online", busy: false),
      RemoteRunner(id: 11, name: "someone-elses-runner", status: "online", busy: false),
      RemoteRunner(id: 12, name: "mactions-testmac-bbb", status: "offline", busy: false),
      // Another Mac's Mactions runner — must be left alone (no cross-machine clobber).
      RemoteRunner(id: 13, name: "mactions-othermac-ccc", status: "online", busy: false),
    ]
    await orch.start()
    await orch.stop()

    XCTAssertEqual(orch.state, .offline)
    XCTAssertTrue(orch.runners.isEmpty)
    XCTAssertTrue(factory.made.allSatisfy { $0.stopped })
    // Only THIS machine's runners are deregistered; the stranger and the other
    // Mac's runner are untouched.
    XCTAssertEqual(Set(cp.deleted), [10, 12])
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
    let factory = FakeFactory()
    let config = FleetConfig(owner: "o", repo: "r", labels: ["self-hosted"], desiredCount: 1)
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
