import Foundation

/// Soft host-wide admission budget for bare-host macOS runner processes.
///
/// Unlike Windows VMs and Linux containers, a local macOS runner cannot be given
/// a reliable per-job memory or disk hard limit: workflow code runs directly on
/// the host. This budget is therefore an admission cap, not isolation. It keeps
/// all-repos mode from starting an unbounded number of local CI jobs at once.
public enum MacOSLocalBudget {
  /// Conservative default: a GitHub-hosted private macOS runner is not directly
  /// comparable to a laptop host, but 2 active cores per job avoids saturating
  /// the UI under normal developer workloads.
  public static let defaultCPUsPerRunner = 2
  /// Soft RAM allowance per active local job. Jobs can exceed it, but the cap
  /// prevents Mactions from admitting too many jobs for the machine size.
  public static let defaultMemoryGBPerRunner = 4
  /// Soft disk allowance per active local job for checkouts/build artifacts.
  public static let defaultStorageGBPerRunner = 20

  public static func maxConcurrentRunners(
    physicalMemoryBytes: UInt64,
    activeProcessorCount: Int,
    availableStorageBytes: UInt64? = nil,
    memoryGBPerRunner: Int = defaultMemoryGBPerRunner,
    cpusPerRunner: Int = defaultCPUsPerRunner,
    storageGBPerRunner: Int = defaultStorageGBPerRunner,
    reservedMemoryGB: Int = 4,
    reservedStorageGB: Int = 20
  ) -> Int {
    guard memoryGBPerRunner > 0, cpusPerRunner > 0, storageGBPerRunner > 0 else { return 0 }

    let totalMemoryGB = Int(physicalMemoryBytes / (1024 * 1024 * 1024))
    let usableMemoryGB = totalMemoryGB - reservedMemoryGB
    let byRAM = usableMemoryGB >= memoryGBPerRunner ? usableMemoryGB / memoryGBPerRunner : 0
    let byCPU = max(0, activeProcessorCount) / cpusPerRunner

    var limits = [byRAM, byCPU]
    if let availableStorageBytes {
      let storageGB = Int(availableStorageBytes / (1024 * 1024 * 1024))
      let usableStorageGB = storageGB - reservedStorageGB
      let byStorage = usableStorageGB >= storageGBPerRunner ? usableStorageGB / storageGBPerRunner : 0
      limits.append(byStorage)
    }
    return max(0, limits.min() ?? 0)
  }
}
