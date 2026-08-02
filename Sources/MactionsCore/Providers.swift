import Foundation

/// A runner *provider* is the substrate a single ephemeral runner executes on.
/// It takes a JIT config, runs the agent for exactly one job, and reports when
/// the agent exits so the orchestrator can recycle it.
public protocol RunnerProvider: AnyObject, Sendable {
  /// Stable id for logging/UI (usually the runner name).
  var id: String { get }
  /// Launch the agent with `jitConfig`. `onExit` fires (any thread) when the
  /// agent process/VM finishes — a clean ephemeral exit or a crash.
  /// May BLOCK (agent clone, VM clone, container run), so the orchestrator runs
  /// it off the main actor — all conformers are `@unchecked Sendable`.
  func start(jitConfig: String, onExit: @escaping @Sendable (Int32) -> Void) throws
  /// Tear down immediately (user went offline / quit).
  func stop()
  var isRunning: Bool { get }
}

public protocol RunnerProviderFactory {
  /// Human label for the substrate (shown in the UI).
  var kind: String { get }
  func makeProvider(name: String) -> RunnerProvider
}

// MARK: - Local process (the no-VM POC path)

/// Runs the actions-runner agent directly on this Mac. No VM isolation — fine
/// for trusted private repos and for proving the loop end to end. For untrusted
/// code, use a VM-backed provider instead.
///
/// Host hygiene: each run executes in its **own clone** of the cached agent at
/// `runsRoot/<id>`, deleted the instant the job exits. The job's `_work`
/// checkout, `_tool`/`_actions` caches, `_diag` logs and `.credentials` all
/// live inside that clone, so nothing accumulates on the host across runs.
public final class LocalProcessProvider: RunnerProvider, @unchecked Sendable {
  public let id: String
  private let templateDirectory: URL
  private let runsRoot: URL
  private let runDirectory: URL
  private var process: Process?
  private var cleaned = false
  private let lock = NSLock()

  /// `templateDirectory` is the pristine cached agent install; the per-run
  /// clone lives at `runsRoot/<id>`.
  public init(id: String, templateDirectory: URL, runsRoot: URL) {
    self.id = id
    self.templateDirectory = templateDirectory
    self.runsRoot = runsRoot
    self.runDirectory = runsRoot.appendingPathComponent(id, isDirectory: true)
  }

  public var isRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return process?.isRunning ?? false
  }

  /// The GitHub-hosted `ImageOS` token for a macOS major version: lowercase
  /// `macos` + the bare major, NO separator/case (e.g. 26 → `macos26`, 15 →
  /// `macos15`). This exact shape is the contract setup-* actions validate and
  /// cache keys embed — `macOS`, `macos-26`, etc. would be worse than unset
  /// (whitelist-checking actions hard-fail). Pure → unit-tested so the format
  /// can't silently drift.
  static func imageOSToken(majorVersion: Int) -> String { "macos\(majorVersion)" }

  public func start(jitConfig: String, onExit: @escaping @Sendable (Int32) -> Void) throws {
    try FileManager.default.createDirectory(
      at: runDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: runDirectory)
    try cloneAgent()

    // Full ephemerality: point the job's HOME, every cache, and TMPDIR INSIDE
    // the per-run clone. When the clone is wiped on exit, NOTHING the job did
    // survives — no npm cache in the user's ~/.npm, no tool cache, no temp
    // files, no dotfiles. Each job runs as if on a throwaway machine. (The
    // cost is no cross-run cache reuse — deps re-download each run — which is
    // the whole point of "separate PC every time".)
    let jobHome = runDirectory.appendingPathComponent("_home", isDirectory: true)
    let jobTmp = runDirectory.appendingPathComponent("_tmp", isDirectory: true)
    // macOS `security` derives the per-user keychain search list from $HOME. With
    // HOME redirected into the throwaway clone, the user's login keychain
    // (~/Library/Keychains/login.keychain-db) drops out and the list collapses to
    // just /Library/Keychains/System.keychain — so `security find-identity -v -p
    // codesigning` returns 0 identities inside the job. That breaks macOS code
    // signing: electron-builder (even with CSC_LINK) can't resolve a valid Developer
    // ID identity, nor the leaf's Developer ID intermediate to validate its own temp
    // CSC keychain, so it falls back to an ad-hoc signature that fails notarization —
    // even though the same secret signs cleanly on a normal HOME / hosted runner.
    // (Verified live: System-only / 0 identities under a redirected HOME; the valid
    // identity reappears the moment the login keychain is back in the search list.)
    // Note an empty Library/Preferences does NOT fix this — there's usually no
    // com.apple.security.plist to persist to. We must explicitly point the job's user
    // search list at the host login keychain + System below.
    let jobKeychainPrefs = jobHome.appendingPathComponent("Library/Preferences", isDirectory: true)
    for dir in [jobHome, jobTmp, jobKeychainPrefs] {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    var env = ProcessInfo.processInfo.environment
    let realHome = env["HOME"]
    env["HOME"] = jobHome.path
    env["npm_config_cache"] = jobHome.appendingPathComponent(".npm").path
    env["RUNNER_TOOL_CACHE"] = runDirectory.appendingPathComponent("_tool").path
    env["XDG_CACHE_HOME"] = jobHome.appendingPathComponent(".cache").path
    env["TMPDIR"] = jobTmp.path

    // GitHub-hosted-runner identity + git-cred parity (BASE.md: bake OS/runner
    // SEMANTICS, never a tool stack). These are read by setup-* actions / git —
    // they are not tools — so they belong in the base contract even though the
    // macOS runner executes on the bare host:
    //   - ImageOS: the lowercase-os+major token (e.g. macos15, macos26) that
    //     setup-* and cache keys branch on. Derived from the LIVE host because
    //     the runner literally IS that OS — honest by construction (it only
    //     diverges from a published GitHub image if the host runs a macOS major
    //     GitHub hasn't shipped an image for yet). When UNSET, whitelist-checking
    //     actions (setup-ruby/erlef-setup-beam) hard-fail "ImageOS must be set"
    //     before user code runs — the surprising-failure case BASE.md targets.
    //   - AGENT_TOOLSDIRECTORY: hosted sets it to the SAME path as
    //     RUNNER_TOOL_CACHE (a legacy alias some setup-* read instead). Keep them
    //     EQUAL to the ephemeral per-run _tool dir so they can never diverge.
    //   - GCM_INTERACTIVE=Never: the bare host may have Git Credential Manager
    //     configured; a headless job hitting an interactive auth prompt would
    //     hang. Mirrors the baked Windows value (bootstrap.ps1).
    env["ImageOS"] = Self.imageOSToken(
      majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    env["AGENT_TOOLSDIRECTORY"] = env["RUNNER_TOOL_CACHE"]
    env["GCM_INTERACTIVE"] = "Never"

    // Restore the keychain search list the HOME redirect collapsed: set the job's
    // *user* search list (persisted to jobHome/Library/Preferences) to the host
    // login keychain + System. Run with HOME already pointed at jobHome so it writes
    // into the clone, never the user's real search list. This restores identity
    // auto-discovery AND lets electron-builder's temp CSC keychain chain up to the
    // Developer ID intermediate; electron-builder's own temp keychain (CSC_LINK +
    // set-key-partition-list) still owns the signing key, so no interactive prompts.
    if let realHome {
      let loginKeychain = "\(realHome)/Library/Keychains/login.keychain-db"
      if FileManager.default.fileExists(atPath: loginKeychain) {
        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        seed.arguments = [
          "list-keychains", "-d", "user", "-s",
          loginKeychain, "/Library/Keychains/System.keychain",
        ]
        seed.environment = env  // HOME == jobHome → the list persists into the clone
        try? seed.run()
        seed.waitUntilExit()
      }
    }

    // Deliver the JIT registration secret via the environment, NOT the arg list,
    // so it never appears in `ps`/proc args (parity with the Linux & Windows
    // providers). The runner's CommandSettings strips the ACTIONS_RUNNER_INPUT_
    // prefix and treats this exactly as `--jitconfig`.
    env["ACTIONS_RUNNER_INPUT_JITCONFIG"] = jitConfig

    let process = Process()
    process.executableURL = runDirectory.appendingPathComponent("run.sh")
    process.currentDirectoryURL = runDirectory
    process.environment = env
    process.terminationHandler = { [weak self] proc in
      self?.cleanup()
      onExit(proc.terminationStatus)
    }
    try process.run()
    lock.lock(); self.process = process; lock.unlock()
  }

  /// Terminate the agent, then clean up UNCONDITIONALLY.
  ///
  /// Do NOT defer the cleanup to `terminationHandler`. On the reap path the app
  /// stays up so the handler does eventually fire, but on quit / go-offline the
  /// process can exit first — and `AppState.goOfflineAndWait()` then calls
  /// `HostCleanup.purgeRuns()`, deleting the run tree out from under descendants
  /// nothing has killed yet. That is exactly how a 100%-CPU orphan is made.
  ///
  /// `LinuxContainerProvider.stop()` already does this, for the same reason
  /// ("one zombie per reap cycle"). `cleanup()` is idempotent via `cleaned`, so
  /// a later terminationHandler is a harmless no-op.
  ///
  /// This is synchronous and can take ~2s when a descendant ignores SIGTERM, so
  /// callers on the main actor must not invoke it inline — see
  /// `RunnerOrchestrator.stop()` and `stopProviderOffMain`.
  public func stop() {
    lock.lock(); let process = self.process; self.process = nil; lock.unlock()
    process?.terminate()
    cleanup()
  }

  /// APFS copy-on-write clone keeps the per-run copy near-instant and almost
  /// free on disk; fall back to a plain recursive copy on non-APFS volumes.
  private func cloneAgent() throws {
    let clone = try Shell.run("/bin/cp", ["-cR", templateDirectory.path, runDirectory.path])
    if !clone.ok {
      try Shell.runChecked("/bin/cp", ["-R", templateDirectory.path, runDirectory.path])
    }
  }

  /// Idempotent: delete this run's working copy so nothing is left on the host.
  /// Kills any surviving agent descendants FIRST — see `killDescendants()`.
  private func cleanup() {
    lock.lock()
    if cleaned { lock.unlock(); return }
    cleaned = true
    lock.unlock()
    killDescendants()
    try? FileManager.default.removeItem(at: runDirectory)
  }

  /// Kill anything still running out of this run's clone, scoped to THIS run.
  ///
  /// `Process.terminate()` signals only our direct child (`run.sh`). The real
  /// tree is `run.sh → bash → Runner.Listener → Runner.Worker → Runner.Worker`.
  /// Observed live 2026-08-01: five `Runner.Worker` processes left at PPID=1,
  /// each spinning at ~100% CPU on a 14-core Mac, one per `sustained_unhealthy`
  /// reap, every one of their run directories already deleted.
  ///
  /// Note only the WORKERS were orphaned, not the bash layers or the Listener —
  /// five reaps left five strays, not ~20. So the gap is narrower than "the
  /// subtree survives SIGTERM": the Listener exits but does not guarantee its
  /// Worker is dead. That also means a Worker can be stranded by a NORMAL job
  /// completion with no teardown involved, which this covers too, since a
  /// natural `run.sh` exit still runs `cleanup()`.
  ///
  /// (An earlier version of this comment claimed the leak starved the host and
  /// caused the next reap, a closed feedback loop. The data does not support
  /// that: macOS runner boot time held at ~32s with zero orphans and with all
  /// five live, and the first reap preceded any orphan. The leak is real; the
  /// loop was not established.)
  ///
  /// Refuses to run unless the target really is a directory BELOW `runsRoot`.
  /// An empty `id` would collapse `runsRoot.appendingPathComponent("")` to the
  /// runs root itself and turn a run-scoped kill into a host-wide SIGKILL of
  /// every concurrent runner.
  private func killDescendants() {
    let root = runsRoot.standardizedFileURL.path
    let run = runDirectory.standardizedFileURL.path
    guard run != root, run.hasPrefix(root + "/") else {
      ControlPlaneLog.log("runner.teardown_kill_refused", ["runner": id, "path": run])
      return
    }
    Self.killProcesses(under: run, runner: id)
  }

  /// SIGTERM everything running out of `path`, wait briefly for the tree to fall
  /// over, then SIGKILL whatever ignored it. Static + internal so the behavior
  /// (including the scoping guarantee) is unit-testable without launching a real
  /// runner agent.
  ///
  /// The pattern is anchored so a path cannot match a longer sibling: bare
  /// `pkill -f /runs/run-1` also kills `/runs/run-10` (verified). Production ids
  /// end in a fixed-length hex suffix so that cannot happen today, but the
  /// helper must not depend on its caller's naming scheme to be safe.
  static func killProcesses(under path: String, runner: String = "") {
    // `pkill -f` takes an extended regex, so escape the path and require the
    // next character to be a path separator, whitespace, or end-of-line.
    let pattern = escapeForExtendedRegex(path) + "(/|[[:space:]]|$)"

    // Happy path: the agent already exited, so there is nothing to signal.
    guard stillAlive(pattern) else { return }

    _ = try? Shell.run("/usr/bin/pkill", ["-f", pattern])
    // Poll rather than sleep a fixed interval, so a tree that dies promptly
    // costs milliseconds instead of a fixed wait.
    for _ in 0..<20 {
      if !stillAlive(pattern) {
        ControlPlaneLog.log(
          "runner.teardown_kill", ["runner": runner, "escalated": "false", "survived": "false"])
        return
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    _ = try? Shell.run("/usr/bin/pkill", ["-9", "-f", pattern])
    let survived = stillAlive(pattern)
    ControlPlaneLog.log(
      "runner.teardown_kill",
      ["runner": runner, "escalated": "true", "survived": String(survived)])
  }

  /// Whether anything still matches `pattern`. Fails SAFE: `pgrep` exits 1 for
  /// "no match", but 2/3 mean pgrep itself failed (bad args, internal error) and
  /// must NOT read as "nothing left", or the SIGKILL escalation is skipped while
  /// reporting success. Anything other than a definite 1 counts as alive.
  private static func stillAlive(_ pattern: String) -> Bool {
    guard let probe = try? Shell.run("/usr/bin/pgrep", ["-f", pattern]) else { return true }
    return probe.status != 1
  }

  /// Escape only the POSIX ERE metacharacters. `/` is deliberately NOT escaped:
  /// it is an ordinary character in ERE, and escaping an ordinary character is
  /// undefined behavior per POSIX.
  static func escapeForExtendedRegex(_ value: String) -> String {
    var escaped = ""
    for character in value {
      if "\\.[]{}()*+?^$|".contains(character) { escaped.append("\\") }
      escaped.append(character)
    }
    return escaped
  }
}

public struct LocalProcessProviderFactory: RunnerProviderFactory {
  public let kind = "Local process (isolated clone, wiped each run)"
  private let templateDirectory: URL
  private let runsRoot: URL
  public init(templateDirectory: URL, runsRoot: URL) {
    self.templateDirectory = templateDirectory
    self.runsRoot = runsRoot
  }
  public func makeProvider(name: String) -> RunnerProvider {
    LocalProcessProvider(id: name, templateDirectory: templateDirectory, runsRoot: runsRoot)
  }
}
