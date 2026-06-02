import XCTest

@testable import MactionsCore

/// Round-trips `RunRecord` through the SAME JSON strategies `RunHistoryStore`
/// uses (ISO-8601 dates). Deliberately does NOT exercise `RunHistoryStore.save`/
/// `load`: those read/write the real `~/.mactions/logs/run-history.json`, and a
/// test must not clobber a developer's actual run history.
final class RunHistoryTests: XCTestCase {
  func testRunRecordCodableRoundTrip() throws {
    // Whole-second timestamps so ISO-8601's second granularity round-trips exactly
    // (Equatable on RunRecord compares the Dates).
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let record = RunRecord(
      id: "mactions-host-ab12cd", os: .windows, repo: "owner/name", remoteId: 42,
      startedAt: start, endedAt: start.addingTimeInterval(95), exitStatus: 0, outcome: .completed)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode([record])
    let decoded = try decoder.decode([RunRecord].self, from: data)

    XCTAssertEqual(decoded, [record])
    XCTAssertEqual(decoded.first?.duration, 95)
  }

  func testOutcomesEncodeAsStableStrings() throws {
    // The raw values are persisted, so they must stay stable across versions.
    XCTAssertEqual(RunRecord.Outcome.completed.rawValue, "completed")
    XCTAssertEqual(RunRecord.Outcome.failed.rawValue, "failed")
  }

  func testNilExitStatusRoundTrips() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_500)
    let record = RunRecord(
      id: "r", os: .macOS, repo: "o/r", remoteId: nil,
      startedAt: start, endedAt: start, exitStatus: nil, outcome: .completed)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode([RunRecord].self, from: try encoder.encode([record]))
    XCTAssertEqual(decoded, [record])
    XCTAssertNil(decoded.first?.exitStatus)
    XCTAssertNil(decoded.first?.remoteId)
  }
}
