import Foundation

/// How many concurrent ephemeral Linux containers the host can run without
/// thrashing.
///
/// Containers are far lighter than the Windows Fusion VM (sub-second start/stop,
/// shared kernel, CPU overcommits gracefully), so the strict RAM-divide of
/// `WindowsVMBudget` is overkill — but we still bound the count and put a hard
/// `--cpus`/`--memory` limit on every container so N concurrent runner jobs
/// cannot OOM the Mac. The cap binds on the tighter of a RAM divide and a CPU
/// divide.
///
/// SCOPE (same caveat as `WindowsVMBudget`): this bounds the **Linux containers**
/// in isolation. `reservedGB` is a flat allowance for macOS + the app + idle
/// macOS runner agents, NOT a per-active-job reserve, and it does not model the
/// combined footprint of co-resident macOS + Windows + Linux fleets. It keeps
/// Linux containers from thrashing the host on their own.
public enum LinuxContainerBudget {
  /// Default per-container CPU cap (`--cpus`). Mirrors the private-repo
  /// GitHub-hosted Linux runner (2 vCPU) so jobs see a familiar shape.
  public static let defaultCPUsPerContainer = 2
  /// Default per-container RAM hard cap in GB (`--memory`). A job that exceeds it
  /// is OOM-killed (exit 137) rather than swamping the host.
  public static let defaultMemoryGBPerContainer = 6

  /// Hard ceiling on concurrent containers, applied BELOW the RAM/CPU divide.
  /// Apple `container` shares a single vmnet NAT bridge across every container;
  /// past a handful of concurrent lightweight VMs the bridge/DHCP path — not
  /// RAM/CPU — becomes the binding constraint, and a registered-but-offline
  /// container can wedge it for the others. Clamp explicitly so a large Mac
  /// can't authorize a fan-out that exhausts the bridge (the raw divide permitted
  /// 8+ on a 64 GB host, which is how a stuck runner snowballed into a pileup).
  public static let maxConcurrentContainersCeiling = 4

  /// Max concurrent containers given the host's physical memory + core count.
  ///
  /// Reserves `reservedGB` for macOS, the app, and idle agents, then divides the
  /// remainder by the per-container RAM cap; separately divides the core count by
  /// the per-container CPU cap; returns the tighter bound. `reservedGB` is lower
  /// than the Windows VM reserve (no per-VM guest-OS overhead). Returns `0` when
  /// the host can't fit even one — the caller should then skip the Linux fleet
  /// and say so, rather than thrash.
  public static func maxConcurrentContainers(
    physicalMemoryBytes: UInt64,
    activeProcessorCount: Int,
    memoryGBPerContainer: Int = defaultMemoryGBPerContainer,
    cpusPerContainer: Int = defaultCPUsPerContainer,
    reservedGB: Int = 4
  ) -> Int {
    guard memoryGBPerContainer > 0, cpusPerContainer > 0 else { return 0 }
    let totalGB = Int(physicalMemoryBytes / (1024 * 1024 * 1024))
    let usableGB = totalGB - reservedGB
    let byRAM = usableGB >= memoryGBPerContainer ? usableGB / memoryGBPerContainer : 0
    let byCPU = max(0, activeProcessorCount) / cpusPerContainer
    return max(0, min(byRAM, byCPU))
  }

  /// The cap the host budget should actually ENFORCE: the RAM/CPU divide above,
  /// then clamped to `maxConcurrentContainersCeiling`. The raw divide can
  /// authorize many containers on a big Mac, but Apple `container`'s shared
  /// vmnet NAT bridge — not RAM/CPU — binds first, so the effective cap is the
  /// lower of the two. Callers computing the live Linux budget use THIS.
  public static func effectiveMaxConcurrentContainers(
    physicalMemoryBytes: UInt64,
    activeProcessorCount: Int,
    memoryGBPerContainer: Int = defaultMemoryGBPerContainer,
    cpusPerContainer: Int = defaultCPUsPerContainer,
    reservedGB: Int = 4
  ) -> Int {
    min(
      maxConcurrentContainers(
        physicalMemoryBytes: physicalMemoryBytes, activeProcessorCount: activeProcessorCount,
        memoryGBPerContainer: memoryGBPerContainer, cpusPerContainer: cpusPerContainer,
        reservedGB: reservedGB),
      maxConcurrentContainersCeiling)
  }
}
