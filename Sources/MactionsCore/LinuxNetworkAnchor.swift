import Foundation

/// Keeps the Linux container network's bridge up while Linux runners are armed:
/// one idle container from the runner image, started at go-online before any
/// runner can launch and stopped at go-offline.
///
/// Why: Apple `container` gives its NAT network a kernel bridge only while a
/// container is attached to it, but fixes the bridge's number the first time
/// the network comes up and reuses that number every time after
/// (apple/container#2051, open against container 1.0.0, the version here).
/// While no container runs, the bridge is gone and another vmnet network can be
/// given the same number. A Fusion VM booting for a Windows job does exactly
/// that: with no Linux job running, its host-only network took `bridge100`. The
/// next Linux runner then brings the container network up on that same bridge,
/// taking it over from the VM, and when the VM powers off the bridge is deleted
/// with the runner still attached. The runner has no network until it exits:
/// GitHub lists it offline, the orchestrator reaps it as `sustained_unhealthy`
/// five minutes later, and its job is lost.
///
/// On 2026-10-25 that killed two Linux jobs, on runners that came online 1 s
/// and 3 s before a Windows VM powered off; none of the 13 Linux runners that
/// finished normally that day overlapped a VM power-off. Reproduced the same
/// day with the `container` CLI and a linked clone of the Windows base: VM
/// first, then a container, and the VM's power-off cut the container off for
/// good (every check failed from that second on, and starting another
/// container did not bring it back). With the container started first, the VM
/// was given `bridge101` and `bridge102`, and neither its power-off nor its
/// deletion touched the container.
///
/// The anchor makes "container network first" permanent: its bridge stays up
/// for as long as Mactions is online with Linux armed, so a VM is never given
/// its number, whichever starts first afterwards. The takeover also pulls a
/// running VM's interfaces off the bridge the moment the container network comes
/// up on it (Fusion's host-only network lost its member that way in the
/// reproduction), which the anchor prevents too. It costs one idle VM: 1 CPU and
/// 200 MB, the least `container` 1.0.0 accepts ("minimum memory amount allowed
/// is 200 MiB"), about 340 MB resident measured.
public final class LinuxNetworkAnchor: @unchecked Sendable {
  /// Fixed and `mactions-` prefixed: one anchor per Mac, and the go-online
  /// orphan sweep removes one a crash left behind before a new one starts.
  public static let containerName = "mactions-network-anchor"

  /// How long `start()` waits for `container` to report the anchor running. A
  /// cold container start took up to ~6 s live.
  public static let defaultStartTimeout: TimeInterval = 30

  /// Waits between restarts after the anchor exits on its own: from
  /// `initialRestartDelay`, doubling per exit that came within
  /// `stableRunTime` of its start, up to `maxRestartDelay`. An anchor whose
  /// daemon is down fails at once, so its retries back off; one that ran for a
  /// while (stopped by `container system stop`, say) comes back quickly, which
  /// keeps the window in which a VM could take the bridge short.
  public struct RestartPolicy: Equatable, Sendable {
    public var initialRestartDelay: TimeInterval
    public var maxRestartDelay: TimeInterval
    public var stableRunTime: TimeInterval

    public init(
      initialRestartDelay: TimeInterval = 2, maxRestartDelay: TimeInterval = 5 * 60,
      stableRunTime: TimeInterval = 60
    ) {
      self.initialRestartDelay = max(0, initialRestartDelay)
      self.maxRestartDelay = max(self.initialRestartDelay, maxRestartDelay)
      self.stableRunTime = max(0, stableRunTime)
    }

    /// `initialRestartDelay × 2^quickExits`, capped at `maxRestartDelay`.
    public func delay(quickExits: Int) -> TimeInterval {
      let exponent = Double(min(max(quickExits, 0), 16))
      return min(maxRestartDelay, initialRestartDelay * pow(2, exponent))
    }
  }

  private let cli: LinuxContainerCLI
  private let image: String
  private let startTimeout: TimeInterval
  private let commandTimeout: TimeInterval
  private let pollInterval: TimeInterval
  private let restartPolicy: RestartPolicy
  private let lock = NSLock()
  private var process: Process?
  private var stopped = false
  /// Bumped per launch, so the exit of an anchor that was already replaced or
  /// stopped is ignored.
  private var launchID = 0
  private var launchedAt: Date?
  /// Exits within `stableRunTime` of their start, in a row.
  private var quickExits = 0

  public init(
    cli: LinuxContainerCLI, image: String,
    startTimeout: TimeInterval = LinuxNetworkAnchor.defaultStartTimeout,
    commandTimeout: TimeInterval = LinuxContainerProvider.commandTimeout,
    pollInterval: TimeInterval = 0.5,
    restartPolicy: RestartPolicy = RestartPolicy()
  ) {
    self.cli = cli
    self.image = image
    self.startTimeout = startTimeout
    self.commandTimeout = commandTimeout
    self.pollInterval = pollInterval
    self.restartPolicy = restartPolicy
  }

  public var isRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return process?.isRunning ?? false
  }

  /// Start the anchor and wait, at most `startTimeout`, until `container`
  /// reports it running. Blocking: call it off the main actor. Returns whether
  /// it is up. An anchor that fails to start, or exits later, is started again
  /// on its own until `stop()`.
  @discardableResult
  public func start() -> Bool {
    let started = Date()
    // A same-named container (a previous generation's, or one a crash left that
    // the sweep didn't reach) would make `run --name` fail.
    removeContainer()
    guard let launch = launch() else { return false }
    let up = waitUntilRunning(launch)
    if !up { abandonStuckLaunch(launch) }
    ControlPlaneLog.log(
      up ? "linux.anchor.started" : "linux.anchor.not_running",
      ["seconds": String(format: "%.1f", Date().timeIntervalSince(started))])
    return up
  }

  /// Stop the anchor, remove its container and stop restarting it. Blocking (one
  /// time-limited `container delete`): call it off the main actor. Idempotent,
  /// and safe to call before or during `start()`.
  public func stop() {
    lock.lock()
    let wasStopped = stopped
    stopped = true
    let process = self.process
    self.process = nil
    lock.unlock()
    guard !wasStopped else { return }
    // The foreground `container run` client is only an attachment; terminating it
    // does not reliably end the container, so delete it by name as well (the
    // same reason as `LinuxContainerProvider.stop()`).
    process?.terminate()
    removeContainer()
    ControlPlaneLog.log("linux.anchor.stopped")
  }

  // MARK: Launch, wait, restart

  private struct Launch {
    let id: Int
    let process: Process
  }

  private func launch() -> Launch? {
    lock.lock()
    if stopped { lock.unlock(); return nil }
    launchID += 1
    let id = launchID
    lock.unlock()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli.executable)
    process.arguments = cli.anchorArgs(name: Self.containerName, image: image)
    // Only the CLI's progress lines would arrive here; nothing reads them.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [weak self] proc in
      self?.exited(launchID: id, status: proc.terminationStatus)
    }
    do {
      try process.run()
    } catch {
      ControlPlaneLog.log("linux.anchor.launch_failed", ["error": String(describing: error)])
      // No process means no termination handler: schedule the retry here.
      exited(launchID: id, status: -1)
      return nil
    }
    lock.lock()
    if stopped {
      // stop() ran while this launch was starting and found no process to end.
      lock.unlock()
      process.terminate()
      removeContainer()
      return nil
    }
    self.process = process
    launchedAt = Date()
    lock.unlock()
    return Launch(id: id, process: process)
  }

  private func waitUntilRunning(_ launch: Launch) -> Bool {
    let deadline = Date().addingTimeInterval(startTimeout)
    while Date() < deadline {
      lock.lock()
      let current = !stopped && launchID == launch.id
      lock.unlock()
      guard current, launch.process.isRunning else { return false }
      if let inspect = try? Shell.run(
        cli.executable, cli.inspectArgs(name: Self.containerName), timeout: commandTimeout),
        inspect.ok, cli.parseIsRunning(from: inspect.stdout)
      {
        return true
      }
      Thread.sleep(forTimeInterval: pollInterval)
    }
    return false
  }

  /// The wait gave up but the `run` client is still alive (the daemon never
  /// reported the container running): end it, so its exit runs the normal
  /// restart backoff instead of holding the slot forever with no retry
  /// scheduled. A launch that already exited, was replaced, or was stopped
  /// needs nothing — its exit already scheduled (or cancelled) the retry.
  private func abandonStuckLaunch(_ launch: Launch) {
    lock.lock()
    let current = !stopped && launchID == launch.id
    lock.unlock()
    guard current, launch.process.isRunning else { return }
    // The client is only an attachment: delete the container by name too, so
    // the exit fires even if terminating the client doesn't end it.
    launch.process.terminate()
    removeContainer()
  }

  private func exited(launchID id: Int, status: Int32) {
    lock.lock()
    guard id == launchID, !stopped else {
      lock.unlock()
      return
    }
    process = nil
    let ranFor = launchedAt.map { Date().timeIntervalSince($0) } ?? 0
    launchedAt = nil
    quickExits = ranFor >= restartPolicy.stableRunTime ? 0 : quickExits + 1
    let delay = restartPolicy.delay(quickExits: max(0, quickExits - 1))
    lock.unlock()
    ControlPlaneLog.log(
      "linux.anchor.exited",
      [
        "status": String(status), "ranSeconds": String(Int(ranFor)),
        "restartInSeconds": String(Int(delay.rounded(.up))),
      ])
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let isStopped = self.stopped
      self.lock.unlock()
      if !isStopped { self.start() }
    }
  }

  private func removeContainer() {
    _ = try? Shell.run(
      cli.executable, cli.rmArgs(name: Self.containerName), timeout: commandTimeout)
  }
}
