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
    /// Unix timestamp the row was published — a deterministic tiebreaker when two
    /// rows share a build number. Optional: a malformed row may omit it.
    public let created: Int?

    public init(title: String, build: String, arch: String, uuid: String, created: Int? = nil) {
      self.title = title
      self.build = build
      self.arch = arch
      self.uuid = uuid
      self.created = created
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
  /// entries (the endpoint's free-text search can return amd64/x86 too).
  ///
  /// IMPORTANT: the live API sends `response.builds` as a JSON OBJECT keyed by
  /// stringified ints (`"1","2","4",…`), NOT an array — decoding it as `[Row]`
  /// silently yields `[]`. Order is therefore UNDEFINED here (a dictionary has
  /// none); callers must SELECT by build number, not trust position. Use
  /// `selectLatestGA` rather than `.first`.
  public static func parseBuilds(_ data: Data) -> [Build] {
    struct Row: Decodable {
      let title: String
      let build: String
      let arch: String
      let uuid: String
      let created: Int?
    }
    struct Response: Decodable {
      struct Inner: Decodable { let builds: [String: Row]? }
      let response: Inner?
    }
    guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
      let dict = decoded.response?.builds
    else { return [] }
    return
      Array(dict.values)
      .filter { $0.arch.lowercased() == "arm64" }
      .map { Build(title: $0.title, build: $0.build, arch: $0.arch, uuid: $0.uuid, created: $0.created) }
  }

  /// Major build prefixes that have actually shipped as **retail GA** Win11
  /// ARM64 media. A title-substring filter alone is unsafe: the not-yet-GA
  /// 26H1/28000 branch carries a GA-style ", version 26H1" title, so we pin to
  /// majors that have really GA'd.
  ///
  /// MAINTENANCE TOUCHPOINT (conflicts with the "no pinned values" preference):
  /// bump when a new HNN label actually GAs. A fully-automated follow-up would
  /// derive this from majors that ALSO appear on a clean retail GA title and
  /// never only via Insider/Preview/.NET rows — see issue tracker.
  public static let knownGAMajors: Set<Int> = [22000, 22621, 22631, 26100, 26200]

  /// Substrings that mark a row as NOT a clean base image even when it carries a
  /// "version" label (Insider, preview, cumulative/security/.NET updates, etc.).
  static let nonBaseTitleSubstrings = [
    "insider", "preview update", "cumulative update", ".net framework",
    "feature update to windows", "oobe update", "security update",
    "update for windows 11 (",
  ]

  /// A `listid.php` row usable as a runner base image: a clean Win11 GA feature
  /// update (e.g. "Windows 11, version 25H2") on a known-GA major prefix. The
  /// newest rows from the API are usually Insider/canary/preview, so this is
  /// what keeps us off prerelease media.
  public static func isGABase(_ b: Build) -> Bool {
    guard b.arch.lowercased() == "arm64" else { return false }
    let title = b.title.lowercased()
    guard title.contains("windows 11, version ") else { return false }
    guard !nonBaseTitleSubstrings.contains(where: { title.contains($0) }) else { return false }
    guard let majorStr = b.build.split(separator: ".").first, let major = Int(majorStr) else {
      return false
    }
    return knownGAMajors.contains(major)
  }

  /// Pick the single latest STABLE GA Win11 ARM64 build from parsed rows:
  /// GA-filter, then the highest build by DOTTED-NUMERIC comparison (never
  /// lexical, never API order), tie-broken by the newest `created` timestamp.
  /// `nil` if no GA row is present (so the caller fails loudly rather than
  /// shipping a preview image).
  public static func selectLatestGA(_ builds: [Build]) -> Build? {
    builds
      .filter(isGABase)
      .max { a, b in
        switch compareBuilds(a.build, b.build) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return (a.created ?? Int.min) < (b.created ?? Int.min)
        }
      }
  }

  /// Resolve the single latest STABLE GA Win11 ARM64 build. Selects by GA filter
  /// + numeric build (NOT `.first` — the API order is mixed-channel and the
  /// dict-decoded rows are unordered). Throws `noBuildFound` if no GA build is
  /// present.
  public static func latestBuild(
    search: String = "Windows 11 arm64",
    session: URLSession = .shared
  ) async throws -> Build {
    let (data, _) = try await session.data(for: latestBuildsRequest(search: search))
    guard let latest = selectLatestGA(parseBuilds(data)) else {
      throw ImageError.noBuildFound(search)
    }
    return latest
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

  // MARK: - Provisioning-recipe version + maintenance state (pure → unit-testable)

  /// Provisioning-recipe version the CURRENT build scripts produce. It tracks
  /// `bootstrap.ps1` (what gets baked into the base): bump it whenever a
  /// bootstrap change makes an ALREADY-BUILT base functionally stale — e.g. the
  /// MinGit→PortableGit switch that added `bash` (PR #19), or adding PowerShell 7
  /// (`pwsh`) to the base. Do NOT bump for comment/whitespace-only edits. This
  /// MUST equal `PROVISIONING_RECIPE_VERSION` in `scripts/prepare-windows-image` —
  /// the authority that gets stamped into `windows-base.recipe` at build time —
  /// and a unit test asserts they match.
  ///
  /// v4: bootstrap.ps1 now VERIFIES git/bash/pwsh are present before writing the
  /// provisioning sentinel (and retries their downloads). v3 bases can be silently
  /// missing those tools — a transient PortableGit download failure was swallowed and
  /// still snapshotted, shipping a base where `actions/checkout` falls back to a REST
  /// tarball and every `shell: bash`/`shell: pwsh` step dies. So v3 bases are
  /// untrustworthy and warrant a rebuild to a verified v4.
  ///
  /// v5: bootstrap.ps1 gains the package picker (`$SelectedPackages` → sections
  /// 0b/0c): opt-in GitHub-hosted-image parity packages — toolcache entries
  /// (node/Python/Go at the versions GitHub's `windows-11-arm` image ships,
  /// installed via their own manifests + embedded setup.ps1, mirroring
  /// `Install-Toolset.ps1`) and global tools (gh, CMake, .NET 8, Temurin Java,
  /// jq+yq). `RUNNER_TOOL_CACHE`/`AGENT_TOOLSDIRECTORY` are set machine-wide
  /// unconditionally (matching GitHub). Selected packages are fatal-on-failure
  /// and verified before the sentinel. Package SELECTION changes are tracked
  /// separately (`windows-base.packages` → `.packagesChanged`), so this version
  /// only bumps when bootstrap's CAPABILITIES change.
  public static let currentProvisioningRecipeVersion = 5

  /// Where `prepare-windows-image` records the provisioning-recipe version the
  /// base was built with. A sibling of `windows-base.build`; must survive run
  /// sweeps (NOT under `runs/`).
  public static func baseImageRecipeFile() -> URL {
    HostCleanup.mactionsRoot().appendingPathComponent("windows-base.recipe", isDirectory: false)
  }

  /// The provisioning-recipe version the current base image was built with, or
  /// `nil` if none was recorded — either no image yet, or a base built by a
  /// Mactions that predates recipe-versioning. Callers treat `nil` as STALE:
  /// those old bases predate the bootstrap changes recipe-versioning exists to
  /// catch (the bash/PortableGit fix), so they genuinely warrant a rebuild.
  public static func recordedRecipeVersion() -> Int? {
    guard let raw = try? String(contentsOf: baseImageRecipeFile(), encoding: .utf8) else {
      return nil
    }
    return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  // MARK: - Base health (informational stamp written by fusion-windows-base)

  /// What we verifiably know about the built base, recorded at build success:
  /// when, how long, that VMware Tools answered (the provisioning sentinel can
  /// ONLY be observed via Tools guest-ops, so a recorded base implies Tools are
  /// installed + working), and where the guest's own `bootstrap.log` was copied
  /// (captured in the ~60s window between sentinel and guest power-off). Purely
  /// informational — never drives maintenance/rebuild decisions (that's
  /// `MaintenanceReason`), just the "what's in my base" summary line in the UI.
  public struct BaseHealth: Equatable, Sendable {
    /// ISO-8601 UTC timestamp the build finished, as recorded (`built=`).
    public var builtAt: String?
    /// Boot → power-off duration in seconds (`elapsed_secs=`).
    public var elapsedSecs: Int?
    /// VMware Tools answered guest-ops during the build (`tools=up`).
    public var toolsUp: Bool
    /// Host path of the copied guest `C:\setup\logs\bootstrap.log` (`guest_log=`),
    /// if the in-window copy landed. Callers should re-check it still exists.
    public var guestLogPath: String?

    public init(
      builtAt: String? = nil, elapsedSecs: Int? = nil, toolsUp: Bool = false,
      guestLogPath: String? = nil
    ) {
      self.builtAt = builtAt
      self.elapsedSecs = elapsedSecs
      self.toolsUp = toolsUp
      self.guestLogPath = guestLogPath
    }
  }

  /// Where `fusion-windows-base` records the health stamp. A sibling of
  /// `windows-base.build`/`.recipe` (must survive run sweeps). Only written on a
  /// VERIFIED build (sentinel + snapshot), and a failed rebuild restores the
  /// prior base without touching it — so it always describes the base on disk.
  public static func baseHealthFile() -> URL {
    HostCleanup.mactionsRoot().appendingPathComponent("windows-base.health", isDirectory: false)
  }

  /// The recorded health of the current base, or `nil` if none was recorded
  /// (no base yet, or one built before health stamping existed — fine, the UI
  /// just omits those details).
  public static func recordedBaseHealth() -> BaseHealth? {
    guard let raw = try? String(contentsOf: baseHealthFile(), encoding: .utf8) else { return nil }
    return parseBaseHealth(raw)
  }

  /// Parse the `key=value`-per-line health file. Pure → unit-testable; unknown
  /// keys are ignored (forward-compatible), `nil` for an empty/garbage file.
  public static func parseBaseHealth(_ raw: String) -> BaseHealth? {
    var kv: [String: String] = [:]
    for line in raw.split(whereSeparator: \.isNewline) {
      guard let eq = line.firstIndex(of: "=") else { continue }
      let key = line[..<eq].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      if !key.isEmpty, !value.isEmpty { kv[key] = value }
    }
    guard !kv.isEmpty else { return nil }
    return BaseHealth(
      builtAt: kv["built"],
      elapsedSecs: kv["elapsed_secs"].flatMap(Int.init),
      toolsUp: kv["tools"] == "up",
      guestLogPath: kv["guest_log"])
  }

  // MARK: - Optional package catalog (the UI picker; baked at base-build time)

  /// One opt-in package the user can bake into the Windows base — the curated
  /// "what GitHub's hosted `windows-11-arm` image has" menu (its
  /// `toolset-win-11-arm64.json` toolcache entries + globally preinstalled
  /// tools). `id` doubles as the wire format: it's what
  /// `MACTIONS_WINDOWS_PACKAGES` carries and what `bootstrap.ps1` dispatches on
  /// (a unit test pins that parity). Anything left unchecked still works in
  /// workflows via `actions/setup-*` / install steps at job time — the base
  /// just stays lean.
  public struct WindowsPackage: Identifiable, Equatable, Sendable {
    /// Which picker section the row belongs to.
    public enum Group: String, Sendable {
      /// Pre-warmed `C:\hostedtoolcache\windows` entries — what `setup-node` /
      /// `-python` / `-go` check before downloading.
      case toolcache
      /// Globally installed CLIs/SDKs (on PATH for every job).
      case tool
    }

    public let id: String
    public let title: String
    /// One-liner for the picker row (what it is / why you'd want it).
    public let detail: String
    /// Honest cost label shown in the row (download + disk are real).
    public let approxSize: String
    public let group: Group
  }

  /// The full menu, mirroring GitHub's hosted `windows-11-arm` image (toolset
  /// JSON + preinstalled tools) as of recipe v5. Order = display order.
  public static let packageCatalog: [WindowsPackage] = [
    // Toolcache (used by actions/setup-node / -python / -go).
    .init(
      id: "node-22", title: "Node.js 22 (arm64)",
      detail: "Pre-warms the toolcache for setup-node.", approxSize: "~60 MB", group: .toolcache),
    .init(
      id: "node-24", title: "Node.js 24 (arm64)",
      detail: "Pre-warms the toolcache for setup-node.", approxSize: "~60 MB", group: .toolcache),
    .init(
      id: "python-3.12", title: "Python 3.12 (arm64)",
      detail: "Pre-warms the toolcache for setup-python.", approxSize: "~100 MB", group: .toolcache),
    .init(
      id: "python-3.13", title: "Python 3.13 (arm64)",
      detail: "GitHub's default Python on windows-11-arm.", approxSize: "~100 MB", group: .toolcache),
    .init(
      id: "python-3.13-x64", title: "Python 3.13 (x64, emulated)",
      detail: "For x64-only wheels — GitHub ships this too.", approxSize: "~100 MB", group: .toolcache),
    .init(
      id: "python-3.14", title: "Python 3.14 (arm64)",
      detail: "Pre-warms the toolcache for setup-python.", approxSize: "~100 MB", group: .toolcache),
    .init(
      id: "go-1.22", title: "Go 1.22 (arm64)",
      detail: "Pre-warms the toolcache for setup-go.", approxSize: "~250 MB", group: .toolcache),
    .init(
      id: "go-1.23", title: "Go 1.23 (arm64)",
      detail: "Pre-warms the toolcache for setup-go.", approxSize: "~250 MB", group: .toolcache),
    .init(
      id: "go-1.24", title: "Go 1.24 (arm64)",
      detail: "GitHub's default Go on windows-11-arm.", approxSize: "~250 MB", group: .toolcache),
    .init(
      id: "go-1.25", title: "Go 1.25 (arm64)",
      detail: "Pre-warms the toolcache for setup-go.", approxSize: "~250 MB", group: .toolcache),
    // Global tools (installed on PATH).
    .init(
      id: "gh", title: "GitHub CLI",
      detail: "gh — native ARM64 MSI, on PATH.", approxSize: "~15 MB", group: .tool),
    .init(
      id: "cmake", title: "CMake",
      detail: "Native ARM64 MSI, on PATH.", approxSize: "~40 MB", group: .tool),
    .init(
      id: "dotnet-8", title: ".NET SDK 8 (LTS)",
      detail: "Native arm64 via dotnet-install; sets DOTNET_ROOT.", approxSize: "~250 MB", group: .tool),
    .init(
      id: "java-21", title: "Java 21 — Temurin (LTS)",
      detail: "GitHub's default JDK; native aarch64 MSI, sets JAVA_HOME.", approxSize: "~300 MB", group: .tool),
    .init(
      id: "java-23", title: "Java 23 — Temurin",
      detail: "The second JDK GitHub's ARM image ships.", approxSize: "~300 MB", group: .tool),
    .init(
      id: "jq-yq", title: "jq + yq",
      detail: "JSON/YAML CLIs in C:\\tools (jq is x64-under-emulation, like GitHub ships it).",
      approxSize: "~15 MB", group: .tool),
  ]

  /// Where `prepare-windows-image` records the package selection baked into the
  /// base (csv of catalog ids; an empty file means "built with none"). Sibling
  /// of `windows-base.build`/`.recipe` — survives run sweeps.
  public static func baseImagePackagesFile() -> URL {
    HostCleanup.mactionsRoot().appendingPathComponent("windows-base.packages", isDirectory: false)
  }

  /// The package set the current base was built with, or `nil` when never
  /// recorded (no base, or a base that predates the package picker — those get
  /// the recipe-outdated nudge anyway, which a rebuild resolves together).
  public static func recordedPackages() -> Set<String>? {
    guard let raw = try? String(contentsOf: baseImagePackagesFile(), encoding: .utf8) else { return nil }
    return parsePackageList(raw)
  }

  /// Parse a csv/newline list of package ids into a set. Pure → unit-testable.
  public static func parsePackageList(_ raw: String) -> Set<String> {
    Set(
      raw.split(whereSeparator: { $0 == "," || $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty })
  }

  /// Why the base image needs a rebuild — or that it doesn't. Pure-computed from
  /// the recorded OS build + recipe version vs the latest available build + the
  /// current recipe. Drives the UI banner text and the "rebuild needed" badge.
  public enum MaintenanceReason: Equatable, Sendable {
    /// Fresh — no rebuild needed.
    case upToDate
    /// A newer Windows 11 ARM64 GA build is available.
    case osBuildAvailable(latest: String)
    /// The provisioning recipe was updated since this base was built (e.g. bash
    /// was added) — same OS build, but the base is functionally outdated.
    case provisioningOutdated
    /// Both a newer OS build AND an updated provisioning recipe.
    case both(latest: String)
    /// The package selection in the UI no longer matches what's baked into the
    /// base (only reported when nothing bigger is stale — an OS/recipe rebuild
    /// bakes the current selection anyway).
    case packagesChanged
    /// No base image has been built yet.
    case notBuilt

    /// True iff a rebuild would actually change something worth doing.
    public var needsRebuild: Bool {
      switch self {
      case .upToDate, .notBuilt: return false
      case .osBuildAvailable, .provisioningOutdated, .both, .packagesChanged: return true
      }
    }
  }

  /// Decide the base image's maintenance state. `latestBuild` is `nil` when the
  /// (throttled, networked) OS-build check hasn't run or failed — in that case
  /// we deliberately do NOT claim an OS update (no false nudges offline), but we
  /// STILL flag recipe staleness, which is a purely local comparison.
  public static func maintenanceReason(
    recordedBuild: String?,
    recordedRecipe: Int?,
    latestBuild: String?,
    currentRecipe: Int = currentProvisioningRecipeVersion,
    selectedPackages: Set<String> = [],
    recordedPackages: Set<String>? = nil
  ) -> MaintenanceReason {
    let hasImage = !((recordedBuild?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true)
    guard hasImage else { return .notBuilt }
    let recipeStale = (recordedRecipe ?? 0) < currentRecipe
    // OS staleness needs the networked `latest`; `nil` ⇒ don't assert an OS
    // update (avoids false offline nudges). Recipe staleness is purely local.
    if let latestBuild, updateAvailable(installed: recordedBuild, latest: latestBuild) {
      return recipeStale ? .both(latest: latestBuild) : .osBuildAvailable(latest: latestBuild)
    }
    if recipeStale { return .provisioningOutdated }
    // Packages last: only worth reporting when nothing bigger is stale (an
    // OS/recipe rebuild bakes the current selection anyway). A `nil` recorded
    // set (pre-picker base) only nudges when the user actually selected
    // something — an empty selection matches an unrecorded base by definition.
    if selectedPackages != (recordedPackages ?? []) { return .packagesChanged }
    return .upToDate
  }

  /// A one-line, user-facing nudge for a maintenance reason (`nil` ⇒ no banner).
  public static func maintenanceNotice(for reason: MaintenanceReason) -> String? {
    switch reason {
    case .upToDate, .notBuilt:
      return nil
    case let .osBuildAvailable(latest):
      return "A newer Windows 11 ARM64 build (\(latest)) is available — rebuild to update the base image."
    case .provisioningOutdated:
      return "The Windows base image needs maintenance — the runner setup recipe was updated (e.g. Git/bash). Rebuild to apply it."
    case let .both(latest):
      return "The Windows base image needs a rebuild: a newer Windows 11 ARM64 build (\(latest)) is available AND the runner setup recipe was updated."
    case .packagesChanged:
      return "The package selection changed since the base was built — rebuild to apply it (reuses the cached ISO)."
    }
  }

  // MARK: - ISO-converter dependency check (pure → unit-testable)

  /// One ISO-converter dependency: the command the UUP-dump convert script
  /// invokes (what we probe for on PATH) paired with the Homebrew formula that
  /// provides it. They're kept together so the binary→formula mapping is
  /// data-driven and can't drift (the bug where `aria2c` was passed to `brew
  /// install` as a formula name — there is no `aria2c` formula, it's `aria2`).
  public struct ConverterDependency: Equatable, Sendable {
    /// The command the converter calls; what `Shell.which` looks for.
    public let binary: String
    /// The `brew install` argument that provides `binary`. May be tap-qualified
    /// for formulae outside homebrew-core (chntpw).
    public let formula: String
    public init(binary: String, formula: String) {
      self.binary = binary
      self.formula = formula
    }
  }

  /// CLIs the UUP-dump → ISO conversion needs — the upstream converter
  /// (`convert.sh`) hard-requires ALL of these (a missing one aborts it before
  /// the multi-GB download), so we check them up front and install via Homebrew.
  /// Binary and formula names differ for several, hence the explicit pairing:
  ///   - aria2c        ← `aria2`      (parallel downloader the convert script uses)
  ///   - cabextract    ← `cabextract` (unpacks the .cab payloads)
  ///   - wimlib-imagex ← `wimlib`     (builds/edits install.wim)
  ///   - mkisofs       ← `cdrtools`   (writes the final bootable ISO)
  ///   - chntpw        ← `minacle/chntpw/chntpw` (edits the offline registry;
  ///     not in homebrew-core — this tap ships a maintained native-arm64 build,
  ///     verified building cleanly on Apple Silicon. `brew install` auto-taps it.)
  public static let converterDependencies: [ConverterDependency] = [
    .init(binary: "aria2c", formula: "aria2"),
    .init(binary: "cabextract", formula: "cabextract"),
    .init(binary: "wimlib-imagex", formula: "wimlib"),
    .init(binary: "mkisofs", formula: "cdrtools"),
    .init(binary: "chntpw", formula: "minacle/chntpw/chntpw"),
  ]

  /// Brew formula (the `brew install` argument) that provides a converter
  /// `binary`. Data-driven from `converterDependencies`; falls back to the
  /// binary name itself for anything not listed.
  static func brewFormula(for binary: String) -> String {
    converterDependencies.first { $0.binary == binary }?.formula ?? binary
  }

  /// Which converter deps are NOT installed, as the brew formula names to
  /// install (resolved via `Shell.which`, which also checks the Homebrew dirs a
  /// Finder-launched GUI app won't have on its PATH). Empty array == all present.
  public static func missingConverterDependencies(
    lookup: (String) -> Bool = { Shell.which($0) != nil }
  ) -> [String] {
    converterDependencies.filter { !lookup($0.binary) }.map(\.formula)
  }

  // MARK: - Per-clone config ISO (the headless JIT-delivery payload)

  /// `hdiutil makehybrid` arguments to build a tiny per-clone **config ISO** that
  /// carries the JIT registration into a headless Windows guest (the guest reads
  /// it off the disc by volume label and registers OUTBOUND to GitHub — no SSH /
  /// IP discovery needed). Pure builder, unit-tested like the `WindowsVMCLI` verb
  /// shapes; the real run is a `Shell.runChecked` at provision time.
  ///
  /// Flags mirror the proven unattend-ISO build in `scripts/prepare-windows-image`:
  ///   - `-iso -joliet`: ISO9660 + Joliet so Windows reads exact lowercase names
  ///     (the primary tree mangles to 8.3); do NOT add Rock Ridge (Windows ignores it).
  ///   - `-ov`: overwrite — required for an idempotent rebuild.
  ///   - `-default-volume-name`: a stable label so the guest finds the disc
  ///     regardless of drive letter.
  /// `sourceDir` holds `mactions/jitconfig` (the base64 JIT, no trailing newline).
  public static func configISOArgs(
    sourceDir: String, output: String, volumeName: String = "MACTIONS"
  ) -> [String] {
    ["makehybrid", "-iso", "-joliet", "-ov", "-default-volume-name", volumeName, "-o", output, sourceDir]
  }

  /// `hdiutil` for the config-ISO build (PATH first, then the system path a
  /// Finder-launched app always has).
  public static func hdiutilPath() -> String { Shell.which("hdiutil") ?? "/usr/bin/hdiutil" }
}
