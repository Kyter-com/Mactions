import XCTest

@testable import MactionsCore

final class MacOSLocalBudgetTests: XCTestCase {
  private let gib: UInt64 = 1024 * 1024 * 1024
  private let gb: UInt64 = 1_000_000_000

  func testBindsOnCPUWhenCoresAreTheConstraint() {
    let budget = MacOSLocalBudget.assess(
      physicalMemoryBytes: 64 * gib,
      activeProcessorCount: 6,
      availableStorageBytes: 500 * gb,
      memoryGBPerRunner: 4,
      cpusPerRunner: 2,
      storageGBPerRunner: 20)

    XCTAssertEqual(budget.maxConcurrentRunners, 3)
    XCTAssertEqual(budget.limitedBy, .cpu)
  }

  func testBindsOnRAMWhenMemoryIsTheConstraint() {
    let budget = MacOSLocalBudget.assess(
      physicalMemoryBytes: 16 * gib,
      activeProcessorCount: 12,
      availableStorageBytes: 500 * gb,
      memoryGBPerRunner: 4,
      cpusPerRunner: 2,
      storageGBPerRunner: 20,
      reservedMemoryGB: 4)

    XCTAssertEqual(budget.maxConcurrentRunners, 3)
    XCTAssertEqual(budget.limitedBy, .memory)
  }

  func testBindsOnStorageWhenDiskIsTheConstraint() {
    let budget = MacOSLocalBudget.assess(
      physicalMemoryBytes: 64 * gib,
      activeProcessorCount: 12,
      availableStorageBytes: 65 * gb,
      memoryGBPerRunner: 4,
      cpusPerRunner: 2,
      storageGBPerRunner: 20,
      reservedStorageGB: 20)

    XCTAssertEqual(budget.maxConcurrentRunners, 2)
    XCTAssertEqual(budget.limitedBy, .storage)
    XCTAssertEqual(budget.availableStorageGB, 65)
  }

  func testStorageIsIgnoredWhenUnavailable() {
    let budget = MacOSLocalBudget.assess(
      physicalMemoryBytes: 24 * gib,
      activeProcessorCount: 10,
      availableStorageBytes: nil,
      memoryGBPerRunner: 4,
      cpusPerRunner: 2,
      reservedMemoryGB: 4)

    XCTAssertEqual(budget.maxConcurrentRunners, 5)
    XCTAssertNil(budget.availableStorageGB)
    XCTAssertNotEqual(budget.limitedBy, .storage)
  }

  func testReturnsZeroWhenHostCannotFitOne() {
    let budget = MacOSLocalBudget.assess(
      physicalMemoryBytes: 6 * gib,
      activeProcessorCount: 8,
      availableStorageBytes: 500 * gb,
      memoryGBPerRunner: 4,
      reservedMemoryGB: 4)

    XCTAssertEqual(budget.maxConcurrentRunners, 0)
    XCTAssertEqual(budget.hardwareMaxConcurrentRunners, 0, "freeing disk would not help")
    XCTAssertEqual(budget.limitedBy, .memory)
  }

  /// Disk counts in decimal GB, the unit Finder shows: when Finder reads
  /// "40 GB available", the first job fits.
  func testStorageCountsDecimalGigabytesLikeFinder() {
    func runners(freeBytes: UInt64) -> Int {
      MacOSLocalBudget.assess(
        physicalMemoryBytes: 64 * gib, activeProcessorCount: 12,
        availableStorageBytes: freeBytes
      ).maxConcurrentRunners
    }
    XCTAssertEqual(runners(freeBytes: 40 * gb), 1)
    XCTAssertEqual(runners(freeBytes: 40 * gb - 1), 0)
    XCTAssertEqual(
      MacOSLocalBudget.assess(
        physicalMemoryBytes: 64 * gib, activeProcessorCount: 12, availableStorageBytes: 0
      ).storageGBForNextRunner, 40, "20 GB kept free + 20 GB for the job")
  }

  /// A Mac with plenty of RAM and cores and a nearly full disk (36 GB, 12
  /// cores, 26 GB free on 2026-11-02): disk alone holds macOS jobs back, so
  /// they wait for space rather than being switched off.
  func testFullDiskHoldsJobsBackWithoutHidingTheHardwareCap() {
    let budget = MacOSLocalBudget.assess(
      physicalMemoryBytes: 36 * gib, activeProcessorCount: 12,
      availableStorageBytes: 26 * gb)

    XCTAssertEqual(budget.maxConcurrentRunners, 0)
    XCTAssertEqual(budget.hardwareMaxConcurrentRunners, 6)
    XCTAssertEqual(budget.limitedBy, .storage)
    XCTAssertEqual(budget.availableStorageGB, 26)
  }

  /// Free disk is read while jobs run, and it doesn't show what they will
  /// still write: each running job keeps a full allowance, so a burst of jobs
  /// can't all be admitted against the same free space. A running job never
  /// loses its slot.
  func testRunningJobsKeepAFullAllowanceEach() {
    func assess(freeGB: UInt64, inUse: Int, cores: Int = 12) -> MacOSLocalBudget.Assessment {
      MacOSLocalBudget.assess(
        physicalMemoryBytes: 64 * gib, activeProcessorCount: cores,
        availableStorageBytes: freeGB * gb, runnersInUse: inUse)
    }
    XCTAssertEqual(
      assess(freeGB: 45, inUse: 0).maxConcurrentRunners, 1, "45 GB with nothing running: one job")
    XCTAssertEqual(
      assess(freeGB: 45, inUse: 1).maxConcurrentRunners, 1,
      "the same 45 GB once that job has started (and not yet written) can't admit a second")
    XCTAssertEqual(assess(freeGB: 65, inUse: 1).maxConcurrentRunners, 2)
    XCTAssertEqual(
      assess(freeGB: 25, inUse: 1).maxConcurrentRunners, 1, "the running job keeps its slot")
    XCTAssertEqual(assess(freeGB: 45, inUse: 1).storageGBForNextRunner, 60)
    XCTAssertEqual(
      assess(freeGB: 500, inUse: 1, cores: 2).maxConcurrentRunners, 1,
      "disk never lifts the hardware cap")
  }

  func testTiesNameTheFixedResource() {
    let budget = MacOSLocalBudget.assess(
      physicalMemoryBytes: 12 * gib, activeProcessorCount: 4,
      availableStorageBytes: 60 * gb)

    XCTAssertEqual(budget.maxConcurrentRunners, 2, "RAM, cores and disk all allow 2")
    XCTAssertEqual(budget.limitedBy, .memory)
  }
}
