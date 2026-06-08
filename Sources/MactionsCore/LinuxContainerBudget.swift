import Foundation

/// How many concurrent ephemeral Linux containers the host can run without
/// thrashing.
///
/// Containers are far lighter than the Windows Fusion VM (sub-second start/stop,
/// shared kernel, CPU overcommits gracefully), so the strict RAM-divide of
/// `WindowsVMBudget` is overkill — but we still bound the count and put a hard
/// `--cpus`/`--memory` limit on every container, because Docker's default is
/// *unlimited* and N concurrent runner jobs would otherwise OOM the Mac. The cap
/// binds on the tighter of a RAM divide and a CPU divide.
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
}
