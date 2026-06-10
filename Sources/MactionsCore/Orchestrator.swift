import Foundation

/// What the user wants the fleet to look like. Persisted by the app; the core
/// just consumes it.
public struct FleetConfig: Equatable, Sendable {
  public var owner: String
  public var repo: String
  public var labels: [String]
  /// CEILING on concurrent runners for this combo. Scale-from-zero: the
  /// reconcile loop provisions `min(busy + matchingQueuedJobs, maxRunners)` —
  /// zero runners is the normal idle state. (Formerly `desiredCount`, a warm
  /// floor the fleet was held at even with no jobs queued.)
  public var maxRunners: Int

  public init(owner: String, repo: String, labels: [String], maxRunners: Int) {
    self.owner = owner
    self.repo = repo
    self.labels = labels
    self.maxRunners = max(1, maxRunners)
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
/// prefix). Called from the GO-ONLINE sweeps (explicit repos in `goOnline`,
/// each discovered repo at first discovery), BEFORE any new runner is
/// provisioned: a clean `stop()` deletes its own slots' registrations directly,
/// but a crash/force-quit skips that, leaving "ghost" registrations (agents
/// killed before they could self-deregister) that GitHub only auto-prunes much
/// later. NOTE: `stop()` does NOT route through this function — a machine-
/// prefix sweep would deregister a sibling combo's live runner out from under
/// it (combos share the machine prefix and stop independently under all-repos
/// discovery); it deletes only its own slots. The sweeps can opt into broader
/// stale cleanup for offline/non-busy `mactions-*` registrations left by old
/// host-name generations; online or busy runners from another Mac are kept.
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

/// Owns the lifecycle of the ephemeral runners for one `(repo, OS)` combo —
/// **scale-from-zero**: runners exist only while queued jobs need them.
///
/// Each reconcile tick polls the repo's QUEUED jobs, filters them to this
/// combo's labels (job labels ⊆ runner labels — GitHub's routing rule), and
/// converges the fleet to `min(busy + matchingQueued, maxRunners)`: scale-up
/// provisions JIT runners, scale-down trims confirmed-idle surplus (a job that
/// vanished — taken elsewhere or cancelled). Zero runners is the normal idle
/// state; the poll keeps ticking (at a slower idle pace) and rides on ETags so
/// it's free against the rate limit. On a FAILED queue poll the fleet HOLDS —
/// a transient API error must never read as "queue is empty".
///
/// An `epoch` counter invalidates in-flight provisions/recycles the moment
/// `stop()` runs, so a slow JIT-config call or a late exit callback can never
/// revive a fleet the user already took offline. Teardown only touches runners
/// under *this machine's* prefix (see `machineRunnerPrefix`).
@MainActor
public final class RunnerOrchestrator {
  private let controlPlane: RunnerControlPlane
  private let factory: RunnerProviderFactory
  private let config: FleetConfig
  /// Which OS this fleet runs — stamps `RunRecord`s for history AND keys this
  /// combo's draw on the shared `HostBudget`. The control loop is otherwise
  /// OS-agnostic; the provider does the OS-specific work.
  private let os: RunnerOS
  /// Live capacity ledger SHARED across every combo (Windows VMs and Linux
  /// containers are RAM/CPU-bounded host-wide, not per-combo). `nil` = uncapped
  /// (macOS agent processes, tests). Acquired per provision, released on every
  /// slot exit/reap — see `HostBudget`.
  private let budget: HostBudget?
  private let machinePrefix: String
  private let reconcileInterval: UInt64
  /// Tick pace while idle AT ZERO (no slots, empty queue): poll less often —
  /// nothing local needs supervising, and job-pickup latency only grows by the
  /// difference. Any activity flips back to `reconcileInterval`.
  private let idleReconcileInterval: UInt64
  /// A just-launched VM/local agent can take a short time to register with
  /// GitHub. Do not treat a missing remote runner as stale until this grace has
  /// elapsed.
  private let remoteRegistrationGraceInterval: TimeInterval
  /// JIT runner credentials are short-lived. An idle runner can look locally
  /// healthy while GitHub can no longer assign it useful work, so refresh idle
  /// slots before that window closes. `nil` disables age-based refresh. (Under
  /// scale-from-zero this only fires while a matching job sits queued-but-
  /// unclaimed past the window — rare; surplus idle runners are trimmed by the
  /// demand loop long before it.)
  private let idleJITRefreshInterval: TimeInterval?
  /// Minimum age before a surplus idle runner may be trimmed. Gives GitHub a
  /// fair window to assign the queued job that triggered the provision before
  /// we conclude the job vanished (taken by another runner, or cancelled).
  private let idleTrimGraceInterval: TimeInterval
  /// Minimum WALL-CLOCK time between first observing a slot surplus-idle and
  /// actually trimming it (the two-snapshot rule's confirmation window). Must
  /// be long enough that the confirming observation is genuinely fresh data —
  /// exit-triggered reconciles can re-run within milliseconds of the mark.
  private let trimConfirmInterval: TimeInterval
  /// A non-zero exit from a runner GitHub NEVER confirmed online, younger than
  /// this, is a LAUNCH failure (e.g. the container daemon died mid-session):
  /// don't record a run, don't hot-loop a replacement — the periodic tick
  /// paces the retry.
  private let launchFailureGraceInterval: TimeInterval

  /// What the last queue poll saw — the UI's window into scale-from-zero
  /// (zero runners is the normal armed state, so the demand signal itself is
  /// what tells the user "watching, nothing queued" apart from "broken").
  public struct DemandSnapshot: Equatable, Sendable {
    /// Matching queued jobs at the last successful poll.
    public var queuedMatching = 0
    /// When the queue was last successfully polled.
    public var lastPolledAt: Date?
    /// The most recent poll failed (the fleet HOLDS until one succeeds).
    public var lastPollFailed = false
    /// A provision was denied by the shared host budget while demand remains —
    /// "N queued" is waiting on capacity, not starting. Cleared when capacity
    /// is acquired or demand drains.
    public var waitingForCapacity = false
  }

  public private(set) var state: FleetState = .offline
  public private(set) var lastError: String?
  public private(set) var demand = DemandSnapshot()
  /// Consecutive launch failures (handleExit's launch-failure branch) with no
  /// runner reaching GitHub in between — ≥2 means the substrate is likely
  /// broken (dead daemon, bad base image) and "starting…" would be a lie.
  private var consecutiveLaunchFailures = 0
  public var launchFailing: Bool { consecutiveLaunchFailures >= 2 }
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
    /// When this slot first looked unhealthy (missing from GitHub's list, or not
    /// `online`), or `nil` while it looks healthy. The missing/non-online prune
    /// keys off SUSTAINED unhealth (≥ the grace interval), not "old enough + a
    /// single bad reading": one transient eventual-consistency / connection blip
    /// must NOT tear down a runner that's mid-job (which orphans the job). The flip
    /// side is the cleanup we DO want — a runner that's genuinely running a job
    /// stays online+busy on GitHub, so a runner that's been OFFLINE for the whole
    /// grace window is a dead agent (e.g. a sleep/crash/force-quit "ghost" that
    /// shows offline-but-busy) and gets reaped + deregistered.
    var unhealthySince: Date?
    /// Set when `pruneUnusableSlots` reaps this slot (idle-JIT refresh or
    /// sustained-offline). The Local/Linux providers' `stop()` SIGTERMs the
    /// agent, whose terminationHandler still fires `onExit` — without this
    /// flag, `handleExit` would record every routine refresh as a `failed` run
    /// (observed live 2026-06-09: history full of exit-143 "failed" entries
    /// that were just the 8-min idle refresh). Reaps are fleet maintenance,
    /// not runs; only exits the orchestrator did NOT initiate get recorded.
    var reaped = false
    /// True while this slot holds one unit of the shared `HostBudget`. Cleared
    /// by `releaseBudget` exactly once, on whichever path removes the slot
    /// (natural exit, prune reap, trim, teardown).
    var holdsBudget = false
    /// Set once `provisionOne` records the slot into `slots`. An exit callback
    /// firing BEFORE this (rare: the exit must beat the detached-start
    /// continuation onto the main actor) must not be lost: `handleExit` stashes
    /// the status in `earlyExitStatus` and `provisionOne` discards the
    /// stillborn slot instead of appending a zombie that would pin a budget
    /// unit and a fleet slot for the 5-minute unhealth grace. (The common
    /// async launch death lands AFTER append — `handleExit`'s launch-failure
    /// branch covers it via `confirmedOnline`.)
    var appended = false
    var earlyExitStatus: Int32?
    /// When this slot was first observed surplus-idle — the trim two-snapshot
    /// rule (see `trimIdleSurplus`). TIME-based on purpose: exit-triggered
    /// reconciles can run passes milliseconds apart, so a tick-count gate would
    /// let two near-simultaneous "snapshots" (reading the same stale busy data)
    /// confirm a trim. Cleared whenever the slot is busy, demanded, or
    /// unconfirmed again; NOT refreshed by a too-soon confirming pass.
    var trimMarkedAt: Date?
    /// GitHub confirmed this runner online at least once (set by
    /// `pruneUnusableSlots`). An exit BEFORE any confirmation is a launch
    /// failure, not a run — see `handleExit`.
    var confirmedOnline = false
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
  /// Set by reconcile when slots == 0 AND the queue is empty; the loop then
  /// ticks at `idleReconcileInterval`. A failed poll keeps the previous pace.
  /// Internal-read for tests (@testable) — pace is otherwise only observable
  /// by timing.
  private(set) var idleAtZero = false
  /// Monotonic reconcile-pass counter, for the trim two-snapshot rule.
  private var reconcileTick = 0

  public init(
    controlPlane: RunnerControlPlane,
    factory: RunnerProviderFactory,
    config: FleetConfig,
    os: RunnerOS = .macOS,
    budget: HostBudget? = nil,
    machinePrefix: String = machineRunnerPrefix(),
    reconcileInterval: UInt64 = 30_000_000_000,
    idleReconcileInterval: UInt64 = 60_000_000_000,
    remoteRegistrationGraceInterval: TimeInterval = 5 * 60,
    idleJITRefreshInterval: TimeInterval? = 8 * 60,
    idleTrimGraceInterval: TimeInterval = 90,
    trimConfirmInterval: TimeInterval = 25,
    launchFailureGraceInterval: TimeInterval = 30
  ) {
    self.controlPlane = controlPlane
    self.factory = factory
    self.config = config
    self.os = os
    self.budget = budget
    self.machinePrefix = machinePrefix
    self.reconcileInterval = reconcileInterval
    self.idleReconcileInterval = idleReconcileInterval
    self.remoteRegistrationGraceInterval = remoteRegistrationGraceInterval
    self.idleJITRefreshInterval = idleJITRefreshInterval
    self.idleTrimGraceInterval = idleTrimGraceInterval
    self.trimConfirmInterval = trimConfirmInterval
    self.launchFailureGraceInterval = launchFailureGraceInterval
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
    // Deregister FIRST (fast API calls), BEFORE the local teardown below — a
    // Windows VM can take >10s to power off + delete, and the quit/sleep handlers
    // bound this whole call with a deadline. If a slow teardown ran first and the
    // deadline cut us off before the deregister, GitHub would be left with a
    // still-registered runner it thinks is busy → an orphaned job "stuck" at its
    // last step until GitHub's hours-long lost-communication timeout. Removing the
    // registration up front instead makes GitHub fail any in-flight job cleanly.
    //
    // Scoped to THIS orchestrator's OWN slots — NOT a machine-prefix sweep.
    // Every combo on this Mac shares the machine prefix, and under
    // scale-from-zero single orchestrators stop while siblings stay live (the
    // all-repos discovery reap): a prefix sweep here would deregister a sibling
    // combo's runner out from under it. Crash ghosts (slots we never knew
    // about) are covered by the go-online prefix sweep + GitHub's 1-day
    // auto-prune of disconnected ephemeral runners.
    for slot in current {
      if let id = slot.remoteId { try? await controlPlane.deleteRunner(id: id) }
    }
    // Now reclaim the local VMs/containers/processes (the registrations are
    // already gone, so a leftover here is just disk — swept on next go-online).
    for slot in current {
      slot.provider.stop()
      releaseBudget(slot)
    }
    state = .offline
    notify()
  }

  /// What `pruneUnusableSlots` learned from GitHub's runner list, for the
  /// demand math: which SURVIVING slots are confirmed busy (mid-job) vs
  /// confirmed idle (online + assignable). A slot in neither set is still
  /// registering — it is counted toward the slot total but never trimmed.
  private struct SlotHealth {
    var busy: Set<String> = []
    var idle: Set<String> = []
  }

  /// Demand-driven reconcile: converge the fleet to
  /// `min(busy + matchingQueuedJobs, maxRunners)` — provision the shortfall,
  /// trim the confirmed-idle surplus. Idempotent and re-entrancy-guarded; safe
  /// to call from start(), an exit callback, or the periodic loop.
  private func reconcile() async {
    guard state == .starting || state == .online, !reconciling else { return }
    reconciling = true
    defer { reconciling = false }
    let myEpoch = epoch
    reconcileTick += 1

    // 1. Prune dead/stale slots against GitHub's authoritative runner state
    //    FIRST, learning which survivors are busy vs idle. Ordering matters:
    //    reading runners BEFORE the queue means a job assigned between the two
    //    reads vanishes from the queue while its runner may not show busy yet —
    //    an UNDER-count, self-corrected next tick. Queue-first would
    //    double-count that job (demand AND busy) and boot a spurious runner.
    //    `nil` health = the runner list couldn't be fetched.
    var health: SlotHealth? = SlotHealth()
    if state == .online, !slots.isEmpty {
      health = await pruneUnusableSlots(epoch: myEpoch)
      guard epoch == myEpoch, state == .online else { return }
    }

    // 2. Demand: queued jobs whose labels this combo's runners satisfy. A
    //    FAILED poll HOLDS the fleet (no scaling in either direction): a
    //    transient API error must never read as "queue is empty".
    let demand: Int
    do {
      let queued = try await controlPlane.listQueuedJobLabels()
      demand = queued.filter { jobLabelsMatchRunner(job: $0, runner: config.labels) }.count
    } catch {
      lastError = String(describing: error)
      self.demand.lastPollFailed = true
      notify()
      return
    }
    guard epoch == myEpoch, state == .starting || state == .online else { return }
    idleAtZero = demand == 0 && slots.isEmpty
    // Demand draining also clears the capacity-wait flag (nothing left to wait
    // for); while demand persists the flag carries over until an acquire
    // succeeds, so "waiting for capacity" survives the tick boundary.
    let stillWaiting = demand > 0 && self.demand.waitingForCapacity
    let demandChanged =
      demand != self.demand.queuedMatching || self.demand.lastPollFailed
      || self.demand.waitingForCapacity != stillWaiting
    self.demand = DemandSnapshot(
      queuedMatching: demand, lastPolledAt: Date(), lastPollFailed: false,
      waitingForCapacity: stillWaiting)
    if demandChanged { notify() }  // lastPolledAt alone isn't worth a UI churn

    // 3. Converge.
    guard let health else {
      // The queue read is real but busy-ness is unknown (listRunners failed).
      // Assume every current slot is busy: demand that PERSISTS alongside
      // genuinely idle runners doesn't happen (GitHub assigns within seconds),
      // so queued jobs likely need new runners. Scale up only (to a FIXED
      // target — the assumption is about the pre-existing slots) — never trim
      // on unknown state; and clear trim marks (conservative: restart the
      // confirmation clock rather than confirm against unknown busy-ness).
      for slot in slots { slot.trimMarkedAt = nil }
      let target = min(slots.count + demand, config.maxRunners)
      await scaleUp(target: { target }, epoch: myEpoch)
      return
    }
    // Recompute the target each provision against the LIVE busy set: a busy
    // slot exiting during a provision await shrinks it (the job is done —
    // replacing it against zero demand would boot a phantom runner).
    let busyNames = health.busy
    await scaleUp(
      target: { [weak self] in
        guard let self else { return 0 }
        let liveBusy = busyNames.intersection(Set(self.slots.map(\.name))).count
        return min(liveBusy + demand, self.config.maxRunners)
      }, epoch: myEpoch)
    guard epoch == myEpoch, state == .starting || state == .online else { return }
    let target = min(busyNames.intersection(Set(slots.map(\.name))).count + demand, config.maxRunners)
    if slots.count > target {
      await trimIdleSurplus(downTo: target, idle: health.idle, epoch: myEpoch)
    } else {
      for slot in slots { slot.trimMarkedAt = nil }  // demand is back — unmark
    }
  }

  private func scaleUp(target: @MainActor () -> Int, epoch myEpoch: Int) async {
    while slots.count < target() {
      let ok = await provisionOne(epoch: myEpoch)
      // Bail if we were stopped mid-flight, or on a transient failure (the
      // periodic loop / next exit retries — we never spin).
      guard epoch == myEpoch, state == .starting || state == .online else { return }
      if !ok { break }
    }
  }

  /// Scale-down: trim surplus runners the queue no longer justifies (their job
  /// was taken by another runner, or cancelled). Two safety layers against
  /// reaping a runner that's actually winning a job:
  ///
  /// 1. TWO-SNAPSHOT rule, TIME-based: a slot is only deleted once it has been
  ///    continuously surplus-idle for `trimConfirmInterval` since first marked
  ///    (`trimMarkedAt`). Time, not ticks, on purpose — exit-triggered
  ///    reconciles can run passes milliseconds apart on the SAME stale busy
  ///    data, so "a later pass" is not "a fresh observation". A job assigned in
  ///    the window flips the runner busy / restores demand, which unmarks it.
  /// 2. Deregister-FIRST, then stop: GitHub refuses to delete a runner that is
  ///    actively running a job, so a runner that won a job in the final
  ///    sub-second window is (best-effort) protected server-side — on a failed
  ///    delete we keep the slot.
  ///
  /// Only confirmed-idle slots past `idleTrimGraceInterval` are candidates
  /// (give GitHub a fair window to assign before concluding the job vanished),
  /// oldest first. Trims are fleet maintenance, not runs — never recorded.
  private func trimIdleSurplus(downTo target: Int, idle: Set<String>, epoch myEpoch: Int) async {
    let now = Date()
    let candidates =
      slots
      .filter {
        idle.contains($0.name) && now.timeIntervalSince($0.startedAt) >= idleTrimGraceInterval
      }
      .sorted { $0.startedAt < $1.startedAt }
    let candidateIds = Set(candidates.map(ObjectIdentifier.init))
    for slot in slots where !candidateIds.contains(ObjectIdentifier(slot)) {
      slot.trimMarkedAt = nil  // busy / unconfirmed again — restart its clock
    }
    for slot in candidates {
      // Live recheck: exits can land during the awaits below and shrink the
      // surplus out from under a stale snapshot.
      guard slots.count > target else { break }
      guard let remoteId = slot.remoteId else { continue }
      // First sighting only marks; a too-soon confirming pass neither deletes
      // NOR refreshes the mark (refreshing would let back-to-back passes push
      // the clock forever without ever trimming).
      guard let marked = slot.trimMarkedAt else {
        slot.trimMarkedAt = now
        continue
      }
      guard now.timeIntervalSince(marked) >= trimConfirmInterval else { continue }
      // Before the delete AWAIT: if the SIGTERM'd/raced agent exits mid-await,
      // handleExit must see the reap flag and not record a phantom failed run.
      slot.reaped = true
      do {
        try await controlPlane.deleteRunner(id: remoteId)
      } catch {
        // It just took a job (GitHub rejects deleting a busy runner) — keep it,
        // and let its eventual natural exit record normally.
        slot.reaped = false
        slot.trimMarkedAt = nil
        continue
      }
      guard epoch == myEpoch, state == .online else { return }
      stopProviderOffMain(slot)
      slots.removeAll { $0 === slot }
      notify()
    }
  }

  /// Tear a reaped slot's provider down OFF the main actor, releasing its
  /// budget unit only once the substrate is actually gone. A Windows VM stop
  /// is `vmrun stop` + poll + `deleteVM` (potentially >10s) — calling it
  /// inline would freeze the UI on every routine trim/refresh, and releasing
  /// the budget before the VM's RAM is back would briefly overcommit the host.
  ///
  /// Deliberately NOT routed through `self`: the budget is SHARED across
  /// combos and outlives this orchestrator — a discovery-reaped combo can
  /// deallocate while a slow teardown is still in flight, and a `self?`-gated
  /// release would leak the unit for the rest of the online session (silently
  /// denying every future provision of this OS host-wide). The exactly-once
  /// invariant rides on `slot.holdsBudget`, read/cleared on the main actor.
  private func stopProviderOffMain(_ slot: Slot) {
    let provider = slot.provider
    let budget = self.budget
    let os = self.os
    Task.detached {
      provider.stop()
      await MainActor.run {
        guard slot.holdsBudget else { return }
        slot.holdsBudget = false
        budget?.release(os)
      }
    }
  }

  /// Reconcile local slots with GitHub's authoritative runner state. The
  /// provider can only know "process/VM is alive"; GitHub decides whether a
  /// runner is online and assignable. This catches stale JIT registrations that
  /// expired while an idle provider kept running locally. Returns the surviving
  /// slots' busy/idle health, or `nil` when the runner list couldn't be
  /// fetched (the caller must not trim on unknown state).
  private func pruneUnusableSlots(epoch myEpoch: Int) async -> SlotHealth? {
    guard !slots.isEmpty else { return SlotHealth() }
    let remote: [RemoteRunner]
    do {
      remote = try await controlPlane.listRunners()
    } catch {
      lastError = String(describing: error)
      notify()
      return nil
    }
    guard epoch == myEpoch, state == .online else { return nil }

    let byId = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let byName = Dictionary(remote.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let now = Date()
    var stale: [(slot: Slot, remote: RemoteRunner?)] = []
    var refresh: [(slot: Slot, remote: RemoteRunner)] = []

    for slot in slots {
      let remoteRunner = slot.remoteId.flatMap { byId[$0] } ?? byName[slot.name]
      let age = now.timeIntervalSince(slot.startedAt)
      let healthy = remoteRunner?.status.lowercased() == "online"

      if !healthy {
        // Missing from GitHub's list, or not online. Prune ONLY after SUSTAINED
        // unhealth (≥ grace), never on a single bad reading — a transient
        // eventual-consistency / connection blip must not tear down a runner
        // that's mid-job (that orphans the job). Conversely, a runner that's been
        // offline for the whole grace window is a genuinely DEAD agent — a live
        // job keeps the runner online+busy on GitHub — so reaping + deregistering
        // it is exactly the cleanup that clears an offline-but-busy "ghost" left
        // by a sleep / crash / force-quit. (Whether it was ever busy is
        // irrelevant: sustained-offline == dead.)
        if slot.unhealthySince == nil { slot.unhealthySince = now }
        if age >= remoteRegistrationGraceInterval,
          now.timeIntervalSince(slot.unhealthySince ?? now) >= remoteRegistrationGraceInterval
        {
          stale.append((slot, remoteRunner))
        }
        continue
      }

      // Online: a recovered blip clears the unhealthy clock. Then refresh a
      // long-IDLE runner before its short-lived JIT registration expires — the
      // `!busy` guard keeps a runner that's executing a job (never refresh it out
      // from under, which would orphan the job).
      slot.unhealthySince = nil
      slot.confirmedOnline = true  // a later quick exit is a run, not a launch failure
      consecutiveLaunchFailures = 0  // a runner reached GitHub: launches work again
      if let idleJITRefreshInterval, idleJITRefreshInterval >= 0,
        let remoteRunner, !remoteRunner.busy, age >= idleJITRefreshInterval
      {
        refresh.append((slot, remoteRunner))
      }
    }

    let reapIds = Set((stale.map(\.slot) + refresh.map(\.slot)).map(ObjectIdentifier.init))
    var health = SlotHealth()
    for slot in slots where !reapIds.contains(ObjectIdentifier(slot)) {
      guard let remoteRunner = slot.remoteId.flatMap({ byId[$0] }) ?? byName[slot.name],
        remoteRunner.status.lowercased() == "online"
      else { continue }  // still registering (or mid-blip): neither busy nor trimmable
      if remoteRunner.busy {
        health.busy.insert(slot.name)
      } else {
        health.idle.insert(slot.name)
      }
    }

    // Sustained-unhealthy slots are DEAD agents: local teardown first, then a
    // best-effort deregister (there is no live job to race).
    if !stale.isEmpty {
      let staleIds = Set(stale.map { ObjectIdentifier($0.slot) })
      for item in stale {
        item.slot.reaped = true  // before stop(): its onExit can fire immediately
        stopProviderOffMain(item.slot)
      }
      slots.removeAll { staleIds.contains(ObjectIdentifier($0)) }
      notify()
      for item in stale {
        if let id = item.remote?.id ?? item.slot.remoteId {
          try? await controlPlane.deleteRunner(id: id)
        }
      }
      guard epoch == myEpoch, state == .online else { return health }
    }

    // Idle-JIT refresh reaps a LIVE runner, so deregister FIRST (like the trim
    // path): GitHub refuses to delete a runner that's running a job, so a
    // runner that won a job since our snapshot keeps both job and slot — we
    // just skip its refresh until it's idle again.
    for item in refresh {
      item.slot.reaped = true  // before the await: a mid-await exit must not record
      do {
        try await controlPlane.deleteRunner(id: item.remote.id)
      } catch {
        item.slot.reaped = false
        continue
      }
      guard epoch == myEpoch, state == .online else { return health }
      stopProviderOffMain(item.slot)
      slots.removeAll { $0 === item.slot }
      notify()
    }
    return health
  }

  /// Provision exactly one runner. Returns false on failure. The slot is only
  /// recorded **after** the agent actually launches, so a failed start can't
  /// leave a phantom "online" slot.
  private func provisionOne(epoch myEpoch: Int) async -> Bool {
    // Draw on the SHARED host capacity first (Windows VMs / Linux containers
    // are budgeted host-wide): at the ceiling we skip — not an error; capacity
    // frees when any combo's runner exits and the next tick retries. Flag the
    // denial so the UI can say "waiting for capacity" instead of "starting…".
    if let budget, !budget.tryAcquire(os) {
      if !demand.waitingForCapacity {
        demand.waitingForCapacity = true
        notify()
      }
      return false
    }
    if demand.waitingForCapacity {
      demand.waitingForCapacity = false
      notify()
    }
    var holdingBudget = budget != nil
    defer { if holdingBudget { budget?.release(os) } }

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
      // The agent can die during launch with its onExit landing BEFORE we
      // resume (only when the exit beats the detached-start continuation onto
      // the main actor — e.g. a provider that fails synchronously in start):
      // handleExit stashes the status here. Don't append a zombie slot — it
      // would read as a live runner, suppress real scale-up, and pin a budget
      // unit until the 5-minute unhealth grace reaps it. Treat it as a
      // provision failure (the defer refunds the budget; the next tick
      // retries). The more common ASYNC death (dead container daemon: `run`
      // exits ms after spawn) lands after append — handleExit's launch-failure
      // branch handles that ordering.
      if let status = slot.earlyExitStatus {
        lastError = "Runner \(jit.runnerName) exited during launch (status \(status))."
        try? await controlPlane.deleteRunner(id: jit.runnerId)
        notify()
        return false
      }
      // Hand the budget unit to the slot; from here it's released on whichever
      // path removes the slot (exit / reap / trim / teardown), not by our defer.
      slot.appended = true
      slot.holdsBudget = holdingBudget
      holdingBudget = false
      slots.append(slot)
      notify()
      return true
    } catch {
      lastError = String(describing: error)
      notify()
      return false
    }
  }

  /// Release this slot's draw on the shared host budget, exactly once.
  private func releaseBudget(_ slot: Slot) {
    guard slot.holdsBudget else { return }
    slot.holdsBudget = false
    budget?.release(os)
  }

  private func handleExit(_ slot: Slot, epoch slotEpoch: Int, status: Int32) {
    // Exit raced ahead of the slot being recorded (only when the exit beats the
    // detached-start continuation onto the main actor — e.g. a provider whose
    // start fails synchronously): park the status for provisionOne to discard
    // the stillborn slot. Nothing to remove, no budget held yet (the transfer
    // happens at append time).
    guard slot.appended else {
      slot.earlyExitStatus = status
      return
    }

    // LAUNCH failure: a non-zero exit from a runner GitHub never confirmed
    // online, within the launch grace. This is the COMMON dead-daemon shape —
    // `run` exits tens-to-hundreds of ms AFTER spawn, so the slot was already
    // appended and the early-exit discard above never sees it. Without this
    // branch every such death records a phantom `.failed` run AND hot-loops a
    // replacement at exit speed (the job is still queued): mint → die → mint,
    // thousands of JIT POSTs per hour. Instead: surface the error, clean up
    // the never-connected registration, and let the periodic tick pace the
    // retry. (Trade-off: a REAL job that fails in under the grace on a runner
    // we never saw online skips local history — GitHub's run history still has
    // it.)
    if status != 0, !slot.confirmedOnline, !slot.reaped,
      Date().timeIntervalSince(slot.startedAt) < launchFailureGraceInterval
    {
      consecutiveLaunchFailures += 1
      lastError = "Runner \(slot.name) exited during launch (status \(status))."
      releaseBudget(slot)
      if let index = slots.firstIndex(where: { $0 === slot }) {
        slots.remove(at: index)
      }
      notify()
      if epoch == slotEpoch, let remoteId = slot.remoteId {
        let plane = controlPlane
        Task { try? await plane.deleteRunner(id: remoteId) }
      }
      return  // no record, no immediate reconcile — the next tick retries
    }
    // Record the run ONLY when it ended on its own while the fleet is online — a
    // genuine end-of-life for an ephemeral runner (ran its one job, or the agent
    // crashed). Status 0 → `.completed`, non-zero → `.failed`.
    //
    // We deliberately do NOT record teardown reaps (go-offline/quit), prune
    // reaps (`slot.reaped` — idle-JIT refresh / sustained-offline), or stale-
    // generation late exits. Reasons: (1) they're noise — every idle runner is
    // reaped on each go-offline, and the idle refresh recycles runners every
    // ~8 min, which used to flood history with phantom exit-143 "failed" runs;
    // and (2) on teardown AppState drops the orchestrator the instant `stop()`
    // returns, while a provider's exit callback can still fire asynchronously
    // afterward — by then this `[weak self]` hop no-ops, so a record emitted on
    // that path would be lost unreliably anyway. Recording only the
    // orchestrator-didn't-initiate-it online path keeps history to "runs that
    // actually ran" and is race-free (the orchestrator is always alive here).
    if state == .online, epoch == slotEpoch, !slot.reaped {
      onRunFinished?(
        RunRecord(
          id: slot.name, os: os, repo: "\(config.owner)/\(config.repo)",
          remoteId: slot.remoteId, startedAt: slot.startedAt, endedAt: Date(),
          exitStatus: status, outcome: status == 0 ? .completed : .failed))
    }

    releaseBudget(slot)
    if let index = slots.firstIndex(where: { $0 === slot }) {
      slots.remove(at: index)
      notify()
    }
    // Re-reconcile only if this exit belongs to the current generation and
    // we're still meant to be online — never revive a fleet the user stopped.
    // Under scale-from-zero this is demand-GATED, not a blind replace: the
    // reconcile polls the queue and only re-provisions if jobs still wait.
    guard epoch == slotEpoch, state == .online else { return }
    Task { await reconcile() }
  }

  /// Periodic reconcile: polls the queued-jobs demand signal and self-heals
  /// transient provision failures. Ticks at `reconcileInterval` while anything
  /// is live or queued, relaxing to `idleReconcileInterval` when idle at zero
  /// (the ETag'd poll makes the idle tick free against the rate limit).
  private func startReconcileLoop() {
    stopReconcileLoop()
    let activePace = reconcileInterval
    let idlePace = idleReconcileInterval
    reconcileTask = Task { [weak self] in
      while !Task.isCancelled {
        let interval = self?.idleAtZero == true ? idlePace : activePace
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
