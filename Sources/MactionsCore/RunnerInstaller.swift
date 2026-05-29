import Foundation

/// Downloads + extracts the GitHub Actions runner agent so `LocalProcessProvider`
/// has a `run.sh` to launch. Idempotent: if the agent is already extracted in
/// Application Support, it's reused. Picks the asset for the host arch.
public enum RunnerInstaller {
  public enum InstallError: Error, CustomStringConvertible {
    case noAsset(String)
    case extractionFailed(String)
    public var description: String {
      switch self {
      case let .noAsset(v): return "No runner asset for this arch (version \(v))."
      case let .extractionFailed(e): return "Failed to extract runner: \(e)"
      }
    }
  }

  /// Where the cached agent template lives (runs are cloned from it).
  public static func installDirectory() -> URL {
    HostCleanup.agentTemplateDirectory()
  }

  static var arch: String {
    #if arch(arm64)
    return "arm64"
    #else
    return "x64"
    #endif
  }

  /// Ensure the agent is present; returns its directory. Downloads the latest
  /// release on first use. Pass a token to avoid the unauthenticated API rate
  /// limit when resolving the latest version.
  public static func ensureInstalled(
    token: String? = nil,
    session: URLSession = .shared
  ) async throws -> URL {
    let dir = installDirectory()
    let runSh = dir.appendingPathComponent("run.sh")
    let versionFile = dir.appendingPathComponent(".version")
    let installed =
      FileManager.default.isExecutableFile(atPath: runSh.path)
      ? (try? String(contentsOf: versionFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      : nil

    // Resolve the latest version (cheap, one API call). Refreshing the cached
    // TEMPLATE when GitHub ships a new runner is what stops every ephemeral run
    // from re-paying the agent self-update (the clones inherit a current agent).
    // If we can't reach GitHub but already have an install, use it; otherwise
    // there's nothing to run with.
    let latest = try? await latestRunnerVersion(token: token, session: session) // e.g. "2.319.1"
    guard let version = latest else {
      if installed != nil { return dir }
      throw InstallError.noAsset("unknown (couldn't reach GitHub to resolve the runner version)")
    }
    if installed == version { return dir } // up to date — reuse the template

    let asset = "actions-runner-osx-\(arch)-\(version).tar.gz"
    let url = URL(string: "https://github.com/actions/runner/releases/download/v\(version)/\(asset)")!

    let (tmp, response) = try await session.download(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw InstallError.noAsset("\(version) (HTTP \(http.statusCode))")
    }

    // Fresh dir so a version bump never mixes old + new agent files.
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tarball = dir.appendingPathComponent(asset)
    try FileManager.default.moveItem(at: tmp, to: tarball)

    let result = try Shell.run("/usr/bin/tar", ["xzf", tarball.path, "-C", dir.path])
    guard result.ok else { throw InstallError.extractionFailed(result.stderr) }
    try? FileManager.default.removeItem(at: tarball)
    try? version.write(to: versionFile, atomically: true, encoding: .utf8)
    return dir
  }

  static func latestRunnerVersion(token: String?, session: URLSession) async throws -> String {
    struct Release: Decodable { let tag_name: String }
    var req = URLRequest(url: URL(string: "https://api.github.com/repos/actions/runner/releases/latest")!)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, _) = try await session.data(for: req)
    let release = try JSONDecoder().decode(Release.self, from: data)
    // tag is like "v2.319.1" → strip the leading "v".
    return release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
  }
}
