import Foundation

/// One control plane per REPO, shared by every consumer that polls it — the
/// repo's combo orchestrators (which differ only by label filter) and the
/// all-repos discovery probe.
///
/// Why: each queued-jobs poll costs 2 runs-list requests + up to 30 per-run
/// jobs requests. Same-repo combos tick independently, so without sharing, a
/// repo with macOS+Windows+Linux combos pays that bill three times per tick.
/// This actor collapses concurrent polls into ONE in-flight fetch and serves
/// a short-TTL cache to polls that arrive within the same tick window — the
/// per-repo bill becomes ~1× regardless of combo count, on top of the ETag
/// store already making unchanged re-polls free.
///
/// JIT minting, runner listing, and deletion pass straight through: they are
/// cheap, per-combo, and freshness-critical (busy flags drive trim decisions).
public actor SharedRepoControlPlane: RunnerControlPlane {
  private let inner: any RunnerControlPlane
  private let queueCacheTTL: TimeInterval
  private var cachedQueue: (labels: [[String]], at: Date)?
  private var inflight: Task<[[String]], Error>?

  /// `inner` is the repo-scoped plane to share (a `GitHubClient` in the app;
  /// a fake in tests). The TTL must stay BELOW the orchestrator's
  /// `trimConfirmInterval` so a trim's mark and its confirmation can never be
  /// served by the same cached queue read.
  public init(inner: any RunnerControlPlane, queueCacheTTL: TimeInterval = 20) {
    self.inner = inner
    self.queueCacheTTL = queueCacheTTL
  }

  public func listQueuedJobLabels() async throws -> [[String]] {
    if let cached = cachedQueue, Date().timeIntervalSince(cached.at) < queueCacheTTL {
      return cached.labels
    }
    if let inflight {
      // A sibling combo's poll is already on the wire — share its answer.
      return try await inflight.value
    }
    let client = inner
    let task = Task { try await client.listQueuedJobLabels() }
    inflight = task
    defer { inflight = nil }
    let labels = try await task.value
    cachedQueue = (labels, Date())
    return labels
  }

  public func generateJITConfig(name: String, labels: [String]) async throws -> JITConfig {
    try await inner.generateJITConfig(name: name, labels: labels)
  }

  public func listRunners() async throws -> [RemoteRunner] {
    try await inner.listRunners()
  }

  public func deleteRunner(id: Int) async throws {
    try await inner.deleteRunner(id: id)
  }
}

/// The all-repos discovery reap decision for one discovered `(repo, OS)` key,
/// extracted pure so the quiet-scan ledger is unit-testable (the I/O — repo
/// listing, probing, orchestrator lifecycle — stays in the app layer).
public enum DiscoveryReapDecision: Equatable, Sendable {
  /// Poll failed: unknown, not quiet — leave the counter untouched.
  case hold
  /// Demand or live runners: reset the quiet counter to zero.
  case reset
  /// Genuinely quiet this scan, but not for long enough yet.
  case countQuiet(quietScans: Int)
  /// Quiet for `reapAfterQuietScans` consecutive scans — retire the fleet.
  case reap
}

/// `matched`: this key's platform matched a queued job this scan (or the
/// orchestrator itself reports queued demand). `pollFailed`: the repo's queue
/// probe failed this scan. `liveRunners`: the orchestrator's current slots.
/// `quietScans`: consecutive quiet scans so far. Reap requires
/// `reapAfterQuietScans` CONSECUTIVE quiet scans (default 2) — a single quiet
/// scan can race a job that's mid-pickup.
public func discoveryReapDecision(
  matched: Bool,
  pollFailed: Bool,
  liveRunners: Int,
  quietScans: Int,
  reapAfterQuietScans: Int = 2
) -> DiscoveryReapDecision {
  if pollFailed { return .hold }
  if matched || liveRunners > 0 { return .reset }
  let quiet = quietScans + 1
  return quiet >= reapAfterQuietScans ? .reap : .countQuiet(quietScans: quiet)
}
