import XCTest

@testable import MactionsCore

/// A queued-jobs poll that takes a set time (or never answers in a test's
/// time), and records how many polls were in flight at once and in what order
/// they started.
final class TimedQueuePlane: RunnerControlPlane, @unchecked Sendable {
  struct Failure: Error {}

  let name: String
  private let delay: TimeInterval
  private let fails: Bool
  private let recorder: PollRecorder

  init(name: String, delay: TimeInterval, fails: Bool = false, recorder: PollRecorder) {
    self.name = name
    self.delay = delay
    self.fails = fails
    self.recorder = recorder
  }

  func listQueuedJobLabels() async throws -> [[String]] {
    recorder.started(name)
    defer { recorder.finished() }
    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    if fails { throw Failure() }
    return [["self-hosted", name]]
  }

  func generateJITConfig(name: String, labels: [String]) async throws -> JITConfig {
    throw Failure()
  }
  func listRunners() async throws -> [RemoteRunner] { [] }
  func deleteRunner(id: Int) async throws {}
}

final class PollRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var inFlight = 0
  private var _maxInFlight = 0
  private var _order: [String] = []

  var maxInFlight: Int { synchronized { _maxInFlight } }
  var order: [String] { synchronized { _order } }

  func started(_ name: String) {
    synchronized {
      inFlight += 1
      _maxInFlight = max(_maxInFlight, inFlight)
      _order.append(name)
    }
  }

  func finished() { synchronized { inFlight -= 1 } }

  private func synchronized<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

final class DiscoveryPollTests: XCTestCase {
  private func targets(
    _ count: Int, delay: TimeInterval, recorder: PollRecorder, failing: Set<Int> = [],
    hanging: Set<Int> = []
  ) -> [QueuedJobsPollTarget] {
    (0..<count).map { i in
      let name = "o/r\(i)"
      return QueuedJobsPollTarget(
        name: name,
        plane: TimedQueuePlane(
          name: name, delay: hanging.contains(i) ? 30 : delay, fails: failing.contains(i),
          recorder: recorder))
    }
  }

  func testEveryRepoIsPolledAtMostNAtATimeInOrder() async {
    let recorder = PollRecorder()
    let polls = await pollQueuedJobs(
      targets(12, delay: 0.05, recorder: recorder), concurrency: 4, timeout: 10)
    XCTAssertEqual(polls.count, 12)
    XCTAssertEqual(polls["o/r3"], .queued([["self-hosted", "o/r3"]]))
    XCTAssertEqual(recorder.maxInFlight, 4)
    // Started in order: most recently pushed repos first.
    XCTAssertEqual(Array(recorder.order.prefix(4)).sorted(), ["o/r0", "o/r1", "o/r2", "o/r3"])
    XCTAssertEqual(recorder.order.last, "o/r11")
  }

  func testPollingInParallelHidesLatency() async {
    // 20 repos at 100 ms each: about 2 s one at a time, about 0.5 s four at a time.
    let recorder = PollRecorder()
    let started = Date()
    let polls = await pollQueuedJobs(
      targets(20, delay: 0.1, recorder: recorder), concurrency: 4, timeout: 10)
    XCTAssertEqual(polls.values.filter { !$0.isUnknown }.count, 20)
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
  }

  func testAFailedPollIsUnknownNotEmpty() async {
    let polls = await pollQueuedJobs(
      targets(3, delay: 0.01, recorder: PollRecorder(), failing: [1]), concurrency: 2, timeout: 10)
    XCTAssertEqual(polls["o/r1"], .failed)
    XCTAssertTrue(polls["o/r1"]!.isUnknown)
    XCTAssertFalse(polls["o/r0"]!.isUnknown)
  }

  func testTheDeadlineReturnsWithoutTheSlowPolls() async {
    let started = Date()
    let polls = await pollQueuedJobs(
      targets(6, delay: 0.01, recorder: PollRecorder(), hanging: [0, 4]),
      concurrency: 2, timeout: 0.5)
    XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the scan must not wait on a hung poll")
    XCTAssertEqual(polls["o/r0"], .unfinished)
    XCTAssertEqual(polls["o/r4"], .unfinished)
    // The other worker kept going past the hung first poll.
    XCTAssertEqual(polls["o/r1"], .queued([["self-hosted", "o/r1"]]))
    XCTAssertEqual(polls["o/r2"], .queued([["self-hosted", "o/r2"]]))
    XCTAssertEqual(polls["o/r3"], .queued([["self-hosted", "o/r3"]]))
  }

  func testCancellingTheScanReturnsPromptly() async {
    let hung = targets(4, delay: 30, recorder: PollRecorder())
    let scan = Task { await pollQueuedJobs(hung, concurrency: 4, timeout: 60) }
    try? await Task.sleep(nanoseconds: 100_000_000)
    let started = Date()
    scan.cancel()
    let polls = await scan.value
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    XCTAssertEqual(polls.count, 4)
    XCTAssertTrue(polls.values.allSatisfy(\.isUnknown))
  }

  func testAnswersArriveAsEachPollReturns() async {
    // A fast repo's answer is handed over while a slow one is still polling,
    // so a repo with a queued job never waits on the slowest poll.
    let recorder = PollRecorder()
    let slow = TimedQueuePlane(name: "o/slow", delay: 1.5, recorder: recorder)
    let fast = TimedQueuePlane(name: "o/fast", delay: 0.05, recorder: recorder)
    let polling = startPollingQueuedJobs(
      [QueuedJobsPollTarget(name: "o/slow", plane: slow), QueuedJobsPollTarget(name: "o/fast", plane: fast)],
      concurrency: 2, timeout: 10)
    defer { polling.cancel() }
    let started = Date()
    var iterator = polling.answers.makeAsyncIterator()
    let first = await iterator.next()
    XCTAssertEqual(first?.name, "o/fast")
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    let second = await iterator.next()
    XCTAssertEqual(second?.name, "o/slow")
    let end = await iterator.next()
    XCTAssertNil(end, "the stream ends once every repo has answered")
    XCTAssertLessThan(
      Date().timeIntervalSince(started), 5, "…at once, not at the 10 s deadline")
  }

  func testNoTargetsAndRepeatedNames() async {
    let none = await pollQueuedJobs([], timeout: 1)
    XCTAssertTrue(none.isEmpty)
    let recorder = PollRecorder()
    let plane = TimedQueuePlane(name: "o/a", delay: 0.01, recorder: recorder)
    let twice = await pollQueuedJobs(
      [QueuedJobsPollTarget(name: "o/a", plane: plane), QueuedJobsPollTarget(name: "o/a", plane: plane)],
      timeout: 5)
    XCTAssertEqual(twice.count, 1)
    XCTAssertEqual(recorder.order, ["o/a"], "a repo listed twice is polled once")
  }
}
