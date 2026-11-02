import Foundation

/// Soft host-wide admission budget for bare-host macOS runner processes.
///
/// Unlike Windows VMs and Linux containers, a local macOS runner cannot be given
/// a reliable per-job memory or disk hard limit: workflow code runs directly on
/// the host. This budget is therefore an admission cap, not isolation. It keeps
/// all-repos mode from starting an unbounded number of local CI jobs at once.
///
/// RAM and cores are fixed, but free disk moves while the fleet runs. AppState
/// re-reads it every 30 s and moves the live `HostBudget` limit with it, so a
/// macOS job waits for disk space and starts once space is freed, without a
/// fleet restart. Read mid-run, the free figure no longer shows what running
/// jobs will still write, so the disk term holds a full allowance back for
/// each of them before admitting another. That counts what they have already
/// written twice, which errs safe: without it, a burst of queued jobs could
/// each be admitted against the same free space before any of them wrote.
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
  /// RAM left to macOS and the user's apps before any job is counted.
  public static let defaultReservedMemoryGB = 4
  /// Free disk never handed to jobs, so CI can't fill the Mac's disk.
  public static let defaultReservedStorageGB = 20

  /// The resource that sets the cap.
  public enum Limit: String, Equatable, Sendable {
    case memory, cpu, storage
  }

  public struct Assessment: Equatable, Sendable {
    /// Runners admitted host-wide right now, running ones included.
    public let maxConcurrentRunners: Int
    /// The cap from RAM and cores alone. 0 means this Mac can't run a macOS
    /// job at all, and freeing disk would not help.
    public let hardwareMaxConcurrentRunners: Int
    /// The resource that sets `maxConcurrentRunners`. On a tie RAM wins over
    /// cores and both win over disk: a fixed limit explains the cap better
    /// than one that moves.
    public let limitedBy: Limit
    /// Free disk in whole decimal GB, as Finder counts it; nil when it
    /// couldn't be read, and disk then doesn't limit.
    public let availableStorageGB: Int?
    /// Free disk the next job needs: the reserve plus an allowance for it and
    /// for each running job.
    public let storageGBForNextRunner: Int
  }

  public static func assess(
    physicalMemoryBytes: UInt64,
    activeProcessorCount: Int,
    availableStorageBytes: UInt64?,
    runnersInUse: Int = 0,
    memoryGBPerRunner: Int = defaultMemoryGBPerRunner,
    cpusPerRunner: Int = defaultCPUsPerRunner,
    storageGBPerRunner: Int = defaultStorageGBPerRunner,
    reservedMemoryGB: Int = defaultReservedMemoryGB,
    reservedStorageGB: Int = defaultReservedStorageGB
  ) -> Assessment {
    // Disk in decimal GB, the unit Finder and Disk Utility show, so "needs
    // 40 GB" means what the user reads there. RAM stays binary: a "36 GB" Mac
    // reports 36 GiB.
    let storageGB = availableStorageBytes.map { Int($0 / 1_000_000_000) }
    let inUse = max(0, runnersInUse)
    let nextRunnerGB = reservedStorageGB + (inUse + 1) * storageGBPerRunner
    guard memoryGBPerRunner > 0, cpusPerRunner > 0, storageGBPerRunner > 0 else {
      return Assessment(
        maxConcurrentRunners: 0, hardwareMaxConcurrentRunners: 0, limitedBy: .memory,
        availableStorageGB: storageGB, storageGBForNextRunner: nextRunnerGB)
    }

    let totalMemoryGB = Int(physicalMemoryBytes / (1024 * 1024 * 1024))
    let usableMemoryGB = totalMemoryGB - reservedMemoryGB
    let byRAM = usableMemoryGB >= memoryGBPerRunner ? usableMemoryGB / memoryGBPerRunner : 0
    let byCPU = max(0, activeProcessorCount) / cpusPerRunner

    var limits: [(limit: Limit, runners: Int)] = [(.memory, byRAM), (.cpu, byCPU)]
    if let storageGB {
      let usableStorageGB = storageGB - reservedStorageGB - inUse * storageGBPerRunner
      let more = usableStorageGB >= storageGBPerRunner ? usableStorageGB / storageGBPerRunner : 0
      limits.append((.storage, inUse + more))
    }
    let cap = limits.map(\.runners).min() ?? 0
    return Assessment(
      maxConcurrentRunners: max(0, cap),
      hardwareMaxConcurrentRunners: min(byRAM, byCPU),
      limitedBy: limits.first { $0.runners == cap }?.limit ?? .memory,
      availableStorageGB: storageGB,
      storageGBForNextRunner: nextRunnerGB)
  }
}
