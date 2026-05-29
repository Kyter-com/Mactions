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
  private let machinePrefix: String
  private let reconcileInterval: UInt64

  public private(set) var state: FleetState = .offline
  public private(set) var lastError: String?
  /// Fired (on the main actor) whenever `state`/`runners` change.
  public var onChange: (() -> Void)?

  private final class Slot {
    let name: String
    var remoteId: Int?
    var phase: ManagedRunner.Phase
    let provider: RunnerProvider
    init(name: String, remoteId: Int?, phase: ManagedRunner.Phase, provider: RunnerProvider) {
      self.name = name; self.remoteId = remoteId; self.phase = phase; self.provider = provider
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
    machinePrefix: String = machineRunnerPrefix(),
    reconcileInterval: UInt64 = 30_000_000_000
  ) {
    self.controlPlane = controlPlane
    self.factory = factory
    self.config = config
    self.machinePrefix = machinePrefix
    self.reconcileInterval = reconcileInterval
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
    if let remote = try? await controlPlane.listRunners() {
      for r in remote where r.name.hasPrefix(machinePrefix) {
        try? await controlPlane.deleteRunner(id: r.id)
      }
    }
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
    while slots.count < config.desiredCount {
      let ok = await provisionOne(epoch: myEpoch)
      // Bail if we were stopped mid-flight, or on a transient failure (the
      // periodic loop / next exit retries — we never spin).
      guard epoch == myEpoch, state == .starting || state == .online else { return }
      if !ok { break }
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
      let slot = Slot(name: jit.runnerName, remoteId: jit.runnerId, phase: .online, provider: provider)
      try provider.start(jitConfig: jit.encodedConfig) { [weak self] _ in
        Task { @MainActor in self?.handleExit(slot, epoch: myEpoch) }
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

  private func handleExit(_ slot: Slot, epoch slotEpoch: Int) {
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
