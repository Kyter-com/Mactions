import XCTest

@testable import MactionsCore

/// Pins the host-RAM concurrency budget for Windows VMs (each runner clone is a
/// full ~8 GB VM, so the count must be bounded or N repos thrash the Mac).
final class WindowsVMBudgetTests: XCTestCase {
  private func gb(_ n: UInt64) -> UInt64 { n * 1024 * 1024 * 1024 }

  func testScalesWithPhysicalRAM() {
    // (total - 6 GB reserved) / 8 GB per VM, floored.
    XCTAssertEqual(WindowsVMBudget.maxConcurrentVMs(physicalMemoryBytes: gb(16)), 1)  // (16-6)/8
    XCTAssertEqual(WindowsVMBudget.maxConcurrentVMs(physicalMemoryBytes: gb(24)), 2)  // (24-6)/8
    XCTAssertEqual(WindowsVMBudget.maxConcurrentVMs(physicalMemoryBytes: gb(32)), 3)  // (32-6)/8
    XCTAssertEqual(WindowsVMBudget.maxConcurrentVMs(physicalMemoryBytes: gb(64)), 7)  // (64-6)/8
  }

  func testReturnsZeroWhenTooLittleRAM() {
    // 8 GB Mac: only 2 GB usable after reserve — can't fit an 8 GB VM → skip Windows.
    XCTAssertEqual(WindowsVMBudget.maxConcurrentVMs(physicalMemoryBytes: gb(8)), 0)
    // Exactly at the reserve floor is still 0.
    XCTAssertEqual(WindowsVMBudget.maxConcurrentVMs(physicalMemoryBytes: gb(6)), 0)
  }

  func testRespectsCustomFootprintAndReserve() {
    // Smaller VMs (4 GB) + smaller reserve (4 GB) fit more.
    XCTAssertEqual(
      WindowsVMBudget.maxConcurrentVMs(physicalMemoryBytes: gb(16), perVMGB: 4, reservedGB: 4), 3)
    // A zero/negative footprint never divides by zero.
    XCTAssertEqual(
      WindowsVMBudget.maxConcurrentVMs(physicalMemoryBytes: gb(64), perVMGB: 0), 0)
  }

  // MARK: per-VM footprint read from the base .vmx (keeps the budget in sync with --ram)

  func testPerVMGBParsesMemsizeFromVMX() {
    // Linked clones inherit the base memsize, so the budget must divide by THIS,
    // not a hardcoded 8 — a --ram 16384 base is a 16 GB clone.
    let vmx = """
      .encoding = "UTF-8"
      memsize = "16384"
      numvcpus = "4"
      """
    XCTAssertEqual(WindowsVMBudget.perVMGB(fromVMX: vmx), 16)
    // The default base (8192 MB) reads back as 8 GB == defaultPerVMGB.
    XCTAssertEqual(WindowsVMBudget.perVMGB(fromVMX: "memsize = \"8192\""), 8)
    XCTAssertEqual(WindowsVMBudget.defaultPerVMGB, 8)
  }

  func testPerVMGBRoundsUpAndToleratesWhitespaceAndCase() {
    // Round UP so we never UNDER-reserve (a 6144 MB / 6 GB VM must not read as 5).
    XCTAssertEqual(WindowsVMBudget.perVMGB(fromVMX: "memsize = \"6144\""), 6)
    XCTAssertEqual(WindowsVMBudget.perVMGB(fromVMX: "memsize = \"6145\""), 7)  // 6.0009 GB -> 7
    XCTAssertEqual(WindowsVMBudget.perVMGB(fromVMX: "   MemSize=\"4096\"  "), 4)
  }

  func testPerVMGBReturnsNilWhenAbsentOrUnparseable() {
    XCTAssertNil(WindowsVMBudget.perVMGB(fromVMX: "numvcpus = \"4\""))
    XCTAssertNil(WindowsVMBudget.perVMGB(fromVMX: "memsize = \"\""))
    XCTAssertNil(WindowsVMBudget.perVMGB(fromVMX: "memsize = \"lots\""))
    XCTAssertNil(WindowsVMBudget.perVMGB(fromVMX: "memsize = \"0\""))
  }
}
