import Foundation

// MARK: - Windows VM CLI abstraction

/// The clone/boot/ip/stop/delete verbs a Windows-VM provider drives, expressed
/// as **pure command builders** so the per-tool argument shapes are unit-testable
/// without a live VM (mirrors the `jitConfigRequest`-style split the rest of the
/// core uses). A concrete tool (`prlctl` for Parallels, `utmctl` for UTM) is just
/// a struct that fills these in.
///
/// Why an abstraction instead of hard-coding `tart`-style calls like
/// `TartProvider` does: Tart cannot boot Windows guests at all (no Secure
/// Boot/TPM via Virtualization.framework), so a Windows runner needs a different
/// hypervisor CLI. The two viable Apple-Silicon options have *different* verbs
/// (`prlctl clone --linked` vs `utmctl clone`), and the research recommends
/// Parallels for robustness but keeps UTM as a free fallback — so we keep the
/// provider tool-agnostic and pick the backend at construction time.
public protocol WindowsVMCLI: Sendable {
  /// Absolute path to the CLI binary (e.g. `/usr/local/bin/prlctl`).
  var executable: String { get }
  /// Human label for the substrate (shown in the UI / logs).
  var displayName: String { get }
  /// Make a cheap throwaway clone of `base` named `clone` (CoW / linked clone).
  func cloneArgs(base: String, clone: String) -> [String]
  /// Boot the clone headless (no GUI window). Returns immediately — unlike
  /// `tart run`, these CLIs do NOT block until the VM powers off.
  func startArgs(clone: String) -> [String]
  /// Force power-off (used on teardown / stop()).
  func stopArgs(clone: String) -> [String]
  /// Permanently delete the clone and all its files (the ephemerality bar).
  func deleteArgs(clone: String) -> [String]
  /// Discover the guest's IP. The provider parses stdout via `parseIP`.
  func ipArgs(clone: String) -> [String]
  /// Pull a single IPv4 address out of the `ip` command's stdout.
  func parseIP(from output: String) -> String?
}

extension WindowsVMCLI {
  /// First IPv4-looking token in the output. `prlctl`/`utmctl` print the address
  /// on its own (utmctl) or embedded in a list line (prlctl `-f`), so we scan.
  public func parseIP(from output: String) -> String? {
    let tokens = output.components(separatedBy: CharacterSet(charactersIn: " \t\n\r,/"))
    return tokens.first { token in
      let parts = token.split(separator: ".")
      guard parts.count == 4 else { return false }
      // Skip the all-zero placeholder Parallels prints before DHCP completes.
      if token == "0.0.0.0" { return false }
      return parts.allSatisfy { part in
        guard let n = Int(part), (0...255).contains(n) else { return false }
        return true
      }
    }
  }
}

/// Parallels Desktop Pro/Business via `prlctl` — the recommended backend.
///
/// The only Microsoft-authorized hypervisor for Windows 11 ARM on Apple Silicon
/// with full hardware acceleration, a true background-service headless mode, and
/// a complete CLI lifecycle. `clone --linked` is the cheap copy-on-write analog
/// to Tart's clone + the local provider's APFS clone; `delete` removes the clone
/// and every file it owns.
public struct ParallelsCLI: WindowsVMCLI {
  public let executable: String
  public init(executable: String = "/usr/local/bin/prlctl") {
    self.executable = executable
  }
  public var displayName: String { "Parallels (prlctl)" }
  public func cloneArgs(base: String, clone: String) -> [String] {
    ["clone", base, "--linked", "--name", clone]
  }
  public func startArgs(clone: String) -> [String] { ["start", clone] }
  // `--kill` forces an immediate power-off rather than a graceful ACPI shutdown,
  // matching the throwaway-PC model (we're about to delete the clone anyway).
  public func stopArgs(clone: String) -> [String] { ["stop", clone, "--kill"] }
  public func deleteArgs(clone: String) -> [String] { ["delete", clone] }
  public func ipArgs(clone: String) -> [String] { ["list", "-f", "--info", clone] }
}

/// UTM via `utmctl` — the free/open-source fallback (QEMU backend).
///
/// CAVEAT (see AGENTS.md): `utmctl` uses Apple's ScriptingBridge, which needs an
/// active GUI (Aqua) login session and does NOT work over SSH or from a pure
/// launchd/headless context. Fine when Mactions runs in the foreground; fragile
/// for an unattended host. Prefer `ParallelsCLI` unless the license cost is a
/// non-starter.
public struct UTMCLI: WindowsVMCLI {
  public let executable: String
  public init(executable: String = "/Applications/UTM.app/Contents/MacOS/utmctl") {
    self.executable = executable
  }
  public var displayName: String { "UTM (utmctl)" }
  public func cloneArgs(base: String, clone: String) -> [String] {
    ["clone", base, "--name", clone]
  }
  // `--hide` boots without surfacing a window; the VM itself must also have its
  // display device removed for a truly headless run (done in image prep).
  public func startArgs(clone: String) -> [String] { ["start", clone, "--hide"] }
  public func stopArgs(clone: String) -> [String] { ["stop", clone] }
  public func deleteArgs(clone: String) -> [String] { ["delete", clone] }
  public func ipArgs(clone: String) -> [String] { ["ip-address", clone] }
}

// MARK: - Windows VM provider

/// Runs each ephemeral runner inside a **throwaway Windows 11 ARM VM** cloned
/// from a prepared base image, then destroys the clone — the only way to hit the
/// ephemerality bar on Windows (there is no APFS-clone HOME-redirect trick like
/// the local provider uses; the entire guest disk is discarded per job).
///
/// Control flow mirrors `TartProvider` (clone → boot → SSH in → launch agent →
/// destroy on exit) with one behavioral divergence baked in: the VM CLIs'
/// `start` returns immediately (it does NOT block until the VM powers off, the
/// way `tart run` does), so we cannot key `onExit` off a long-lived run process.
/// Instead the **SSH command blocks** while the in-guest `run.cmd --jitconfig`
/// runs its single job; when SSH returns (agent exited), we force-stop and delete
/// the clone, then fire `onExit`.
///
/// Base image requirements (built once by `scripts/prepare-windows-image`):
///   - Windows 11 ARM64 with the `actions-runner-win-arm64` agent at
///     `C:\actions-runner`.
///   - OpenSSH Server enabled, with a `runner` login and **cmd.exe** as the
///     default shell, reachable on the VM's IP. (cmd.exe is required: the
///     launch command `remoteCommand` builds is CMD syntax — `&&` and `cd /d`
///     are PowerShell 5.1 parse errors. `bootstrap.ps1` sets this.)
///   - (Parallels only, if you use `prlctl exec` instead of SSH) Parallels Tools.
///
/// EXPERIMENTAL: depends on a hand-prepared base image + a Windows-capable
/// hypervisor CLI (`prlctl`/`utmctl`) that is NOT bundled. Not live-verified.
public final class WindowsVMProvider: RunnerProvider {
  public let id: String
  private let baseImage: String
  private let cli: WindowsVMCLI
  private let sshUser: String
  private let sshPassword: String?
  /// Absolute path to the runner agent inside the guest. Short root path on
  /// purpose: Windows MAX_PATH (260 chars) bites deep `node_modules` trees.
  private let runnerPath: String
  private let ipTimeout: TimeInterval
  private let sshpassPath: String?

  /// Clone name carries the same `mactions-` prefix `HostCleanup` and the
  /// orchestrator use to identify (and reap) our own VMs.
  var cloneName: String { "mactions-\(id)" }

  private var running = false
  /// Set the first (and only) time the clone is torn down. Mirrors
  /// `LocalProcessProvider.cleaned`: guards against the background thread and
  /// `stop()` both racing to stop+delete the VM and fire `onExit` twice (the
  /// orchestrator treats a second `onExit` as a real second exit and would
  /// re-provision against a fleet the user already took offline).
  private var tornDown = false
  private let lock = NSLock()

  /// - Parameters:
  ///   - baseImage: name of the pristine Win11-ARM base VM to clone per job.
  ///   - cli: the hypervisor backend (`ParallelsCLI` recommended; `UTMCLI` free
  ///     fallback). Defaults to Parallels.
  ///   - sshUser/sshPassword: the in-guest login the base image was prepared
  ///     with. A password is used for the throwaway VM (key injection per clone
  ///     is more plumbing); pass `nil` to rely on an SSH key/agent instead.
  ///   - sshpassPath: path to `sshpass` for non-interactive password auth; if
  ///     `nil`, password auth is skipped (SSH will use keys).
  public init(
    id: String,
    baseImage: String,
    cli: WindowsVMCLI = ParallelsCLI(),
    sshUser: String = "runner",
    sshPassword: String? = "P@ssw0rd-throwaway",
    runnerPath: String = "C:\\actions-runner",
    ipTimeout: TimeInterval = 240,
    sshpassPath: String? = Shell.which("sshpass")
  ) {
    self.id = id
    self.baseImage = baseImage
    self.cli = cli
    self.sshUser = sshUser
    self.sshPassword = sshPassword
    self.runnerPath = runnerPath
    self.ipTimeout = ipTimeout
    self.sshpassPath = sshpassPath
  }

  public var isRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return running
  }

  public func start(jitConfig: String, onExit: @escaping (Int32) -> Void) throws {
    try Shell.runChecked(cli.executable, cli.cloneArgs(base: baseImage, clone: cloneName))
    lock.lock(); running = true; lock.unlock()

    // Boot + SSH-launch-agent + teardown run on a background thread so `start`
    // returns promptly; `onExit` fires when the single job (and the VM) is done.
    Thread.detachNewThread { [self] in
      var status: Int32 = 0
      do {
        try Shell.runChecked(cli.executable, cli.startArgs(clone: cloneName))
        let ip = try waitForIP()
        // SSH BLOCKS until run.cmd's single job finishes (then run.cmd exits).
        // This is how we observe job completion, since `start` did not block.
        let ssh = sshInvocation(ip: ip, jitConfig: jitConfig)
        let result = try Shell.run(ssh.executable, ssh.arguments)
        status = result.status
      } catch {
        status = 1
      }
      // Teardown — MUST run on every path (success, SSH failure, boot failure)
      // so no clone, snapshot, or _work checkout survives. `teardown` is
      // idempotent: if `stop()` already raced in and tore the clone down (user
      // went offline mid-job), this is a no-op and `onExit` does NOT fire a
      // second time.
      if teardown() { onExit(status) }
    }
  }

  public func stop() {
    // User went offline / quit: tear the clone down now. We deliberately do NOT
    // call `onExit` here — `stop()` is the orchestrator's own teardown path, and
    // a second `onExit` would look like a real exit to re-provision against.
    _ = teardown()
  }

  /// Force-stop + permanently delete the clone, exactly once. Returns `true` the
  /// first time (the caller owns firing `onExit`), `false` on every subsequent
  /// call so the natural-exit thread and a racing `stop()` can't double-delete
  /// the VM or fire `onExit` twice. Mirrors `LocalProcessProvider.cleanup()`'s
  /// `cleaned` guard.
  @discardableResult
  private func teardown() -> Bool {
    lock.lock()
    if tornDown { lock.unlock(); return false }
    tornDown = true
    running = false
    lock.unlock()
    _ = try? Shell.run(cli.executable, cli.stopArgs(clone: cloneName))
    _ = try? Shell.run(cli.executable, cli.deleteArgs(clone: cloneName))
    return true
  }

  // MARK: Pure builders (unit-testable without a VM)

  /// The remote command run inside the guest: launch the win-arm64 agent with
  /// the single-use JIT config. With `--jitconfig`, `run.cmd` takes exactly one
  /// job then EXITS (and the JIT registration auto-deregisters). The base image
  /// is additionally wired to power the VM off after the agent exits, but we
  /// don't rely on that for `onExit` — the blocking SSH command is our signal.
  func remoteCommand(jitConfig: String) -> String {
    "cd /d \(runnerPath) && run.cmd --jitconfig \(jitConfig)"
  }

  /// Full SSH invocation (executable + args), routed through `sshpass` when a
  /// password is configured so the agent can authenticate non-interactively.
  /// `StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null` because the
  /// throwaway clone's host key changes every run — matches `TartProvider`.
  func sshInvocation(ip: String, jitConfig: String) -> (executable: String, arguments: [String]) {
    let sshArgs = [
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "-o", "ConnectTimeout=15",
      "\(sshUser)@\(ip)",
      remoteCommand(jitConfig: jitConfig),
    ]
    if let sshPassword, let sshpassPath {
      return (sshpassPath, ["-p", sshPassword, "/usr/bin/ssh"] + sshArgs)
    }
    return ("/usr/bin/ssh", sshArgs)
  }

  // MARK: IP polling

  /// Poll the VM CLI until the guest reports a usable IP, or time out. A fresh
  /// Win11 clone takes appreciably longer to get an address than a Tart Linux/
  /// macOS guest, hence the longer default timeout.
  private func waitForIP() throws -> String {
    let deadline = Date().addingTimeInterval(ipTimeout)
    while Date() < deadline {
      if let r = try? Shell.run(cli.executable, cli.ipArgs(clone: cloneName)), r.ok,
        let ip = cli.parseIP(from: r.stdout) {
        return ip
      }
      Thread.sleep(forTimeInterval: 3)
    }
    throw Shell.ShellError.nonZeroExit(
      command: "\(cli.executable) ip \(cloneName)",
      status: -1,
      stderr: "timed out waiting for Windows VM IP after \(Int(ipTimeout))s")
  }
}

// MARK: - Factory

/// Builds `WindowsVMProvider`s for the orchestrator. Mirrors
/// `LocalProcessProviderFactory`: holds the per-fleet config (base image, CLI
/// backend, SSH login) and stamps a provider per runner name.
public struct WindowsVMProviderFactory: RunnerProviderFactory {
  public var kind: String { "Windows VM — \(cli.displayName) (throwaway clone, destroyed each run)" }
  private let baseImage: String
  private let cli: WindowsVMCLI
  private let sshUser: String
  private let sshPassword: String?

  public init(
    baseImage: String,
    cli: WindowsVMCLI = ParallelsCLI(),
    sshUser: String = "runner",
    sshPassword: String? = "P@ssw0rd-throwaway"
  ) {
    self.baseImage = baseImage
    self.cli = cli
    self.sshUser = sshUser
    self.sshPassword = sshPassword
  }

  public func makeProvider(name: String) -> RunnerProvider {
    WindowsVMProvider(
      id: name, baseImage: baseImage, cli: cli, sshUser: sshUser, sshPassword: sshPassword)
  }

  /// Pick the best installed Windows-VM backend, or `nil` if none is present.
  /// Parallels (`prlctl`) is preferred for an unattended host (UTM's `utmctl`
  /// needs a GUI login session). The app can call this to decide whether the
  /// Windows provider is even offerable before building a factory.
  ///
  /// Mirrors `Shell.which`-style detection used elsewhere in the core; checks
  /// the Homebrew/SDK install locations a Finder-launched GUI app won't have on
  /// its inherited PATH.
  public static func detectInstalledCLI() -> WindowsVMCLI? {
    let prlctlCandidates = ["/usr/local/bin/prlctl", "/opt/homebrew/bin/prlctl"]
    if let path = prlctlCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
      return ParallelsCLI(executable: path)
    }
    let utmctl = "/Applications/UTM.app/Contents/MacOS/utmctl"
    if FileManager.default.isExecutableFile(atPath: utmctl) {
      return UTMCLI(executable: utmctl)
    }
    return nil
  }
}
