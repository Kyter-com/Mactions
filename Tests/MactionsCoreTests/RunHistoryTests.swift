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

  // MARK: - jobConclusion (the true GitHub result, back-filled post-record)

  func testJobConclusionRoundTrips() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_900)
    let record = RunRecord(
      id: "mactions-host-zz99", os: .windows, repo: "o/r", remoteId: 7,
      startedAt: start, endedAt: start.addingTimeInterval(60), exitStatus: 0,
      outcome: .completed, jobConclusion: .failure)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode([RunRecord].self, from: try encoder.encode([record]))
    XCTAssertEqual(decoded, [record])
    XCTAssertEqual(decoded.first?.jobConclusion, .failure)
  }

  /// Back-compat: history written before `jobConclusion` existed has no such key.
  /// It must decode as `nil` (no migration), and the row must NOT claim a green
  /// "Passed" — it shows the honest `unknownCompleted` / "Completed" fallback.
  func testLegacyRecordWithoutJobConclusionDecodes() throws {
    let json = """
      [{"id":"mactions-host-legacy","os":"windows","repo":"o/r","remoteId":1,
        "startedAt":"2024-01-01T00:00:00Z","endedAt":"2024-01-01T00:01:00Z",
        "exitStatus":0,"outcome":"completed"}]
      """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode([RunRecord].self, from: json)
    XCTAssertNil(decoded.first?.jobConclusion)
    XCTAssertEqual(decoded.first?.resolvedStatus, .unknownCompleted)
    XCTAssertEqual(decoded.first?.statusLabel, "Completed")
  }

  func testJobConclusionRawValuesAreStable() {
    // Persisted, so the raw values must not drift across versions.
    XCTAssertEqual(RunRecord.JobConclusion.success.rawValue, "success")
    XCTAssertEqual(RunRecord.JobConclusion.failure.rawValue, "failure")
    XCTAssertEqual(RunRecord.JobConclusion.cancelled.rawValue, "cancelled")
    XCTAssertEqual(RunRecord.JobConclusion.timedOut.rawValue, "timed_out")
    XCTAssertEqual(RunRecord.JobConclusion.neutral.rawValue, "neutral")
    XCTAssertEqual(RunRecord.JobConclusion.skipped.rawValue, "skipped")
    XCTAssertEqual(RunRecord.JobConclusion.inProgress.rawValue, "in_progress")
    XCTAssertEqual(RunRecord.JobConclusion.agentFailed.rawValue, "agent_failed")
  }

  func testResolvedStatusAndLabelMapping() {
    func make(_ c: RunRecord.JobConclusion?, outcome: RunRecord.Outcome = .completed) -> RunRecord {
      RunRecord(
        id: "r", os: .macOS, repo: "o/r", remoteId: nil,
        startedAt: .distantPast, endedAt: .distantPast, exitStatus: 0,
        outcome: outcome, jobConclusion: c)
    }
    let cases: [(RunRecord.JobConclusion?, RunRecord.ResolvedStatus, String)] = [
      (.success, .passed, "Passed"),
      (.failure, .failed, "Failed"),
      (.timedOut, .failed, "Timed out"),
      (.agentFailed, .failed, "Agent failed"),
      (.cancelled, .neutral, "Cancelled"),
      (.skipped, .neutral, "Skipped"),
      (.neutral, .neutral, "Neutral"),
      (.inProgress, .running, "Running"),
    ]
    for (c, status, label) in cases {
      XCTAssertEqual(make(c).resolvedStatus, status, "status for \(String(describing: c))")
      XCTAssertEqual(make(c).statusLabel, label, "label for \(String(describing: c))")
    }
    // Fallbacks when not yet resolved.
    XCTAssertEqual(make(nil, outcome: .completed).resolvedStatus, .unknownCompleted)
    XCTAssertEqual(make(nil, outcome: .completed).statusLabel, "Completed")
    XCTAssertEqual(make(nil, outcome: .failed).resolvedStatus, .failed)
    XCTAssertEqual(make(nil, outcome: .failed).statusLabel, "Failed")
  }

  /// The exact bug class (a failed job recorded as Completed/exit 0): a clean agent
  /// exit (0) with a GitHub "failure" conclusion must resolve to `.failure`.
  func testResolveMapper() {
    typealias C = RunRecord.JobConclusion
    XCTAssertEqual(C.resolve(status: "completed", conclusion: "failure", exitStatus: 0), .failure)
    XCTAssertEqual(C.resolve(status: "completed", conclusion: "success", exitStatus: 0), .success)
    XCTAssertEqual(C.resolve(status: "completed", conclusion: "timed_out", exitStatus: 0), .timedOut)
    XCTAssertEqual(C.resolve(status: "completed", conclusion: "cancelled", exitStatus: 0), .cancelled)
    XCTAssertEqual(C.resolve(status: "completed", conclusion: "skipped", exitStatus: 0), .skipped)
    XCTAssertEqual(C.resolve(status: "completed", conclusion: "neutral", exitStatus: 0), .neutral)
    // Completed with a null conclusion ≈ still settling.
    XCTAssertEqual(C.resolve(status: "completed", conclusion: nil, exitStatus: 0), .inProgress)
    // Not completed yet → running, regardless of conclusion.
    XCTAssertEqual(C.resolve(status: "in_progress", conclusion: nil, exitStatus: 0), .inProgress)
    XCTAssertEqual(C.resolve(status: "queued", conclusion: nil, exitStatus: nil), .inProgress)
    // A non-zero agent exit wins: the agent crashed, the job may never have run.
    XCTAssertEqual(C.resolve(status: "completed", conclusion: "success", exitStatus: 1), .agentFailed)
    XCTAssertEqual(C.resolve(status: "queued", conclusion: nil, exitStatus: 5), .agentFailed)
  }
}
