import Foundation

/// Resolve + compare Windows 11 ARM64 build ids so the app can tell the user (or
/// rebuild) when a newer Windows is out — the **auto-update** half of opt-in
/// Windows support. Mirrors `RunnerInstaller`'s "resolve latest + refresh when
/// newer" pattern: the base image is the one cached/auto-refreshed artifact;
/// per-job clones stay throwaway and are NOT touched here.
///
/// The latest build is resolved via the UUP dump JSON API (the only automatable
/// source for the official Win11 ARM64 media — Microsoft only offers the ISO as
/// a time-limited interactive download, so there's no hard-coded URL). Every
/// network call has a pure request-builder/parser counterpart so it's
/// unit-testable without hitting the network, exactly like `jitConfigRequest`.
public enum WindowsImage {
  /// A Windows build offered by UUP dump (one row of `listid.php`'s response).
  public struct Build: Equatable, Sendable {
    /// e.g. "Feature update to Windows 11, version 24H2 (arm64)".
    public let title: String
    /// e.g. "26100.1742" — the value we compare for "is there a newer one?".
    public let build: String
    /// "arm64" | "amd64" | "x86".
    public let arch: String
    /// UUP dump's update UUID (what the download/convert step keys off).
    public let uuid: String

    public init(title: String, build: String, arch: String, uuid: String) {
      self.title = title
      self.build = build
      self.arch = arch
      self.uuid = uuid
    }
  }

  public enum ImageError: Error, CustomStringConvertible {
    case noBuildFound(String)
    case missingConverterDeps([String])
    public var description: String {
      switch self {
      case let .noBuildFound(q):
        return "No Windows 11 ARM64 build found via UUP dump for query \"\(q)\"."
      case let .missingConverterDeps(missing):
        return
          "Missing ISO-converter dependencies: \(missing.joined(separator: ", ")). "
          + "Install them with: brew install \(missing.joined(separator: " "))"
      }
    }
  }

  // MARK: - UUP dump request builders (pure → unit-testable)

  /// The UUP dump JSON API host. Public so a test/UI can point at a mirror.
  public static let apiBase = URL(string: "https://api.uupdump.net")!

  /// `listid.php` query for Win11 ARM64 builds, newest first. We filter the
  /// response to retail `arm64` rows in `parseBuilds` (the endpoint itself only
  /// takes a free-text `search` + `sortByDate`).
  public static func latestBuildsRequest(search: String = "Windows 11 arm64") -> URLRequest {
    var components = URLComponents(
      url: apiBase.appendingPathComponent("listid.php"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "search", value: search),
      URLQueryItem(name: "sortByDate", value: "1"),
    ]
    var req = URLRequest(url: components.url!)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    return req
  }

  /// Parse `listid.php`'s JSON into our `Build` rows, keeping only `arm64`
  /// entries (the endpoint's free-text search can return amd64/x86 too). Order
  /// is preserved — the API returns newest-first when `sortByDate=1`.
  public static func parseBuilds(_ data: Data) -> [Build] {
    struct Row: Decodable {
      let title: String
      let build: String
      let arch: String
      let uuid: String
    }
    struct Response: Decodable {
      struct Inner: Decodable { let builds: [Row]? }
      let response: Inner?
    }
    guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
      let rows = decoded.response?.builds
    else { return [] }
    return
      rows
      .filter { $0.arch.lowercased() == "arm64" }
      .map { Build(title: $0.title, build: $0.build, arch: $0.arch, uuid: $0.uuid) }
  }

  /// Resolve the single latest Win11 ARM64 build (the first arm64 row UUP dump
  /// returns newest-first). Throws `noBuildFound` if the listing is empty.
  public static func latestBuild(
    search: String = "Windows 11 arm64",
    session: URLSession = .shared
  ) async throws -> Build {
    let (data, _) = try await session.data(for: latestBuildsRequest(search: search))
    guard let first = parseBuilds(data).first else {
      throw ImageError.noBuildFound(search)
    }
    return first
  }

  // MARK: - Build-id comparison (pure → unit-testable)

  /// Compare two Windows build strings (e.g. "26100.1742" vs "26100.1") the way
  /// Windows orders them: dotted numeric segments, compared left-to-right as
  /// integers (so "26100.9" < "26100.10", which a string compare gets wrong),
  /// missing trailing segments treated as 0. Returns `.orderedAscending` if
  /// `lhs` is older than `rhs`.
  public static func compareBuilds(_ lhs: String, _ rhs: String) -> ComparisonResult {
    func segments(_ s: String) -> [Int] {
      s.split(separator: ".").map { Int($0) ?? 0 }
    }
    let a = segments(lhs)
    let b = segments(rhs)
    for i in 0..<max(a.count, b.count) {
      let x = i < a.count ? a[i] : 0
      let y = i < b.count ? b[i] : 0
      if x != y { return x < y ? .orderedAscending : .orderedDescending }
    }
    return .orderedSame
  }

  /// True iff `latest` is a strictly newer build than `installed`. The app calls
  /// this with the recorded build of the built base image vs the resolved
  /// latest to decide whether to nudge the user to rebuild. A `nil`/empty
  /// `installed` (no image built yet) is treated as "an update is available".
  public static func updateAvailable(installed: String?, latest: String) -> Bool {
    guard let installed, !installed.trimmingCharacters(in: .whitespaces).isEmpty else {
      return true
    }
    return compareBuilds(installed, latest) == .orderedAscending
  }

  // MARK: - Recorded base-image build (the cached/auto-refreshed artifact)

  /// Where `prepare-windows-image` records the build id it built the base image
  /// from (so we can compare it to the latest available). A sibling of the
  /// mactions root, NOT under `runs/` — it must survive run sweeps.
  public static func baseImageBuildFile() -> URL {
    HostCleanup.mactionsRoot().appendingPathComponent("windows-base.build", isDirectory: false)
  }

  /// The build id the current base image was built from, or `nil` if none has
  /// been recorded (no image built yet).
  public static func recordedBaseImageBuild() -> String? {
    guard let raw = try? String(contentsOf: baseImageBuildFile(), encoding: .utf8) else {
      return nil
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Record the build id a freshly-built base image was made from.
  public static func recordBaseImageBuild(_ build: String) {
    try? FileManager.default.createDirectory(
      at: HostCleanup.mactionsRoot(), withIntermediateDirectories: true)
    try? build.write(to: baseImageBuildFile(), atomically: true, encoding: .utf8)
  }

  // MARK: - ISO-converter dependency check (pure → unit-testable)

  /// CLIs the UUP-dump → ISO conversion needs (all brew-installable). Checked
  /// before kicking off an auto-download so we fail with a clear, actionable
  /// message instead of midway through a multi-GB download.
  ///   - aria2c:    parallel downloader UUP dump's convert scripts use.
  ///   - cabextract: unpacks the .cab payloads.
  ///   - wimlib-imagex: builds/edits the install.wim (the `wimlib` formula).
  ///   - chntpw:    edits the offline registry during conversion.
  public static let converterDependencies = ["aria2c", "cabextract", "wimlib-imagex", "chntpw"]

  /// Brew formula name for a given dependency binary (the binary name and the
  /// formula differ for wimlib-imagex → `wimlib`).
  static func brewFormula(for binary: String) -> String {
    binary == "wimlib-imagex" ? "wimlib" : binary
  }

  /// Which converter deps are NOT installed (resolved via `Shell.which`, which
  /// also checks the Homebrew dirs a Finder-launched GUI app won't have on its
  /// PATH). Empty array == all present.
  public static func missingConverterDependencies(
    lookup: (String) -> Bool = { Shell.which($0) != nil }
  ) -> [String] {
    converterDependencies.filter { !lookup($0) }.map(brewFormula(for:))
  }
}
