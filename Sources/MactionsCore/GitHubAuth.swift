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

/// Where the GitHub token lives. Keychain-backed; same surface whether the
/// token came from the device flow or a pasted PAT.
public enum TokenStore {
  private static let account = "github-token"

  public static func save(_ token: String) throws { try Keychain.set(token, for: account) }
  public static func load() -> String? { Keychain.get(account) }
  public static func clear() throws { try Keychain.remove(account) }
}
