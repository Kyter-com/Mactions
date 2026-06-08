import Foundation

/// The per-`(repo, platform)` runner configuration — the model that replaces the
/// old flat globals (one OS set + one label string + one count applied uniformly
/// to every repo). Each repo enables its own platforms, and each
/// `(repo, platform)` combo carries its **own label set and runner count**. A
/// combo maps 1:1 onto `FleetConfig`, so the orchestrator core is untouched: the
/// app just enumerates `enabledCombos()` and spins one orchestrator per combo.
///
/// Pure Foundation, `Codable` + `Sendable`, no UI and no `UserDefaults` — the app
/// persists a `FleetPlan` as a single JSON blob and migrates the legacy flat keys
/// into one via the pure static `migrate(...)` (unit-tested like
/// `RunnerOS.restoreSelection`).

/// One `(repo, platform)` combo: whether it's on, how many runners, and the
/// exact GitHub `runs-on` label set those runners register with.
public struct PlatformConfig: Codable, Equatable, Sendable {
  public var enabled: Bool
  /// Desired runner count, clamped 1...5. Only macOS varies it in the UI;
  /// Windows/Linux are pinned to 1 at go-online (each is a full VM/container the
  /// RAM budget caps), so their stored count is informational.
  public var count: Int
  /// This combo's OWN labels (e.g. `["self-hosted", "macOS", "mactions"]`).
  public var labels: [String]

  public init(enabled: Bool, count: Int, labels: [String]) {
    self.enabled = enabled
    self.count = max(1, min(5, count))
    self.labels = labels
  }
}

/// One repository's plan: which platforms it runs, each with its own config.
/// `platforms` is keyed by `RunnerOS.rawValue` (a `String`) rather than
/// `[RunnerOS: PlatformConfig]` on purpose — a non-`String`-keyed dictionary
/// encodes to JSON as a brittle flat `[key, value, key, value]` array, which is
/// easy to corrupt across versions. The string keys round-trip as a stable JSON
/// object.
public struct RepoPlan: Codable, Equatable, Sendable, Identifiable {
  public var repo: RepoRef
  public var platforms: [String: PlatformConfig]

  public var id: String { repo.fullName }

  public init(repo: RepoRef, platforms: [String: PlatformConfig] = [:]) {
    self.repo = repo
    self.platforms = platforms
  }

  /// This repo's config for `os`, or `nil` if the platform was never configured.
  public func config(for os: RunnerOS) -> PlatformConfig? { platforms[os.rawValue] }

  /// The platforms this repo has switched ON (in stable `RunnerOS.allCases` order).
  public var enabledPlatforms: [RunnerOS] {
    RunnerOS.allCases.filter { platforms[$0.rawValue]?.enabled == true }
  }

  /// A one-line subtitle for the repo header — e.g. `"macOS ×2 · Linux"`. Only
  /// macOS shows its count (the others are always one VM/container per job).
  /// Empty selection reads as a nudge.
  public func summary() -> String {
    let parts = RunnerOS.allCases.compactMap { os -> String? in
      guard let config = platforms[os.rawValue], config.enabled else { return nil }
      return os == .macOS ? "macOS ×\(config.count)" : os.displayName
    }
    return parts.isEmpty ? "No platforms — open Configure" : parts.joined(separator: " · ")
  }
}

/// A single resolved combo to bring online: a repo, an OS, and that combo's
/// config. The unit `enabledCombos()` / `invalidCombos()` work in (a value, so
/// it's `Equatable` for tests, unlike a tuple).
public struct FleetCombo: Equatable, Sendable {
  public let repo: RepoRef
  public let os: RunnerOS
  public let config: PlatformConfig

  public init(repo: RepoRef, os: RunnerOS, config: PlatformConfig) {
    self.repo = repo
    self.os = os
    self.config = config
  }
}

/// The whole fleet: the ordered list of repo plans plus the templates used to
/// seed a freshly-added repo (so defaults live in the model, not in leftover
/// global state).
public struct FleetPlan: Codable, Equatable, Sendable {
  public var repos: [RepoPlan]
  /// Labels seeded into a new macOS combo (user-editable in Settings → General).
  public var defaultMacOSLabels: [String]
  /// Runner count seeded into a new macOS combo.
  public var defaultMacOSCount: Int
  /// `RunnerOS.rawValue`s auto-enabled when a repo is added (default: macOS only).
  public var defaultPlatforms: [String]

  public init(
    repos: [RepoPlan] = [],
    defaultMacOSLabels: [String] = ["self-hosted", "macOS", "mactions"],
    defaultMacOSCount: Int = 1,
    defaultPlatforms: [String] = ["macOS"]
  ) {
    self.repos = repos
    self.defaultMacOSLabels = defaultMacOSLabels
    self.defaultMacOSCount = max(1, min(5, defaultMacOSCount))
    self.defaultPlatforms = defaultPlatforms
  }

  // MARK: Seeds

  /// The starting config for a newly-enabled `(repo, os)` combo: macOS uses the
  /// editable defaults; Windows/Linux use their derived label set + count 1.
  public func seed(for os: RunnerOS) -> PlatformConfig {
    os == .macOS
      ? PlatformConfig(enabled: true, count: defaultMacOSCount, labels: defaultMacOSLabels)
      : PlatformConfig(enabled: true, count: 1, labels: os.defaultLabels)
  }

  // MARK: Queries (what go-online consumes)

  /// Every enabled combo across all repos, in `repos` × `RunnerOS.allCases`
  /// order. Readiness gating (Windows image built / Linux runtime up) stays at
  /// the `AppState` call site — this is the pure "what the user asked for" list.
  public func enabledCombos() -> [FleetCombo] {
    repos.flatMap { plan in
      RunnerOS.allCases.compactMap { os -> FleetCombo? in
        guard let config = plan.config(for: os), config.enabled else { return nil }
        return FleetCombo(repo: plan.repo, os: os, config: config)
      }
    }
  }

  /// Enabled combos whose labels would silently never match a workflow — empty,
  /// or missing the mandatory `self-hosted` token. The UI hard-blocks go-online
  /// on a non-empty result so the failure surfaces up front instead of as a job
  /// that never starts.
  public func invalidCombos() -> [FleetCombo] {
    enabledCombos().filter { $0.config.labels.isEmpty || !$0.config.labels.contains("self-hosted") }
  }

  // MARK: Mutation (offline-gated by the caller; saved by the caller)

  /// Add a repo, seeding it with `defaultPlatforms`. No-op if already present.
  public mutating func addRepo(_ repo: RepoRef) {
    guard !repos.contains(where: { $0.repo == repo }) else { return }
    var platforms: [String: PlatformConfig] = [:]
    for raw in defaultPlatforms {
      if let os = RunnerOS(rawValue: raw) { platforms[raw] = seed(for: os) }
    }
    repos.append(RepoPlan(repo: repo, platforms: platforms))
  }

  public mutating func removeRepo(id: String) {
    repos.removeAll { $0.id == id }
  }

  public mutating func setPlatform(_ os: RunnerOS, enabled: Bool, in repoID: String) {
    mutate(os, in: repoID) { $0.enabled = enabled }
  }

  public mutating func setCount(_ count: Int, os: RunnerOS, in repoID: String) {
    mutate(os, in: repoID) { $0.count = max(1, min(5, count)) }
  }

  public mutating func setLabels(_ labels: [String], os: RunnerOS, in repoID: String) {
    mutate(os, in: repoID) { $0.labels = labels }
  }

  /// Mutate a combo's config in place, seeding a DISABLED placeholder when the
  /// platform was never configured (so editing labels before flipping Enable
  /// doesn't silently switch the platform on).
  private mutating func mutate(
    _ os: RunnerOS, in repoID: String, _ transform: (inout PlatformConfig) -> Void
  ) {
    guard let i = repos.firstIndex(where: { $0.id == repoID }) else { return }
    var config =
      repos[i].config(for: os)
      ?? {
        var placeholder = seed(for: os)
        placeholder.enabled = false
        return placeholder
      }()
    transform(&config)
    repos[i].platforms[os.rawValue] = config
  }

  // MARK: Migration off the legacy flat keys

  /// Reproduce TODAY'S exact go-online fleet from the four legacy globals, so an
  /// existing install comes up identically after the upgrade. macOS uses
  /// `runnersPerRepo` + the user's labels; Windows/Linux are enabled only when
  /// their image is actually ready (count 1, derived labels) — mirroring the old
  /// `goOnline` readiness gating. Pure → unit-tested like
  /// `RunnerOS.restoreSelection`.
  public static func migrate(
    repoFullNames: [String],
    oses: Set<RunnerOS>,
    labels: [String],
    runnersPerRepo: Int,
    windowsImageReady: Bool,
    linuxImageReady: Bool
  ) -> FleetPlan {
    let macLabels = labels.isEmpty ? RunnerOS.macOS.defaultLabels : labels
    let count = max(1, min(5, runnersPerRepo))
    let repos = repoFullNames.compactMap(RepoRef.init(fullName:)).map { ref -> RepoPlan in
      var platforms: [String: PlatformConfig] = [:]
      if oses.contains(.macOS) {
        platforms[RunnerOS.macOS.rawValue] =
          PlatformConfig(enabled: true, count: count, labels: macLabels)
      }
      if oses.contains(.windows), windowsImageReady {
        platforms[RunnerOS.windows.rawValue] =
          PlatformConfig(enabled: true, count: 1, labels: RunnerOS.windows.defaultLabels)
      }
      if oses.contains(.linux), linuxImageReady {
        platforms[RunnerOS.linux.rawValue] =
          PlatformConfig(enabled: true, count: 1, labels: RunnerOS.linux.defaultLabels)
      }
      return RepoPlan(repo: ref, platforms: platforms)
    }
    // Seed future-repo defaults from what the user was running: their macOS
    // labels/count, and the platforms they had selected — but gate Windows/Linux
    // on readiness (mirroring the per-repo configs above), so a new repo doesn't
    // default to an enabled-but-unbuildable combo. macOS is always the floor (it
    // needs no setup), in stable RunnerOS.allCases order.
    var defaultPlatforms = [RunnerOS.macOS.rawValue]
    if oses.contains(.windows), windowsImageReady {
      defaultPlatforms.append(RunnerOS.windows.rawValue)
    }
    if oses.contains(.linux), linuxImageReady {
      defaultPlatforms.append(RunnerOS.linux.rawValue)
    }
    return FleetPlan(
      repos: repos, defaultMacOSLabels: macLabels, defaultMacOSCount: count,
      defaultPlatforms: defaultPlatforms)
  }
}
