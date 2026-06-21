import Foundation
import OSLog

/// Structured logging for the control-plane hot path: the all-repos discovery
/// scan, queued-jobs polls, provision decisions, orchestrator create/reap, host
/// budget, and `listRunners` outages.
///
/// Why this exists: Mactions previously emitted NO runtime application logs, so
/// a ~9.5 h all-OS provisioning stall (2026-06-21) was undiagnosable after the
/// fact — `run-history.json` records only runner EXITS, leaving polls, demand,
/// reaps, budget denials, and a frozen scan loop with no trace. This fills that
/// gap so a recurrence is explainable from the log alone.
///
/// Two sinks, both best-effort and crash-proof:
///   - the unified log (subsystem `com.kyter.mactions`, category `control-plane`),
///     queryable live via `log stream --predicate 'subsystem == "com.kyter.mactions"'`
///     or after the fact via `log show --predicate '…' --last 1d`; and
///   - an append-only JSONL file at `~/.mactions/logs/control-plane.jsonl`
///     (survives restarts like run-history; rotated once past `maxBytes` so it
///     can never grow without bound).
///
/// `nonisolated` statics + a private serial queue so ANY actor or detached task
/// can log without `await`; file writes are serialized on that queue and every
/// I/O step is `try?` (a logging failure must never affect provisioning).
public enum ControlPlaneLog {
  private static let logger = Logger(subsystem: "com.kyter.mactions", category: "control-plane")
  private static let queue = DispatchQueue(label: "com.kyter.mactions.control-plane-log")
  /// Rotate to `…jsonl.1` (keeping one prior file) once the live file exceeds this.
  private static let maxBytes = 8 * 1024 * 1024

  public static func fileURL() -> URL {
    HostCleanup.logsRoot().appendingPathComponent("control-plane.jsonl", isDirectory: false)
  }

  /// Record one control-plane event. `fields` is small, string-valued context
  /// (repo, os, counts, decision, error). Safe to call from the hot path: the
  /// unified-log write is immediate (thread-safe) and the file write is queued.
  public static func log(_ event: String, _ fields: [String: String] = [:]) {
    let rendered =
      fields.isEmpty
      ? event
      : event + " " + fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
    logger.log("\(rendered, privacy: .public)")

    let at = Date()
    queue.async {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      var obj: [String: String] = ["ts": formatter.string(from: at), "event": event]
      for (key, value) in fields { obj[key] = value }
      guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
      else { return }
      appendLine(data)
    }
  }

  // MARK: - serial-queue only

  private static func appendLine(_ data: Data) {
    let url = fileURL()
    let fm = FileManager.default
    try? fm.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    rotateIfNeeded(url, fm: fm)
    var line = data
    line.append(0x0A)  // newline-delimited JSON
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: line)
    } else {
      // File doesn't exist yet (or isn't writable as a handle) — create it.
      try? line.write(to: url, options: .atomic)
    }
  }

  private static func rotateIfNeeded(_ url: URL, fm: FileManager) {
    guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int,
      size > maxBytes
    else { return }
    let prior = url.deletingLastPathComponent()
      .appendingPathComponent("control-plane.jsonl.1", isDirectory: false)
    try? fm.removeItem(at: prior)
    try? fm.moveItem(at: url, to: prior)
  }
}
