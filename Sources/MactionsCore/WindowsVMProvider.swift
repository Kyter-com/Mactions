import Foundation

// MARK: - Windows VM CLI abstraction

/// The clone/boot/status/stop/delete + per-clone-config-injection verbs a
/// Windows-VM provider drives, expressed as **pure command builders** so the
/// per-tool shapes are unit-testable without a live VM (mirrors the
/// `jitConfigRequest`-style split the rest of the core uses). A concrete tool
/// (`prlctl` for Parallels, `utmctl` for UTM) fills these in.
///
/// HEADLESS / OUTBOUND-REGISTRATION model (see AGENTS.md): there is no inbound
/// SSH and no guest-IP discovery. Per job we deliver a per-clone **config ISO**
/// carrying the JIT registration into the guest; the in-guest runtime reads it,
/// runs `run.cmd --jitconfig` (registering OUTBOUND to GitHub) for ONE job, then
/// powers the VM off. The host learns completion purely by polling VM **power
/// state**. The two backends differ only in how the config ISO is delivered:
/// Parallels has a real attach verb; UTM has none, so we overwrite a fixed
/// in-bundle disk image in the clone bundle while it's powered off.
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
  /// Discover the guest's IP. UNUSED on the outbound-registration flow; kept for
  /// the Parallels diagnostics / any future direct-connect path.
  func ipArgs(clone: String) -> [String]
  /// Pull a single IPv4 address out of the `ip` command's stdout.
  func parseIP(from output: String) -> String?
  /// Query the clone's power state. The provider parses it via `parseIsStopped`.
  func statusArgs(clone: String) -> [String]
  /// Query the BASE image's readiness. For VM-named backends (UTM, Parallels)
  /// this matches `statusArgs` — the base is a named VM that's powered off.
  /// QEMU overrides it because the base is a set of files on disk, not a VM.
  func baseStatusArgs(base: String) -> [String]
  /// `true` when the status/list output shows the VM powered-off/stopped.
  func parseIsStopped(from output: String) -> Bool
  /// Force/kill power-off — escalation when a graceful `stop` doesn't settle.
  func forceStopArgs(clone: String) -> [String]
  /// How this backend delivers the per-clone config ISO into the guest.
  func injectionPlan(clone: String, clonePath: String?, configISO: String) -> WindowsInjectionPlan
  /// Absolute path to the clone's on-disk bundle, for backends that inject by
  /// overwriting an in-bundle file (UTM). `nil` when injection is via the CLI
  /// (Parallels), so the provider skips path resolution.
  func cloneBundlePath(clone: String) -> String?
}

/// How a backend delivers the per-clone config ISO into a powered-off clone.
public enum WindowsInjectionPlan: Equatable, Sendable {
  /// Overwrite a fixed in-bundle disk image (absolute `target`) with the config
  /// ISO while the clone is powered off — UTM has no CLI attach verb, but a
  /// fixed in-bundle drive travels byte-for-byte through `utmctl clone`, so
  /// replacing that one file delivers the payload. (UNVERIFIED: hinges on UTM
  /// re-reading the replaced image on start rather than a cached fd — see the
  /// live-verification checklist in AGENTS.md / issue tracker.)
  case overwriteInBundleDrive(target: String)
  /// Copy the config ISO to a per-clone path that the backend's `start` step
  /// picks up as a real `-cdrom` attachment (QEMU). No pre-existing target file
  /// is required (vs. `overwriteInBundleDrive`, which guards on it as a UTM
  /// build-step assertion).
  case copyConfigFile(target: String)
  /// Attach the config ISO as a CD via the CLI (Parallels' real attach verb).
  case attachCommands([[String]])
}

/// Coarse VM power phase, used to gate completion detection. We must observe
/// `.running` once before treating `.stopped` as "the job finished and the guest
/// powered itself off" — a freshly cloned (not-yet-started) VM also reads stopped.
public enum VMPhase: Equatable, Sendable { case starting, running, stopped }

/// True for a real, usable guest IPv4: four in-range octets, not 0.0.0.0, not
/// APIPA (169.254/16), and not a netmask/broadcast-looking 255.x value.
func isUsableIPv4(_ s: String) -> Bool {
  let octs = s.split(separator: ".").compactMap { Int($0) }
  guard octs.count == 4, octs.allSatisfy({ (0...255).contains($0) }) else { return false }
  if octs.allSatisfy({ $0 == 0 }) { return false }      // 0.0.0.0 placeholder
  if octs[0] == 169 && octs[1] == 254 { return false }  // APIPA link-local
  if octs[0] == 255 { return false }                    // mask/broadcast
  return true
}

extension WindowsVMCLI {
  /// First usable-IPv4 token in the output (`utmctl ip-address` prints a bare
  /// address per line). Parallels overrides this with a JSON parse.
  public func parseIP(from output: String) -> String? {
    output
      .components(separatedBy: CharacterSet(charactersIn: " \t\n\r,/"))
      .first(where: isUsableIPv4)
  }

  /// Default power-state read: mentions "stopped" and isn't mid-transition.
  public func parseIsStopped(from output: String) -> Bool {
    let o = output.lowercased()
    return o.contains("stopped") && !o.contains("stopping")
  }

  /// Default force-stop == the normal stop (override where a kill flag exists).
  public func forceStopArgs(clone: String) -> [String] { stopArgs(clone: clone) }

  /// Backends that attach via the CLI don't need a bundle path.
  public func cloneBundlePath(clone: String) -> String? { nil }

  /// Default base-readiness check is the same as a clone status check — the
  /// base is a VM with the same name. QEMU overrides this because the base is
  /// a set of files on disk, not a VM that can be in "running" / "stopped".
  public func baseStatusArgs(base: String) -> [String] { statusArgs(clone: base) }
}

/// Parallels Desktop Pro/Business via `prlctl` — the **proven** backend.
///
/// The only Microsoft-authorized hypervisor for Windows 11 ARM on Apple Silicon
/// with full hardware acceleration, a true background-service headless mode (no
/// GUI-login dependency), CoW linked clones, and a complete CLI lifecycle
/// including a **real attach verb** — so the per-clone config ISO is attached
/// directly, with no in-bundle-overwrite dance.
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
  public func forceStopArgs(clone: String) -> [String] { ["stop", clone, "--kill"] }
  public func deleteArgs(clone: String) -> [String] { ["delete", clone] }
  public func statusArgs(clone: String) -> [String] { ["status", clone] }
  // Query structured JSON and read the labeled lease field — scraping `-f --info`
  // text yields a netmask/gateway as the "first IPv4 token".
  public func ipArgs(clone: String) -> [String] { ["list", clone, "--full", "--json"] }
  public func parseIP(from output: String) -> String? {
    guard let data = output.data(using: .utf8),
      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
      let ip = arr.first?["ip_configured"] as? String,
      ip != "-", !ip.isEmpty, isUsableIPv4(ip)
    else { return nil }
    return ip  // ip_configured is a bare address, no /mask
  }
  // Real attach verb: connect the per-clone config ISO to the base's empty
  // cdrom0 slot while the clone is stopped, then boot.
  public func injectionPlan(clone: String, clonePath: String?, configISO: String) -> WindowsInjectionPlan {
    .attachCommands([["set", clone, "--device-set", "cdrom0", "--image", configISO, "--connect"]])
  }
}

/// UTM via `utmctl` — the free/open-source default (QEMU backend).
///
/// CAVEAT (see AGENTS.md): `utmctl` uses Apple's ScriptingBridge, which needs an
/// active GUI (Aqua) login session and does NOT work over SSH or from a pure
/// launchd/headless context. Its verb set is clone/start/stop/delete/status/
/// ip-address — there is **no attach-drive verb**, and `file`/`exec` need the
/// QEMU guest agent (no first-class arm64-Windows build, UTM #5134). So the
/// per-clone config ISO is delivered by OVERWRITING a fixed in-bundle disk image
/// in the clone bundle while powered off (`injectionPlan`). UNVERIFIED end to end
/// — see the live-verification checklist before trusting this backend.
public struct UTMCLI: WindowsVMCLI {
  public let executable: String
  /// Directory UTM stores VM bundles in. The clone bundle is `<dir>/<clone>.utm`.
  public let documentsDir: String
  /// Filename of the fixed in-bundle data disk we overwrite per clone (the
  /// `<UUID>` recorded for the second drive added during base-image prep). The
  /// guest reads the config off this disk by volume label.
  public let inBundleImageName: String
  public init(
    executable: String = "/Applications/UTM.app/Contents/MacOS/utmctl",
    documentsDir: String = NSString(
      string: "~/Library/Containers/com.utmapp.UTM/Data/Documents").expandingTildeInPath,
    inBundleImageName: String = "mactions-config.img"
  ) {
    self.executable = executable
    self.documentsDir = documentsDir
    self.inBundleImageName = inBundleImageName
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
  public func statusArgs(clone: String) -> [String] { ["status", clone] }
  public func ipArgs(clone: String) -> [String] { ["ip-address", clone] }
  // Deterministic bundle path: UTM names bundles by VM name under documentsDir.
  // (Verify against a real `utmctl clone` — see AGENTS.md live checklist.)
  public func cloneBundlePath(clone: String) -> String? {
    documentsDir + "/" + clone + ".utm"
  }
  // No attach verb: overwrite the fixed in-bundle drive at <bundle>/Data/<name>.
  public func injectionPlan(clone: String, clonePath: String?, configISO: String) -> WindowsInjectionPlan {
    let bundle = clonePath ?? cloneBundlePath(clone: clone) ?? ""
    return .overwriteInBundleDrive(target: bundle + "/Data/" + inBundleImageName)
  }
}

/// QEMU + swtpm + edk2 — the FULLY-HEADLESS, GUI-LESS, FREE/OSS backend (no
/// Aqua login session required, vs. UTM/Parallels). The actual multi-process
/// QEMU + swtpm lifecycle is wrapped in `scripts/mactions-qemu-vm` so the Swift
/// side stays "one CLI + verb args" like prlctl/utmctl — every method here is
/// pure command-shape, unit-testable without launching anything.
///
/// State layout (the helper owns these paths):
///   ~/.mactions/windows-base/        — the pristine base (built once, atomic)
///   ~/.mactions/windows-clones/<id>/ — per-clone state (qcow2 overlay, EFI
///                                      vars copy, TPM state copy, sockets,
///                                      pidfiles, optional config.iso)
///
/// Injection model: provider `inject()` copies the per-job config ISO into
/// `<clone-dir>/config.iso`; the helper's `start` step attaches it as a real
/// `-cdrom` (no in-bundle-overwrite hack, no separate attach command).
public struct QEMUCLI: WindowsVMCLI {
  public let executable: String
  /// Where per-clone state lives. The helper builds `<dir>/<clone-name>/`.
  public let clonesDir: String
  public init(
    executable: String,
    clonesDir: String = NSString(string: "~/.mactions/windows-clones").expandingTildeInPath
  ) {
    self.executable = executable
    self.clonesDir = clonesDir
  }
  public var displayName: String { "QEMU (headless)" }
  public func cloneArgs(base: String, clone: String) -> [String] {
    ["clone", base, clone]
  }
  public func startArgs(clone: String) -> [String] { ["start", clone] }
  public func stopArgs(clone: String) -> [String] { ["stop", clone] }
  /// Helper `stop` already escalates SIGTERM → SIGKILL, so a separate force
  /// path adds nothing — but we still expose it to satisfy the protocol.
  public func forceStopArgs(clone: String) -> [String] { ["stop", clone] }
  public func deleteArgs(clone: String) -> [String] { ["delete", clone] }
  public func statusArgs(clone: String) -> [String] { ["status", clone] }
  /// The QEMU helper has a dedicated `base-status` verb that checks the BASE
  /// directory (qcow2 + EFI vars + tpm-state all present, no live qemu against
  /// the base) and prints "stopped" / "in-use" / "missing". We map it to the
  /// same parseIsStopped path so "stopped" → ready to clone from.
  public func baseStatusArgs(base: String) -> [String] { ["base-status", base] }
  /// QMP doesn't expose a guest IPv4 (no guest agent), and the outbound model
  /// doesn't need one. Return a benign no-op to keep the protocol total — the
  /// provider never asks for the IP on the outbound flow.
  public func ipArgs(clone: String) -> [String] { ["status", clone] }
  public func parseIP(from output: String) -> String? { nil }
  /// Helper prints exactly "running" or "stopped" so the default substring match
  /// is correct; explicit override here as documentation.
  public func parseIsStopped(from output: String) -> Bool {
    output.lowercased().contains("stopped")
  }
  /// Clone state dir, where the helper drops the per-clone files. The provider's
  /// inject step uses this to compute the config ISO target path.
  public func cloneBundlePath(clone: String) -> String? {
    clonesDir + "/" + clone
  }
  /// Drop the JIT config ISO at <clone-dir>/config.iso; the helper's `start`
  /// step picks it up and attaches it as a usb-storage CD-ROM to the guest.
  public func injectionPlan(clone: String, clonePath: String?, configISO: String) -> WindowsInjectionPlan {
    let dir = clonePath ?? cloneBundlePath(clone: clone) ?? ""
    return .copyConfigFile(target: dir + "/config.iso")
  }
}

/// VMware Fusion (free) via `vmrun` — the **PROVEN** backend for Win11-ARM on
/// Apple Silicon (see AGENTS.md → Windows support). Fusion's EFI boots Win11-ARM
/// cleanly where stock QEMU's firmware hangs, and `vmrun` gives a true headless
/// CLI (clone/start/stop/deleteVM + snapshots). As with `QEMUCLI`, the lifecycle
/// is wrapped in `scripts/mactions-fusion-vm` so the Swift side stays "one CLI +
/// verb args" — every method here is pure command-shape, unit-testable without
/// launching anything.
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
  /// `vmrun` exposes no guest IPv4 (no guest agent needed on the outbound model).
  /// Return a benign no-op to keep the protocol total — the provider never asks
  /// for the IP on the outbound flow.
  public func ipArgs(clone: String) -> [String] { ["status", clone] }
  public func parseIP(from output: String) -> String? { nil }
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
///   1. **Clone** the pristine base to a throwaway `mactions-<id>` clone.
///   2. **Build** a tiny per-clone **config ISO** carrying the JIT config.
///   3. **Inject** it into the (powered-off) clone: Parallels attaches it as a
///      CD; UTM overwrites a fixed in-bundle disk image in the clone bundle.
///   4. **Start** headless. The base image's in-guest runtime (a logon Scheduled
///      Task from `bootstrap.ps1`) reads the JIT off the disc, runs
///      `run.cmd --jitconfig` for ONE job (registering OUTBOUND to GitHub), then
///      `shutdown /s`.
///   5. **Detect completion by power state**: poll `status` until the guest has
///      powered itself off (after first confirming it reached `.running`).
///   6. **Destroy** the clone on every path, then fire `onExit`.
///
/// EXPERIMENTAL, not live-verified end to end. The UTM in-bundle injection hinges
/// on an assumption that needs a live test (see AGENTS.md); Parallels is the
/// proven backend.
public final class WindowsVMProvider: RunnerProvider {
  public let id: String
  private let baseImage: String
  private let cli: WindowsVMCLI
  /// Volume label the in-guest runtime locates the config disc by.
  private let configVolumeName: String
  /// How long to wait for the clone to reach `.running` before giving up, and
  /// how long to then wait for it to power itself off (job done). The JIT token
  /// expires ~60 min from mint, so jobTimeout stays under that budget.
  private let bootTimeout: TimeInterval
  private let jobTimeout: TimeInterval
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
  /// Per-clone scratch dir (config ISO + staging); removed on teardown. For
  /// Parallels the attached CD references the ISO until the VM is gone, so we
  /// can't delete it earlier.
  private var configWorkdir: String?
  private let lock = NSLock()

  public init(
    id: String,
    baseImage: String,
    cli: WindowsVMCLI = ParallelsCLI(),
    configVolumeName: String = "MACTIONS",
    bootTimeout: TimeInterval = 300,
    jobTimeout: TimeInterval = 3000,
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

  public func start(jitConfig: String, onExit: @escaping (Int32) -> Void) throws {
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
      // Clone exists but couldn't be prepared/started — reclaim it and report.
      if teardown() { onExit(1) }
      throw error
    }

    Thread.detachNewThread { [self] in
      var status: Int32 = 0
      // PHASE 1 — confirm the clone actually reached `.running` (defeats the
      // just-cloned 'stopped' false positive) within bootTimeout.
      let bootDeadline = Date().addingTimeInterval(bootTimeout)
      var sawRunning = false
      while Date() < bootDeadline {
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

  /// Deliver the config ISO into the powered-off clone per the backend's plan.
  private func inject(configISO: String) throws {
    let clonePath = cli.cloneBundlePath(clone: cloneName)
    switch cli.injectionPlan(clone: cloneName, clonePath: clonePath, configISO: configISO) {
    case let .overwriteInBundleDrive(target):
      // Overwrite the fixed in-bundle drive in the (powered-off) clone bundle.
      let fm = FileManager.default
      guard fm.fileExists(atPath: target) else {
        throw Shell.ShellError.nonZeroExit(
          command: "cp \(configISO) \(target)", status: -1,
          stderr:
            "config-drive target not found in the clone bundle: \(target). The base image needs a fixed "
            + "in-bundle data disk at that path (added once during image prep). See the UTM "
            + "live-verification steps in AGENTS.md.")
      }
      try? fm.removeItem(atPath: target)
      try fm.copyItem(atPath: configISO, toPath: target)
    case let .copyConfigFile(target):
      // Copy the config ISO to the per-clone path. Unlike .overwriteInBundleDrive,
      // we don't require the target to pre-exist — for QEMU, start-time reads
      // <clone-dir>/config.iso if present and attaches it as a real -cdrom.
      let fm = FileManager.default
      let parent = (target as NSString).deletingLastPathComponent
      if !parent.isEmpty {
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
      }
      if fm.fileExists(atPath: target) { try? fm.removeItem(atPath: target) }
      try fm.copyItem(atPath: configISO, toPath: target)
    case let .attachCommands(commands):
      for cmd in commands { try Shell.runChecked(cli.executable, cmd) }
    }
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

  public init(baseImage: String, cli: WindowsVMCLI = ParallelsCLI()) {
    self.baseImage = baseImage
    self.cli = cli
  }

  public func makeProvider(name: String) -> RunnerProvider {
    WindowsVMProvider(id: name, baseImage: baseImage, cli: cli)
  }

  /// Resolve a `scripts/<name>` lifecycle helper at module-load time: first next
  /// to the binary's working dir (dev builds run via `swift run` from the repo),
  /// then by walking up from the executable to a repo root (useful when the app
  /// is launched from a path that isn't the repo cwd). nil if the helper isn't
  /// shipped alongside the binary (that backend is then not offered).
  static func resolveHelper(named name: String) -> String? {
    let fm = FileManager.default
    let rel = "scripts/" + name
    // 1. ./scripts/<name> relative to the binary's working dir.
    let cwd = fm.currentDirectoryPath + "/" + rel
    if fm.isExecutableFile(atPath: cwd) { return cwd }
    // 2. Walk up from the binary (.build/<…>/Mactions → repo root with scripts/).
    var dir = URL(fileURLWithPath: CommandLine.arguments.first ?? "/").deletingLastPathComponent()
    for _ in 0..<6 {
      let candidate = dir.appendingPathComponent(rel).path
      if fm.isExecutableFile(atPath: candidate) { return candidate }
      if dir.path == "/" { break }
      dir = dir.deletingLastPathComponent()
    }
    return nil
  }

  /// Path to the `mactions-qemu-vm` helper that owns QEMU+swtpm lifecycle.
  public static var qemuHelperPath: String? = resolveHelper(named: "mactions-qemu-vm")

  /// Path to the `mactions-fusion-vm` helper that owns the VMware Fusion `vmrun`
  /// lifecycle (the proven backend).
  public static var fusionHelperPath: String? = resolveHelper(named: "mactions-fusion-vm")

  /// Absolute path to VMware Fusion's `vmrun`. Fusion is NOT brew-installable
  /// (Broadcom-portal download), so detection is presence-only — we never try to
  /// install it. Pairing the helper + this binary is the "Fusion available" gate.
  static let fusionVmrunPath = "/Applications/VMware Fusion.app/Contents/Library/vmrun"

  /// Pick the best installed Windows-VM backend, or `nil` if none is present.
  /// Prefers VMware Fusion (the PROVEN Win11-ARM backend), then QEMU (headless
  /// but does NOT boot Win11-ARM on this stack — kept for parity), then Parallels
  /// (`prlctl`), then UTM (`utmctl`, needs a GUI session).
  public static func detectInstalledCLI() -> WindowsVMCLI? {
    if let fusion = fusionHelperPath,
      FileManager.default.isExecutableFile(atPath: fusionVmrunPath)
    {
      return VMwareCLI(executable: fusion)
    }
    if let qemu = qemuHelperPath,
      FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/qemu-system-aarch64")
    {
      return QEMUCLI(executable: qemu)
    }
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

  /// Pick the installed backend FREE-FIRST: VMware Fusion (free since Nov 2024
  /// AND the proven Win11-ARM backend — preferred), else QEMU (free + headless
  /// but does NOT boot Win11-ARM here), else UTM (free but needs a GUI session),
  /// else Parallels (paid — only if already installed), else `nil`. Fusion's
  /// "installed" condition is BOTH the `mactions-fusion-vm` helper present
  /// alongside the binary AND `vmrun` on disk; QEMU's is the helper AND
  /// `qemu-system-aarch64`. If either half is missing that backend isn't offered.
  public static func detectFreeFirstCLI() -> WindowsVMCLI? {
    if let fusion = fusionHelperPath,
      FileManager.default.isExecutableFile(atPath: fusionVmrunPath)
    {
      return VMwareCLI(executable: fusion)
    }
    if let qemu = qemuHelperPath,
      FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/qemu-system-aarch64")
    {
      return QEMUCLI(executable: qemu)
    }
    let utmctl = "/Applications/UTM.app/Contents/MacOS/utmctl"
    if FileManager.default.isExecutableFile(atPath: utmctl) {
      return UTMCLI(executable: utmctl)
    }
    let prlctlCandidates = ["/usr/local/bin/prlctl", "/opt/homebrew/bin/prlctl"]
    if let path = prlctlCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
      return ParallelsCLI(executable: path)
    }
    return nil
  }

  /// `true` iff the base image is built AND idle — the only state from which a
  /// per-job clone is reliable. UTM/Parallels: VM named `name` exists + powered
  /// off. QEMU: the base files (qcow2 + EFI vars + tpm-state) exist + no live
  /// qemu against them. Used to gate `windowsImageReady` rather than trusting
  /// the prep script's exit code. A probe error (e.g. utmctl outside an Aqua
  /// session, or the helper failing) returns `false`, never throws.
  public static func baseImagePoweredOff(name: String, cli: WindowsVMCLI) -> Bool {
    guard let r = try? Shell.run(cli.executable, cli.baseStatusArgs(base: name)), r.ok else {
      return false
    }
    return cli.parseIsStopped(from: r.stdout)
  }
}
