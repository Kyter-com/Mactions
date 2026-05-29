import Foundation

/// The lowest-friction sign-in for developers: reuse the GitHub CLI's existing
/// login. `gh auth token` returns the token `gh` already holds (typically with
/// `repo` + `workflow` scope, which is enough to manage repo runners), so
/// there's no PAT to copy and no OAuth App to register. No-op if `gh` isn't
/// installed or isn't signed in.
public enum GitHubCLIAuth {
  public enum CLIError: Error, CustomStringConvertible {
    case notInstalled
    case notAuthenticated(String)
    public var description: String {
      switch self {
      case .notInstalled:
        return "GitHub CLI (`gh`) isn't installed. Install it, or paste a token below."
      case let .notAuthenticated(detail):
        let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return "GitHub CLI isn't signed in — run `gh auth login` in Terminal."
          + (d.isEmpty ? "" : " (\(d))")
      }
    }
  }

  public static func isAvailable() -> Bool { Shell.which("gh") != nil }

  /// The token `gh` is currently using. Throws if `gh` is missing or signed out.
  public static func currentToken() throws -> String {
    guard let gh = Shell.which("gh") else { throw CLIError.notInstalled }
    let result = try Shell.run(gh, ["auth", "token"])
    let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.ok, !token.isEmpty else { throw CLIError.notAuthenticated(result.stderr) }
    return token
  }
}
