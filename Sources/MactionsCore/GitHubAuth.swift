import Foundation

/// GitHub sign-in for a desktop app, done the friendly way: the OAuth
/// **device flow**. We show the user a short code, they open github.com in
/// their browser, paste it, and approve. No embedded secret, no redirect
/// server, no copying long tokens by hand. A paste-a-PAT path also exists for
/// users who'd rather (see `TokenStore`).
///
/// Device flow needs a registered OAuth App **client id** (not a secret —
/// device flow has no client secret). Register one at
/// github.com → Settings → Developer settings → OAuth Apps, tick
/// "Enable Device Flow", and drop the client id into Settings. Until then the
/// app falls back to the PAT field.
public enum GitHubAuth {
  public static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
  public static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!
  /// Repo-admin scope: required to register/remove self-hosted runners on a repo.
  public static let defaultScope = "repo"

  public struct DeviceCode: Decodable, Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
      case deviceCode = "device_code"
      case userCode = "user_code"
      case verificationURI = "verification_uri"
      case expiresIn = "expires_in"
      case interval
    }
  }

  public enum AuthError: Error, Equatable, CustomStringConvertible {
    case noClientId
    case denied
    case expired
    case server(String)
    case http(Int)

    public var description: String {
      switch self {
      case .noClientId: return "No OAuth client id configured. Add one in Settings, or paste a token."
      case .denied: return "Sign-in was denied in the browser."
      case .expired: return "The code expired before it was approved. Try again."
      case let .server(msg): return "GitHub said: \(msg)"
      case let .http(code): return "GitHub returned HTTP \(code)."
      }
    }
  }

  // MARK: Request builders (pure → unit-testable without the network)

  public static func deviceCodeRequest(clientId: String, scope: String = defaultScope) -> URLRequest {
    jsonPOST(deviceCodeURL, ["client_id": clientId, "scope": scope])
  }

  public static func accessTokenRequest(clientId: String, deviceCode: String) -> URLRequest {
    jsonPOST(accessTokenURL, [
      "client_id": clientId,
      "device_code": deviceCode,
      "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
    ])
  }

  private static func jsonPOST(_ url: URL, _ body: [String: String]) -> URLRequest {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    return req
  }

  // MARK: Flow

  /// Step 1: ask GitHub for a device + user code.
  public static func requestDeviceCode(
    clientId: String,
    scope: String = defaultScope,
    session: URLSession = .shared
  ) async throws -> DeviceCode {
    guard !clientId.isEmpty else { throw AuthError.noClientId }
    let (data, response) = try await session.data(for: deviceCodeRequest(clientId: clientId, scope: scope))
    try checkHTTP(response)
    return try JSONDecoder().decode(DeviceCode.self, from: data)
  }

  /// Step 2: poll until the user approves (or it expires / is denied),
  /// respecting GitHub's `interval` and `slow_down` backoff. Returns the token.
  public static func pollForToken(
    clientId: String,
    deviceCode: DeviceCode,
    session: URLSession = .shared,
    sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
  ) async throws -> String {
    var interval = UInt64(max(deviceCode.interval, 1))
    while true {
      try await sleep(interval * 1_000_000_000)
      let (data, response) = try await session.data(for: accessTokenRequest(clientId: clientId, deviceCode: deviceCode.deviceCode))
      try checkHTTP(response)
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      if let token = json["access_token"] as? String { return token }
      switch json["error"] as? String {
      case "authorization_pending": continue
      case "slow_down": interval += 5
      case "expired_token": throw AuthError.expired
      case "access_denied": throw AuthError.denied
      case let other?: throw AuthError.server(other)
      case nil: throw AuthError.server("unexpected response")
      }
    }
  }

  private static func checkHTTP(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else { throw AuthError.http(http.statusCode) }
  }
}

/// Where the GitHub token lives.
///
/// File-based (a `0600` file under Application Support), NOT the login
/// keychain — on purpose. An unsigned/dev build has no stable code identity,
/// so the keychain re-prompts on every read and "Always Allow" won't stick,
/// and those modal prompts even steal focus from the menubar popover (which
/// cancels in-flight requests). A `0600` file avoids all of that — the same
/// choice a sibling app makes. Cached in memory so we touch disk at most once.
///
/// A signed/notarized build could move this back to the keychain; see
/// AGENTS.md → Roadmap.
public enum TokenStore {
  private static let lock = NSLock()
  // nil = not loaded yet; .some(nil) = loaded, no token present. Every access is
  // serialized by `lock`, so this is safe despite being mutable global state —
  // `nonisolated(unsafe)` tells the Swift 6 compiler we synchronize it ourselves.
  nonisolated(unsafe) private static var cached: String??

  private static func tokenURL() -> URL {
    HostCleanup.mactionsRoot().appendingPathComponent("auth.token")
  }

  public static func save(_ token: String) throws {
    let dir = HostCleanup.mactionsRoot()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = tokenURL()
    try token.write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    lock.lock(); cached = .some(token); lock.unlock()
  }

  public static func load() -> String? {
    lock.lock()
    if let cached { lock.unlock(); return cached }
    lock.unlock()
    let raw = try? String(contentsOf: tokenURL(), encoding: .utf8)
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = (trimmed?.isEmpty == false) ? trimmed : nil
    lock.lock(); cached = .some(value); lock.unlock()
    return value
  }

  public static func clear() throws {
    lock.lock(); cached = .some(nil); lock.unlock()
    try? FileManager.default.removeItem(at: tokenURL())
  }
}
