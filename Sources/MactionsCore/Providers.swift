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
  private let runDirectory: URL
  private var process: Process?
  private var cleaned = false
  private let lock = NSLock()

  /// `templateDirectory` is the pristine cached agent install; the per-run
  /// clone lives at `runsRoot/<id>`.
  public init(id: String, templateDirectory: URL, runsRoot: URL) {
    self.id = id
    self.templateDirectory = templateDirectory
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

  public func stop() {
    lock.lock(); let process = self.process; self.process = nil; lock.unlock()
    if let process, process.isRunning {
      process.terminate() // terminationHandler runs cleanup()
    } else {
      cleanup()
    }
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
  private func cleanup() {
    lock.lock()
    if cleaned { lock.unlock(); return }
    cleaned = true
    lock.unlock()
    try? FileManager.default.removeItem(at: runDirectory)
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
