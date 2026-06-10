import Foundation

/// Live, SHARED capacity ledger for the heavyweight substrates, consulted at
/// provision time and released on every slot exit/reap.
///
/// This replaces the static per-combo grants go-online used to bake into each
/// orchestrator's count: scale-from-zero makes demand bursty and concurrent,
/// so every combo must draw from one live pool — otherwise N combos could each
/// scale to their own cap simultaneously and thrash the host. The per-OS
/// ceilings still come from the pure budget formulas (`MacOSLocalBudget`,
/// `WindowsVMBudget`, `LinuxContainerBudget`) computed against the host's
/// physical RAM/CPU/storage; this type just makes spending them dynamic.
///
/// `@MainActor` rather than an `actor` on purpose: every caller — `AppState`
/// and each `RunnerOrchestrator` — is already main-actor-isolated, which keeps
/// `tryAcquire`/`release` synchronous (no await interleaving between two combos
/// racing for the last unit).
@MainActor
public final class HostBudget {
  /// Concurrent-runner ceiling per OS. A missing key = uncapped; AppState
  /// normally supplies a limit for every currently armed OS.
  private let limits: [RunnerOS: Int]
  private var used: [RunnerOS: Int] = [:]

  public init(limits: [RunnerOS: Int]) {
    self.limits = limits
  }

  /// The configured ceiling for `os`, or `nil` when uncapped. For status copy
  /// and (later) UI "recommended max" seeding.
  public func limit(for os: RunnerOS) -> Int? { limits[os] }

  public func inUse(_ os: RunnerOS) -> Int { used[os, default: 0] }

  /// Reserve one runner's worth of capacity. `false` = at the ceiling — the
  /// caller skips provisioning; capacity frees when any combo's runner exits,
  /// and the next reconcile tick retries.
  public func tryAcquire(_ os: RunnerOS) -> Bool {
    if let limit = limits[os], used[os, default: 0] >= limit { return false }
    used[os, default: 0] += 1
    return true
  }

  public func release(_ os: RunnerOS) {
    used[os] = max(0, used[os, default: 0] - 1)
  }
}
