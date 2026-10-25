import XCTest

@testable import MactionsCore

final class NetworkChangeTests: XCTestCase {
  func testSnapshotsCompareByUsabilityAndTheSetOfInterfaces() {
    let a = NetworkPathSnapshot(usable: true, interfaces: ["utun420", "en0", "en0"])
    XCTAssertEqual(a.interfaces, ["en0", "utun420"])
    XCTAssertEqual(a, NetworkPathSnapshot(usable: true, interfaces: ["en0", "utun420"]))
    XCTAssertNotEqual(a, NetworkPathSnapshot(usable: true, interfaces: ["en0"]))
    XCTAssertNotEqual(a, NetworkPathSnapshot(usable: false, interfaces: ["en0", "utun420"]))
    XCTAssertEqual(a.summary, "up:en0,utun420")
    XCTAssertEqual(NetworkPathSnapshot(usable: false, interfaces: []).summary, "down:")
  }

  func testTheFirstSnapshotIsABaselineAndRepeatsAreNotChanges() {
    var filter = NetworkChangeFilter()
    let wifi = NetworkPathSnapshot(usable: true, interfaces: ["en0"])
    let vpn = NetworkPathSnapshot(usable: true, interfaces: ["en0", "utun420"])
    XCTAssertFalse(filter.isChange(wifi), "what the monitor reports at start is the baseline")
    XCTAssertFalse(filter.isChange(wifi))
    XCTAssertTrue(filter.isChange(vpn), "a VPN connecting")
    XCTAssertFalse(filter.isChange(vpn))
    XCTAssertTrue(filter.isChange(wifi), "the VPN dropping")
    XCTAssertTrue(filter.isChange(NetworkPathSnapshot(usable: false, interfaces: [])))
  }
}

@MainActor
final class KickableWaitTests: XCTestCase {
  func testAWaitRunsOutWithoutAKick() async {
    let wait = KickableWait()
    let started = Date()
    let kicked = await wait.wait(seconds: 0.1)
    XCTAssertFalse(kicked)
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.09)
  }

  func testAKickEndsTheWaitAtOnce() async {
    let wait = KickableWait()
    let started = Date()
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 50_000_000)
      wait.kick()
    }
    let kicked = await wait.wait(seconds: 10)
    XCTAssertTrue(kicked)
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
  }

  func testAKickWithNobodyWaitingEndsTheNextWait() async {
    let wait = KickableWait()
    wait.kick()  // e.g. the network changed in the middle of a scan
    let started = Date()
    let kicked = await wait.wait(seconds: 10)
    XCTAssertTrue(kicked)
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    // Used up: the wait after that runs its course.
    let again = await wait.wait(seconds: 0.05)
    XCTAssertFalse(again)
  }

  func testResetForgetsAPendingKick() async {
    let wait = KickableWait()
    wait.kick()
    wait.reset()
    let kicked = await wait.wait(seconds: 0.05)
    XCTAssertFalse(kicked)
  }

  func testCancellingTheWaiterEndsTheWaitPromptly() async {
    let wait = KickableWait()
    let started = Date()
    let waiter = Task { @MainActor in await wait.wait(seconds: 10) }
    try? await Task.sleep(nanoseconds: 50_000_000)
    waiter.cancel()
    let kicked = await waiter.value
    XCTAssertFalse(kicked)
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
  }
}
