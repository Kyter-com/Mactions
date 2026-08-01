import XCTest

@testable import MactionsCore

/// Serves canned responses for `GitHubClient` so the queued-jobs aggregation
/// and the ETag/304 replay run against a real `URLSession` (no live network).
final class StubURLProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var _handler:
    ((URLRequest) -> (status: Int, headers: [String: String], body: Data))?
  nonisolated(unsafe) private static var _seen: [URLRequest] = []

  static var handler: ((URLRequest) -> (status: Int, headers: [String: String], body: Data))? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _handler
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _handler = newValue
    }
  }

  static var seen: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return _seen
  }

  static func reset() {
    lock.lock()
    defer { lock.unlock() }
    _handler = nil
    _seen = []
  }

  private static func record(_ request: URLRequest) {
    lock.lock()
    defer { lock.unlock() }
    _seen.append(request)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.record(request)
    guard let url = request.url, let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    let (status, headers, body) = handler(request)
    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

final class GitHubQueuedJobsTests: XCTestCase {
  private var client: GitHubClient!

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    client = GitHubClient(owner: "o", repo: "r", token: "tok")
    client.session = URLSession(configuration: config)
  }

  override func tearDown() {
    StubURLProtocol.reset()
    super.tearDown()
  }

  private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private func json(_ string: String) -> Data { Data(string.utf8) }

  /// Job-level status is the truth (verified live 2026-06-10): queued jobs are
  /// collected from runs in BOTH `queued` and `in_progress` states, a run seen
  /// in both listings is only fetched once, non-queued jobs are skipped, and a
  /// months-old zombie run in the queued listing is age-filtered out (its jobs
  /// endpoint is never even called).
  func testAggregatesQueuedJobsAcrossRunStatesAndFiltersZombies() async throws {
    let now = iso(Date())
    let old = iso(Date().addingTimeInterval(-90 * 24 * 3600))
    StubURLProtocol.handler = { request in
      let url = request.url!.absoluteString
      if url.contains("/actions/runs?"), url.contains("status=queued") {
        return (
          200, [:],
          self.json(
            #"{"workflow_runs": [{"id": 1, "created_at": "\#(now)", "status": "queued"},"#
              + #"{"id": 9, "created_at": "\#(old)", "status": "queued"}]}"#)
        )
      }
      if url.contains("/actions/runs?"), url.contains("status=in_progress") {
        // Run 1 appears AGAIN here (run-level status flaps in real life) plus
        // run 2, an in_progress run carrying a queued matrix leg.
        return (
          200, [:],
          self.json(
            #"{"workflow_runs": [{"id": 1, "created_at": "\#(now)", "status": "in_progress"},"#
              + #"{"id": 2, "created_at": "\#(now)", "status": "in_progress"}]}"#)
        )
      }
      if url.contains("/actions/runs/1/jobs") {
        return (
          200, [:],
          self.json(
            #"{"jobs": [{"id": 10, "run_id": 1, "name": "a", "status": "queued", "labels": ["self-hosted", "macOS"]},"#
              + #"{"id": 11, "run_id": 1, "name": "b", "status": "completed", "labels": ["self-hosted", "macOS"]}]}"#
          )
        )
      }
      if url.contains("/actions/runs/2/jobs") {
        return (
          200, [:],
          self.json(
            #"{"jobs": [{"id": 20, "run_id": 2, "name": "c", "status": "in_progress", "labels": ["self-hosted", "Linux"]},"#
              + #"{"id": 21, "run_id": 2, "name": "d", "status": "queued", "labels": ["self-hosted", "Windows", "mactions"]}]}"#
          )
        )
      }
      return (404, [:], self.json(#"{"message": "unexpected: \#(url)"}"#))
    }

    let labels = try await client.listQueuedJobLabels()

    XCTAssertEqual(labels, [["self-hosted", "macOS"], ["self-hosted", "Windows", "mactions"]])
    let jobFetches = StubURLProtocol.seen.filter { $0.url!.path.contains("/jobs") }
    XCTAssertEqual(jobFetches.count, 2, "run 1 deduped; zombie run 9's jobs never fetched")
  }

  /// The idle-poll economics: the second poll carries If-None-Match, the stub's
  /// 304 has no body, and the client replays the cached runs list — same result,
  /// zero primary-rate-limit cost (GitHub doesn't bill 304s).
  func testETagReplayServesCachedBodyOn304() async throws {
    let now = iso(Date())
    let runsBody = json(
      #"{"workflow_runs": [{"id": 1, "created_at": "\#(now)", "status": "queued"}]}"#)
    let jobsBody = json(
      #"{"jobs": [{"id": 10, "run_id": 1, "name": "a", "status": "queued", "labels": ["self-hosted"]}]}"#
    )
    StubURLProtocol.handler = { request in
      let url = request.url!.absoluteString
      if url.contains("/actions/runs?") {
        if request.value(forHTTPHeaderField: "If-None-Match") == #"W/"etag-1""# {
          return (304, [:], Data())
        }
        return (200, ["ETag": #"W/"etag-1""#], runsBody)
      }
      if url.contains("/jobs") { return (200, [:], jobsBody) }
      return (404, [:], Data())
    }

    let first = try await client.listQueuedJobLabels()
    let second = try await client.listQueuedJobLabels()

    XCTAssertEqual(first, [["self-hosted"]])
    XCTAssertEqual(second, first, "the 304 replayed the cached runs list")
    let conditional = StubURLProtocol.seen.filter {
      $0.value(forHTTPHeaderField: "If-None-Match") != nil
    }
    XCTAssertEqual(conditional.count, 2, "both runs lists re-polled conditionally")
  }

  /// A RE-RUN keeps the run's ORIGINAL created_at and bumps updated_at when its
  /// jobs re-queue. The freshness filter must key on the latest of the two —
  /// filtering on created_at alone made re-runs of older runs permanently
  /// invisible (their queued jobs would die at GitHub's 24h timeout, runnerless).
  func testReRunOfOldRunStaysVisibleViaUpdatedAt() async throws {
    let old = iso(Date().addingTimeInterval(-3 * 24 * 3600))
    let now = iso(Date())
    StubURLProtocol.handler = { request in
      let url = request.url!.absoluteString
      if url.contains("/actions/runs?"), url.contains("status=queued") {
        return (
          200, [:],
          self.json(
            #"{"workflow_runs": [{"id": 5, "created_at": "\#(old)", "updated_at": "\#(now)", "status": "queued"}]}"#
          )
        )
      }
      if url.contains("/actions/runs?") {
        return (200, [:], self.json(#"{"workflow_runs": []}"#))
      }
      if url.contains("/actions/runs/5/jobs") {
        return (
          200, [:],
          self.json(
            #"{"jobs": [{"id": 50, "run_id": 5, "name": "retry", "status": "queued", "labels": ["self-hosted", "mactions"]}]}"#
          )
        )
      }
      return (404, [:], Data())
    }

    let labels = try await client.listQueuedJobLabels()
    XCTAssertEqual(labels, [["self-hosted", "mactions"]])
  }

  /// Runner→job correlation needs the same re-run timestamp rule as demand
  /// detection. A manual re-run can happen hours or days after the original run,
  /// so filtering only on created_at loses the live runner and its History log.
  func testFindJobUsesUpdatedAtForOldReRun() async throws {
    let old = iso(Date().addingTimeInterval(-3 * 24 * 3600))
    let now = iso(Date())
    StubURLProtocol.handler = { request in
      let url = request.url!.absoluteString
      if url.contains("/actions/runs?") {
        return (
          200, [:],
          self.json(
            #"{"workflow_runs": [{"id": 5, "created_at": "\#(old)", "updated_at": "\#(now)", "status": "in_progress"}]}"#
          )
        )
      }
      if url.contains("/actions/runs/5/jobs") {
        return (
          200, [:],
          self.json(
            #"{"total_count": 1, "jobs": [{"id": 50, "run_id": 5, "name": "retry", "status": "in_progress", "runner_name": "mactions-host-rerun"}]}"#
          )
        )
      }
      return (404, [:], Data())
    }

    let job = try await client.findJob(
      runnerName: "mactions-host-rerun", since: Date().addingTimeInterval(-60))

    XCTAssertEqual(job?.id, 50)
  }

  /// A readable workflow-runs list does not prove the token can read Jobs. If
  /// every candidate's Jobs request fails, surface that API error instead of
  /// misreporting a scope failure or outage as "no matching job".
  func testFindJobThrowsWhenEveryCandidateJobsRequestFails() async {
    let now = iso(Date())
    StubURLProtocol.handler = { request in
      let url = request.url!
      if url.path == "/repos/o/r/actions/runs" {
        return (
          200, [:],
          self.json(
            #"{"workflow_runs":[{"id":5,"created_at":"\#(now)","updated_at":"\#(now)","status":"in_progress"}]}"#
          )
        )
      }
      if url.path == "/repos/o/r/actions/runs/5/jobs" {
        return (403, [:], self.json(#"{"message":"Resource not accessible by token"}"#))
      }
      return (404, [:], Data())
    }

    do {
      _ = try await client.findJob(
        runnerName: "mactions-host-scope", since: Date().addingTimeInterval(-60))
      XCTFail("expected the Jobs API failure to propagate")
    } catch GitHubClient.ClientError.http(let code, _) {
      XCTAssertEqual(code, 403)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  /// GitHub allows matrices larger than one 100-item Jobs API page. Missing page
  /// 2 can hide queued demand or make a valid ephemeral runner impossible to
  /// correlate, so listJobs must honor total_count and paginate.
  func testListJobsPaginatesAllPages() async throws {
    func jobsBody(ids: ClosedRange<Int>, total: Int) -> Data {
      let jobs: [[String: Any]] = ids.map {
        ["id": $0, "run_id": 9, "name": "job-\($0)", "status": "queued"]
      }
      return try! JSONSerialization.data(withJSONObject: ["total_count": total, "jobs": jobs])
    }
    StubURLProtocol.handler = { request in
      let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "page" })?.value
      if page == "2" { return (200, [:], jobsBody(ids: 101...101, total: 101)) }
      return (200, [:], jobsBody(ids: 1...100, total: 101))
    }

    let jobs = try await client.listJobs(runId: 9)

    XCTAssertEqual(jobs.count, 101)
    XCTAssertEqual(jobs.last?.id, 101)
    XCTAssertEqual(StubURLProtocol.seen.count, 2)
    XCTAssertTrue(StubURLProtocol.seen[1].url!.absoluteString.contains("page=2"))
  }

  /// After initial runner-name correlation, live refreshes use the direct job
  /// endpoint. Its ETag must survive across ticks and replay the cached job on a
  /// 304 so a steady checklist does not consume primary rate-limit quota.
  func testDirectJobRefreshReplaysETaggedBody() async throws {
    let body = json(
      #"{"id": 50, "run_id": 5, "name": "build", "status": "in_progress", "runner_name": "mactions-host-live", "steps": [{"name": "Test", "status": "in_progress", "conclusion": null, "number": 1}]}"#
    )
    StubURLProtocol.handler = { request in
      if request.value(forHTTPHeaderField: "If-None-Match") == #"W/"job-etag""# {
        return (304, [:], Data())
      }
      return (200, ["ETag": #"W/"job-etag""#], body)
    }

    let first = try await client.getJob(jobId: 50, etagged: true)
    let second = try await client.getJob(jobId: 50, etagged: true)

    XCTAssertEqual(first, second)
    XCTAssertEqual(second.steps?.first?.status, "in_progress")
    XCTAssertEqual(
      StubURLProtocol.seen.last?.value(forHTTPHeaderField: "If-None-Match"),
      #"W/"job-etag""#)
  }

  /// A failed poll must throw (the orchestrator HOLDS the fleet on a throw) —
  /// not silently return an empty queue.
  func testQueuedPollThrowsOnHTTPError() async {
    StubURLProtocol.handler = { _ in (500, [:], Data()) }
    do {
      _ = try await client.listQueuedJobLabels()
      XCTFail("expected a throw")
    } catch {}
  }

  func testListRunnersPaginatesAllPages() async throws {
    StubURLProtocol.handler = { request in
      let url = request.url!
      guard url.path == "/repos/o/r/actions/runners" else {
        return (404, [:], self.json(#"{"message": "unexpected"}"#))
      }
      let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "page" })?.value
      if page == "2" {
        return (
          200, [:],
          self.json(
            #"{"total_count":3,"runners":[{"id":3,"name":"r3","status":"offline","busy":false}]}"#)
        )
      }
      return (
        200, [:],
        self.json(
          #"{"total_count":3,"runners":[{"id":1,"name":"r1","status":"online","busy":true},"#
            + #"{"id":2,"name":"r2","status":"offline","busy":false}]}"#)
      )
    }

    let runners = try await client.listRunners()

    XCTAssertEqual(runners.map(\.id), [1, 2, 3])
    XCTAssertEqual(
      StubURLProtocol.seen.map { $0.url!.absoluteString },
      [
        "https://api.github.com/repos/o/r/actions/runners?per_page=100",
        "https://api.github.com/repos/o/r/actions/runners?per_page=100&page=2",
      ])
  }

  /// The visible-runner poll runs every six seconds. It must use the ETag GitHub
  /// exposes on this endpoint; otherwise nine watched repos alone can exhaust a
  /// 5,000-request hourly token budget.
  func testListRunnersReplaysETaggedBodyOn304() async throws {
    let body = json(
      #"{"total_count":1,"runners":[{"id":1,"name":"r1","status":"online","busy":true}]}"#)
    StubURLProtocol.handler = { request in
      if request.value(forHTTPHeaderField: "If-None-Match") == #"W/"runners-etag""# {
        return (304, [:], Data())
      }
      return (200, ["ETag": #"W/"runners-etag""#], body)
    }

    let first = try await client.listRunners()
    let second = try await client.listRunners()

    XCTAssertEqual(second, first)
    XCTAssertEqual(second.first?.busy, true)
    XCTAssertEqual(
      StubURLProtocol.seen.last?.value(forHTTPHeaderField: "If-None-Match"),
      #"W/"runners-etag""#)
  }

  /// History survives restarts and can outlive the first workflow-runs page.
  /// Correlation must paginate to the runner's time window instead of silently
  /// making a still-retained GitHub log unreachable after 100 newer runs.
  func testFindJobPaginatesPastFirstWorkflowRunsPage() async throws {
    let now = Date()
    func runsBody(ids: ClosedRange<Int>, at date: Date) -> Data {
      let runs: [[String: Any]] = ids.map {
        [
          "id": $0, "created_at": self.iso(date), "updated_at": self.iso(date),
          "status": "completed",
        ]
      }
      return try! JSONSerialization.data(withJSONObject: ["workflow_runs": runs])
    }
    StubURLProtocol.handler = { request in
      let url = request.url!
      if url.path == "/repos/o/r/actions/runs" {
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "page" })?.value
        if page == "2" { return (200, [:], runsBody(ids: 999...999, at: now)) }
        // Outside the requested upper bound, so no Jobs API calls are wasted on
        // these 100 newer records while we advance to page 2.
        return (200, [:], runsBody(ids: 1...100, at: now.addingTimeInterval(3600)))
      }
      if url.path == "/repos/o/r/actions/runs/999/jobs" {
        return (
          200, [:],
          self.json(
            #"{"total_count":1,"jobs":[{"id":700,"run_id":999,"name":"old history","status":"completed","conclusion":"success","runner_name":"mactions-host-history"}]}"#
          )
        )
      }
      return (404, [:], Data())
    }

    let job = try await client.findJob(
      runnerName: "mactions-host-history", since: now.addingTimeInterval(-60),
      until: now.addingTimeInterval(60), maxPages: 2)

    XCTAssertEqual(job?.id, 700)
    XCTAssertEqual(
      StubURLProtocol.seen.filter { $0.url?.path == "/repos/o/r/actions/runs" }.count, 2)
    XCTAssertFalse(
      StubURLProtocol.seen.contains {
        $0.url?.path.contains("/jobs") == true && $0.url?.path != "/repos/o/r/actions/runs/999/jobs"
      })
  }

  /// A workflow's `updated_at` can advance well after this runner exits because
  /// matrix/sibling jobs are still executing. Correlation uses interval overlap,
  /// not a requirement that the workflow's final update lands inside our job.
  func testFindJobIncludesWorkflowSpanningRunnerLifetime() async throws {
    let now = Date()
    let began = iso(now.addingTimeInterval(-2 * 3600))
    let finished = iso(now.addingTimeInterval(2 * 3600))
    StubURLProtocol.handler = { request in
      let url = request.url!
      if url.path == "/repos/o/r/actions/runs" {
        return (
          200, [:],
          self.json(
            #"{"workflow_runs":[{"id":88,"created_at":"\#(began)","updated_at":"\#(finished)","status":"in_progress"}]}"#
          )
        )
      }
      if url.path == "/repos/o/r/actions/runs/88/jobs" {
        return (
          200, [:],
          self.json(
            #"{"total_count":1,"jobs":[{"id":808,"run_id":88,"name":"matrix leg","status":"completed","conclusion":"success","runner_name":"mactions-host-span"}]}"#
          )
        )
      }
      return (404, [:], Data())
    }

    let job = try await client.findJob(
      runnerName: "mactions-host-span", since: now.addingTimeInterval(-60),
      until: now.addingTimeInterval(60))

    XCTAssertEqual(job?.id, 808)
  }
}
