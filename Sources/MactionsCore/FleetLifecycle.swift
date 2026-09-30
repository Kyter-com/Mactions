import Foundation

/// Orders app-level shutdown and sleep/wake requests without depending on
/// AppKit. Providers may still be tearing down when a short sleep ends.
@MainActor
public final class FleetLifecycle {
  private var shutdownTask: Task<Void, Never>?
  private var resumeTask: Task<Void, Never>?
  private var generation = 0
  private var shouldResume = false
  public private(set) var isSleeping = false
  public var allowsStart: Bool { !isSleeping && shutdownTask == nil }

  public init() {}

  /// All callers wait for the same teardown. A second request must not remove
  /// state or run folders after the first caller has already restarted.
  public func shutDown(_ operation: @escaping @MainActor () async -> Void) async {
    await beginShutdown(operation).value
  }

  /// Register synchronously, before the operation is scheduled. Repeated sleep,
  /// restart, or stop requests must not enqueue separate delayed teardowns.
  private func beginShutdown(
    _ operation: @escaping @MainActor () async -> Void
  ) -> Task<Void, Never> {
    if let shutdownTask { return shutdownTask }
    let task = Task {
      await operation()
      shutdownTask = nil
    }
    shutdownTask = task
    return task
  }

  /// An explicit restart shares the same resume intent as sleep/wake, so a
  /// sleep or offline request arriving during teardown can defer or cancel it.
  public func restart(
    suspend: @escaping @MainActor () async -> Void,
    resume: @escaping @MainActor () -> Void
  ) {
    generation += 1
    resumeTask?.cancel()
    resumeTask = nil
    shouldResume = true
    _ = beginShutdown(suspend)
    resumeAfterShutdown(resume)
  }

  public func willSleep(
    wasRunning: Bool, suspend: @escaping @MainActor () async -> Void
  ) {
    isSleeping = true
    generation += 1
    resumeTask?.cancel()
    resumeTask = nil
    // Preserve the intent across another sleep while the previous wake is
    // still waiting for shutdown. An already-offline fleet stays offline.
    shouldResume = shouldResume || wasRunning
    guard shouldResume else { return }
    _ = beginShutdown(suspend)
  }

  public func didWake(resume: @escaping @MainActor () -> Void) {
    isSleeping = false
    resumeAfterShutdown(resume)
  }

  private func resumeAfterShutdown(_ resume: @escaping @MainActor () -> Void) {
    guard !isSleeping, shouldResume, resumeTask == nil else { return }
    let expectedGeneration = generation
    let pendingShutdown = shutdownTask
    resumeTask = Task {
      await pendingShutdown?.value
      guard !Task.isCancelled, generation == expectedGeneration, shouldResume else { return }
      shouldResume = false
      resumeTask = nil
      resume()
    }
  }

  /// Quit or an explicit offline request revokes any pending automatic resume.
  /// Teardown itself continues even if its caller no longer wants to wait.
  public func cancelResume() {
    generation += 1
    shouldResume = false
    resumeTask?.cancel()
    resumeTask = nil
  }
}
