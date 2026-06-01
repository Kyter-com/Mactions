import Foundation

/// How many concurrent Win11-ARM VMs the host can run without thrashing.
///
/// Each per-job runner is a full VM (default 8 GB RAM / 4 vCPU), so N selected
/// repos each booting one simultaneously would otherwise exhaust physical RAM
/// and lag the whole Mac. This is the pure, unit-testable budget the app uses to
/// cap how many Windows fleets it stamps on go-online. macOS runners are
/// lightweight local processes and are NOT counted here.
public enum WindowsVMBudget {
  /// Max concurrent Windows VMs given the host's physical memory.
  ///
  /// Reserves `reservedGB` for macOS, the app, and the lightweight macOS runner
  /// agents, then divides the remainder by the per-VM footprint. Returns `0`
  /// when the host can't fit even one VM without thrashing — the caller should
  /// then skip the Windows fleet entirely and tell the user, rather than swap
  /// the machine to its knees.
  public static func maxConcurrentVMs(
    physicalMemoryBytes: UInt64,
    perVMGB: Int = 8,
    reservedGB: Int = 6
  ) -> Int {
    let totalGB = Int(physicalMemoryBytes / (1024 * 1024 * 1024))
    let usableGB = totalGB - reservedGB
    guard perVMGB > 0, usableGB >= perVMGB else { return 0 }
    return usableGB / perVMGB
  }
}
