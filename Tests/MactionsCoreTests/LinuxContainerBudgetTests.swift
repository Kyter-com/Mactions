import XCTest

@testable import MactionsCore

/// Pins the host concurrency budget for ephemeral Linux containers. Lighter than
/// the Windows VM budget (no per-VM guest-OS overhead), and bounded on the
/// tighter of a RAM divide and a CPU divide so a small-RAM-but-many-core (or
/// big-RAM-but-few-core) Mac can't over-subscribe.
final class LinuxContainerBudgetTests: XCTestCase {
  private func gb(_ n: UInt64) -> UInt64 { n * 1024 * 1024 * 1024 }

  func testBindsOnRAMWhenRAMIsTheConstraint() {
    // Plenty of cores, less RAM: (total - 4) / 6, floored, wins.
    // 16 GB, 16 cores: byRAM = (16-4)/6 = 2 ; byCPU = 16/2 = 8 -> 2
    XCTAssertEqual(
      LinuxContainerBudget.maxConcurrentContainers(physicalMemoryBytes: gb(16), activeProcessorCount: 16), 2)
    // 32 GB, 32 cores: byRAM = (32-4)/6 = 4 ; byCPU = 16 -> 4
    XCTAssertEqual(
      LinuxContainerBudget.maxConcurrentContainers(physicalMemoryBytes: gb(32), activeProcessorCount: 32), 4)
  }

  func testBindsOnCPUWhenCoresAreTheConstraint() {
    // Plenty of RAM, few cores: cores/2 wins.
    // 64 GB, 8 cores: byRAM = (64-4)/6 = 10 ; byCPU = 8/2 = 4 -> 4
    XCTAssertEqual(
      LinuxContainerBudget.maxConcurrentContainers(physicalMemoryBytes: gb(64), activeProcessorCount: 8), 4)
    // 64 GB, 10 cores: byCPU = 5 ; byRAM = 10 -> 5
    XCTAssertEqual(
      LinuxContainerBudget.maxConcurrentContainers(physicalMemoryBytes: gb(64), activeProcessorCount: 10), 5)
  }

  func testReturnsZeroWhenTooLittleRAM() {
    // 4 GB Mac: 0 usable after the 4 GB reserve — can't fit a 6 GB container.
    XCTAssertEqual(
      LinuxContainerBudget.maxConcurrentContainers(physicalMemoryBytes: gb(4), activeProcessorCount: 8), 0)
    // 8 GB Mac: (8-4)=4 usable < 6 GB per container -> 0.
    XCTAssertEqual(
      LinuxContainerBudget.maxConcurrentContainers(physicalMemoryBytes: gb(8), activeProcessorCount: 8), 0)
  }

  func testRespectsCustomCapsAndGuardsAgainstZeroDivisors() {
    // Smaller containers (2 GB) + smaller reserve fit more, but CPU can still cap.
    // 16 GB, 8 cores, 2 GB/1 cpu, reserve 2: byRAM = (16-2)/2 = 7 ; byCPU = 8 -> 7
    XCTAssertEqual(
      LinuxContainerBudget.maxConcurrentContainers(
        physicalMemoryBytes: gb(16), activeProcessorCount: 8,
        memoryGBPerContainer: 2, cpusPerContainer: 1, reservedGB: 2), 7)
    // Zero/negative caps never divide by zero.
    XCTAssertEqual(
      LinuxContainerBudget.maxConcurrentContainers(
        physicalMemoryBytes: gb(64), activeProcessorCount: 8, memoryGBPerContainer: 0), 0)
    XCTAssertEqual(
      LinuxContainerBudget.maxConcurrentContainers(
        physicalMemoryBytes: gb(64), activeProcessorCount: 8, cpusPerContainer: 0), 0)
  }

  func testDefaultsMatchPrivateHostedLinuxShape() {
    XCTAssertEqual(LinuxContainerBudget.defaultCPUsPerContainer, 2)
    XCTAssertEqual(LinuxContainerBudget.defaultMemoryGBPerContainer, 6)
  }
}
