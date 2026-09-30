import XCTest

@testable import MactionsCore

final class JobLogSearchTests: XCTestCase {
  func testSearchKeepsOriginalLineNumbersAndMatchesCaseInsensitively() {
    let result = JobLogSearch.matchingLines(
      in: ["Starting", "", "ERROR: checkout", "done", "error: upload"], query: "  Error  ")
    XCTAssertEqual(result.map(\.id), [2, 4])
    XCTAssertEqual(result.map(\.text), ["ERROR: checkout", "error: upload"])
  }

  func testWhitespaceQueryPreservesEmptyLines() {
    let lines = ["first", "", "last"]
    let result = JobLogSearch.matchingLines(in: lines, query: " \n ")
    XCTAssertEqual(result.map(\.id), [0, 1, 2])
    XCTAssertEqual(result.map(\.text), lines)
  }

  func testRefreshedContentWithSameLineCountProducesNewMatches() {
    let before = JobLogSearch.matchingLines(in: ["starting", "waiting"], query: "failure")
    let after = JobLogSearch.matchingLines(in: ["finished", "failure"], query: "failure")
    XCTAssertTrue(before.isEmpty)
    XCTAssertEqual(after.map(\.id), [1])
    XCTAssertEqual(after.map(\.text), ["failure"])
  }
}
