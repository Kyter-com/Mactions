import Foundation
import MactionsCore
import Network

/// Watches the Mac's network path and reports a settled change on the main
/// actor: Wi-Fi joined, lost or switched, a VPN connecting or dropping.
/// Sleep/wake notifications don't cover these, and on 2026-10-24 they were
/// what changed under a running fleet: plane Wi-Fi reconnecting, and a VPN
/// coming back minutes after wake while the first scans after wake failed.
@MainActor
final class NetworkPathWatcher {
  static let shared = NetworkPathWatcher()

  /// A Wi-Fi roam or a VPN reconnect produces several path updates within a
  /// second or two; act once they stop.
  private let settleNanoseconds: UInt64 = 2_000_000_000
  private let monitor = NWPathMonitor()
  private var filter = NetworkChangeFilter()
  private var settling: Task<Void, Never>?
  private var started = false

  /// Called once per settled change (never for the baseline at start).
  var onChange: ((NetworkPathSnapshot) -> Void)?

  func start() {
    guard !started else { return }
    started = true
    monitor.pathUpdateHandler = { [weak self] path in
      let snapshot = NetworkPathSnapshot(
        usable: path.status == .satisfied, interfaces: path.availableInterfaces.map(\.name))
      Task { @MainActor in self?.receive(snapshot) }
    }
    monitor.start(queue: DispatchQueue(label: "com.kyter.mactions.network-path"))
  }

  private func receive(_ snapshot: NetworkPathSnapshot) {
    settling?.cancel()
    let settle = settleNanoseconds
    settling = Task { [weak self] in
      try? await Task.sleep(nanoseconds: settle)
      guard !Task.isCancelled, let self else { return }
      if self.filter.isChange(snapshot) { self.onChange?(snapshot) }
    }
  }
}
