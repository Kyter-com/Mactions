import Foundation

// MARK: - Linux container CLI abstraction

/// The pull/run/stop/rm/inspect verbs a container-per-job provider drives,
/// expressed as **pure command builders** so the Apple `container` command
/// shape is unit-testable without a live daemon (mirrors `WindowsVMCLI`).
///
/// CONTAINER-PER-JOB / FOREGROUND model (see AGENTS.md → Linux support): per job
/// we run ONE ephemeral container whose command is the agent's `run.sh`,
/// self-configured from the JIT blob delivered via the env var
/// `ACTIONS_RUNNER_INPUT_JITCONFIG` (the runner's `CommandSettings` strips the
/// `ACTIONS_RUNNER_INPUT_` prefix and treats it as `--jitconfig`) so the secret
/// never lands in the host process arg list / `ps`. `--rm` destroys the
/// throwaway writable layer the instant `run.sh` returns. The host learns
/// completion from the foreground process's **exit code** — no power-state
/// polling (that was only needed for Fusion's decoupled VM shutdown).
///
/// NOTE: the Apple `container` verb spellings below were validated live against
/// `container` 0.12.3 on macOS 26.5.1 (run/stop/delete/inspect, image
/// pull+inspect, system status/start, and the fact that `container list` has no
/// `--filter`). The pure-builder + unit-test split keeps any future flag change
/// a one-line edit.
public protocol LinuxContainerCLI: Sendable {
  /// Absolute path to the CLI binary (e.g. `/usr/local/bin/container`).
  var executable: String { get }
  /// Human label for the substrate (shown in the UI / logs).
  var displayName: String { get }
  /// The env-var name the JIT config is delivered through. The same value that
  /// launches `run.sh` on macOS/Windows; via env so it never hits the arg list.
  var jitEnvName: String { get }

  /// Run ONE ephemeral container in the FOREGROUND; the container command is the
  /// agent's `run.sh`. The JIT blob is delivered via `jitEnvName` (env), NOT the
  /// arg list. `--rm` + no volumes/binds == clean slate per job.
  func runArgs(name: String, image: String, label: String, cpus: Int, memoryGB: Int) -> [String]
  /// Stop a running container (graceful, bounded).
  func stopArgs(name: String) -> [String]
  /// Force-remove a container by name/id (belt-and-suspenders teardown + sweep).
  func rmArgs(name: String) -> [String]
  /// Inspect a container's status (parsed via `parseIsRunning`).
  func inspectArgs(name: String) -> [String]
  /// Ensure the runner image is present locally (the image-acquisition step).
  func pullArgs(image: String) -> [String]
  /// Check the image is present locally (part of the "ready" gate).
  func imageInspectArgs(image: String) -> [String]
  /// Probe daemon liveness (the "ready" gate; analog of Fusion's base-status).
  /// Non-zero exit == daemon down.
  func daemonStatusArgs() -> [String]
  /// Idempotently bring the daemon/VM up (`container system start`). Safe to run
  /// when already up.
  func daemonStartArgs() -> [String]
  /// One-time daemon preparation needed before the FIRST container can run.
  /// Apple `container` must install a default Linux kernel — `system start`
  /// only PROMPTS for it, which fails non-interactively. Run only when
  /// `daemonPrepareNeeded()` is true; it is not idempotent.
  func daemonPrepareArgs() -> [String]
  /// Whether `daemonPrepareArgs()` still needs to run (e.g. no default kernel is
  /// installed yet).
  func daemonPrepareNeeded() -> Bool
  /// List candidate container refs for the orphan sweep. Apple `container` has
  /// no label filter, so `sweepRefs(from:)` scopes by the `mactions-` name
  /// prefix (the `--name` we set IS the container ID).
  func sweepListArgs() -> [String]
  /// Parse the refs to force-remove from `sweepListArgs()` output.
  func sweepRefs(from output: String) -> [String]
  /// `true` when the inspect output shows the container alive/running.
  func parseIsRunning(from output: String) -> Bool
}

extension LinuxContainerCLI {
  /// The env-var the actions/runner consumes as `--jitconfig`. Shared by every
  /// backend (it's a property of the agent, not the container engine).
  public var jitEnvName: String { "ACTIONS_RUNNER_INPUT_JITCONFIG" }

  /// Default: a running container reports "running" in its inspected state.
  public func parseIsRunning(from output: String) -> Bool {
    output.lowercased().contains("running")
  }
}

// MARK: - Apple `container` backend (macOS 26+, per-container lightweight VM)

/// Apple's `container` (Containerization framework) backend — Apache-2.0, free
/// at any org size, native arm64, one lightweight VM per container. Requires
/// macOS 26+.
public struct ContainerCLI: LinuxContainerCLI {
  public let executable: String
  public init(executable: String) { self.executable = executable }
  public var displayName: String { "Apple container" }

  public func runArgs(name: String, image: String, label: String, cpus: Int, memoryGB: Int) -> [String] {
    // RUNNER_TOOL_CACHE/AGENT_TOOLSDIRECTORY: hosted-identity parity using the
    // runner-writable, --rm-ephemeral `/home/runner/_work/_tool` (the agent's
    // own default), never the root-owned `/opt/hostedtoolcache`.
    [
      "run", "--rm",
      "--name", name, "--label", label,
      "--cpus", String(cpus), "--memory", "\(memoryGB)g",
      "-e", jitEnvName,
      "-e", "RUNNER_TOOL_CACHE=/home/runner/_work/_tool",
      "-e", "AGENT_TOOLSDIRECTORY=/home/runner/_work/_tool",
      image,
      "/home/runner/run.sh",
    ]
  }
  public func stopArgs(name: String) -> [String] { ["stop", "--time", "30", name] }
  public func rmArgs(name: String) -> [String] { ["delete", "--force", name] }
  public func inspectArgs(name: String) -> [String] { ["inspect", name] }
  public func pullArgs(image: String) -> [String] { ["image", "pull", image] }
  public func imageInspectArgs(image: String) -> [String] { ["image", "inspect", image] }
  public func daemonStatusArgs() -> [String] { ["system", "status"] }
  public func daemonStartArgs() -> [String] { ["system", "start"] }

  /// Apple `container` runs each container in a VM and needs a default Linux
  /// kernel installed once. `system start` only PROMPTS for it (and so fails
  /// non-interactively), so we install it explicitly.
  public func daemonPrepareArgs() -> [String] { ["system", "kernel", "set", "--recommended"] }
  /// Only when no kernel is installed yet — `set --recommended` is NOT idempotent
  /// (it re-downloads the kata tarball and then errors with "File exists"), so we
  /// gate on the presence of a `vmlinux*` in container's kernels dir.
  public func daemonPrepareNeeded() -> Bool {
    let kernels = NSString(string: "~/Library/Application Support/com.apple.container/kernels")
      .expandingTildeInPath
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: kernels)) ?? []
    return !entries.contains { $0.hasPrefix("vmlinux") }
  }

  /// `container list` has NO `--filter`, so list all (the `--quiet` ID is the
  /// `--name` we set) and scope to ours by the `mactions-` name prefix.
  public func sweepListArgs() -> [String] { ["list", "--all", "--quiet"] }
  public func sweepRefs(from output: String) -> [String] {
    output.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("mactions-") }
  }
}

// MARK: - Linux container provider

/// Runs each ephemeral runner inside a **throwaway Linux container**, then
/// destroys it (`--rm`). The container's whole writable layer is discarded on
/// exit, which is cleaner than the macOS APFS-clone HOME-redirect dance and far
/// lighter than the Windows Fusion VM.
///
/// FOREGROUND model: `start()` launches `<cli> run --rm … run.sh` as a Foundation
/// `Process`; the process blocks until the agent exits, and the container's exit
/// code IS the completion signal — so we reuse `LocalProcessProvider`'s exact
/// `terminationHandler` reaping pattern (no boot/job/stop polling threads, no
/// power-state classifier; those were only needed for Fusion's decoupled VM
/// shutdown). Clean for TRUSTED/private repos; untrusted code needs full VM
/// isolation — same caveat as `LocalProcessProvider`.
public final class LinuxContainerProvider: RunnerProvider, @unchecked Sendable {
  public let id: String
  private let image: String
  private let cli: LinuxContainerCLI
  private let label: String
  private let cpus: Int
  private let memoryGB: Int
  private var process: Process?
  private var cleaned = false
  private let lock = NSLock()

  /// Container name carries the same `mactions-` prefix the orchestrator and the
  /// label sweep use to identify (and reap) our own containers. The orchestrator
  /// already hands us a `mactions-<host>-<id>` name, so guard against
  /// double-prefixing a bare id.
  var containerName: String { id.hasPrefix("mactions-") ? id : "mactions-\(id)" }

  public init(
    id: String, image: String, cli: LinuxContainerCLI,
    label: String = "mactions", cpus: Int = LinuxContainerBudget.defaultCPUsPerContainer,
    memoryGB: Int = LinuxContainerBudget.defaultMemoryGBPerContainer
  ) {
    self.id = id
    self.image = image
    self.cli = cli
    self.label = label
    self.cpus = cpus
    self.memoryGB = memoryGB
  }

  public var isRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return process?.isRunning ?? false
  }

  public func start(jitConfig: String, onExit: @escaping @Sendable (Int32) -> Void) throws {
    // JIT rides in via the environment (not the arg list) so it never appears in
    // `ps`; runArgs references it by name only (`-e <jitEnvName>`).
    var env = ProcessInfo.processInfo.environment
    env[cli.jitEnvName] = jitConfig

    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli.executable)
    process.arguments = cli.runArgs(
      name: containerName, image: image, label: label, cpus: cpus, memoryGB: memoryGB)
    process.environment = env
    // Foreground `run --rm` blocks until the agent exits; the container's exit
    // code IS the completion signal (no power-state polling). Identical to
    // LocalProcessProvider — reap + report from the termination handler.
    process.terminationHandler = { [weak self] proc in
      self?.cleanup()
      onExit(proc.terminationStatus)
    }
    try process.run()
    lock.lock(); self.process = process; lock.unlock()
  }

  public func stop() {
    lock.lock(); let process = self.process; self.process = nil; lock.unlock()
    // Terminate the foreground `container run` client so its Process settles and
    // the `onExit` callback fires — but that client is only an ATTACHMENT to a
    // daemon-managed container. SIGTERM does NOT reliably make `container run`
    // exit, so we must not depend on its terminationHandler to invoke cleanup().
    // Force-delete by NAME ourselves, unconditionally: `container delete --force`
    // removes a still-running container, and `cleanup()` is idempotent (the
    // `cleaned` guard), so a later terminationHandler is a harmless no-op.
    //
    // Without this, a reaped runner's container kept running in the daemon while
    // the orchestrator dropped it from `slots` and launched a replacement — so a
    // never-connecting runner (failed egress) piled up one zombie per reap cycle.
    process?.terminate()
    cleanup()
  }

  /// Idempotent: `--rm` reaps the container on a normal exit, but a SIGKILL
  /// mid-job (or the `container` CLI client being terminated before it
  /// reaps) can leave the container alive — so force-remove by name to guarantee
  /// nothing survives. Best-effort (a missing/dead daemon is harmless here).
  private func cleanup() {
    lock.lock()
    if cleaned { lock.unlock(); return }
    cleaned = true
    lock.unlock()
    _ = try? Shell.run(cli.executable, cli.rmArgs(name: containerName))
  }
}

// MARK: - Factory

/// Builds `LinuxContainerProvider`s for the orchestrator. Holds the per-fleet
/// config (runner image + CLI backend) and stamps a provider per runner name.
public struct LinuxContainerProviderFactory: RunnerProviderFactory {
  public var kind: String { "Linux container — \(cli.displayName) (throwaway, destroyed each run)" }
  private let image: String
  private let cli: LinuxContainerCLI

  public init(image: String, cli: LinuxContainerCLI) {
    self.image = image
    self.cli = cli
  }

  public func makeProvider(name: String) -> RunnerProvider {
    LinuxContainerProvider(id: name, image: image, cli: cli)
  }

  /// Presence-only detection, exactly like Fusion's `vmrun` probe — we never
  /// install a daemon. Linux is offered only when Apple `container` is installed
  /// on arm64 macOS 26+.
  public static func detectInstalledCLI(
    operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
  ) -> LinuxContainerCLI? {
    let fm = FileManager.default
    #if arch(arm64)
    let isARM64 = true
    #else
    let isARM64 = false
    #endif
    if isARM64, operatingSystemVersion.majorVersion >= 26 {
      for bin in ["/usr/local/bin/container", "/opt/homebrew/bin/container"]
      where fm.isExecutableFile(atPath: bin) {
        return ContainerCLI(executable: bin)
      }
    }
    return nil
  }

  /// The "ready" gate — the analog of `windowsImageReady` / `baseImagePoweredOff`:
  /// the container daemon is up AND the runner image is present locally. A probe
  /// error returns `false`, never throws.
  public static func ready(image: String, cli: LinuxContainerCLI) -> Bool {
    guard let info = try? Shell.run(cli.executable, cli.daemonStatusArgs()), info.ok else {
      return false
    }
    guard let img = try? Shell.run(cli.executable, cli.imageInspectArgs(image: image)), img.ok else {
      return false
    }
    return true
  }
}
