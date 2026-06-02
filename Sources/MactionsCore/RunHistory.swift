import Foundation

/// A finished ephemeral runner — one row in the "past runs since turning on"
/// history. An ephemeral runner registers, runs (at most) one job, and exits;
/// this is the record we keep once it's gone, so the dashboard can show what ran
/// after the live runner has been recycled away.
///
/// `startedAt` is when the runner *came up* (the agent launched), not when a job
/// began — we don't parse the agent log yet, so for an idle-then-recycled runner
/// the duration includes its wait. `outcome` is a coarse classification of the
/// exit (see `RunnerOrchestrator.handleExit`): a clean ephemeral exit while
/// online is `.completed`, a non-zero exit while online is `.failed`. Runners
/// reaped by go-offline/teardown are intentionally NOT recorded (see handleExit).
public struct RunRecord: Codable, Sendable, Identifiable, Equatable {
  public enum Outcome: String, Codable, Sendable {
    case completed  // exited 0 on its own while the fleet was online
    case failed     // exited non-zero on its own while online (agent crash / error)
  }

  /// The runner name (unique per ephemeral runner), e.g. `mactions-host-ab12cd`.
  public let id: String
  public let os: RunnerOS
  /// `owner/name`.
  public let repo: String
  public let remoteId: Int?
  public let startedAt: Date
  public let endedAt: Date
  /// The agent process / VM exit status, when known.
  public let exitStatus: Int32?
  public let outcome: Outcome

  public init(
    id: String, os: RunnerOS, repo: String, remoteId: Int?,
    startedAt: Date, endedAt: Date, exitStatus: Int32?, outcome: Outcome
  ) {
    self.id = id
    self.os = os
    self.repo = repo
    self.remoteId = remoteId
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.exitStatus = exitStatus
    self.outcome = outcome
  }

  /// Runner lifetime in seconds (came-up → exited). See the note on `startedAt`.
  public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// Persists run history to `~/.mactions/logs/run-history.json` so the dashboard
/// can show past runs across app restarts. Lives under `logsRoot()` on purpose:
/// that directory survives go-offline and the per-go-online orphan sweep (only a
/// full `purgeAll` clears it), exactly the lifetime we want for history.
///
/// Newest-first, bounded to `maxRecords` so it can't grow without limit. All I/O
/// is synchronous + best-effort (a failed read/write degrades to an empty/lost
/// history, never a crash); callers do the write off the main actor.
public enum RunHistoryStore {
  /// Cap so the file can't grow unbounded over a long-lived install. Older rows
  /// fall off the end (history is newest-first).
  public static let maxRecords = 500

  public static func fileURL() -> URL {
    HostCleanup.logsRoot().appendingPathComponent("run-history.json", isDirectory: false)
  }

  public static func load() -> [RunRecord] {
    guard let data = try? Data(contentsOf: fileURL()) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([RunRecord].self, from: data)) ?? []
  }

  /// Overwrite the history file with `records` (already newest-first), trimmed to
  /// `maxRecords`. Atomic so a crash mid-write can't truncate the file. Returns
  /// whether the write succeeded.
  @discardableResult
  public static func save(_ records: [RunRecord]) -> Bool {
    let dir = HostCleanup.logsRoot()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Defensive cap: callers (AppState.recordRun) already keep the in-memory list
    // at/under maxRecords, but trim here too so the file is bounded regardless of
    // who calls save().
    let trimmed = Array(records.prefix(maxRecords))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(trimmed) else { return false }
    return (try? data.write(to: fileURL(), options: .atomic)) != nil
  }
}
