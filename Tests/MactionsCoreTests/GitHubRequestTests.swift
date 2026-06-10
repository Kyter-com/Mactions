import XCTest

@testable import MactionsCore

final class GitHubRequestTests: XCTestCase {
  let client = GitHubClient(owner: "Kyter-com", repo: "sweep-collector", token: "tok_123")

  func testJITConfigRequestShape() throws {
    let req = try client.jitConfigRequest(name: "mactions-abc", labels: ["self-hosted", "macOS"])
    XCTAssertEqual(req.httpMethod, "POST")
    XCTAssertEqual(
      req.url?.absoluteString,
      "https://api.github.com/repos/Kyter-com/sweep-collector/actions/runners/generate-jitconfig"
    )
    XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok_123")
    XCTAssertEqual(req.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")

    let body = try XCTUnwrap(req.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["name"] as? String, "mactions-abc")
    XCTAssertEqual(json["runner_group_id"] as? Int, 1)
    XCTAssertEqual(json["work_folder"] as? String, "_work")
    XCTAssertEqual(json["labels"] as? [String], ["self-hosted", "macOS"])
  }

  func testListAndDeleteRequestShape() {
    let list = client.listRunnersRequest()
    XCTAssertEqual(list.httpMethod, "GET")
    XCTAssertEqual(
      list.url?.absoluteString,
      "https://api.github.com/repos/Kyter-com/sweep-collector/actions/runners?per_page=100"
    )

    let del = client.deleteRunnerRequest(id: 42)
    XCTAssertEqual(del.httpMethod, "DELETE")
    XCTAssertEqual(
      del.url?.absoluteString,
      "https://api.github.com/repos/Kyter-com/sweep-collector/actions/runners/42"
    )
    XCTAssertEqual(del.value(forHTTPHeaderField: "Authorization"), "Bearer tok_123")
  }

  func testActionsLogRequestShapes() {
    let runs = client.listWorkflowRunsRequest(perPage: 40)
    XCTAssertEqual(runs.httpMethod, "GET")
    XCTAssertEqual(
      runs.url?.absoluteString,
      "https://api.github.com/repos/Kyter-com/sweep-collector/actions/runs?per_page=40")

    let jobs = client.listJobsRequest(runId: 99)
    XCTAssertEqual(jobs.httpMethod, "GET")
    XCTAssertEqual(
      jobs.url?.absoluteString,
      "https://api.github.com/repos/Kyter-com/sweep-collector/actions/runs/99/jobs?per_page=100&filter=all"
    )

    let logs = client.jobLogsRequest(jobId: 7)
    XCTAssertEqual(logs.httpMethod, "GET")
    XCTAssertEqual(
      logs.url?.absoluteString,
      "https://api.github.com/repos/Kyter-com/sweep-collector/actions/jobs/7/logs")
    XCTAssertEqual(logs.value(forHTTPHeaderField: "Authorization"), "Bearer tok_123")
  }

  func testWorkflowJobDecoding() throws {
    let json = """
      {"id":123,"run_id":456,"name":"build (windows)","status":"completed","conclusion":"success",
       "runner_name":"mactions-host-ab12cd","runner_id":77,
       "html_url":"https://github.com/x/y/actions/runs/456/job/123",
       "started_at":"2024-06-01T12:00:00Z","completed_at":"2024-06-01T12:03:20Z",
       "steps":[{"name":"Set up job","status":"completed","conclusion":"success","number":1},
                {"name":"Run tests","status":"in_progress","conclusion":null,"number":2}]}
      """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let job = try decoder.decode(WorkflowJob.self, from: json)
    XCTAssertEqual(job.id, 123)
    XCTAssertEqual(job.runId, 456)
    XCTAssertEqual(job.runnerName, "mactions-host-ab12cd")
    XCTAssertEqual(job.runnerId, 77)
    XCTAssertEqual(job.conclusion, "success")
    XCTAssertEqual(job.steps?.count, 2)
    XCTAssertEqual(job.steps?.first?.name, "Set up job")
    XCTAssertNil(job.steps?.last?.conclusion)
  }

  /// The re-run-attempt fix: when a run has two jobs sharing our (unique) runner
  /// name — attempt 1 and a later attempt 2 — `pickJob` must return the NEWEST by
  /// `startedAt`, so a re-run resolves to its real (latest) result, not attempt 1.
  func testPickJobPrefersLatestAttempt() throws {
    func job(id: Int, runner: String, startedAt: String?, conclusion: String?) -> WorkflowJob {
      let started = startedAt.map { "\"\($0)\"" } ?? "null"
      let json = """
        {"id":\(id),"run_id":456,"name":"build (windows)","status":"completed",
         "conclusion":\(conclusion.map { "\"\($0)\"" } ?? "null"),
         "runner_name":"\(runner)","runner_id":77,
         "html_url":"https://github.com/x/y/actions/runs/456/job/\(id)",
         "started_at":\(started),"completed_at":null}
        """.data(using: .utf8)!
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try! decoder.decode(WorkflowJob.self, from: json)
    }
    let attempt1 = job(id: 1, runner: "mactions-host-ab12cd", startedAt: "2024-06-01T12:00:00Z", conclusion: "failure")
    let attempt2 = job(id: 2, runner: "mactions-host-ab12cd", startedAt: "2024-06-01T12:30:00Z", conclusion: "success")
    let other = job(id: 3, runner: "mactions-host-zzzz", startedAt: "2024-06-01T12:45:00Z", conclusion: "failure")

    // Order shouldn't matter — newest attempt wins regardless of array position.
    XCTAssertEqual(GitHubClient.pickJob([attempt1, attempt2, other], runnerName: "mactions-host-ab12cd")?.id, 2)
    XCTAssertEqual(GitHubClient.pickJob([attempt2, attempt1], runnerName: "mactions-host-ab12cd")?.id, 2)
    // No matching runner → nil (the honest "no matching job" path).
    XCTAssertNil(GitHubClient.pickJob([attempt1, attempt2, other], runnerName: "mactions-host-nope"))
    XCTAssertNil(GitHubClient.pickJob([], runnerName: "mactions-host-ab12cd"))
  }

  func testDeviceFlowRequestShapes() {
    let codeReq = GitHubAuth.deviceCodeRequest(clientId: "Iv1.abc", scope: "repo")
    XCTAssertEqual(codeReq.httpMethod, "POST")
    XCTAssertEqual(codeReq.url, GitHubAuth.deviceCodeURL)
    XCTAssertEqual(codeReq.value(forHTTPHeaderField: "Accept"), "application/json")
    let codeBody = (try? JSONSerialization.jsonObject(with: codeReq.httpBody ?? Data())) as? [String: String]
    XCTAssertEqual(codeBody?["client_id"], "Iv1.abc")
    XCTAssertEqual(codeBody?["scope"], "repo")

    let tokenReq = GitHubAuth.accessTokenRequest(clientId: "Iv1.abc", deviceCode: "dev_1")
    let tokenBody = (try? JSONSerialization.jsonObject(with: tokenReq.httpBody ?? Data())) as? [String: String]
    XCTAssertEqual(tokenBody?["device_code"], "dev_1")
    XCTAssertEqual(tokenBody?["grant_type"], "urn:ietf:params:oauth:grant-type:device_code")
  }

  func testRequestDeviceCodeRejectsEmptyClientId() async {
    do {
      _ = try await GitHubAuth.requestDeviceCode(clientId: "")
      XCTFail("expected noClientId")
    } catch {
      XCTAssertEqual(error as? GitHubAuth.AuthError, .noClientId)
    }
  }

  // MARK: Scale-from-zero (queued-jobs demand signal)

  func testListWorkflowRunsRequestStatusFilterShape() {
    let queued = client.listWorkflowRunsRequest(perPage: 40, status: "queued")
    XCTAssertEqual(
      queued.url?.absoluteString,
      "https://api.github.com/repos/Kyter-com/sweep-collector/actions/runs?per_page=40&status=queued"
    )
    // Status-filtered (polled) requests bypass URLCache so the explicit ETag
    // handling is the only caching layer in play.
    XCTAssertEqual(queued.cachePolicy, .reloadIgnoringLocalCacheData)

    // No status → the original shape, untouched.
    let plain = client.listWorkflowRunsRequest(perPage: 40)
    XCTAssertEqual(
      plain.url?.absoluteString,
      "https://api.github.com/repos/Kyter-com/sweep-collector/actions/runs?per_page=40")
  }

  func testWorkflowJobDecodesRunsOnLabels() throws {
    let json = Data(
      #"{"id": 1, "run_id": 2, "name": "build", "status": "queued", "labels": ["self-hosted", "Windows", "mactions"]}"#
        .utf8)
    let job = try JSONDecoder().decode(WorkflowJob.self, from: json)
    XCTAssertEqual(job.labels, ["self-hosted", "Windows", "mactions"])
    XCTAssertEqual(job.status, "queued")
  }

  /// GitHub's `runs-on` routing rule: every job label must be present on the
  /// runner (cumulative), matching is case-insensitive, extra runner labels are
  /// fine, and a label-less job never routes to self-hosted.
  func testJobLabelsMatchRunnerRule() {
    let runner = ["self-hosted", "Windows", "mactions"]
    XCTAssertTrue(jobLabelsMatchRunner(job: ["self-hosted", "windows"], runner: runner))
    XCTAssertTrue(
      jobLabelsMatchRunner(job: ["SELF-HOSTED", "Windows", "MACTIONS"], runner: runner))
    XCTAssertFalse(
      jobLabelsMatchRunner(job: ["self-hosted", "windows", "gpu"], runner: runner),
      "a job label the runner lacks blocks routing")
    XCTAssertFalse(jobLabelsMatchRunner(job: ["windows-latest"], runner: runner))
    XCTAssertFalse(jobLabelsMatchRunner(job: [], runner: runner))
  }
}
