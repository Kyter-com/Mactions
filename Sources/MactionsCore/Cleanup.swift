import Foundation

/// Host hygiene. The whole point of ephemeral runners is to leave nothing
/// behind, so cleanup is a first-class concern, not an afterthought:
///
///   - Per run: `LocalProcessProvider` runs each job in an isolated, cloned
///     copy of the agent and deletes that copy the instant the job exits, so a
///     job's `_work` checkout, `_tool`/`_actions` caches, `_diag` logs and
///     `.credentials` never accumulate.
///   - Per launch / go-online: `purgeRuns()` + `purgeStrayTartClones()` sweep
///     anything a crash or force-quit orphaned last time.
///   - On demand: `purgeAll()` removes everything Mactions ever wrote to disk
///     (including the cached agent) for a clean uninstall.
///
/// Everything Mactions writes lives under one directory so it's all reapable.
public enum HostCleanup {
  /// `~/.mactions`. A dot-dir in $HOME on purpose: the GitHub Actions runner
  /// breaks on spaces in its work path, and `~/Library/Application Support`
  /// contains one ("Application Support") — which fails jobs with a bash
  /// "is a directory" / exit 126 the moment a step runs. homerun uses
  /// `~/.homerun` for exactly this reason.
  public static func mactionsRoot() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".mactions", isDirectory: true)
  }

  /// Cached, pristine agent install (the template runs are cloned from).
  public static func agentTemplateDirectory() -> URL {
    mactionsRoot().appendingPathComponent("actions-runner", isDirectory: true)
  }

  /// Parent of the per-run working copies.
  public static func runsRoot() -> URL {
    mactionsRoot().appendingPathComponent("runs", isDirectory: true)
  }

  /// Delete all per-run working copies. Safe to call any time we're offline —
  /// these only exist for the duration of a job.
  public static func purgeRuns() {
    try? FileManager.default.removeItem(at: runsRoot())
  }

  /// Remove the cached agent + all run dirs (the big/transient stuff). Leaves
  /// the auth token in place — signing out clears that via `TokenStore.clear()`.
  public static func purgeAll() {
    try? FileManager.default.removeItem(at: agentTemplateDirectory())
    purgeRuns()
  }

  /// Best-effort: delete leftover ephemeral Tart VMs from a crashed session.
  /// No-op if `tart` isn't installed. Only touches our `mactions-` clones.
  public static func purgeStrayTartClones() {
    guard let tart = Shell.which("tart") else { return }
    guard let list = try? Shell.run(tart, ["list"]), list.ok else { return }
    let tokens = list.stdout.components(separatedBy: .whitespacesAndNewlines)
    let names = Set(tokens.filter { $0.hasPrefix("mactions-") })
    for name in names {
      _ = try? Shell.run(tart, ["delete", name])
    }
  }

  /// Sweep orphans left by a previous (possibly crashed) session. Call before
  /// going online.
  public static func sweepOrphans() {
    purgeRuns()
    purgeStrayTartClones()
  }
}
