import XCTest

@testable import MactionsCore

final class MacOSLocalBudgetTests: XCTestCase {
  func testBindsOnCPUWhenCoresAreTheConstraint() {
    let max = MacOSLocalBudget.maxConcurrentRunners(
      physicalMemoryBytes: UInt64(64) * 1024 * 1024 * 1024,
      activeProcessorCount: 6,
      availableStorageBytes: UInt64(500) * 1024 * 1024 * 1024,
      memoryGBPerRunner: 4,
      cpusPerRunner: 2,
      storageGBPerRunner: 20)

    XCTAssertEqual(max, 3)
  }

  func testBindsOnRAMWhenMemoryIsTheConstraint() {
    let max = MacOSLocalBudget.maxConcurrentRunners(
      physicalMemoryBytes: UInt64(16) * 1024 * 1024 * 1024,
      activeProcessorCount: 12,
      availableStorageBytes: UInt64(500) * 1024 * 1024 * 1024,
      memoryGBPerRunner: 4,
      cpusPerRunner: 2,
      storageGBPerRunner: 20,
      reservedMemoryGB: 4)

    XCTAssertEqual(max, 3)
  }

  func testBindsOnStorageWhenDiskIsTheConstraint() {
    let max = MacOSLocalBudget.maxConcurrentRunners(
      physicalMemoryBytes: UInt64(64) * 1024 * 1024 * 1024,
      activeProcessorCount: 12,
      availableStorageBytes: UInt64(65) * 1024 * 1024 * 1024,
      memoryGBPerRunner: 4,
      cpusPerRunner: 2,
      storageGBPerRunner: 20,
      reservedStorageGB: 20)

    XCTAssertEqual(max, 2)
  }

  func testStorageIsIgnoredWhenUnavailable() {
    let max = MacOSLocalBudget.maxConcurrentRunners(
      physicalMemoryBytes: UInt64(24) * 1024 * 1024 * 1024,
      activeProcessorCount: 10,
      availableStorageBytes: nil,
      memoryGBPerRunner: 4,
      cpusPerRunner: 2,
      reservedMemoryGB: 4)

    XCTAssertEqual(max, 5)
  }

  func testReturnsZeroWhenHostCannotFitOne() {
    XCTAssertEqual(
      MacOSLocalBudget.maxConcurrentRunners(
        physicalMemoryBytes: UInt64(6) * 1024 * 1024 * 1024,
        activeProcessorCount: 8,
        availableStorageBytes: UInt64(500) * 1024 * 1024 * 1024,
        memoryGBPerRunner: 4,
        reservedMemoryGB: 4),
      0)
  }
}
