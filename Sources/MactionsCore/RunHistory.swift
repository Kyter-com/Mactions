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

  /// The *true* result, resolved from the GitHub job once we can find it — NOT the
  /// agent's exit. An ephemeral runner agent exits 0 after reporting its job's
  /// result to GitHub, pass or fail, so `Outcome` alone says "Completed/exit 0"
  /// even for a failed job. This is back-filled by `AppState.loadJobLog` and is the
  /// authority History displays. Optional so pre-existing history JSON (no key)
  /// decodes as `nil` — no migration needed.
  public enum JobConclusion: String, Codable, Sendable {
    case success
    case failure
    case cancelled
    case timedOut = "timed_out"
    case neutral
    case skipped
    case inProgress = "in_progress"    // job still running / queued on GitHub
    case agentFailed = "agent_failed"  // agent exited non-zero (crash; job may not have run)

    /// Resolve the persisted conclusion from a fetched GitHub job + the agent exit.
    /// A non-zero agent exit wins — the agent crashed, so the job may never have
    /// reported a real conclusion. Pure → unit-tested without the app.
    public static func resolve(status: String, conclusion: String?, exitStatus: Int32?)
      -> JobConclusion
    {
      if let code = exitStatus, code != 0 { return .agentFailed }
      guard status == "completed" else { return .inProgress }
      switch conclusion {
      case "success":   return .success
      case "failure":   return .failure
      case "timed_out": return .timedOut
      case "cancelled": return .cancelled
      case "skipped":   return .skipped
      case "neutral":   return .neutral
      default:          return .inProgress  // completed with a null conclusion ≈ still settling
      }
    }
  }

  /// Coarse status the UI buckets on (badge/circle color + the Passed/Failed
  /// filter). Derived from `jobConclusion` when resolved, else an honest fallback.
  public enum ResolvedStatus: Sendable, Equatable {
    case passed, failed, neutral, running, unknownCompleted
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
  /// Provisional, agent-exit-derived classification. Use `resolvedStatus` /
  /// `statusLabel` for display — they prefer `jobConclusion` when it's resolved.
  public let outcome: Outcome
  /// The true GitHub job result, back-filled from the Jobs API. `nil` until
  /// resolved (offline, not fetched yet, or the job isn't indexed). `var` so
  /// `AppState.updateRunConclusion` can patch it in place in the in-memory array.
  public var jobConclusion: JobConclusion?

  public init(
    id: String, os: RunnerOS, repo: String, remoteId: Int?,
    startedAt: Date, endedAt: Date, exitStatus: Int32?, outcome: Outcome,
    jobConclusion: JobConclusion? = nil
  ) {
    self.id = id
    self.os = os
    self.repo = repo
    self.remoteId = remoteId
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.exitStatus = exitStatus
    self.outcome = outcome
    self.jobConclusion = jobConclusion
  }

  /// Runner lifetime in seconds (came-up → exited). See the note on `startedAt`.
  /// This is the *agent's* uptime, not the job's runtime — the UI labels it so.
  public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

  /// Coarse bucket for badge/circle color + filtering. Prefers the resolved
  /// GitHub conclusion; falls back to the agent exit (a clean exit is reported as
  /// `unknownCompleted`, NOT a green "passed", so we never claim a result we
  /// haven't verified against GitHub).
  public var resolvedStatus: ResolvedStatus {
    guard let c = jobConclusion else {
      return outcome == .completed ? .unknownCompleted : .failed
    }
    switch c {
    case .success:                          return .passed
    case .failure, .timedOut, .agentFailed: return .failed
    case .cancelled, .skipped, .neutral:    return .neutral
    case .inProgress:                       return .running
    }
  }

  /// Precise human label for the History status badge.
  public var statusLabel: String {
    guard let c = jobConclusion else {
      return outcome == .completed ? "Completed" : "Failed"
    }
    switch c {
    case .success:     return "Passed"
    case .failure:     return "Failed"
    case .timedOut:    return "Timed out"
    case .cancelled:   return "Cancelled"
    case .skipped:     return "Skipped"
    case .neutral:     return "Neutral"
    case .inProgress:  return "Running"
    case .agentFailed: return "Agent failed"
    }
  }
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
