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

  /// Best-effort: delete leftover ephemeral Windows VM clones from a crashed
  /// session. The Windows provider names its throwaway clones `mactions-…`, the
  /// same prefix we scope teardown to, so we never touch a non-Mactions VM.
  /// VMware Fusion is the sole backend: clones are on-disk per-clone subdirs
  /// under `~/.mactions/fusion/mactions-*` (not in any registry vmrun can list),
  /// so we drive the `mactions-fusion-vm` helper's `list`/`delete` verbs (delete
  /// = `vmrun stop hard` + `deleteVM` + `rm -rf` the clone dir), then an on-disk
  /// fallback sweep. No-op if the helper isn't present.
  ///
  /// Honors the ephemerality bar across crashes: if the app died mid-job, a
  /// powered-down clone (with its `_work` checkout + linked disk) can be left
  /// behind; this reaps it on the next go-online.
  public static func purgeStrayWindowsClones() {
    // Drive the helper's own list/delete (it self-prepends the Fusion + Homebrew
    // bins to PATH, so this works even from a Finder/launchd-launched app).
    if let fusion = WindowsVMProviderFactory.fusionHelperPath,
      let list = try? Shell.run(fusion, ["list"]), list.ok {
      for name in windowsCloneNames(in: list.stdout) {
        _ = try? Shell.run(fusion, ["delete", name])
      }
    }
    // Belt-and-suspenders: even if the helper is gone (tools uninstalled) or its
    // setup died, reap any leftover throwaway clone dirs by hand. The `mactions-`
    // prefix scopes this to our own clones (the base's flat `win11-runner-base.*`
    // files aren't matched). Fusion clones are powered off by `delete`/crash and
    // hold no detached host process, so a plain removeItem suffices.
    let fm = FileManager.default
    let clonesDir = NSString(string: "~/.mactions/fusion").expandingTildeInPath
    if let entries = try? fm.contentsOfDirectory(atPath: clonesDir) {
      for entry in entries where entry.hasPrefix("mactions-") {
        try? fm.removeItem(atPath: clonesDir + "/" + entry)
      }
    }
  }

  /// Pull our `mactions-…` clone names out of a VM-CLI listing (pure → testable).
  static func windowsCloneNames(in listing: String) -> Set<String> {
    let tokens = listing.components(separatedBy: .whitespacesAndNewlines)
    return Set(tokens.filter { $0.hasPrefix("mactions-") })
  }

  /// Best-effort: kill leftover runner-agent processes (run.sh / Runner.Listener
  /// and their job children) from a crashed/force-quit session. On a hard exit
  /// the agents reparent to launchd and keep running (and holding their GitHub
  /// registration) — `pkill -f` matches them by their working path under
  /// `runs/`. MUST run before `purgeRuns()` so we don't delete a live job's
  /// directory out from under it.
  public static func killOrphanRunnerProcesses() {
    _ = try? Shell.run("/usr/bin/pkill", ["-f", runsRoot().path])
  }

  /// Sweep orphans left by a previous (possibly crashed) session. Call before
  /// going online.
  public static func sweepOrphans() {
    killOrphanRunnerProcesses()
    purgeRuns()
    purgeStrayTartClones()
    purgeStrayWindowsClones()
  }
}
