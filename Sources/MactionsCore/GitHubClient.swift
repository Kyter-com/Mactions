import Foundation

/// A just-in-time runner config: a single-use, ephemeral registration GitHub
/// mints for us. We hand `encodedConfig` to the runner agent (`run.sh
/// --jitconfig …`); it registers, runs exactly one job, and deregisters itself.
public struct JITConfig: Equatable, Sendable {
  public let encodedConfig: String
  public let runnerId: Int
  public let runnerName: String
}

public struct RemoteRunner: Decodable, Equatable, Sendable {
  public let id: Int
  public let name: String
  public let status: String // "online" | "offline"
  public let busy: Bool
}

/// Drops the `Authorization` header when a request is redirected to a different
/// host. Used for the job-log download, whose 302 points at a pre-signed blob URL
/// that needs no auth — so the GitHub token never travels to the storage host.
private final class RedirectAuthStripper: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    if request.url?.host != task.originalRequest?.url?.host {
      var stripped = request
      stripped.setValue(nil, forHTTPHeaderField: "Authorization")
      completionHandler(stripped)
    } else {
      completionHandler(request)
    }
  }
}

/// A minimal workflow-run summary — just enough to find the run that contains
/// the job our ephemeral runner executed (we scan recent runs by creation time).
public struct WorkflowRunSummary: Decodable, Sendable, Equatable {
  public let id: Int
  public let createdAt: Date?
  public let status: String?

  enum CodingKeys: String, CodingKey {
    case id
    case createdAt = "created_at"
    case status
  }
}

/// One step of a job (the Jobs API returns these), so the dashboard can show a
/// live-ish progress checklist for a running runner without log streaming.
public struct WorkflowStep: Decodable, Sendable, Equatable, Identifiable {
  public let name: String
  public let status: String  // queued | in_progress | completed
  public let conclusion: String?  // success | failure | skipped | cancelled | null
  public let number: Int
  public var id: Int { number }
}

/// A GitHub Actions job. The key field for us is `runnerName`: an ephemeral
/// runner runs exactly one job, and the job carries the unique `mactions-…`
/// runner name we minted, so we can correlate a local run → its job → its log.
public struct WorkflowJob: Decodable, Sendable, Equatable, Identifiable {
  public let id: Int
  public let runId: Int
  public let name: String
  public let status: String  // queued | in_progress | completed
  public let conclusion: String?  // success | failure | cancelled | skipped | null
  public let runnerName: String?
  public let runnerId: Int?
  public let htmlURL: String?
  public let startedAt: Date?
  public let completedAt: Date?
  public let steps: [WorkflowStep]?

  enum CodingKeys: String, CodingKey {
    case id, name, status, conclusion, steps
    case runId = "run_id"
    case runnerName = "runner_name"
    case runnerId = "runner_id"
    case htmlURL = "html_url"
    case startedAt = "started_at"
    case completedAt = "completed_at"
  }
}

/// The slice of the GitHub Actions API the orchestrator needs. A protocol so
/// tests can drive the orchestrator with a fake (no network).
public protocol RunnerControlPlane: Sendable {
  func generateJITConfig(name: String, labels: [String]) async throws -> JITConfig
  func listRunners() async throws -> [RemoteRunner]
  func deleteRunner(id: Int) async throws
}

/// Talks to `api.github.com` for a single `owner/repo`. Repo-level runners,
/// authenticated with the stored token (needs repo-admin / `repo` scope).
public struct GitHubClient: RunnerControlPlane {
  public let owner: String
  public let repo: String
  public let token: String
  public var apiBase = URL(string: "https://api.github.com")!
  public var session: URLSession = .shared

  public init(owner: String, repo: String, token: String) {
    self.owner = owner
    self.repo = repo
    self.token = token
  }

  public enum ClientError: Error, CustomStringConvertible {
    case http(Int, String)
    public var description: String {
      switch self {
      case let .http(code, body):
        return "GitHub API HTTP \(code): \(body.prefix(300))"
      }
    }
  }

  // MARK: Request builders (pure → unit-testable)

  private func request(url: URL, method: String) -> URLRequest {
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return req
  }

  private func base(_ path: String, method: String) -> URLRequest {
    request(url: apiBase.appendingPathComponent(path), method: method)
  }

  struct JITBody: Encodable {
    let name: String
    let runner_group_id: Int
    let labels: [String]
    let work_folder: String
  }

  public func jitConfigRequest(name: String, labels: [String], runnerGroupId: Int = 1) throws -> URLRequest {
    var req = base("repos/\(owner)/\(repo)/actions/runners/generate-jitconfig", method: "POST")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode(
      JITBody(name: name, runner_group_id: runnerGroupId, labels: labels, work_folder: "_work")
    )
    return req
  }

  public func listRunnersRequest() -> URLRequest {
    var components = URLComponents(
      url: apiBase.appendingPathComponent("repos/\(owner)/\(repo)/actions/runners"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
    return request(url: components.url!, method: "GET")
  }

  public func deleteRunnerRequest(id: Int) -> URLRequest {
    base("repos/\(owner)/\(repo)/actions/runners/\(id)", method: "DELETE")
  }

  // MARK: Calls

  public func generateJITConfig(name: String, labels: [String]) async throws -> JITConfig {
    struct Response: Decodable {
      struct Runner: Decodable { let id: Int; let name: String }
      let runner: Runner
      let encoded_jit_config: String
    }
    let data = try await send(jitConfigRequest(name: name, labels: labels))
    let decoded = try JSONDecoder().decode(Response.self, from: data)
    return JITConfig(
      encodedConfig: decoded.encoded_jit_config,
      runnerId: decoded.runner.id,
      runnerName: decoded.runner.name
    )
  }

  public func listRunners() async throws -> [RemoteRunner] {
    struct Response: Decodable { let runners: [RemoteRunner] }
    let data = try await send(listRunnersRequest())
    return try JSONDecoder().decode(Response.self, from: data).runners
  }

  public func deleteRunner(id: Int) async throws {
    _ = try await send(deleteRunnerRequest(id: id), allowEmpty: true)
  }

  // MARK: Actions logs (jobs + runner→job correlation)

  /// Decoder for the Actions endpoints (GitHub returns ISO-8601 `Z` timestamps).
  private static func actionsDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  public func listWorkflowRunsRequest(perPage: Int = 40) -> URLRequest {
    var components = URLComponents(
      url: apiBase.appendingPathComponent("repos/\(owner)/\(repo)/actions/runs"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "per_page", value: String(perPage))]
    var req = request(url: components.url!, method: "GET")
    req.timeoutInterval = 20  // bound each call so a slow network can't stall findJob's loop
    return req
  }

  public func listJobsRequest(runId: Int) -> URLRequest {
    var components = URLComponents(
      url: apiBase.appendingPathComponent("repos/\(owner)/\(repo)/actions/runs/\(runId)/jobs"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "per_page", value: "100"),
      URLQueryItem(name: "filter", value: "all"),
    ]
    var req = request(url: components.url!, method: "GET")
    req.timeoutInterval = 20
    return req
  }

  public func jobLogsRequest(jobId: Int) -> URLRequest {
    // 302s to a short-lived signed URL whose body is the plaintext log; URLSession
    // follows the redirect by default, so `send` returns the log bytes directly.
    base("repos/\(owner)/\(repo)/actions/jobs/\(jobId)/logs", method: "GET")
  }

  public func listRecentWorkflowRuns(perPage: Int = 40) async throws -> [WorkflowRunSummary] {
    struct Response: Decodable { let workflow_runs: [WorkflowRunSummary] }
    let data = try await send(listWorkflowRunsRequest(perPage: perPage))
    return try Self.actionsDecoder().decode(Response.self, from: data).workflow_runs
  }

  public func listJobs(runId: Int) async throws -> [WorkflowJob] {
    struct Response: Decodable { let jobs: [WorkflowJob] }
    let data = try await send(listJobsRequest(runId: runId))
    return try Self.actionsDecoder().decode(Response.self, from: data).jobs
  }

  /// Download a finished job's log as text. The endpoint 302s to a short-lived
  /// signed blob URL that needs NO auth, so we follow the redirect with a session
  /// that strips the `Authorization` header on a cross-host hop — the GitHub token
  /// must never leak to the storage host (belt-and-suspenders even if URLSession
  /// already strips it). The endpoint 404s while the job is in-progress and after
  /// GitHub's retention window expires — callers handle the throw as "unavailable".
  public func fetchJobLog(jobId: Int) async throws -> String {
    let session = URLSession(
      configuration: .ephemeral, delegate: RedirectAuthStripper(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: jobLogsRequest(jobId: jobId))
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  /// Every job across recent workflow runs created at/after `since` (minus a
  /// margin for clock skew + queue time), newest run first, bounded to `maxRuns`.
  /// The shared sweep behind `findJob` (single runner) and the History pane's
  /// batch back-fill (many runners, one sweep). Best-effort: a failed page is
  /// skipped, a total failure returns nil.
  ///
  /// The window is deliberately generous (30 min / 30 runs): a *re-run* of a
  /// failed job starts well after the original agent came up, and other runs may
  /// have been triggered in between — a tight window would push the run out of the
  /// scanned set and the lookup would miss (the "No matching job found" bug).
  public func recentJobs(since: Date, maxRuns: Int = 30) async -> [WorkflowJob]? {
    guard let runs = try? await listRecentWorkflowRuns(perPage: 40) else { return nil }
    let earliest = since.addingTimeInterval(-1800)  // 30 min slack: covers re-run attempts + skew
    let candidates =
      runs
      .filter { ($0.createdAt ?? .distantPast) >= earliest }
      .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
      .prefix(maxRuns)
    var all: [WorkflowJob] = []
    for run in candidates {
      if let jobs = try? await listJobs(runId: run.id) { all.append(contentsOf: jobs) }
    }
    return all
  }

  /// Pick the job our ephemeral runner ran from a set of jobs. The `mactions-…`
  /// runner name is unique per registration, so a name match is definitive; when a
  /// run has multiple attempts indexed under it (a re-run reuses the run id and
  /// bumps `run_attempt`, and `filter=all` returns every attempt), prefer the
  /// newest by `startedAt` so a re-run resolves to attempt 2, not attempt 1.
  public static func pickJob(_ jobs: [WorkflowJob], runnerName: String) -> WorkflowJob? {
    jobs
      .filter { $0.runnerName == runnerName }
      .max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
  }

  /// Find the single job our ephemeral runner ran, by matching the unique runner
  /// name across recent workflow runs. Returns nil if not found (job not yet
  /// visible, run too old to be in the recent window, etc.).
  public func findJob(runnerName: String, since: Date, maxRuns: Int = 30) async -> WorkflowJob? {
    Self.pickJob(await recentJobs(since: since, maxRuns: maxRuns) ?? [], runnerName: runnerName)
  }

  @discardableResult
  private func send(_ request: URLRequest, allowEmpty: Bool = false) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }
    return data
  }
}
