import Foundation

/// The host's network path as Mactions compares it: whether it is usable, and
/// which interfaces carry it. A VPN connecting adds a `utun` interface; Wi-Fi
/// joining, leaving or switching changes the rest. Built by the app from
/// `NWPathMonitor` updates; kept here so the comparison is unit-tested.
public struct NetworkPathSnapshot: Equatable, Sendable {
  public var usable: Bool
  /// Sorted and de-duplicated, so the order the system lists them in does
  /// not read as a change.
  public var interfaces: [String]

  public init(usable: Bool, interfaces: [String]) {
    self.usable = usable
    self.interfaces = Array(Set(interfaces)).sorted()
  }

  /// One token for the control-plane log, e.g. `up:en0,utun420`.
  public var summary: String {
    (usable ? "up" : "down") + ":" + interfaces.joined(separator: ",")
  }
}

/// Decides which settled path snapshots are changes worth acting on. The first
/// one is the baseline a monitor reports when it starts, not a change, and a
/// repeat of the last one is not a change either.
public struct NetworkChangeFilter: Sendable {
  private var last: NetworkPathSnapshot?

  public init() {}

  public mutating func isChange(_ snapshot: NetworkPathSnapshot) -> Bool {
    defer { last = snapshot }
    guard let last else { return false }
    return snapshot != last
  }
}

/// A wait that ends after a time limit or at the first `kick()`, whichever
/// comes first. A kick while nobody is waiting ends the next wait at once, so
/// a kick that lands mid-scan is not lost. The all-repos scan loop waits on
/// one between scans, and a network change kicks it.
@MainActor
public final class KickableWait {
  private var waiting: AsyncStream<Void>.Continuation?
  private var pending = false

  public init() {}

  /// Waits up to `seconds`. Returns `true` when a kick ended it, `false` when
  /// the time ran out or the calling task was cancelled.
  @discardableResult
  public func wait(seconds: TimeInterval) async -> Bool {
    if pending {
      pending = false
      return true
    }
    let (kicks, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    waiting = continuation
    let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
    let kicked = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        try? await Task.sleep(nanoseconds: nanoseconds)
        return false
      }
      group.addTask {
        var iterator = kicks.makeAsyncIterator()
        return await iterator.next() != nil
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    continuation.finish()
    waiting = nil
    return kicked && !Task.isCancelled
  }

  /// End the current wait now, or the next one if nothing is waiting.
  public func kick() {
    if let waiting {
      waiting.yield()
    } else {
      pending = true
    }
  }

  /// Forget a kick nobody waited for (a new loop starts fresh).
  public func reset() {
    pending = false
  }
}
