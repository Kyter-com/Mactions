import Foundation

// MARK: - Windows VM CLI abstraction

/// The clone/boot/status/stop/delete + per-clone-config-injection verbs a
/// Windows-VM provider drives, expressed as **pure command builders** so the
/// per-tool shapes are unit-testable without a live VM (mirrors the
/// `jitConfigRequest`-style split the rest of the core uses). `VMwareCLI` (the
/// `mactions-fusion-vm` helper wrapping `vmrun`) is the sole conformer.
///
/// HEADLESS / OUTBOUND-REGISTRATION model (see AGENTS.md): there is no inbound
/// SSH and no guest-IP discovery. Per job we deliver a per-clone **config ISO**
/// carrying the JIT registration into the guest; the in-guest runtime reads it,
/// runs `run.cmd --jitconfig` (registering OUTBOUND to GitHub) for ONE job, then
/// powers the VM off. The host learns completion purely by polling VM **power
/// state**.
public protocol WindowsVMCLI: Sendable {
  /// Absolute path to the CLI binary (the `mactions-fusion-vm` helper).
  var executable: String { get }
  /// Human label for the substrate (shown in the UI / logs).
  var displayName: String { get }
  /// Make a cheap throwaway clone of `base` named `clone` (CoW / linked clone).
  func cloneArgs(base: String, clone: String) -> [String]
  /// Boot the clone headless (no GUI window). Returns immediately — the helper
  /// does NOT block until the VM powers off.
  func startArgs(clone: String) -> [String]
  /// Force power-off (used on teardown / stop()).
  func stopArgs(clone: String) -> [String]
  /// Permanently delete the clone and all its files (the ephemerality bar).
  func deleteArgs(clone: String) -> [String]
  /// Query the clone's power state. The provider parses it via `parseIsStopped`.
  func statusArgs(clone: String) -> [String]
  /// Query the BASE image's readiness — the helper's `base-status` verb checks
  /// the base `.vmx` exists, carries the linked-clone snapshot, and isn't
  /// powered on (prints "stopped" when ready to clone from).
  func baseStatusArgs(base: String) -> [String]
  /// `true` when the status/list output shows the VM powered-off/stopped.
  func parseIsStopped(from output: String) -> Bool
  /// Force/kill power-off — escalation when a graceful `stop` doesn't settle.
  func forceStopArgs(clone: String) -> [String]
  /// How this backend delivers the per-clone config ISO into the guest.
  func injectionPlan(clone: String, clonePath: String?, configISO: String) -> WindowsInjectionPlan
  /// Absolute path to the clone's on-disk dir, where the helper drops the linked
  /// clone and the provider writes `config.iso` (the CD the helper wired at
  /// clone time). The provider uses it to compute the config-ISO target path.
  func cloneBundlePath(clone: String) -> String?
}

/// How the backend delivers the per-clone config ISO into a powered-off clone.
public enum WindowsInjectionPlan: Equatable, Sendable {
  /// Copy the config ISO to a per-clone path the backend wired up at clone time.
  /// For VMware Fusion, `mactions-fusion-vm`'s `clone` verb already pointed the
  /// clone's `sata0:0` CD at `<clone-dir>/config.iso` with `startConnected=TRUE`,
  /// so injection is just this byte copy (no attach command, no in-bundle dance).
  case copyConfigFile(target: String)
}

/// Coarse VM power phase, used to gate completion detection. We must observe
/// `.running` once before treating `.stopped` as "the job finished and the guest
/// powered itself off" — a freshly cloned (not-yet-started) VM also reads stopped.
public enum VMPhase: Equatable, Sendable { case starting, running, stopped }

extension WindowsVMCLI {
  /// Default power-state read: mentions "stopped" and isn't mid-transition.
  public func parseIsStopped(from output: String) -> Bool {
    let o = output.lowercased()
    return o.contains("stopped") && !o.contains("stopping")
  }

  /// Default force-stop == the normal stop (override where a kill flag exists).
  public func forceStopArgs(clone: String) -> [String] { stopArgs(clone: clone) }

  /// Default base-readiness check is the same as a clone status check.
  public func baseStatusArgs(base: String) -> [String] { statusArgs(clone: base) }
}

/// VMware Fusion (free) via `vmrun` — the **PROVEN** backend for Win11-ARM on
/// Apple Silicon (see AGENTS.md → Windows support). Fusion's EFI boots Win11-ARM
/// cleanly where stock QEMU's firmware hangs, and `vmrun` gives a true headless
/// CLI (clone/start/stop/deleteVM + snapshots). The lifecycle is wrapped in
/// `scripts/mactions-fusion-vm` so the Swift side stays "one CLI + verb args" —
/// every method here is pure command-shape, unit-testable without launching
/// anything.
///
/// State layout (the helper owns these paths):
///   ~/.mactions/fusion/<base>.vmx     — the pristine base (flat), with a
///                                       powered-off `base-provisioned` snapshot
///                                       that linked clones parent from.
///   ~/.mactions/fusion/<clone>/       — per-clone subdir (linked .vmx + delta
///                                       disk + optional config.iso)
///
/// Injection model: provider `inject()` copies the per-job config ISO into
/// `<clone-dir>/config.iso`; the helper's `clone` step has already wired
/// `sata0:0` to that path with `startConnected=TRUE`, so Fusion connects it as a
/// CD at power-on — no new Swift injection plumbing, reusing `.copyConfigFile`.
public struct VMwareCLI: WindowsVMCLI {
  public let executable: String
  /// Where the base + per-clone subdirs live. The helper builds `<dir>/<clone>/`.
  public let clonesDir: String
  public init(
    executable: String,
    clonesDir: String = NSString(string: "~/.mactions/fusion").expandingTildeInPath
  ) {
    self.executable = executable
    self.clonesDir = clonesDir
  }
  public var displayName: String { "VMware Fusion (vmrun)" }
  public func cloneArgs(base: String, clone: String) -> [String] {
    ["clone", base, clone]
  }
  public func startArgs(clone: String) -> [String] { ["start", clone] }
  public func stopArgs(clone: String) -> [String] { ["stop", clone] }
  /// Helper `stop` already issues `vmrun stop … hard` (immediate power-off), so a
  /// separate force path adds nothing — exposed to satisfy the protocol.
  public func forceStopArgs(clone: String) -> [String] { ["stop", clone] }
  public func deleteArgs(clone: String) -> [String] { ["delete", clone] }
  public func statusArgs(clone: String) -> [String] { ["status", clone] }
  /// The helper has a dedicated `base-status` verb (base .vmx exists + carries
  /// the linked-clone snapshot + isn't powered on → "stopped"; else "in-use" /
  /// "no-snapshot" / "missing"). Mapped to the same parseIsStopped path so
  /// "stopped" → ready to clone from.
  public func baseStatusArgs(base: String) -> [String] { ["base-status", base] }
  /// Helper normalizes to exactly "running" or "stopped" (vmrun itself has no
  /// getstate; the helper reads `vmrun list`), so the substring match is correct;
  /// explicit override here as documentation. Also correct for the `base-status`
  /// strings — only "stopped" contains "stopped".
  public func parseIsStopped(from output: String) -> Bool {
    output.lowercased().contains("stopped")
  }
  /// Per-clone subdir, where the helper drops the linked clone + the provider's
  /// inject step writes config.iso (which the clone's wired sata0:0 points at).
  public func cloneBundlePath(clone: String) -> String? {
    clonesDir + "/" + clone
  }
  /// Drop the JIT config ISO at <clone-dir>/config.iso; the helper's `clone` step
  /// already pointed the clone's sata0:0 CD at that path with startConnected=TRUE.
  public func injectionPlan(clone: String, clonePath: String?, configISO: String) -> WindowsInjectionPlan {
    let dir = clonePath ?? cloneBundlePath(clone: clone) ?? ""
    return .copyConfigFile(target: dir + "/config.iso")
  }
}

// MARK: - Windows VM provider

/// Runs each ephemeral runner inside a **throwaway Windows 11 ARM VM** cloned
/// from a prepared base image, then destroys the clone — the only way to hit the
/// ephemerality bar on Windows (the entire guest disk is discarded per job).
///
/// HEADLESS / OUTBOUND-REGISTRATION flow (no SSH, no IP discovery):
///   1. **Clone** the pristine base to a throwaway `mactions-<id>` clone — the
///      `mactions-fusion-vm` `clone` verb linked-clones the base snapshot and
///      wires the clone's `sata0:0` CD at `<clone-dir>/config.iso`.
///   2. **Build** a tiny per-clone **config ISO** carrying the JIT config.
///   3. **Inject** it: copy the config ISO to that `<clone-dir>/config.iso` path
///      (the wired CD), while the clone is still powered off.
///   4. **Start** headless. The base image's in-guest runtime (a logon Scheduled
///      Task from `bootstrap.ps1`) reads the JIT off the disc, runs
///      `run.cmd --jitconfig` for ONE job (registering OUTBOUND to GitHub), then
///      `shutdown /s`.
///   5. **Detect completion by power state**: poll `status` until the guest has
///      powered itself off (after first confirming it reached `.running`).
///   6. **Destroy** the clone on every path, then fire `onExit`.
///
/// PROVEN end to end on VMware Fusion (see AGENTS.md → Windows support).
public final class WindowsVMProvider: RunnerProvider, @unchecked Sendable {
  public let id: String
  private let baseImage: String
  private let cli: WindowsVMCLI
  /// Volume label the in-guest runtime locates the config disc by.
  private let configVolumeName: String
  /// How long to wait for the clone to reach `.running` before giving up, and
  /// how long to then wait for it to power itself off (job done).
  private let bootTimeout: TimeInterval
  private let jobTimeout: TimeInterval

  /// Default `jobTimeout`: GitHub's job-execution allowance (the
  /// `timeout-minutes: 360` default = 6 h) + 30 min of lifecycle headroom. The
  /// provider clock starts at VM BOOT, not job start, so it must cover
  /// registration + the idle wait for a job (bounded by the orchestrator's
  /// ~8-min idle refresh) + the job itself + GitHub's cancellation wind-down +
  /// guest shutdown — an exactly-6h watchdog would kill a legal full-length job
  /// minutes before it finished. This is a last-resort watchdog for a WEDGED
  /// guest, not the duration enforcer: GitHub cancels the job at the workflow's
  /// `timeout-minutes` (default 360; self-hosted jobs may configure up to
  /// 5 days), after which the guest powers itself off and the poll below sees
  /// it. Idle/staleness is the orchestrator's: `idleJITRefreshInterval` (~8 min)
  /// recycles idle runners and the sustained-offline prune reaps dead agents,
  /// both keyed off GitHub's authoritative runner state. (An earlier 50-min
  /// budget tried to stay under the JIT token's ~60-min expiry, but that expiry
  /// bounds REGISTRATION — an unused jitconfig going stale — not job duration:
  /// the macOS/Linux providers run the same JIT mechanism with no provider-level
  /// timeout at all, and long jobs run fine. Verified against docs.github.com
  /// usage limits + actions/runner auth.md, 2026-06.) Jobs needing
  /// `timeout-minutes` > 360 on a Mactions Windows runner are not supported
  /// until this becomes configurable — documented in PARITY.md.
  public static let defaultJobTimeout: TimeInterval = (360 + 30) * 60
  private let pollInterval: TimeInterval
  /// Teardown budget: how long to wait for a confirmed power-off before deleting
  /// the clone, and the poll/escalation interval. Injectable so tests run fast.
  private let stopSettleTimeout: TimeInterval
  private let stopPollInterval: TimeInterval

  /// Clone name carries the same `mactions-` prefix `HostCleanup` and the
  /// orchestrator use to identify (and reap) our own VMs.
  var cloneName: String { "mactions-\(id)" }

  private var running = false
  /// Set the first (and only) time the clone is torn down. Guards the background
  /// thread and `stop()` from racing to delete the VM / fire `onExit` twice.
  private var tornDown = false
  /// Per-clone scratch dir (config ISO + staging); removed on teardown. The
  /// guest reads the JIT off the copy on the clone's wired CD, so this staging
  /// dir is only needed until `inject()` copies it into the clone dir.
  private var configWorkdir: String?
  private let lock = NSLock()

  public init(
    id: String,
    baseImage: String,
    cli: WindowsVMCLI,
    configVolumeName: String = "MACTIONS",
    bootTimeout: TimeInterval = 300,
    jobTimeout: TimeInterval = WindowsVMProvider.defaultJobTimeout,
    pollInterval: TimeInterval = 5,
    stopSettleTimeout: TimeInterval = 12,
    stopPollInterval: TimeInterval = 1.5
  ) {
    self.id = id
    self.baseImage = baseImage
    self.cli = cli
    self.configVolumeName = configVolumeName
    self.bootTimeout = bootTimeout
    self.jobTimeout = jobTimeout
    self.pollInterval = pollInterval
    self.stopSettleTimeout = stopSettleTimeout
    self.stopPollInterval = stopPollInterval
  }

  public var isRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return running
  }

  /// Whether the clone has already been torn down (by `stop()` or the start()
  /// error path). The completion-poll thread reads this to bail out promptly
  /// instead of polling a deleted VM until its timeout.
  private var isTornDown: Bool {
    lock.lock(); defer { lock.unlock() }
    return tornDown
  }

  public func start(jitConfig: String, onExit: @escaping @Sendable (Int32) -> Void) throws {
    // 1. Clone (throwaway), 2. build the per-clone config ISO, 3. inject it into
    // the still-powered-off clone, 4. boot. Steps 1-4 happen synchronously so a
    // failure surfaces from start(); the completion poll runs on a thread.
    try Shell.runChecked(cli.executable, cli.cloneArgs(base: baseImage, clone: cloneName))
    lock.lock(); running = true; lock.unlock()

    do {
      let iso = try buildConfigISO(jitConfig: jitConfig)
      try inject(configISO: iso)
      try Shell.runChecked(cli.executable, cli.startArgs(clone: cloneName))
    } catch {
      // Clone exists but couldn't be prepared/started — reclaim it and report by
      // THROWING only. We deliberately do NOT also fire onExit here: the
      // orchestrator appends this provider's slot only AFTER start() returns, so
      // a thrown start() means no slot exists yet — its provisionOne catch is the
      // sole handler. Firing onExit too would drive a redundant reconcile against
      // a phantom slot (and mismatches LocalProcessProvider/TartProvider, which
      // throw without onExit). The thread below is never started on this path.
      teardown()
      throw error
    }

    Thread.detachNewThread { [self] in
      var status: Int32 = 0
      // PHASE 1 — confirm the clone actually reached `.running` (defeats the
      // just-cloned 'stopped' false positive) within bootTimeout.
      let bootDeadline = Date().addingTimeInterval(bootTimeout)
      var sawRunning = false
      while Date() < bootDeadline {
        // stop()/teardown ran (user went offline / quit) — bail out instead of
        // polling a deleted clone until bootTimeout. teardown already reaped it
        // and stop() owns its own (no-onExit) teardown path.
        if isTornDown { return }
        if let r = try? Shell.run(cli.executable, cli.statusArgs(clone: cloneName)), r.ok,
          phase(from: r.stdout) == .running
        {
          sawRunning = true
          break
        }
        Thread.sleep(forTimeInterval: pollInterval)
      }
      if sawRunning {
        // PHASE 2 — the guest runs its single job, then `shutdown /s`. Wait for
        // the self power-off (the only completion signal — no SSH/exit code; the
        // authoritative job result is on GitHub).
        let jobDeadline = Date().addingTimeInterval(jobTimeout)
        var done = false
        while Date() < jobDeadline {
          if isTornDown { return }  // torn down meanwhile — stop polling a gone VM
          if let r = try? Shell.run(cli.executable, cli.statusArgs(clone: cloneName)), r.ok,
            phase(from: r.stdout) == .stopped
          {
            done = true
            break
          }
          Thread.sleep(forTimeInterval: pollInterval)
        }
        status = done ? 0 : 1  // timeout (hung guest) -> failure; teardown force-kills
      } else {
        status = 1  // never booted
      }
      if teardown() { onExit(status) }
    }
  }

  public func stop() {
    // User went offline / quit: tear the clone down now. We deliberately do NOT
    // call `onExit` here — `stop()` is the orchestrator's own teardown path.
    _ = teardown()
  }

  // MARK: Completion-state classifier (pure → unit-testable)

  /// Classify a backend `status` string. We require an observed `.running`
  /// before treating `.stopped` as job-complete, so a fresh clone reading
  /// "stopped" (between clone and start, or at the very start of boot) is not a
  /// false completion.
  func phase(from status: String) -> VMPhase {
    if cli.parseIsStopped(from: status) { return .stopped }
    let s = status.lowercased()
    if s.contains("running") || s.contains("started") || s.contains("starting")
      || s.contains("stopping") || s.contains("paused") || s.contains("suspend")
      || s.contains("resum")
    {
      return .running
    }
    return .starting
  }

  // MARK: Per-clone config ISO + injection

  /// Build the per-clone config ISO carrying the JIT at `mactions/jitconfig`
  /// (base64, no trailing newline so `run.cmd --jitconfig` reads it byte-exact).
  /// Returns the ISO path; the scratch dir is cleaned on teardown.
  private func buildConfigISO(jitConfig: String) throws -> String {
    let work = NSTemporaryDirectory() + "mactions-cfg-\(cloneName)"
    let staging = work + "/payload"
    let macDir = staging + "/mactions"
    let iso = work + "/config.iso"
    lock.lock(); configWorkdir = work; lock.unlock()
    let fm = FileManager.default
    try? fm.removeItem(atPath: work)
    try fm.createDirectory(atPath: macDir, withIntermediateDirectories: true)
    try Data(jitConfig.utf8).write(to: URL(fileURLWithPath: macDir + "/jitconfig"))
    try Shell.runChecked(
      WindowsImage.hdiutilPath(),
      WindowsImage.configISOArgs(sourceDir: staging, output: iso, volumeName: configVolumeName))
    return iso
  }

  /// Deliver the config ISO into the powered-off clone. The clone's `sata0:0` CD
  /// was already wired at `<clone-dir>/config.iso` by the helper's `clone` verb,
  /// so this is just a byte copy to that path.
  private func inject(configISO: String) throws {
    let clonePath = cli.cloneBundlePath(clone: cloneName)
    guard case let .copyConfigFile(target) = cli.injectionPlan(
      clone: cloneName, clonePath: clonePath, configISO: configISO)
    else { return }  // single-case enum — always matches
    let fm = FileManager.default
    let parent = (target as NSString).deletingLastPathComponent
    if !parent.isEmpty {
      try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
    }
    if fm.fileExists(atPath: target) { try? fm.removeItem(atPath: target) }
    try fm.copyItem(atPath: configISO, toPath: target)
  }

  // MARK: Teardown

  /// Force-stop + permanently delete the clone, exactly once. Returns `true` the
  /// first time (the caller owns firing `onExit`), `false` on every subsequent
  /// call so the natural-exit thread and a racing `stop()` can't double-delete
  /// the VM or fire `onExit` twice.
  @discardableResult
  private func teardown() -> Bool {
    lock.lock()
    if tornDown { lock.unlock(); return false }
    tornDown = true
    running = false
    let work = configWorkdir
    lock.unlock()
    // `start`/`stop` are non-blocking, so a `delete` fired right after `stop`
    // races a still-powering-off VM and refuses — leaking the throwaway disk.
    // Poll for a confirmed stop on a SHORT bounded budget (so the quit path
    // can't wedge), escalating to a force-kill, then delete with retries. Any
    // residual leak is reaped by `HostCleanup.purgeStrayWindowsClones`.
    _ = try? Shell.run(cli.executable, cli.stopArgs(clone: cloneName))
    let deadline = Date().addingTimeInterval(stopSettleTimeout)
    var stopped = false
    while Date() < deadline {
      if let r = try? Shell.run(cli.executable, cli.statusArgs(clone: cloneName)), r.ok,
        cli.parseIsStopped(from: r.stdout)
      {
        stopped = true
        break
      }
      _ = try? Shell.run(cli.executable, cli.forceStopArgs(clone: cloneName))
      Thread.sleep(forTimeInterval: stopPollInterval)
    }
    for _ in 0..<3 {
      if let r = try? Shell.run(cli.executable, cli.deleteArgs(clone: cloneName)), r.ok {
        break
      }
      if !stopped { _ = try? Shell.run(cli.executable, cli.forceStopArgs(clone: cloneName)) }
      Thread.sleep(forTimeInterval: stopPollInterval)
    }
    if let work { try? FileManager.default.removeItem(atPath: work) }
    return true  // possible leak; purgeStrayWindowsClones reaps it next go-online
  }
}

// MARK: - Factory

/// Builds `WindowsVMProvider`s for the orchestrator. Holds the per-fleet config
/// (base image + CLI backend) and stamps a provider per runner name.
public struct WindowsVMProviderFactory: RunnerProviderFactory {
  public var kind: String { "Windows VM — \(cli.displayName) (throwaway clone, destroyed each run)" }
  private let baseImage: String
  private let cli: WindowsVMCLI

  public init(baseImage: String, cli: WindowsVMCLI) {
    self.baseImage = baseImage
    self.cli = cli
  }

  public func makeProvider(name: String) -> RunnerProvider {
    WindowsVMProvider(id: name, baseImage: baseImage, cli: cli)
  }

  /// Resolve the `scripts/mactions-fusion-vm` lifecycle helper at module-load
  /// time: first next to the binary's working dir (dev builds run via
  /// `swift run` from the repo), then by walking up from the executable to a
  /// repo root (useful when the app is launched from a path that isn't the repo
  /// cwd). nil if the helper isn't shipped alongside the binary (Fusion is then
  /// not offered).
  public static let fusionHelperPath: String? = {
    let fm = FileManager.default
    let rel = "scripts/mactions-fusion-vm"
    // 1. ./scripts/<name> relative to the launch cwd (`swift run` from the repo).
    let cwd = fm.currentDirectoryPath + "/" + rel
    if fm.isExecutableFile(atPath: cwd) { return cwd }
    // 2. Walk up from the binary (.build/<…>/Mactions → repo root with scripts/).
    var dir = URL(fileURLWithPath: CommandLine.arguments.first ?? "/").deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = dir.appendingPathComponent(rel).path
      if fm.isExecutableFile(atPath: candidate) { return candidate }
      if dir.path == "/" { break }
      dir = dir.deletingLastPathComponent()
    }
    // 3. Walk up from THIS source file's compile-time location (Sources/
    //    MactionsCore/…) to the repo root — robust for dev runs from ANY cwd,
    //    where (1) and (2) can both miss. (A distributed .app would instead ship
    //    the scripts in its Resources; not built yet — see Roadmap.)
    var src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = src.appendingPathComponent(rel).path
      if fm.isExecutableFile(atPath: candidate) { return candidate }
      if src.path == "/" { break }
      src = src.deletingLastPathComponent()
    }
    return nil
  }()

  /// Absolute path to VMware Fusion's `vmrun`. Fusion is NOT brew-installable
  /// (Broadcom-portal download), so detection is presence-only — we never try to
  /// install it. Pairing the helper + this binary is the "Fusion available" gate.
  static let fusionVmrunPath = "/Applications/VMware Fusion.app/Contents/Library/vmrun"

  /// The Windows-VM backend, or `nil` if VMware Fusion isn't installed. Fusion is
  /// the sole backend (the PROVEN Win11-ARM path on Apple Silicon); its
  /// "installed" condition is BOTH the `mactions-fusion-vm` helper present
  /// alongside the binary AND `vmrun` on disk. If either half is missing, no
  /// Windows backend is offered.
  public static func detectInstalledCLI() -> WindowsVMCLI? {
    guard let fusion = fusionHelperPath,
      FileManager.default.isExecutableFile(atPath: fusionVmrunPath)
    else { return nil }
    return VMwareCLI(executable: fusion)
  }

  /// Alias retained for call sites that historically distinguished a "free-first"
  /// pick. With Fusion the sole backend, this is the same as `detectInstalledCLI`.
  public static func detectFreeFirstCLI() -> WindowsVMCLI? { detectInstalledCLI() }

  /// `true` iff the base image is built AND idle — the only state from which a
  /// per-job clone is reliable. For Fusion: the `mactions-fusion-vm base-status`
  /// verb confirms the base `.vmx` exists, carries the linked-clone snapshot, and
  /// isn't powered on (prints "stopped"). Used to gate `windowsImageReady` rather
  /// than trusting the prep script's exit code. A probe error returns `false`,
  /// never throws.
  public static func baseImagePoweredOff(name: String, cli: WindowsVMCLI) -> Bool {
    guard let r = try? Shell.run(cli.executable, cli.baseStatusArgs(base: name)), r.ok else {
      return false
    }
    return cli.parseIsStopped(from: r.stdout)
  }
}
