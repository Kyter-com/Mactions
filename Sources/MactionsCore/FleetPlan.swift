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
  /// MAX concurrent runners (scale-from-zero CEILING), clamped 1...5: runners
  /// are provisioned on demand when matching jobs queue, up to this many at
  /// once — macOS agent processes, Windows VMs, Linux containers — and torn
  /// down when the queue empties. The live `HostBudget` (RAM/CPU) additionally
  /// bounds Windows/Linux host-wide at provision time.
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

  /// A one-line subtitle for the repo header — e.g. `"macOS ×2 · Linux ×3"`. A
  /// platform shows `×N` only when it allows more than one concurrent runner
  /// (the on-demand cap); a lone runner is left implicit. Empty selection reads
  /// as a nudge.
  public func summary() -> String {
    let parts = RunnerOS.allCases.compactMap { os -> String? in
      guard let config = platforms[os.rawValue], config.enabled else { return nil }
      return config.count > 1 ? "\(os.displayName) ×\(config.count)" : os.displayName
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
  /// Legacy macOS label seed retained for persisted-plan compatibility. New
  /// configs use `RunnerOS.macOS.defaultLabels` so all platform labels are fixed,
  /// read-only workflow `runs-on` tokens.
  public var defaultMacOSLabels: [String]
  /// Runner count seeded into a new macOS combo.
  public var defaultMacOSCount: Int
  /// Optional per-OS default runner ceilings for newly-added repos and all-repos
  /// discovery. Plans persisted before this existed decode with `nil`; macOS
  /// falls back to `defaultMacOSCount`, Windows/Linux fall back to 1.
  public var defaultPlatformCounts: [String: Int]?
  /// `RunnerOS.rawValue`s auto-enabled when a repo is added (default: macOS only).
  public var defaultPlatforms: [String]
  /// Scope: when true, the fleet ALSO watches every repo the user can admin —
  /// queued jobs in undiscovered repos spin up runners seeded from the defaults
  /// above, and those fleets are reaped when the repo goes quiet. Explicitly
  /// configured repos keep their own per-combo configs. Optional (`nil` ==
  /// false) so plans persisted before this field decode unchanged.
  public var allRepos: Bool?

  public var isAllRepos: Bool { allRepos ?? false }

  public init(
    repos: [RepoPlan] = [],
    defaultMacOSLabels: [String] = ["self-hosted", "macOS", "mactions"],
    defaultMacOSCount: Int = 1,
    defaultPlatformCounts: [String: Int]? = nil,
    defaultPlatforms: [String] = ["macOS"],
    allRepos: Bool? = nil
  ) {
    self.repos = repos
    self.defaultMacOSLabels = defaultMacOSLabels
    self.defaultMacOSCount = max(1, min(5, defaultMacOSCount))
    self.defaultPlatformCounts = defaultPlatformCounts?.mapValues { max(1, min(5, $0)) }
    self.defaultPlatforms = defaultPlatforms
    self.allRepos = allRepos
  }

  // MARK: Seeds

  /// The starting config for a newly-enabled `(repo, os)` combo: macOS keeps its
  /// saved default count; every platform uses its fixed workflow label set.
  public func seed(for os: RunnerOS) -> PlatformConfig {
    PlatformConfig(enabled: true, count: defaultCount(for: os), labels: os.defaultLabels)
  }

  public func defaultCount(for os: RunnerOS) -> Int {
    let fallback = os == .macOS ? defaultMacOSCount : 1
    return max(1, min(5, defaultPlatformCounts?[os.rawValue] ?? fallback))
  }

  public mutating func setDefaultCount(_ count: Int, for os: RunnerOS) {
    let clamped = max(1, min(5, count))
    var counts = defaultPlatformCounts ?? [:]
    counts[os.rawValue] = clamped
    defaultPlatformCounts = counts
    if os == .macOS { defaultMacOSCount = clamped }
  }

  /// Normalize labels persisted by older builds that let macOS labels be edited.
  /// Counts/platform enablement are preserved; only the workflow label tokens are
  /// pinned back to the fixed per-OS contract.
  public mutating func normalizeWorkflowLabels() {
    defaultMacOSLabels = RunnerOS.macOS.defaultLabels
    for repoIndex in repos.indices {
      for raw in Array(repos[repoIndex].platforms.keys) {
        guard let os = RunnerOS(rawValue: raw) else { continue }
        repos[repoIndex].platforms[raw]?.labels = os.defaultLabels
      }
    }
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

  /// ALL-REPOS discovery: which default-enabled platforms any of these queued
  /// jobs' label sets would route to (job labels ⊆ the platform's seed labels —
  /// GitHub's cumulative `runs-on` rule). Drives lazy orchestrator creation for
  /// repos outside the explicit plan.
  public func discoveryMatches(for queuedLabelSets: [[String]]) -> [RunnerOS] {
    RunnerOS.allCases.filter { os in
      guard defaultPlatforms.contains(os.rawValue) else { return false }
      let runnerLabels = seed(for: os).labels
      return queuedLabelSets.contains { jobLabelsMatchRunner(job: $0, runner: runnerLabels) }
    }
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

  /// Mutate a combo's config in place, seeding a DISABLED placeholder when the
  /// platform was never configured (so changing a count doesn't silently switch
  /// the platform on).
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
  /// existing install comes up identically after the upgrade except for labels,
  /// which are now fixed per OS. Windows/Linux are enabled only when their image
  /// is actually ready (count 1, derived labels) — mirroring the old `goOnline`
  /// readiness gating. Pure → unit-tested like
  /// `RunnerOS.restoreSelection`.
  public static func migrate(
    repoFullNames: [String],
    oses: Set<RunnerOS>,
    labels: [String],
    runnersPerRepo: Int,
    windowsImageReady: Bool,
    linuxImageReady: Bool
  ) -> FleetPlan {
    _ = labels  // Legacy user-editable macOS labels are intentionally ignored.
    let count = max(1, min(5, runnersPerRepo))
    let repos = repoFullNames.compactMap(RepoRef.init(fullName:)).map { ref -> RepoPlan in
      var platforms: [String: PlatformConfig] = [:]
      if oses.contains(.macOS) {
        platforms[RunnerOS.macOS.rawValue] =
          PlatformConfig(enabled: true, count: count, labels: RunnerOS.macOS.defaultLabels)
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
    // count, and the platforms they had selected — but gate Windows/Linux
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
      repos: repos, defaultMacOSLabels: RunnerOS.macOS.defaultLabels, defaultMacOSCount: count,
      defaultPlatformCounts: [RunnerOS.macOS.rawValue: count],
      defaultPlatforms: defaultPlatforms)
  }
}
