import CryptoKit
import Foundation

/// Downloads + extracts the GitHub Actions runner agent so `LocalProcessProvider`
/// has a `run.sh` to launch. Idempotent: if the agent is already extracted in
/// Application Support, it's reused. Picks the asset for the host arch.
public enum RunnerInstaller {
  public enum InstallError: Error, CustomStringConvertible {
    case noAsset(String)
    case extractionFailed(String)
    case digestMismatch(expected: String, got: String)
    public var description: String {
      switch self {
      case let .noAsset(v): return "No runner asset for this arch (version \(v))."
      case let .extractionFailed(e): return "Failed to extract runner: \(e)"
      case let .digestMismatch(expected, got):
        return "Runner download failed its SHA-256 integrity check "
          + "(expected \(expected), got \(got))."
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
    let latest = try? await latestRunnerRelease(token: token, session: session)
    guard let release = latest else {
      if installed != nil { return dir }
      throw InstallError.noAsset("unknown (couldn't reach GitHub to resolve the runner version)")
    }
    let version = release.version // e.g. "2.319.1"
    if installed == version { return dir } // up to date — reuse the template

    let asset = "actions-runner-osx-\(arch)-\(version).tar.gz"
    let url = URL(string: "https://github.com/actions/runner/releases/download/v\(version)/\(asset)")!

    let (tmp, response) = try await session.download(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw InstallError.noAsset("\(version) (HTTP \(http.statusCode))")
    }

    // Integrity gate: this agent is extracted and RUN on the host with no
    // sandbox, so verify the download against GitHub's published SHA-256 before
    // trusting it. The digest comes from the api.github.com release metadata — a
    // separate TLS-protected response from the github.com asset download — so a
    // tampered or swapped tarball won't match. (If the API omits a sha256 digest
    // we proceed rather than hard-fail on a metadata-shape change; in practice
    // GitHub always provides it.)
    try verifyDownload(at: tmp, expectedDigest: release.assetDigests[asset])

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

  /// The latest runner release: its version plus GitHub's published per-asset
  /// SHA-256 digests (asset name → "sha256:…"), used to integrity-check the
  /// download before it's extracted and run on the host.
  struct RunnerRelease {
    let version: String
    let assetDigests: [String: String]
  }

  static func latestRunnerRelease(token: String?, session: URLSession) async throws -> RunnerRelease {
    struct Asset: Decodable { let name: String; let digest: String? }
    struct Release: Decodable { let tag_name: String; let assets: [Asset] }
    var req = URLRequest(url: URL(string: "https://api.github.com/repos/actions/runner/releases/latest")!)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, _) = try await session.data(for: req)
    let release = try JSONDecoder().decode(Release.self, from: data)
    // tag is like "v2.319.1" → strip the leading "v".
    let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
    var digests: [String: String] = [:]
    for asset in release.assets {
      if let digest = asset.digest { digests[asset.name] = digest }
    }
    return RunnerRelease(version: version, assetDigests: digests)
  }

  /// Verify a downloaded file against GitHub's published `sha256:…` asset digest.
  /// No-op when no sha256 digest is available (older API responses); throws
  /// `InstallError.digestMismatch` when a digest is present and does not match.
  static func verifyDownload(at file: URL, expectedDigest: String?) throws {
    guard let expectedDigest, expectedDigest.hasPrefix("sha256:") else { return }
    let want = String(expectedDigest.dropFirst("sha256:".count)).lowercased()
    guard !want.isEmpty else { return }
    let data = try Data(contentsOf: file, options: .mappedIfSafe)
    let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard got == want else {
      throw InstallError.digestMismatch(expected: want, got: got)
    }
  }
}
