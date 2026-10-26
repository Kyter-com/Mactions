import XCTest

@testable import MactionsCore

/// The network anchor keeps the Linux network's bridge up while Linux runners
/// are armed (see `LinuxNetworkAnchor` for why). A fake `container` script
/// stands in for the CLI: `run` records the call and stays up until the
/// container is deleted, `inspect` reports running while it is up, and
/// `delete` ends it. The check against the real runtime is `testLiveAnchor`,
/// which runs when `MACTIONS_LIVE_LINUX_ANCHOR=1`.
final class LinuxNetworkAnchorTests: XCTestCase {
  // MARK: Command shape

  func testTheAnchorIsAnIdleContainerAtTheSmallestSizeContainerAccepts() {
    let cli = ContainerCLI(executable: "/usr/local/bin/container")
    let args = cli.anchorArgs(name: "mactions-network-anchor", image: "img:2")
    XCTAssertEqual(
      args,
      [
        "run", "--rm", "--name", "mactions-network-anchor", "--cpus", "1", "--memory", "200m",
        "img:2", "/bin/sleep", "infinity",
      ])
    // It only holds a network attachment: no JIT, no environment, no mounts.
    XCTAssertFalse(args.contains("-e"))
    XCTAssertFalse(args.contains("-v"))
  }

  func testTheGoOnlineOrphanSweepRemovesAnAnchorACrashLeftBehind() {
    let cli = ContainerCLI(executable: "/x")
    XCTAssertEqual(
      cli.sweepRefs(from: "\(LinuxNetworkAnchor.containerName)\nsomeone-else\n"),
      [LinuxNetworkAnchor.containerName])
  }

  // MARK: Lifecycle

  func testStartRemovesAStaleAnchorThenWaitsUntilItRuns() throws {
    let fake = try FakeContainer()
    let anchor = makeAnchor(fake)
    defer { anchor.stop() }
    XCTAssertTrue(anchor.start())
    XCTAssertTrue(anchor.isRunning)
    XCTAssertEqual(
      Array(fake.calls().prefix(2)),
      ["delete \(LinuxNetworkAnchor.containerName)", "run \(LinuxNetworkAnchor.containerName)"],
      "a same-named container would make `run --name` fail, so it goes first")
  }

  func testStopEndsTheAnchorRemovesItsContainerAndNothingStartsItAgain() throws {
    let fake = try FakeContainer()
    let anchor = makeAnchor(fake)
    XCTAssertTrue(anchor.start())
    anchor.stop()
    XCTAssertFalse(anchor.isRunning)
    XCTAssertFalse(fake.isUp, "the container is deleted by name, not only its CLI client ended")
    XCTAssertEqual(fake.calls().last, "delete \(LinuxNetworkAnchor.containerName)")
    let runs = fake.runCount()
    Thread.sleep(forTimeInterval: 0.5)  // ten restart delays
    XCTAssertEqual(fake.runCount(), runs, "a stopped anchor stays stopped")
    anchor.stop()  // idempotent
  }

  func testAnAnchorThatExitsOnItsOwnIsStartedAgain() throws {
    // `container system stop`, or a deleted container: the bridge must come back.
    let fake = try FakeContainer(runBody: "touch \"$state\"; sleep 0.3; rm -f \"$state\"; exit 1")
    let anchor = makeAnchor(fake)
    defer { anchor.stop() }
    XCTAssertTrue(anchor.start())
    XCTAssertTrue(eventually { fake.runCount() >= 3 }, "calls: \(fake.calls())")
  }

  func testAnAnchorThatCannotStartKeepsTrying() throws {
    // A daemon that refuses the run: start() says so, and retries continue on
    // their own until stop().
    let fake = try FakeContainer(runBody: "exit 1")
    let anchor = makeAnchor(fake)
    defer { anchor.stop() }
    XCTAssertFalse(anchor.start())
    XCTAssertTrue(eventually { fake.runCount() >= 3 }, "calls: \(fake.calls())")
  }

  func testALaunchThatCannotRunTheCLIIsRetriedToo() throws {
    // The CLI itself can't be executed (mid-reinstall, say): no process, so no
    // exit to restart from, and the retry has to be scheduled anyway.
    let fake = try FakeContainer()
    try fake.setExecutable(false)
    let anchor = makeAnchor(fake)
    defer { anchor.stop() }
    XCTAssertFalse(anchor.start())
    try fake.setExecutable(true)
    XCTAssertTrue(eventually { fake.runCount() >= 1 }, "calls: \(fake.calls())")
  }

  func testStartGivesUpWaitingWhenTheContainerNeverRuns() throws {
    let fake = try FakeContainer(inspectBody: "echo '{\"status\":{\"state\":\"stopped\"}}'")
    let anchor = makeAnchor(fake, startTimeout: 0.5)
    defer { anchor.stop() }
    let started = Date()
    XCTAssertFalse(anchor.start())
    XCTAssertLessThan(Date().timeIntervalSince(started), 4)
  }

  func testAnAnchorThatNeverReportsRunningIsRetriedNotLeftStuck() throws {
    // `inspect` never says running (a wedged daemon, say), but the `run`
    // client stays alive: the wait gives up, and the stuck launch must be
    // ended so the restart backoff starts a fresh one. Left alone, the first
    // launch would hold the slot forever with nothing scheduled to retry.
    let fake = try FakeContainer(inspectBody: "echo '{\"status\":{\"state\":\"stopped\"}}'")
    let anchor = makeAnchor(fake, startTimeout: 0.3)
    defer { anchor.stop() }
    XCTAssertFalse(anchor.start())
    XCTAssertTrue(eventually { fake.runCount() >= 2 }, "calls: \(fake.calls())")
  }

  func testStopBeforeStartMeansItNeverLaunches() throws {
    // Going offline while go-online is still on its way to the anchor.
    let fake = try FakeContainer()
    let anchor = makeAnchor(fake)
    anchor.stop()
    XCTAssertFalse(anchor.start())
    XCTAssertEqual(fake.runCount(), 0)
  }

  func testRestartDelaysDoubleAndAreCapped() {
    let policy = LinuxNetworkAnchor.RestartPolicy(
      initialRestartDelay: 2, maxRestartDelay: 300, stableRunTime: 60)
    XCTAssertEqual(policy.delay(quickExits: 0), 2)
    XCTAssertEqual(policy.delay(quickExits: 1), 4)
    XCTAssertEqual(policy.delay(quickExits: 3), 16)
    XCTAssertEqual(policy.delay(quickExits: 20), 300)
    XCTAssertEqual(policy.delay(quickExits: -1), 2)
  }

  // MARK: Live

  /// Starts the real anchor, checks that the Linux network's bridge is up while
  /// it runs, and stops it:
  /// `MACTIONS_LIVE_LINUX_ANCHOR=1 swift test --filter testLiveAnchor`.
  /// Needs `container system start` and the runner image pulled.
  func testLiveAnchor() throws {
    guard ProcessInfo.processInfo.environment["MACTIONS_LIVE_LINUX_ANCHOR"] == "1" else {
      throw XCTSkip("set MACTIONS_LIVE_LINUX_ANCHOR=1 to run against the real container runtime")
    }
    let cli = try XCTUnwrap(LinuxContainerProviderFactory.detectInstalledCLI())
    let anchor = LinuxNetworkAnchor(cli: cli, image: LinuxRunnerImage.imageRef())
    let started = Date()
    XCTAssertTrue(anchor.start(), "the anchor never reported running")
    let seconds = Date().timeIntervalSince(started)
    let gateway = try XCTUnwrap(defaultNetworkGateway(cli))
    let bridge = bridgeCarrying(gateway)
    print(
      "LIVE ANCHOR (\(String(format: "%.1f", seconds))s): gateway=\(gateway) "
        + "bridge=\(bridge ?? "none")")
    XCTAssertNotNil(bridge, "no bridge carries the Linux network's gateway \(gateway)")
    anchor.stop()
    XCTAssertFalse(anchor.isRunning)
    let inspect = try Shell.run(
      cli.executable, cli.inspectArgs(name: LinuxNetworkAnchor.containerName), timeout: 30)
    XCTAssertFalse(inspect.ok && cli.parseIsRunning(from: inspect.stdout), "still running")
  }

  // MARK: Helpers

  private func makeAnchor(_ fake: FakeContainer, startTimeout: TimeInterval = 5)
    -> LinuxNetworkAnchor
  {
    LinuxNetworkAnchor(
      cli: fake.cli, image: "img", startTimeout: startTimeout, commandTimeout: 5,
      pollInterval: 0.05,
      restartPolicy: .init(initialRestartDelay: 0.05, maxRestartDelay: 0.2, stableRunTime: 60))
  }

  private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
  }

  /// `status.ipv4Gateway` of `container network inspect default`.
  private func defaultNetworkGateway(_ cli: LinuxContainerCLI) throws -> String? {
    let output = try Shell.run(cli.executable, ["network", "inspect", "default"], timeout: 30)
    guard output.ok,
      let networks = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
        as? [[String: Any]],
      let status = networks.first?["status"] as? [String: Any]
    else { return nil }
    return status["ipv4Gateway"] as? String
  }

  /// The `bridgeN` interface whose IPv4 address is `address`.
  private func bridgeCarrying(_ address: String) -> String? {
    guard let output = try? Shell.run("/sbin/ifconfig", [], timeout: 10), output.ok else {
      return nil
    }
    var current: String?
    for line in output.stdout.split(whereSeparator: \.isNewline) {
      if !line.hasPrefix("\t"), !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") {
        current = String(line[..<colon])
      } else if let current, current.hasPrefix("bridge"),
        line.trimmingCharacters(in: .whitespaces).hasPrefix("inet \(address) ")
      {
        return current
      }
    }
    return nil
  }
}

/// A stand-in `container` binary for the anchor: `run` records the container
/// name and runs `runBody`, which by default marks the container up and stays
/// until it is deleted; `inspect` reports running while it is up; `delete`
/// records the call and ends it.
private struct FakeContainer {
  let cli: ContainerCLI
  private let log: URL
  private let state: URL

  init(
    runBody: String = "touch \"$state\"; while [ -f \"$state\" ]; do sleep 0.05; done",
    inspectBody: String? = nil
  ) throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("mactions-anchor-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    log = dir.appendingPathComponent("calls.log")
    state = dir.appendingPathComponent("up")
    let inspect =
      inspectBody
      ?? """
      if [ -f "$state" ]; then echo '{"status":{"state":"running"}}'; else echo '{"status":{"state":"stopped"}}'; fi
      """
    let script = dir.appendingPathComponent("container")
    let contents = """
      #!/bin/sh
      log='\(log.path)'
      state='\(state.path)'
      case "$1" in
        run)
          echo "run $4" >> "$log"
          \(runBody)
          ;;
        inspect) \(inspect) ;;
        delete)
          echo "delete $3" >> "$log"
          rm -f "$state"
          ;;
      esac
      exit 0
      """
    try contents.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    // macOS checks a new executable the first time it runs; do that here so the
    // tests' short limits time the verbs, not the check.
    try Shell.run(script.path, ["warm-up"])
    cli = ContainerCLI(executable: script.path)
  }

  var isUp: Bool { FileManager.default.fileExists(atPath: state.path) }

  func setExecutable(_ executable: Bool) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: cli.executable)
  }

  func calls() -> [String] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
      .split(separator: "\n").map(String.init)
  }

  func runCount() -> Int { calls().filter { $0.hasPrefix("run ") }.count }
}
