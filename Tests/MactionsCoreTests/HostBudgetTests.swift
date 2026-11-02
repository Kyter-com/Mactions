import XCTest

@testable import MactionsCore

@MainActor
final class HostBudgetTests: XCTestCase {
  func testCapsAcquisitionAndReleasesFreeCapacity() {
    let budget = HostBudget(limits: [.windows: 2, .linux: 0])
    XCTAssertTrue(budget.tryAcquire(.windows))
    XCTAssertTrue(budget.tryAcquire(.windows))
    XCTAssertFalse(budget.tryAcquire(.windows), "at the ceiling")
    XCTAssertEqual(budget.inUse(.windows), 2)

    budget.release(.windows)
    XCTAssertTrue(budget.tryAcquire(.windows), "a freed unit is re-acquirable")

    XCTAssertFalse(budget.tryAcquire(.linux), "limit 0 = the host can't fit even one")
  }

  func testUncappedOSAlwaysAcquires() {
    let budget = HostBudget(limits: [.windows: 1])
    for _ in 0..<10 {
      XCTAssertTrue(budget.tryAcquire(.macOS), "no limit entry = uncapped")
    }
  }

  /// A spurious double-release must not mint phantom capacity below zero.
  func testReleaseFloorsAtZero() {
    let budget = HostBudget(limits: [.windows: 1])
    budget.release(.windows)
    XCTAssertEqual(budget.inUse(.windows), 0)
    XCTAssertTrue(budget.tryAcquire(.windows))
    XCTAssertFalse(budget.tryAcquire(.windows), "the floor didn't widen the limit")
  }

  func testLimitExposedForStatusCopy() {
    let budget = HostBudget(limits: [.windows: 3])
    XCTAssertEqual(budget.limit(for: .windows), 3)
    XCTAssertNil(budget.limit(for: .macOS))
  }

  /// macOS's limit follows free disk while online: a raise admits at once,
  /// and a cut below what is in use revokes nothing; it only stops new
  /// admissions until enough runners exit.
  func testLimitMovesWhileRunnersAreLive() {
    let budget = HostBudget(limits: [.macOS: 0])
    XCTAssertFalse(budget.tryAcquire(.macOS), "0 = waiting for disk space")

    budget.setLimit(2, for: .macOS)
    XCTAssertTrue(budget.tryAcquire(.macOS))
    XCTAssertTrue(budget.tryAcquire(.macOS))

    budget.setLimit(1, for: .macOS)
    XCTAssertEqual(budget.limit(for: .macOS), 1)
    XCTAssertEqual(budget.inUse(.macOS), 2, "a cut revokes nothing")
    budget.release(.macOS)
    XCTAssertFalse(budget.tryAcquire(.macOS), "still at the lowered ceiling")
    budget.release(.macOS)
    XCTAssertTrue(budget.tryAcquire(.macOS))
  }
}
