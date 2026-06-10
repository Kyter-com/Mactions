import XCTest

@testable import MactionsCore

/// Pins the per-repo poll sharing (`SharedRepoControlPlane`) and the pure
/// all-repos discovery reap ledger (`discoveryReapDecision`).
final class SharedRepoControlPlaneTests: XCTestCase {

  // MARK: Queue-poll sharing

  func testQueuePollsWithinTTLShareOneFetch() async throws {
    let cp = FakeControlPlane()
    cp.queuedJobs = [["self-hosted"]]
    let plane = SharedRepoControlPlane(inner: cp, queueCacheTTL: 60)

    let first = try await plane.listQueuedJobLabels()
    let second = try await plane.listQueuedJobLabels()  // same tick window

    XCTAssertEqual(first, [["self-hosted"]])
    XCTAssertEqual(second, first)
    XCTAssertEqual(cp.queuePollCount, 1, "the sibling combo's poll rode the cache")
  }

  func testQueuePollRefetchesAfterTTL() async throws {
    let cp = FakeControlPlane()
    cp.queuedJobs = [["self-hosted"]]
    let plane = SharedRepoControlPlane(inner: cp, queueCacheTTL: 0.05)

    _ = try await plane.listQueuedJobLabels()
    try? await Task.sleep(nanoseconds: 120_000_000)
    cp.queuedJobs = []
    let fresh = try await plane.listQueuedJobLabels()

    XCTAssertEqual(cp.queuePollCount, 2)
    XCTAssertEqual(fresh, [], "a post-TTL poll sees fresh data, not the cache")
  }

  func testConcurrentQueuePollsCollapseIntoOneInflightFetch() async throws {
    let cp = FakeControlPlane()
    cp.queuedJobs = [["self-hosted"]]
    cp.queueDelayNanos = 100_000_000  // hold the fetch on the wire
    let plane = SharedRepoControlPlane(inner: cp, queueCacheTTL: 60)

    async let a = plane.listQueuedJobLabels()
    async let b = plane.listQueuedJobLabels()
    let (ra, rb) = (try await a, try await b)

    XCTAssertEqual(ra, rb)
    XCTAssertEqual(cp.queuePollCount, 1, "concurrent polls shared one in-flight fetch")
  }

  func testFailedSharedPollIsNotCached() async {
    let cp = FakeControlPlane()
    cp.failQueuedPoll = true
    let plane = SharedRepoControlPlane(inner: cp, queueCacheTTL: 60)

    do {
      _ = try await plane.listQueuedJobLabels()
      XCTFail("expected a throw")
    } catch {}

    cp.failQueuedPoll = false
    cp.queuedJobs = [["self-hosted"]]
    let recovered = try? await plane.listQueuedJobLabels()
    XCTAssertEqual(recovered, [["self-hosted"]], "an error must not poison the cache")
  }

  func testNonQueueCallsPassStraightThrough() async throws {
    let cp = FakeControlPlane()
    cp.remote = [RemoteRunner(id: 7, name: "r", status: "online", busy: true)]
    let plane = SharedRepoControlPlane(inner: cp, queueCacheTTL: 60)

    let jit = try await plane.generateJITConfig(name: "n", labels: ["self-hosted"])
    XCTAssertEqual(jit.runnerName, "n")
    let runners = try await plane.listRunners()
    XCTAssertEqual(runners.first?.id, 7)
    try await plane.deleteRunner(id: 7)
    XCTAssertEqual(cp.deleted, [7])
  }

  // MARK: Discovery reap ledger (pure)

  func testFailedPollHoldsTheQuietCounter() {
    XCTAssertEqual(
      discoveryReapDecision(matched: false, pollFailed: true, liveRunners: 0, quietScans: 1),
      .hold, "a flaky probe must not march a live fleet toward the reap")
  }

  func testDemandOrLiveRunnersResetTheCounter() {
    XCTAssertEqual(
      discoveryReapDecision(matched: true, pollFailed: false, liveRunners: 0, quietScans: 1),
      .reset)
    XCTAssertEqual(
      discoveryReapDecision(matched: false, pollFailed: false, liveRunners: 2, quietScans: 1),
      .reset, "live runners keep the fleet even when this scan saw no queue match")
  }

  func testReapRequiresConsecutiveQuietScans() {
    XCTAssertEqual(
      discoveryReapDecision(matched: false, pollFailed: false, liveRunners: 0, quietScans: 0),
      .countQuiet(quietScans: 1), "one quiet scan can race a job mid-pickup")
    XCTAssertEqual(
      discoveryReapDecision(matched: false, pollFailed: false, liveRunners: 0, quietScans: 1),
      .reap)
  }

  func testQuietRunThenActivityStartsOver() {
    // quiet → activity → the counter resets, so the next quiet scan counts as 1.
    var quiet = 0
    if case .countQuiet(let n) = discoveryReapDecision(
      matched: false, pollFailed: false, liveRunners: 0, quietScans: quiet)
    { quiet = n }
    XCTAssertEqual(quiet, 1)
    if case .reset = discoveryReapDecision(
      matched: true, pollFailed: false, liveRunners: 0, quietScans: quiet)
    { quiet = 0 }
    XCTAssertEqual(
      discoveryReapDecision(matched: false, pollFailed: false, liveRunners: 0, quietScans: quiet),
      .countQuiet(quietScans: 1), "the earlier quiet scan must not carry over")
  }
}
