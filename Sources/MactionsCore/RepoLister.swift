import Foundation

/// A repository the user can target. Identity is `owner/name` only — `isPrivate`
/// is display metadata and deliberately excluded from equality/hashing so a
/// selection persisted as a bare `owner/name` still matches the fetched repo
/// once we know its visibility.
public struct RepoRef: Identifiable, Sendable, Codable {
  public let owner: String
  public let name: String
  public let isPrivate: Bool

  public init(owner: String, name: String, isPrivate: Bool = false) {
    self.owner = owner
    self.name = name
    self.isPrivate = isPrivate
  }

  public var fullName: String { "\(owner)/\(name)" }
  public var id: String { fullName }

  /// Reconstruct from a persisted "owner/name" string.
  public init?(fullName: String) {
    let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    self.init(owner: parts[0], name: parts[1])
  }
}

extension RepoRef: Hashable {
  public static func == (lhs: RepoRef, rhs: RepoRef) -> Bool {
    lhs.owner == rhs.owner && lhs.name == rhs.name
  }
  public func hash(into hasher: inout Hasher) {
    hasher.combine(owner)
    hasher.combine(name)
  }
}

/// Lists the repositories a signed-in user can **administer** — the set we can
/// register self-hosted runners on. Backs the searchable repo picker.
public struct GitHubRepoLister {
  public let token: String
  public var apiBase = URL(string: "https://api.github.com")!
  // Bounded-timeout session (see GitHubClient.boundedSession): a hung repo-list
  // request must not be able to freeze the discovery loop that awaits it.
  public var session: URLSession = GitHubClient.boundedSession

  public init(token: String) { self.token = token }

  public func reposRequest(page: Int) -> URLRequest {
    var components = URLComponents(
      url: apiBase.appendingPathComponent("user/repos"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "per_page", value: "100"),
      URLQueryItem(name: "page", value: String(page)),
      URLQueryItem(name: "sort", value: "pushed"),
      URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
    ]
    var req = URLRequest(url: components.url!)
    req.httpMethod = "GET"
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return req
  }

  private struct APIRepo: Decodable {
    struct Owner: Decodable { let login: String }
    struct Permissions: Decodable { let admin: Bool }
    let name: String
    let owner: Owner
    let isPrivate: Bool
    let permissions: Permissions?
    enum CodingKeys: String, CodingKey {
      case name, owner, permissions
      case isPrivate = "private"
    }
  }

  /// Parse one `/user/repos` page into admin-capable repos. Exposed for tests.
  public static func decodeAdminRepos(_ data: Data) throws -> [RepoRef] {
    try JSONDecoder().decode([APIRepo].self, from: data)
      .filter { $0.permissions?.admin == true }
      .map { RepoRef(owner: $0.owner.login, name: $0.name, isPrivate: $0.isPrivate) }
  }

  /// All admin-capable repos, most-recently-pushed first, de-duplicated.
  /// Paginated and capped at `maxPages` (×100) to bound the call.
  public func listAdminRepos(maxPages: Int = 5) async throws -> [RepoRef] {
    var all: [RepoRef] = []
    for page in 1...maxPages {
      let (data, response) = try await session.data(for: reposRequest(page: page))
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw GitHubClient.ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
      }
      let pageRepos = try JSONDecoder().decode([APIRepo].self, from: data)
      all.append(
        contentsOf: pageRepos
          .filter { $0.permissions?.admin == true }
          .map { RepoRef(owner: $0.owner.login, name: $0.name, isPrivate: $0.isPrivate) })
      if pageRepos.count < 100 { break } // last page
    }
    var seen = Set<RepoRef>()
    return all.filter { seen.insert($0).inserted }
  }
}
