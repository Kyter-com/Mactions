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

  @discardableResult
  private func send(_ request: URLRequest, allowEmpty: Bool = false) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }
    return data
  }
}
