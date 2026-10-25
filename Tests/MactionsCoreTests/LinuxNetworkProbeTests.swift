import XCTest

@testable import MactionsCore

/// `LinuxNetworkProbe` and `HostRoute`: what each container outcome means, what
/// the user is told, and that the probe container is always removed. A fake
/// `container` script stands in for the CLI; the real one is exercised only by
/// `testLiveProbe`, which runs when `MACTIONS_LIVE_LINUX_PROBE=1`.
final class LinuxNetworkProbeTests: XCTestCase {
  // MARK: Reading the container's output

  func testEachMarkerIsAFinding() {
    func finding(_ stdout: String) -> LinuxNetworkProbe.Finding {
      LinuxNetworkProbe.finding(status: 0, stdout: stdout, stderr: "")
    }
    XCTAssertEqual(finding("mactions-probe:ok\n"), .reachable)
    XCTAssertEqual(finding("mactions-probe:dns\n"), .dnsFailed)
    XCTAssertEqual(finding("mactions-probe:offline\n"), .noNetwork)
    XCTAssertEqual(finding("mactions-probe:connect\n"), .connectFailed)
    XCTAssertEqual(finding("motd line\n  mactions-probe:ok  \n"), .reachable)
  }

  func testWithoutAMarkerTheCLIsErrorIsTheReason() {
    // The CLI's progress lines go to stderr before its error; the error is the
    // reason, the progress is not.
    let stderr = """
      [0/6] [0s]
      [6/6] Starting container [1s]
      Error: internalError: "failed to start" (cause: "notFound: image")
      """
    XCTAssertEqual(
      LinuxNetworkProbe.finding(status: 1, stdout: "", stderr: stderr),
      .couldNotRun(#"Error: internalError: "failed to start" (cause: "notFound: image")"#))
    XCTAssertEqual(
      LinuxNetworkProbe.finding(status: 125, stdout: "", stderr: "[6/6] Starting container [1s]\n"),
      .couldNotRun("exit status 125"))
    XCTAssertEqual(
      LinuxNetworkProbe.finding(status: 0, stdout: "mactions-probe:maybe\n", stderr: ""),
      .couldNotRun("exit status 0"), "an unknown marker is not a finding")
  }

  // MARK: What the user is told

  func testFindingsAreSaidInWordsAndAVPNIsNamedWhenItCouldBeTheCause() {
    let reachable = LinuxNetworkProbe.result(for: .reachable, tunnelInterface: "utun420")
    XCTAssertTrue(reachable.reachable)

    let noNetwork = LinuxNetworkProbe.result(for: .noNetwork, tunnelInterface: nil)
    XCTAssertFalse(noNetwork.reachable)
    XCTAssertEqual(
      noNetwork.detail,
      "Linux VMs have no network: DNS and connections from inside the VM both fail.")

    let behindVPN = LinuxNetworkProbe.result(for: .noNetwork, tunnelInterface: "utun420")
    XCTAssertTrue(behindVPN.detail.hasPrefix(noNetwork.detail))
    XCTAssertTrue(behindVPN.detail.contains("through a VPN (utun420)"))
    XCTAssertTrue(
      LinuxNetworkProbe.result(for: .dnsFailed, tunnelInterface: "utun3").detail.contains("utun3"))

    // A check that could not run is about the container runtime, not the VPN.
    let broken = LinuxNetworkProbe.result(for: .couldNotRun("Error: x"), tunnelInterface: "utun420")
    XCTAssertEqual(broken.detail, "Couldn't run the Linux network check: Error: x")
  }

  // MARK: The host's route

  func testTheRouteInterfaceIsReadFromRouteGet() {
    // Captured on 2026-10-24 with a full-tunnel VPN up.
    let vpn = """
         route to: 1.1.1.1
      destination: default
             mask: 128.0.0.0
        interface: utun420
            flags: <UP,DONE,STATIC,PRCLONING,GLOBAL>
      """
    XCTAssertEqual(HostRoute.interface(fromRouteGet: vpn), "utun420")
    let direct = """
         route to: 1.1.1.1
      destination: default
          gateway: 172.19.0.1
        interface: en0
      """
    XCTAssertEqual(HostRoute.interface(fromRouteGet: direct), "en0")
    XCTAssertNil(HostRoute.interface(fromRouteGet: "route: writing to routing socket: not in table"))
  }

  func testTunnelInterfaces() {
    for name in ["utun420", "utun0", "ipsec0", "ppp0", "tun3", "tap1", "wg0"] {
      XCTAssertTrue(HostRoute.isTunnel(name), name)
    }
    for name in ["en0", "en7", "bridge100", "awdl0", "lo0", "utunnel", "tunx"] {
      XCTAssertFalse(HostRoute.isTunnel(name), name)
    }
  }

  // MARK: Running the check

  func testProbeArgsRunTheScriptInOneSmallThrowawayContainer() {
    let cli = ContainerCLI(executable: "/usr/local/bin/container")
    XCTAssertEqual(
      cli.probeArgs(name: "mactions-probe-1", image: "img:2", script: "echo hi"),
      [
        "run", "--rm", "--name", "mactions-probe-1", "--cpus", "1", "--memory", "512m",
        "img:2", "/bin/bash", "-c", "echo hi",
      ])
    XCTAssertTrue(LinuxNetworkProbe.containerName().hasPrefix("mactions-probe-"))
  }

  func testTheScriptIsValidBash() throws {
    // macOS has no getent or GNU timeout to run it here; parse it at least.
    let parse = try Shell.run("/bin/bash", ["-n", "-c", LinuxNetworkProbe.script], timeout: 10)
    XCTAssertTrue(parse.ok, parse.stderr)
    for marker in ["ok", "connect", "dns", "offline"] {
      XCTAssertTrue(LinuxNetworkProbe.script.contains("${p}\(marker)"), marker)
    }
  }

  func testARunReadsTheMarkerAndRemovesTheContainer() throws {
    let fake = try FakeContainerCLI(run: """
      echo '[6/6] Starting container [1s]' >&2
      echo 'mactions-probe:offline'
      """)
    let result = LinuxNetworkProbe.run(
      cli: fake.cli, image: "img", timeout: 10, tunnelInterface: { "utun420" })
    XCTAssertFalse(result.reachable)
    XCTAssertTrue(result.detail.hasPrefix("Linux VMs have no network"))
    XCTAssertTrue(result.detail.contains("utun420"))
    let calls = fake.calls()
    XCTAssertEqual(calls.count, 2)
    let run = try XCTUnwrap(calls.first)
    XCTAssertTrue(run.hasPrefix("run --rm --name mactions-probe-"))
    let name = run.split(separator: " ")[3]
    XCTAssertEqual(calls.last, "delete --force \(name)", "the probe container is removed by name")
  }

  func testAReachableResultDoesNotReadTheRoute() throws {
    let fake = try FakeContainerCLI(run: "echo 'mactions-probe:ok'")
    var routeRead = false
    let result = LinuxNetworkProbe.run(
      cli: fake.cli, image: "img", timeout: 10,
      tunnelInterface: {
        routeRead = true
        return "utun420"
      })
    XCTAssertTrue(result.reachable)
    XCTAssertFalse(routeRead)
  }

  func testAHungContainerTimesOutAndIsStillRemoved() throws {
    let fake = try FakeContainerCLI(run: "exec sleep 30")
    let started = Date()
    let result = LinuxNetworkProbe.run(
      cli: fake.cli, image: "img", timeout: 1, tunnelInterface: { nil })
    XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    XCTAssertFalse(result.reachable)
    XCTAssertEqual(result.detail, "The Linux network check didn't finish within 1s.")
    XCTAssertEqual(fake.calls().filter { $0.hasPrefix("delete --force mactions-probe-") }.count, 1)
  }

  func testACLIThatCannotStartTheContainerIsReported() throws {
    let fake = try FakeContainerCLI(run: """
      echo 'Error: internalError: "failed to bootstrap container"' >&2
      exit 1
      """)
    let result = LinuxNetworkProbe.run(
      cli: fake.cli, image: "img", timeout: 10, tunnelInterface: { "utun420" })
    XCTAssertEqual(
      result.detail,
      #"Couldn't run the Linux network check: Error: internalError: "failed to bootstrap container""#)
  }

  // MARK: Live (opt-in)

  /// Runs the real check against the installed Apple `container` runtime and
  /// prints what it found: `MACTIONS_LIVE_LINUX_PROBE=1 swift test --filter testLiveProbe`.
  /// Needs `container system start` and the runner image pulled.
  func testLiveProbe() throws {
    guard ProcessInfo.processInfo.environment["MACTIONS_LIVE_LINUX_PROBE"] == "1" else {
      throw XCTSkip("set MACTIONS_LIVE_LINUX_PROBE=1 to run against the real container runtime")
    }
    let cli = try XCTUnwrap(LinuxContainerProviderFactory.detectInstalledCLI())
    let started = Date()
    let result = LinuxNetworkProbe.run(cli: cli, image: LinuxRunnerImage.imageRef())
    print(
      "LIVE PROBE (\(Int(Date().timeIntervalSince(started)))s): reachable=\(result.reachable) "
        + "detail=\(result.detail) route=\(HostRoute.tunnelInterface() ?? "direct")")
    XCTAssertFalse(result.detail.hasPrefix("Couldn't run"), result.detail)
  }
}

/// A stand-in `container` binary: `run` executes the given shell body, every
/// invocation is appended to a log so a test can see what was called.
private struct FakeContainerCLI {
  let cli: ContainerCLI
  private let log: URL

  init(run body: String) throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("mactions-probe-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    log = dir.appendingPathComponent("calls.log")
    let script = dir.appendingPathComponent("container")
    // The probe passes its script as one argument; log only the verb and name.
    let contents = """
      #!/bin/sh
      if [ "$1" = "run" ]; then
        echo "$1 $2 $3 $4" >> '\(log.path)'
        \(body)
        exit 0
      fi
      echo "$*" >> '\(log.path)'
      exit 0
      """
    try contents.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    cli = ContainerCLI(executable: script.path)
  }

  func calls() -> [String] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
      .split(whereSeparator: \.isNewline).map(String.init)
  }
}
