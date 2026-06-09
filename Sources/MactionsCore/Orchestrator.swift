import Foundation

/// What the user wants the fleet to look like. Persisted by the app; the core
/// just consumes it.
public struct FleetConfig: Equatable, Sendable {
  public var owner: String
  public var repo: String
  public var labels: [String]
  public var desiredCount: Int

  public init(owner: String, repo: String, labels: [String], desiredCount: Int) {
    self.owner = owner
    self.repo = repo
    self.labels = labels
    self.desiredCount = max(1, desiredCount)
  }
}

public enum FleetState: String, Sendable {
  case offline, starting, online, stopping
}

/// A single runner the orchestrator is managing, as a value snapshot for the UI.
public struct ManagedRunner: Identifiable, Equatable, Sendable {
  public enum Phase: String, Sendable { case provisioning, online, recycling, stopped, failed }
  public let id: String // runner name
  public var remoteId: Int?
  public var phase: Phase
}

/// Stable per-machine runner-name prefix: `mactions-<host>`. This is how we
/// avoid clobbering across machines — two Macs (personal + work) get different
/// host prefixes, so each only ever deregisters *its own* runners, and the
/// other's registrations are left untouched even when it's offline.
public func machineRunnerPrefix(host: String = ProcessInfo.processInfo.hostName) -> String {
  let safe = host
    .replacingOccurrences(of: ".local", with: "")
    .lowercased()
    .filter { $0.isLetter || $0.isNumber || $0 == "-" }
  return "mactions-\(safe.isEmpty ? "mac" : String(safe.prefix(24)))"
}

/// Deregister every runner registered under `prefix` (default: this machine's
/// prefix). Used on go-offline teardown AND at go-online: a clean `stop()`
/// deregisters our ephemeral runners, but a crash/force-quit skips it, leaving a
/// "ghost" registration (an agent killed before it could self-deregister) that
/// GitHub only auto-prunes much later. Reaping it at go-online — before any new
/// runner is provisioned — keeps the runner list clean without waiting on
/// GitHub. By default this is scoped to our `mactions-<host>` prefix, so stop()
/// never touches another Mac's runners. The launch/go-online sweep can opt into
/// broader stale cleanup for offline/non-busy `mactions-*` registrations left by
/// old host-name generations; online or busy runners from another Mac are kept.
/// Best-effort: a list/delete failure is swallowed (GitHub's own ephemeral
/// cleanup is the backstop).
public func deregisterOrphanRunners(
  _ controlPlane: RunnerControlPlane,
  prefix: String = machineRunnerPrefix(),
  includeOfflineMactionsRunners: Bool = false
) async {
  guard let remote = try? await controlPlane.listRunners() else { return }
  for runner in remote where shouldDeregisterOrphanRunner(
    runner, prefix: prefix, includeOfflineMactionsRunners: includeOfflineMactionsRunners)
  {
    try? await controlPlane.deleteRunner(id: runner.id)
  }
}

func shouldDeregisterOrphanRunner(
  _ runner: RemoteRunner,
  prefix: String,
  includeOfflineMactionsRunners: Bool
) -> Bool {
  if runner.name.hasPrefix(prefix) { return true }
  guard includeOfflineMactionsRunners else { return false }
  return runner.name.hasPrefix("mactions-")
    && runner.status.lowercased() == "offline"
    && !runner.busy
}

/// Owns the lifecycle of N ephemeral runners for one repo.
///
/// The fleet is kept at `desiredCount` by **reconciliation**, not a single
/// exit→replace step: whenever a runner exits (or a provision fails) we
/// reconcile back up to target, and a periodic loop self-heals transient
/// failures. An `epoch` counter invalidates in-flight provisions/recycles the
/// moment `stop()` runs, so a slow JIT-config call or a late exit callback can
/// never revive a fleet the user already took offline. Teardown only touches
/// runners under *this machine's* prefix (see `machineRunnerPrefix`).
@MainActor
public final class RunnerOrchestrator {
  private let controlPlane: RunnerControlPlane
  private let factory: RunnerProviderFactory
  private let config: FleetConfig
  /// Which OS this fleet runs (purely descriptive — used to stamp `RunRecord`s so
  /// the history knows whether a run was macOS or Windows). The control loop is
  /// OS-agnostic; the provider does the OS-specific work.
  private let os: RunnerOS
  private let machinePrefix: String
  private let reconcileInterval: UInt64
  /// A just-launched VM/local agent can take a short time to register with
  /// GitHub. Do not treat a missing remote runner as stale until this grace has
  /// elapsed.
  private let remoteRegistrationGraceInterval: TimeInterval
  /// JIT runner credentials are short-lived. An idle runner can look locally
  /// healthy while GitHub can no longer assign it useful work, so refresh idle
  /// slots before that window closes. `nil` disables age-based refresh.
  private let idleJITRefreshInterval: TimeInterval?

  public private(set) var state: FleetState = .offline
  public private(set) var lastError: String?
  /// Fired (on the main actor) whenever `state`/`runners` change.
  public var onChange: (() -> Void)?
  /// Fired (on the main actor) once for each runner that finishes — a clean
  /// ephemeral exit, a failure, or a teardown reap. The app records these into
  /// its run history. See `handleExit` for the outcome classification.
  public var onRunFinished: ((RunRecord) -> Void)?

  // @MainActor-isolated (like its enclosing orchestrator): only ever touched on
  // the main actor, which also makes it Sendable so it can be captured by the
  // provider's @Sendable onExit closure (which immediately hops back here).
  @MainActor private final class Slot {
    let name: String
    var remoteId: Int?
    var phase: ManagedRunner.Phase
    let provider: RunnerProvider
    /// When the agent launched (used as the run's start time in history).
    let startedAt: Date
    /// Set once GitHub has reported this runner `busy` — i.e. it has started its
    /// one ephemeral job. A runner that's running a job must NEVER be pruned: a
    /// teardown orphans the job (GitHub shows it "stuck" at the last logged step
    /// until its own ~hours-long lost-communication timeout). It reaps itself via
    /// `handleExit` when the agent exits at end of job.
    var everBusy = false
    /// When this slot first looked unhealthy (missing from GitHub's list, or not
    /// `online`), or `nil` while it looks healthy. Pruning the missing/non-online
    /// cases keys off SUSTAINED unhealth (≥ the grace interval) rather than "old
    /// enough + a single bad reading", so one transient GitHub eventual-consistency
    /// blip or connection hiccup can't tear down a long-running runner mid-job.
    var unhealthySince: Date?
    init(
      name: String, remoteId: Int?, phase: ManagedRunner.Phase, provider: RunnerProvider,
      startedAt: Date
    ) {
      self.name = name; self.remoteId = remoteId; self.phase = phase; self.provider = provider
      self.startedAt = startedAt
    }
  }
  private var slots: [Slot] = []
  /// Bumped on every start()/stop(); a stale epoch means "this work belongs to
  /// a fleet generation the user has since stopped — drop it."
  private var epoch = 0
  private var reconciling = false
  private var reconcileTask: Task<Void, Never>?

  public init(
    controlPlane: RunnerControlPlane,
    factory: RunnerProviderFactory,
    config: FleetConfig,
    os: RunnerOS = .macOS,
    machinePrefix: String = machineRunnerPrefix(),
    reconcileInterval: UInt64 = 30_000_000_000,
    remoteRegistrationGraceInterval: TimeInterval = 5 * 60,
    idleJITRefreshInterval: TimeInterval? = 8 * 60
  ) {
    self.controlPlane = controlPlane
    self.factory = factory
    self.config = config
    self.os = os
    self.machinePrefix = machinePrefix
    self.reconcileInterval = reconcileInterval
    self.remoteRegistrationGraceInterval = remoteRegistrationGraceInterval
    self.idleJITRefreshInterval = idleJITRefreshInterval
  }

  public var runners: [ManagedRunner] {
    slots.map { ManagedRunner(id: $0.name, remoteId: $0.remoteId, phase: $0.phase) }
  }

  public func start() async {
    guard state == .offline else { return }
    epoch += 1
    state = .starting
    lastError = nil
    notify()
    await reconcile()
    guard state == .starting else { return } // stop() may have raced us
    state = .online
    startReconcileLoop()
    notify()
  }

  public func stop() async {
    guard state != .offline else { return }
    epoch += 1 // invalidate any in-flight provision / pending recycle
    stopReconcileLoop()
    state = .stopping
    notify()
    let current = slots
    slots = []
    notify()
    for slot in current { slot.provider.stop() }
    // Belt-and-suspenders: ephemeral runners deregister themselves on exit, but
    // a killed agent can leave a ghost. Proactively delete anything still
    // registered under THIS machine's prefix — never another Mac's runners.
    await deregisterOrphanRunners(controlPlane, prefix: machinePrefix)
    state = .offline
    notify()
  }

  /// Bring the fleet up to `desiredCount`. Idempotent and re-entrancy-guarded;
  /// safe to call from start(), an exit callback, or the periodic loop.
  private func reconcile() async {
    guard state == .starting || state == .online, !reconciling else { return }
    reconciling = true
    defer { reconciling = false }
    let myEpoch = epoch
    if state == .online {
      await pruneUnusableSlots(epoch: myEpoch)
      guard epoch == myEpoch, state == .online else { return }
    }
    while slots.count < config.desiredCount {
      let ok = await provisionOne(epoch: myEpoch)
      // Bail if we were stopped mid-flight, or on a transient failure (the
      // periodic loop / next exit retries — we never spin).
      guard epoch == myEpoch, state == .starting || state == .online else { return }
      if !ok { break }
    }
  }

  /// Reconcile local slots with GitHub's authoritative runner state. The
  /// provider can only know "process/VM is alive"; GitHub decides whether a
  /// runner is online and assignable. This catches stale JIT registrations that
  /// expired while an idle provider kept running locally.
  private func pruneUnusableSlots(epoch myEpoch: Int) async {
    guard !slots.isEmpty else { return }
    let remote: [RemoteRunner]
    do {
      remote = try await controlPlane.listRunners()
    } catch {
      lastError = String(describing: error)
      notify()
      return
    }
    guard epoch == myEpoch, state == .online else { return }

    let byId = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let byName = Dictionary(remote.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let now = Date()
    var stale: [(slot: Slot, remote: RemoteRunner?)] = []

    for slot in slots {
      let remoteRunner = slot.remoteId.flatMap { byId[$0] } ?? byName[slot.name]
      let age = now.timeIntervalSince(slot.startedAt)
      if remoteRunner?.busy == true { slot.everBusy = true }

      // A runner that has started its one job is doing work — never prune it, or
      // the job is orphaned (left "stuck" on GitHub). It reaps itself via
      // handleExit when the agent exits at end of job; a genuinely hung job is the
      // workflow's `timeout-minutes` / GitHub's job timeout to end, not ours to
      // kill the runner out from under.
      if slot.everBusy {
        slot.unhealthySince = nil
        continue
      }

      let healthy = remoteRunner?.status.lowercased() == "online"
      if !healthy {
        // Missing from GitHub's list, or not online. Tolerate a transient blip:
        // only prune after it's been CONTINUOUSLY unhealthy for the grace window,
        // not merely "older than grace + one bad reading" (which a single eventual-
        // consistency hiccup would satisfy, tearing down a healthy runner).
        if slot.unhealthySince == nil { slot.unhealthySince = now }
        if age >= remoteRegistrationGraceInterval,
          now.timeIntervalSince(slot.unhealthySince ?? now) >= remoteRegistrationGraceInterval
        {
          stale.append((slot, remoteRunner))
        }
        continue
      }

      // Healthy (online): a recovered blip clears the unhealthy clock. Then refresh
      // a long-IDLE runner before its short-lived JIT registration expires.
      slot.unhealthySince = nil
      if let idleJITRefreshInterval, idleJITRefreshInterval >= 0,
        let remoteRunner, !remoteRunner.busy, age >= idleJITRefreshInterval
      {
        stale.append((slot, remoteRunner))
      }
    }

    guard !stale.isEmpty else { return }
    for item in stale {
      item.slot.provider.stop()
    }
    let staleIds = Set(stale.map { ObjectIdentifier($0.slot) })
    slots.removeAll { staleIds.contains(ObjectIdentifier($0)) }
    notify()

    for item in stale {
      if let id = item.remote?.id ?? item.slot.remoteId {
        try? await controlPlane.deleteRunner(id: id)
      }
    }
  }

  /// Provision exactly one runner. Returns false on failure. The slot is only
  /// recorded **after** the agent actually launches, so a failed start can't
  /// leave a phantom "online" slot.
  private func provisionOne(epoch myEpoch: Int) async -> Bool {
    let name = "\(machinePrefix)-\(String(UUID().uuidString.prefix(6)).lowercased())"
    do {
      let jit = try await controlPlane.generateJITConfig(name: name, labels: config.labels)
      // We may have gone offline during the JIT call — don't launch a runner
      // for a dead generation; deregister the one we just created.
      guard epoch == myEpoch, state == .starting || state == .online else {
        try? await controlPlane.deleteRunner(id: jit.runnerId)
        return false
      }
      let provider = factory.makeProvider(name: jit.runnerName)
      let slot = Slot(
        name: jit.runnerName, remoteId: jit.runnerId, phase: .online, provider: provider,
        startedAt: Date())
      // `provider.start` BLOCKS — it clones the ~200 MB agent (cp), shells out to
      // `security`, or clones a whole VM. Run it OFF the main actor so the UI
      // doesn't beach-ball while the fleet spins up (the orchestrator is
      // @MainActor, so a bare call would block the main thread per runner). The
      // `await` suspends the main actor; it never blocks it. Providers are
      // Sendable and `Slot` is @MainActor-isolated (hence Sendable), so the
      // exit-callback hop back to the main actor stays safe.
      let encoded = jit.encodedConfig
      try await Task.detached {
        try provider.start(jitConfig: encoded) { [weak self] status in
          Task { @MainActor in self?.handleExit(slot, epoch: myEpoch, status: status) }
        }
      }.value
      // We may have gone offline during the (now off-main) launch — don't keep a
      // runner for a dead generation; tear down the one we just started.
      guard epoch == myEpoch, state == .starting || state == .online else {
        provider.stop()
        try? await controlPlane.deleteRunner(id: jit.runnerId)
        return false
      }
      slots.append(slot)
      notify()
      return true
    } catch {
      lastError = String(describing: error)
      notify()
      return false
    }
  }

  private func handleExit(_ slot: Slot, epoch slotEpoch: Int, status: Int32) {
    // Record the run ONLY when it ended on its own while the fleet is online — a
    // genuine end-of-life for an ephemeral runner (ran its one job, or the agent
    // crashed). Status 0 → `.completed`, non-zero → `.failed`.
    //
    // We deliberately do NOT record teardown reaps (go-offline/quit) or stale-
    // generation late exits. Two reasons: (1) they're noise — every idle runner
    // gets reaped on each go-offline; and (2) on teardown AppState drops the
    // orchestrator the instant `stop()` returns, while a provider's exit callback
    // can still fire asynchronously afterward — by then this `[weak self]` hop
    // no-ops, so a record emitted on that path would be lost unreliably anyway.
    // Recording only the online path keeps history to "runs that actually ran"
    // and is race-free (the orchestrator is always alive here). A runner cut off
    // mid-job by go-offline isn't recorded — we can't tell idle from busy without
    // parsing the agent log (a later phase).
    if state == .online, epoch == slotEpoch {
      onRunFinished?(
        RunRecord(
          id: slot.name, os: os, repo: "\(config.owner)/\(config.repo)",
          remoteId: slot.remoteId, startedAt: slot.startedAt, endedAt: Date(),
          exitStatus: status, outcome: status == 0 ? .completed : .failed))
    }

    if let index = slots.firstIndex(where: { $0 === slot }) {
      slots.remove(at: index)
      notify()
    }
    // Only replace if this exit belongs to the current generation and we're
    // still meant to be online — never revive a fleet the user stopped.
    guard epoch == slotEpoch, state == .online else { return }
    Task { await reconcile() }
  }

  /// Periodic top-up so a transient provision failure self-heals instead of
  /// leaving the fleet permanently short.
  private func startReconcileLoop() {
    stopReconcileLoop()
    let interval = reconcileInterval
    reconcileTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval)
        if Task.isCancelled { break }
        await self?.reconcile()
      }
    }
  }

  private func stopReconcileLoop() {
    reconcileTask?.cancel()
    reconcileTask = nil
  }

  private func notify() { onChange?() }
}
