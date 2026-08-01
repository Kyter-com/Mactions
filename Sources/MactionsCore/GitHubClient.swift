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
  public let status: String  // "online" | "offline"
  public let busy: Bool
}

/// Drops the `Authorization` header when a request is redirected to a different
/// host. Used for the job-log download, whose 302 points at a pre-signed blob URL
/// that needs no auth — so the GitHub token never travels to the storage host.
private final class RedirectAuthStripper: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
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
/// the job our ephemeral runner executed (we scan by latest activity time).
/// `updatedAt` matters for the queued-jobs poll: a RE-RUN keeps the original
/// `created_at` and bumps `updated_at` when its jobs re-queue, so freshness
/// filters must key on the latest of the two.
public struct WorkflowRunSummary: Decodable, Sendable, Equatable {
  public let id: Int
  public let createdAt: Date?
  public let updatedAt: Date?
  public let status: String?

  enum CodingKeys: String, CodingKey {
    case id
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case status
  }

  /// A re-run keeps the original `created_at` and advances `updated_at`, so the
  /// latest of the two is the only safe timestamp for freshness and ordering.
  public var latestActivityAt: Date {
    max(createdAt ?? .distantPast, updatedAt ?? .distantPast)
  }

  /// Whether the workflow run's observable lifetime overlaps a runner lifetime.
  /// A workflow may begin before our job and remain in progress for hours after
  /// our ephemeral runner exits because matrix/sibling jobs are still running.
  /// Requiring only `updatedAt` to land inside the runner window would exclude it.
  public func overlapsActivityWindow(from earliest: Date, through latest: Date) -> Bool {
    let began = createdAt ?? updatedAt ?? .distantFuture
    let lastActivity = updatedAt ?? createdAt ?? .distantPast
    return began <= latest && lastActivity >= earliest
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
  /// The job's `runs-on` label set — what decides which runner it can route to
  /// (job labels must all be present on the runner). Optional only for decoding
  /// safety; GitHub always sends it.
  public let labels: [String]?
  public let runnerName: String?
  public let runnerId: Int?
  public let htmlURL: String?
  public let startedAt: Date?
  public let completedAt: Date?
  public let steps: [WorkflowStep]?

  enum CodingKeys: String, CodingKey {
    case id, name, status, conclusion, steps, labels
    case runId = "run_id"
    case runnerName = "runner_name"
    case runnerId = "runner_id"
    case htmlURL = "html_url"
    case startedAt = "started_at"
    case completedAt = "completed_at"
  }
}

/// GitHub's routing rule for `runs-on`: labels are cumulative, so a job can run
/// on a runner iff EVERY job label is present on the runner (extra runner
/// labels are fine). Matching is case-insensitive, like GitHub's. An empty job
/// label set never routes to a self-hosted runner.
public func jobLabelsMatchRunner(job: [String], runner: [String]) -> Bool {
  guard !job.isEmpty else { return false }
  let runnerSet = Set(runner.map { $0.lowercased() })
  return job.allSatisfy { runnerSet.contains($0.lowercased()) }
}

/// Thread-safe ETag store for the polled GET endpoints. A 304 response is FREE
/// against the primary rate limit (GitHub docs; verified live 2026-06-10), so
/// the queued-jobs poll attaches `If-None-Match` and replays the cached body on
/// 304 — an idle fleet polls at effectively zero quota cost.
final class ETagStore: @unchecked Sendable {
  private struct Entry {
    let etag: String
    let body: Data
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var recency: [String] = []
  private var storedBytes = 0
  private let maxEntries = 64
  private let maxBytes = 4 * 1024 * 1024

  func entry(for key: String) -> (etag: String, body: Data)? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[key] else { return nil }
    recency.removeAll { $0 == key }
    recency.append(key)
    return (entry.etag, entry.body)
  }

  func set(etag: String, body: Data, for key: String) {
    lock.lock()
    defer { lock.unlock() }
    if let old = entries.removeValue(forKey: key) { storedBytes -= old.body.count }
    recency.removeAll { $0 == key }
    guard body.count <= maxBytes else { return }
    while !recency.isEmpty
      && (entries.count >= maxEntries || storedBytes + body.count > maxBytes)
    {
      let evicted = recency.removeFirst()
      if let old = entries.removeValue(forKey: evicted) { storedBytes -= old.body.count }
    }
    entries[key] = Entry(etag: etag, body: body)
    recency.append(key)
    storedBytes += body.count
  }
}

/// The slice of the GitHub Actions API the orchestrator needs. A protocol so
/// tests can drive the orchestrator with a fake (no network).
public protocol RunnerControlPlane: Sendable {
  func generateJITConfig(name: String, labels: [String]) async throws -> JITConfig
  func listRunners() async throws -> [RemoteRunner]
  func deleteRunner(id: Int) async throws
  /// The label sets of every job currently QUEUED in this repo — the demand
  /// signal for scale-from-zero. Throws on any fetch failure so the caller can
  /// HOLD fleet state rather than mistake a transient error for an empty queue.
  func listQueuedJobLabels() async throws -> [[String]]
}

/// Talks to `api.github.com` for a single `owner/repo`. Repo-level runners,
/// authenticated with the stored token (needs repo-admin / `repo` scope).
public struct GitHubClient: RunnerControlPlane {
  public let owner: String
  public let repo: String
  public let token: String
  public var apiBase = URL(string: "https://api.github.com")!
  public var session: URLSession = GitHubClient.boundedSession
  /// Shared across copies of this struct (it's a reference): the queued-jobs
  /// poll reuses one store per client so idle 304s stay free all session.
  let etags = ETagStore()

  /// Default session for all GitHub API traffic. CRUCIAL: it caps
  /// `timeoutIntervalForResource` — `URLSession.shared`'s default is 7 DAYS, so
  /// a single wedged connection could hang a request, and thus the SINGLE SERIAL
  /// discovery loop that awaits it, for hours (root of the 2026-06-21 all-OS
  /// provisioning stall). A per-request `URLRequest.timeoutInterval` only bounds
  /// IDLE time between packets, not total resource time, so it can't prevent
  /// that on its own. Reused (sessions are meant to be long-lived); the
  /// injectable `session` lets tests substitute a fake.
  public static let boundedSession: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 30
    cfg.timeoutIntervalForResource = 60
    return URLSession(configuration: cfg)
  }()

  public init(owner: String, repo: String, token: String) {
    self.owner = owner
    self.repo = repo
    self.token = token
  }

  public enum ClientError: Error, CustomStringConvertible, LocalizedError {
    case http(Int, String)
    public var description: String {
      switch self {
      case .http(let code, let body):
        return "GitHub API HTTP \(code): \(body.prefix(300))"
      }
    }

    public var errorDescription: String? { description }
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

  public func jitConfigRequest(name: String, labels: [String], runnerGroupId: Int = 1) throws
    -> URLRequest
  {
    var req = base("repos/\(owner)/\(repo)/actions/runners/generate-jitconfig", method: "POST")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode(
      JITBody(name: name, runner_group_id: runnerGroupId, labels: labels, work_folder: "_work")
    )
    return req
  }

  public func listRunnersRequest(perPage: Int = 100, page: Int? = nil) -> URLRequest {
    var components = URLComponents(
      url: apiBase.appendingPathComponent("repos/\(owner)/\(repo)/actions/runners"),
      resolvingAgainstBaseURL: false
    )!
    var items = [URLQueryItem(name: "per_page", value: String(perPage))]
    if let page { items.append(URLQueryItem(name: "page", value: String(page))) }
    components.queryItems = items
    var req = request(url: components.url!, method: "GET")
    // Busy-ness drives trim/refresh decisions — a URLCache-stale `busy=false`
    // could reap a runner that just took a job. Always hit the network.
    req.cachePolicy = .reloadIgnoringLocalCacheData
    return req
  }

  public func deleteRunnerRequest(id: Int) -> URLRequest {
    base("repos/\(owner)/\(repo)/actions/runners/\(id)", method: "DELETE")
  }

  // MARK: Calls

  public func generateJITConfig(name: String, labels: [String]) async throws -> JITConfig {
    struct Response: Decodable {
      struct Runner: Decodable {
        let id: Int
        let name: String
      }
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
    struct Response: Decodable {
      let total_count: Int
      let runners: [RemoteRunner]
    }
    let perPage = 100
    var page = 1
    var all: [RemoteRunner] = []
    while true {
      let data = try await send(
        listRunnersRequest(perPage: perPage, page: page == 1 ? nil : page),
        etagKey: "runners?page=\(page)")
      let decoded = try JSONDecoder().decode(Response.self, from: data)
      all.append(contentsOf: decoded.runners)
      guard all.count < decoded.total_count, !decoded.runners.isEmpty else { break }
      page += 1
    }
    return all
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

  /// `status` filters at the RUN level (`queued` / `in_progress` / …). NOTE
  /// (verified live 2026-06-10): run-level status is NOT a reliable queued-jobs
  /// signal on its own — an `in_progress` run can still contain individually
  /// queued jobs, and run status flaps — which is why `listQueuedJobLabels`
  /// fetches BOTH states and filters on job-level status. Status-filtered
  /// requests bypass URLCache so our explicit ETag handling is deterministic.
  public func listWorkflowRunsRequest(
    perPage: Int = 40, status: String? = nil, page: Int? = nil
  ) -> URLRequest {
    var components = URLComponents(
      url: apiBase.appendingPathComponent("repos/\(owner)/\(repo)/actions/runs"),
      resolvingAgainstBaseURL: false)!
    var items = [URLQueryItem(name: "per_page", value: String(perPage))]
    if let status { items.append(URLQueryItem(name: "status", value: status)) }
    if let page { items.append(URLQueryItem(name: "page", value: String(page))) }
    components.queryItems = items
    var req = request(url: components.url!, method: "GET")
    req.timeoutInterval = 20  // bound each call so a slow network can't stall findJob's loop
    // GitHub serves Actions state with `Cache-Control: private, max-age=60`.
    // These endpoints drive 4-second live refreshes, so URLCache would make the
    // checklist appear frozen for a minute. Explicit ETags provide the caching
    // we want on polling paths; one-shot history lookups should also be fresh.
    req.cachePolicy = .reloadIgnoringLocalCacheData
    return req
  }

  public func listJobsRequest(runId: Int, perPage: Int = 100, page: Int? = nil) -> URLRequest {
    var components = URLComponents(
      url: apiBase.appendingPathComponent("repos/\(owner)/\(repo)/actions/runs/\(runId)/jobs"),
      resolvingAgainstBaseURL: false)!
    var items = [
      URLQueryItem(name: "per_page", value: String(perPage)),
      URLQueryItem(name: "filter", value: "all"),
    ]
    if let page { items.append(URLQueryItem(name: "page", value: String(page))) }
    components.queryItems = items
    var req = request(url: components.url!, method: "GET")
    req.timeoutInterval = 20
    req.cachePolicy = .reloadIgnoringLocalCacheData
    return req
  }

  /// Direct lookup used after runner-name correlation has found the stable job
  /// id. This returns the same step checklist without rediscovering the job by
  /// scanning recent workflow runs on every UI tick.
  public func jobRequest(jobId: Int) -> URLRequest {
    var req = base("repos/\(owner)/\(repo)/actions/jobs/\(jobId)", method: "GET")
    req.timeoutInterval = 20
    req.cachePolicy = .reloadIgnoringLocalCacheData
    return req
  }

  public func jobLogsRequest(jobId: Int) -> URLRequest {
    // 302s to a short-lived signed URL whose body is the plaintext log; URLSession
    // follows the redirect by default, so `send` returns the log bytes directly.
    base("repos/\(owner)/\(repo)/actions/jobs/\(jobId)/logs", method: "GET")
  }

  public func listRecentWorkflowRuns(
    perPage: Int = 40, status: String? = nil, page: Int? = nil,
    etagged: Bool = false
  ) async throws
    -> [WorkflowRunSummary]
  {
    struct Response: Decodable { let workflow_runs: [WorkflowRunSummary] }
    let data = try await send(
      listWorkflowRunsRequest(perPage: perPage, status: status, page: page),
      etagKey: etagged || status != nil
        ? "runs?per_page=\(perPage)&status=\(status ?? "all")&page=\(page ?? 1)" : nil)
    return try Self.actionsDecoder().decode(Response.self, from: data).workflow_runs
  }

  /// The label sets of every job currently QUEUED in this repo.
  ///
  /// Job-level status is the only reliable signal (verified live 2026-06-10
  /// against the real API): a run whose overall status is `in_progress` can
  /// still contain individually queued jobs (matrix legs, `needs:` chains), and
  /// run-level status flaps in both directions — so we list jobs for runs in
  /// BOTH states and keep only `job.status == "queued"`.
  ///
  /// Freshness filter: runs whose LATEST activity (`max(created, updated)`) is
  /// older than 25 h are skipped — GitHub fails any job queued > 24 h, so they
  /// are zombies (observed live: months-old runs stuck in the queued listing).
  /// Keying on `updated_at` too is what keeps RE-RUNS visible: a re-run reuses
  /// the run id and original `created_at`, but re-queuing its jobs bumps
  /// `updated_at`.
  ///
  /// Bounds (deliberate, laptop-scale): one page of 100 runs per state, and
  /// jobs fetched for at most the 30 freshest active runs (each costs one
  /// request; ETags make unchanged re-polls free). A backlog deeper than that
  /// is beyond what one Mac serves anyway — the next tick catches up.
  ///
  /// THROWS on any fetch failure — the orchestrator HOLDS the fleet on a failed
  /// poll, because a transient API error must not read as "queue is empty" and
  /// scale a fleet to zero out from under pending work.
  public func listQueuedJobLabels() async throws -> [[String]] {
    var runs: [WorkflowRunSummary] = []
    runs += try await listRecentWorkflowRuns(perPage: 100, status: "queued")
    runs += try await listRecentWorkflowRuns(perPage: 100, status: "in_progress")
    let earliest = Date().addingTimeInterval(-25 * 3600)
    var seen = Set<Int>()
    let active =
      runs
      .filter { run in
        run.latestActivityAt >= earliest
          && seen.insert(run.id).inserted
      }
      .sorted { $0.latestActivityAt > $1.latestActivityAt }
    var labelSets: [[String]] = []
    for run in active.prefix(30) {
      for job in try await listJobs(runId: run.id, etagged: true) where job.status == "queued" {
        labelSets.append(job.labels ?? [])
      }
    }
    return labelSets
  }

  /// `etagged` opts the call into the conditional-request store — used by queue
  /// detection and the live dashboard, where most responses are unchanged and a
  /// 304 keeps the request off the primary rate limit. Mutable Actions endpoints
  /// always bypass URLCache because GitHub's 60-second max-age is too stale for
  /// either demand decisions or a 4-second step checklist.
  public func listJobs(runId: Int, etagged: Bool = false) async throws -> [WorkflowJob] {
    struct Response: Decodable {
      let total_count: Int?
      let jobs: [WorkflowJob]
    }
    let perPage = 100
    var page = 1
    var all: [WorkflowJob] = []
    while true {
      let data = try await send(
        listJobsRequest(runId: runId, perPage: perPage, page: page == 1 ? nil : page),
        etagKey: etagged ? "jobs/\(runId)?page=\(page)" : nil)
      let decoded = try Self.actionsDecoder().decode(Response.self, from: data)
      all.append(contentsOf: decoded.jobs)
      let hasMore = decoded.total_count.map { all.count < $0 } ?? (decoded.jobs.count == perPage)
      guard hasMore, !decoded.jobs.isEmpty else { break }
      page += 1
    }
    return all
  }

  /// Refresh one already-correlated job, including its current steps. ETagged
  /// polls replay the prior body on a 304, which GitHub does not charge against
  /// the primary rate limit.
  public func getJob(jobId: Int, etagged: Bool = false) async throws -> WorkflowJob {
    let data = try await send(
      jobRequest(jobId: jobId), etagKey: etagged ? "job/\(jobId)" : nil)
    return try Self.actionsDecoder().decode(WorkflowJob.self, from: data)
  }

  /// Download a finished job's log as text. The endpoint 302s to a short-lived
  /// signed blob URL that needs NO auth, so we follow the redirect with a session
  /// that strips the `Authorization` header on a cross-host hop — the GitHub token
  /// must never leak to the storage host (belt-and-suspenders even if URLSession
  /// already strips it). The endpoint 404s while the job is in-progress and after
  /// GitHub's retention window expires — callers handle the throw as "unavailable".
  public func fetchJobLog(jobId: Int) async throws -> String {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    let session = URLSession(
      configuration: configuration, delegate: RedirectAuthStripper(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: jobLogsRequest(jobId: jobId))
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  /// Every job across workflow runs active inside the requested runner-lifetime
  /// window (with a margin for queue time / clock skew), newest activity first.
  /// The shared sweep behind `findJob` (single runner) and the History pane's
  /// batch back-fill (many runners, one sweep). Best-effort: a failed page is
  /// skipped, a total failure returns nil.
  ///
  /// The window is deliberately generous, and activity uses
  /// `max(created_at, updated_at)`: a re-run keeps its old creation time but bumps
  /// updated_at, so created_at-only filtering loses valid live/history matches.
  /// Workflow runs are paginated so a persisted history row does not become
  /// unreachable merely because 40 newer runs landed after an app restart.
  public func recentJobs(
    since: Date, until: Date? = nil, maxRuns: Int = 100, maxPages: Int = 10,
    etagged: Bool = false
  ) async -> [WorkflowJob]? {
    let earliest = since.addingTimeInterval(-1800)  // 30 min slack: covers re-run attempts + skew
    let latest = (until ?? Date()).addingTimeInterval(1800)
    var runs: [WorkflowRunSummary] = []
    var fetchedRunsPage = false
    for page in 1...max(1, maxPages) {
      if Task.isCancelled { return nil }
      guard
        let pageRuns = try? await listRecentWorkflowRuns(
          perPage: 100, page: page == 1 ? nil : page, etagged: etagged)
      else { continue }
      if Task.isCancelled { return nil }
      fetchedRunsPage = true
      runs.append(contentsOf: pageRuns)
      if pageRuns.count < 100 { break }
    }
    guard fetchedRunsPage else { return nil }
    var seen = Set<Int>()
    let candidates =
      runs
      .filter {
        $0.overlapsActivityWindow(from: earliest, through: latest)
          && seen.insert($0.id).inserted
      }
      .sorted { $0.latestActivityAt > $1.latestActivityAt }
      .prefix(maxRuns)
    var all: [WorkflowJob] = []
    var fetchedJobsPage = false
    for run in candidates {
      if Task.isCancelled { return nil }
      if let jobs = try? await listJobs(runId: run.id, etagged: etagged) {
        if Task.isCancelled { return nil }
        fetchedJobsPage = true
        all.append(contentsOf: jobs)
      }
    }
    return candidates.isEmpty || fetchedJobsPage ? all : nil
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
  /// name across recent workflow runs. Scans newest-first and EARLY-EXITS on the
  /// first run that contains the runner: the runner name is unique per
  /// registration, so it lives in exactly one run, and `pickJob` picks the newest
  /// attempt within that run (a re-run reuses the run id). Early-exit keeps the
  /// POLLED live-runner lookup cheap — it must not list jobs for every recent run
  /// on each 4-second poll. Returns nil if not found (job not yet visible, run too
  /// old to be in the recent window, etc.).
  ///
  /// THROWS on the top-level runs-list failure (auth / missing `Actions: read`
  /// scope / network) so callers can tell "this token can't read Actions" apart
  /// from a genuine "no matching job" (a `nil` return) — swallowing both as `nil`
  /// is what made a scope problem look like an idle runner. A single run's per-run
  /// jobs fetch failing stays best-effort (skip that run, keep scanning).
  public func findJob(
    runnerName: String, since: Date, until: Date? = nil, maxRuns: Int = 100,
    maxPages: Int = 10, preferActive: Bool = false, etagged: Bool = false
  ) async throws -> WorkflowJob? {
    let earliest = since.addingTimeInterval(-1800)  // 30 min slack: re-run attempts + skew
    let latest = (until ?? Date()).addingTimeInterval(1800)
    var seenRuns = Set<Int>()
    var inspectedRuns = 0
    var attemptedJobsFetch = false
    var fetchedAnyJobsPage = false
    var lastJobsError: Error?

    func inspect(_ runs: [WorkflowRunSummary]) async throws -> WorkflowJob? {
      let candidates =
        runs
        .filter {
          $0.overlapsActivityWindow(from: earliest, through: latest)
            && seenRuns.insert($0.id).inserted
        }
        .sorted { $0.latestActivityAt > $1.latestActivityAt }
      for run in candidates where inspectedRuns < maxRuns {
        inspectedRuns += 1
        attemptedJobsFetch = true
        do {
          let jobs = try await listJobs(runId: run.id, etagged: etagged)
          fetchedAnyJobsPage = true
          if let job = Self.pickJob(jobs, runnerName: runnerName) { return job }
        } catch {
          if error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw error
          }
          // Let the unfiltered fallback retry a run whose status-filtered Jobs
          // request failed transiently instead of deduping away the second chance.
          seenRuns.remove(run.id)
          lastJobsError = error
        }
      }
      return nil
    }

    // A busy runner's job belongs to an active run. Searching those compact
    // lists first avoids walking pages of completed history during indexing lag.
    if preferActive {
      for status in ["in_progress", "queued"] {
        let active = try await listRecentWorkflowRuns(
          perPage: 100, status: status, etagged: etagged)
        if let job = try await inspect(active) { return job }
      }
    }

    for page in 1...max(1, maxPages) where inspectedRuns < maxRuns {
      let runs = try await listRecentWorkflowRuns(
        perPage: 100, page: page == 1 ? nil : page, etagged: etagged)
      if let job = try await inspect(runs) { return job }
      if runs.count < 100 { break }
    }
    // A partial failure remains best-effort, but if every candidate's Jobs API
    // request failed, surface the real error instead of calling it an indexing
    // miss. This is especially important for fine-grained token scope failures.
    if attemptedJobsFetch, !fetchedAnyJobsPage, let lastJobsError {
      throw lastJobsError
    }
    return nil
  }

  /// `etagKey` opts a GET into conditional requests: we attach `If-None-Match`
  /// from the store and replay the cached body on 304 (free against the primary
  /// rate limit). Non-polled calls pass nil and behave exactly as before.
  @discardableResult
  private func send(_ request: URLRequest, allowEmpty: Bool = false, etagKey: String? = nil)
    async throws -> Data
  {
    var request = request
    let cached = etagKey.flatMap { etags.entry(for: $0) }
    if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse {
      if http.statusCode == 304, let cached { return cached.body }
      guard (200..<300).contains(http.statusCode) else {
        throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
      }
      if let etagKey, let etag = http.value(forHTTPHeaderField: "ETag") {
        etags.set(etag: etag, body: data, for: etagKey)
      }
    }
    return data
  }
}
