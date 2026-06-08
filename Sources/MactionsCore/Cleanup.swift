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
///   - After a successful Windows base rebuild: old `.win11-runner-base.bak.*`
///     rescue copies are removed, reclaiming the multi-GB failed-build backups
///     that `MACTIONS_KEEP_FAILED=1` intentionally preserved for post-mortem.
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

  /// Durable diagnostic logs (base-build transcripts, captured guest logs). Kept
  /// across runs on purpose — this is where a failed build/run is diagnosed — so
  /// it is NOT swept by `purgeRuns`/`sweepOrphans`; only a full `purgeAll` clears it.
  public static func logsRoot() -> URL {
    mactionsRoot().appendingPathComponent("logs", isDirectory: true)
  }

  /// Delete all per-run working copies. Safe to call any time we're offline —
  /// these only exist for the duration of a job.
  public static func purgeRuns() {
    try? FileManager.default.removeItem(at: runsRoot())
  }

  /// The persistent UUP download cache (`~/.mactions/cache`). An interrupted
  /// Windows base build leaves a multi-GB `cache/uup-<build>/` here ON PURPOSE so
  /// a retry resumes (`prepare-windows-image` reaps it only on a fully-successful
  /// build). It must NOT be swept per go-online (that would defeat resume) — only
  /// a full uninstall (`purgeAll`) reclaims it.
  public static func cacheRoot() -> URL {
    mactionsRoot().appendingPathComponent("cache", isDirectory: true)
  }

  /// VMware Fusion state root. The pristine base lives flat here; per-job clones
  /// and failed-build base backups live in subdirectories.
  public static func fusionRoot() -> URL {
    mactionsRoot().appendingPathComponent("fusion", isDirectory: true)
  }

  /// Remove the cached agent + all run dirs (the big/transient stuff). Leaves
  /// the auth token in place — signing out clears that via `TokenStore.clear()`.
  public static func purgeAll() {
    try? FileManager.default.removeItem(at: agentTemplateDirectory())
    try? FileManager.default.removeItem(at: logsRoot())
    // Reclaim an aborted base build's multi-GB resume cache (NOT touched by
    // purgeRuns/sweepOrphans, which run per go-online and must preserve resume).
    try? FileManager.default.removeItem(at: cacheRoot())
    purgeRuns()
  }

  /// Persist a build/install transcript to `logs/<name>-<stamp>.log` so a failure
  /// is diagnosable from disk (not just Console.app) and survives the ephemeral
  /// clone. `stamp` is passed in (callers format it) so this stays pure. Returns
  /// the written path, or `nil` on failure. Safe to call off the main actor.
  @discardableResult
  public static func writeLog(name: String, stamp: String, contents: String) -> String? {
    let dir = logsRoot()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(name)-\(stamp).log")
    do {
      try contents.write(to: url, atomically: true, encoding: .utf8)
      return url.path
    } catch {
      return nil
    }
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
    // Also reap any per-clone config-ISO staging dir the provider builds under
    // $TMPDIR (`mactions-cfg-<clone>`). teardown() removes it on every normal
    // path, so a leftover here means a hard crash before teardown ran; without
    // this sweep it'd linger until the OS's periodic temp purge.
    let tmp = NSTemporaryDirectory()
    if let tmpEntries = try? fm.contentsOfDirectory(atPath: tmp) {
      for entry in tmpEntries where entry.hasPrefix("mactions-cfg-") {
        try? fm.removeItem(atPath: tmp + entry)
      }
    }
  }

  /// Old rescue copies produced by `fusion-windows-base` when a rebuild fails
  /// with `MACTIONS_KEEP_FAILED=1`. Once a later rebuild succeeds, these are just
  /// stale multi-GB diagnostics and should be reclaimed automatically.
  public static func windowsBaseBackupDirectories(in fusionRoot: URL) -> [URL] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
      at: fusionRoot, includingPropertiesForKeys: [.isDirectoryKey])
    else { return [] }
    return entries.filter { url in
      guard url.lastPathComponent.hasPrefix(".win11-runner-base.bak.") else { return false }
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
      return values?.isDirectory == true
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  @discardableResult
  public static func purgeWindowsBaseBackups() -> Int {
    let backups = windowsBaseBackupDirectories(in: fusionRoot())
    for backup in backups {
      try? FileManager.default.removeItem(at: backup)
    }
    return backups.count
  }

  /// Pull our `mactions-…` clone names out of a VM-CLI listing (pure → testable).
  static func windowsCloneNames(in listing: String) -> Set<String> {
    let tokens = listing.components(separatedBy: .whitespacesAndNewlines)
    return Set(tokens.filter { $0.hasPrefix("mactions-") })
  }

  /// Best-effort: force-remove leftover ephemeral Linux runner **containers** from
  /// a crashed/force-quit session. The provider runs each job in a `--rm`
  /// container labeled `mactions` and named `mactions-…`, so `--rm` reaps it on a
  /// normal exit — but a hard crash (or a daemon killed mid-job) can leave one
  /// behind, holding its `_work` checkout and its GitHub registration. We list by
  /// the `mactions` label and `rm -f` each. No-op if no container CLI is installed
  /// or the daemon is down (we never START a daemon just to clean up).
  public static func purgeStrayLinuxContainers() {
    guard let cli = LinuxContainerProviderFactory.detectInstalledCLI() else { return }
    // Don't spin up a daemon during a cleanup sweep — only reap if it's already up.
    guard let info = try? Shell.run(cli.executable, cli.daemonStatusArgs()), info.ok else { return }
    guard let list = try? Shell.run(cli.executable, cli.listByLabelArgs(label: "mactions")), list.ok
    else { return }
    for ref in linuxContainerRefs(in: list.stdout) {
      _ = try? Shell.run(cli.executable, cli.rmArgs(name: ref))
    }
  }

  /// Pull container refs (ids/names, one per line) out of a `ps -aq` / `list -q`
  /// listing (pure → testable). The `label=mactions` filter already scoped the
  /// listing to our own containers, so we just take every non-empty line.
  static func linuxContainerRefs(in listing: String) -> [String] {
    listing
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
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
    purgeStrayLinuxContainers()
  }
}
