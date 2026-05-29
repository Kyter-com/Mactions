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

/// Owns the lifecycle of N ephemeral runners. `start()` provisions the fleet;
/// each runner is single-use, so when one finishes a job (or dies) it's
/// replaced while we're online. `stop()` tears everything down and best-effort
/// deregisters server-side. MainActor-isolated: it's small, UI-adjacent state.
@MainActor
public final class RunnerOrchestrator {
  private let controlPlane: RunnerControlPlane
  private let factory: RunnerProviderFactory
  private let config: FleetConfig
  private let runnerNamePrefix = "mactions"

  public private(set) var state: FleetState = .offline
  public private(set) var lastError: String?
  /// Fired (on the main actor) whenever `state`/`runners` change, so the app
  /// can republish to SwiftUI without the core depending on Combine.
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

  public init(controlPlane: RunnerControlPlane, factory: RunnerProviderFactory, config: FleetConfig) {
    self.controlPlane = controlPlane
    self.factory = factory
    self.config = config
  }

  public var runners: [ManagedRunner] {
    slots.map { ManagedRunner(id: $0.name, remoteId: $0.remoteId, phase: $0.phase) }
  }

  public func start() async {
    guard state == .offline else { return }
    state = .starting
    lastError = nil
    notify()
    for _ in 0..<config.desiredCount { await provision() }
    state = .online
    notify()
  }

  public func stop() async {
    guard state == .online || state == .starting || state == .stopping else { return }
    state = .stopping
    notify()
    let current = slots
    slots = []
    notify()
    for slot in current { slot.provider.stop() }
    // Belt-and-suspenders cleanup: ephemeral runners deregister themselves on
    // exit, but a killed agent can leave a "ghost" until GitHub's offline
    // sweep. Proactively delete anything still registered under our prefix.
    if let remote = try? await controlPlane.listRunners() {
      for r in remote where r.name.hasPrefix(runnerNamePrefix) {
        try? await controlPlane.deleteRunner(id: r.id)
      }
    }
    state = .offline
    notify()
  }

  private func provision() async {
    let name = "\(runnerNamePrefix)-\(shortHost())-\(String(UUID().uuidString.prefix(6)).lowercased())"
    do {
      let jit = try await controlPlane.generateJITConfig(name: name, labels: config.labels)
      let provider = factory.makeProvider(name: jit.runnerName)
      let slot = Slot(name: jit.runnerName, remoteId: jit.runnerId, phase: .online, provider: provider)
      slots.append(slot)
      notify()
      try provider.start(jitConfig: jit.encodedConfig) { [weak self] status in
        Task { @MainActor in self?.handleExit(slot, status: status) }
      }
    } catch {
      lastError = String(describing: error)
      notify()
    }
  }

  private func handleExit(_ slot: Slot, status: Int32) {
    guard let index = slots.firstIndex(where: { $0 === slot }) else { return }
    slots.remove(at: index)
    notify()
    // While online, an exited runner means a job finished (or crashed) — bring
    // a fresh ephemeral one up to keep the fleet at desiredCount.
    if state == .online {
      Task { await provision() }
    }
  }

  private func shortHost() -> String {
    let host = ProcessInfo.processInfo.hostName
      .replacingOccurrences(of: ".local", with: "")
      .lowercased()
    let safe = host.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    return String(safe.prefix(20)).isEmpty ? "mac" : String(safe.prefix(20))
  }

  private func notify() { onChange?() }
}
