import Darwin
import Foundation

/// One point-in-time memory reading for the dashboard's live gauge + sparkline.
/// Host figures come from the Mach VM statistics; the per-bucket figures (this
/// app, the Windows VMs, the local runner agents) are summed from `ps` RSS.
/// Everything is best-effort — a failed probe degrades to zero, never a crash.
public struct MemorySample: Sendable, Equatable {
  /// Total physical RAM.
  public let totalBytes: UInt64
  /// In active use (wired + active + compressed) — tracks memory pressure, akin
  /// to Activity Monitor's "Memory Used". An approximation, labeled as such.
  public let usedBytes: UInt64
  public let freeBytes: UInt64
  public let wiredBytes: UInt64
  public let compressedBytes: UInt64
  /// This app's resident size.
  public let appBytes: UInt64
  /// Sum of the running VMware VM processes' RSS (the Windows runner VMs).
  public let windowsVMBytes: UInt64
  /// Sum of the local runner-agent processes' RSS (run.sh + job children).
  public let localRunnerBytes: UInt64

  public init(
    totalBytes: UInt64, usedBytes: UInt64, freeBytes: UInt64, wiredBytes: UInt64,
    compressedBytes: UInt64, appBytes: UInt64, windowsVMBytes: UInt64, localRunnerBytes: UInt64
  ) {
    self.totalBytes = totalBytes
    self.usedBytes = usedBytes
    self.freeBytes = freeBytes
    self.wiredBytes = wiredBytes
    self.compressedBytes = compressedBytes
    self.appBytes = appBytes
    self.windowsVMBytes = windowsVMBytes
    self.localRunnerBytes = localRunnerBytes
  }

  /// Fraction of physical RAM in active use, clamped to 0...1.
  public var usedFraction: Double {
    totalBytes == 0 ? 0 : min(1, Double(usedBytes) / Double(totalBytes))
  }
}

/// Samples live memory. `sample` shells out to `ps`, so call it OFF the main
/// actor (the app does, on a timer, only while the dashboard window is open).
public enum MemorySampler {
  public static func sample(runsRootPath: String) -> MemorySample {
    let total = ProcessInfo.processInfo.physicalMemory
    let host = hostMemory()
    let used = host.wired + host.active + host.compressed
    let free = total > used ? total - used : 0
    let psOut = (try? Shell.run("/bin/ps", ["-axo", "pid=,rss=,command="]))?.stdout ?? ""
    let buckets = parseProcessRSS(
      psOut, runsRootPath: runsRootPath, ownPID: ProcessInfo.processInfo.processIdentifier)
    return MemorySample(
      totalBytes: total, usedBytes: used, freeBytes: free,
      wiredBytes: host.wired, compressedBytes: host.compressed,
      appBytes: buckets.app, windowsVMBytes: buckets.windows, localRunnerBytes: buckets.runners)
  }

  /// Bucket process RSS from `ps -axo pid=,rss=,command=` output (pure →
  /// unit-testable). Each line: pid, RSS in KiB, then the full command. We bucket
  /// by command: the VMware VM helpers (`vmware-vmx`) are the Windows runner VMs;
  /// processes whose command contains the runs-root path are local runner agents;
  /// our own pid is this app.
  public static func parseProcessRSS(_ output: String, runsRootPath: String, ownPID: Int32)
    -> (windows: UInt64, runners: UInt64, app: UInt64)
  {
    var windows: UInt64 = 0
    var runners: UInt64 = 0
    var app: UInt64 = 0
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = rawLine.drop(while: { $0 == " " })
      // pid
      guard let pidEnd = line.firstIndex(of: " ") else { continue }
      let pid = Int32(line[..<pidEnd])
      // rss (skip the spaces between fields)
      let afterPid = line[line.index(after: pidEnd)...].drop(while: { $0 == " " })
      guard let rssEnd = afterPid.firstIndex(of: " "), let rssKB = UInt64(afterPid[..<rssEnd])
      else { continue }
      let command = afterPid[afterPid.index(after: rssEnd)...]
      let bytes = rssKB * 1024
      if pid == ownPID {
        app += bytes
      } else if command.contains("vmware-vmx") {
        windows += bytes
      } else if !runsRootPath.isEmpty, command.contains(runsRootPath) {
        runners += bytes
      }
    }
    return (windows, runners, app)
  }

  /// Host VM statistics → (active, wired, compressed, free) in bytes. Uses only
  /// Mach *functions* (no concurrency-unsafe globals), so it's safe to call from
  /// any context.
  private static func hostMemory() -> (active: UInt64, wired: UInt64, compressed: UInt64, free: UInt64)
  {
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)
    let page = UInt64(pageSize == 0 ? 4096 : pageSize)

    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &stats) { ptr in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), host_flavor_t(HOST_VM_INFO64), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return (0, 0, 0, 0) }
    return (
      UInt64(stats.active_count) * page,
      UInt64(stats.wire_count) * page,
      UInt64(stats.compressor_page_count) * page,
      UInt64(stats.free_count) * page)
  }
}
