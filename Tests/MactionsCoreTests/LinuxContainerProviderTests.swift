import XCTest

@testable import MactionsCore

/// Unit tests for the *pure* logic of the Linux container provider: command /
/// argument construction for Apple `container`, the running-state classifier,
/// container naming, the factory, and the teardown guard. These do NOT launch a
/// container (no daemon in CI / on the dev host) — they pin the shape the
/// provider hands to `container`, and that the JIT secret rides in via the
/// ENVIRONMENT, never the arg list.
final class LinuxContainerProviderTests: XCTestCase {

  // MARK: Apple `container` verb shapes

  func testContainerRunArgsArm64NativeNoPlatformFlagAndJitViaEnv() {
    let cli = ContainerCLI(executable: "/usr/local/bin/container")
    let args = cli.runArgs(name: "mactions-xyz", image: "img:2",
                           label: "mactions", cpus: 4, memoryGB: 8)
    XCTAssertEqual(args, [
      "run", "--rm",
      "--name", "mactions-xyz", "--label", "mactions",
      "--cpus", "4", "--memory", "8g",
      "-e", "ACTIONS_RUNNER_INPUT_JITCONFIG",
      "-e", "RUNNER_TOOL_CACHE=/home/runner/_work/_tool",
      "-e", "AGENT_TOOLSDIRECTORY=/home/runner/_work/_tool",
      "img:2",
      "/home/runner/run.sh",
    ])
    // Apple container is arm64-native (one VM per container) — no --platform.
    XCTAssertFalse(args.contains("--platform"))
    XCTAssertEqual(args.last, "/home/runner/run.sh")
    // No bind-mounts / volumes / docker.sock (clean slate per job).
    XCTAssertFalse(args.contains("-v"))
    XCTAssertFalse(args.joined(separator: " ").contains("docker.sock"))
  }

  func testContainerLifecycleVerbShapes() {
    let cli = ContainerCLI(executable: "/usr/local/bin/container")
    XCTAssertEqual(cli.stopArgs(name: "mactions-xyz"), ["stop", "--time", "30", "mactions-xyz"])
    XCTAssertEqual(cli.rmArgs(name: "mactions-xyz"), ["delete", "--force", "mactions-xyz"])
    XCTAssertEqual(cli.inspectArgs(name: "mactions-xyz"), ["inspect", "mactions-xyz"])
    XCTAssertEqual(cli.pullArgs(image: "img:2"), ["image", "pull", "img:2"])
    XCTAssertEqual(cli.imageInspectArgs(image: "img:2"), ["image", "inspect", "img:2"])
    XCTAssertEqual(cli.daemonStatusArgs(), ["system", "status"])
    XCTAssertEqual(cli.daemonStartArgs(), ["system", "start"])
    // `container list` has NO --filter, so list all + scope by the mactions- name
    // prefix (the --name we set IS the container ID).
    XCTAssertEqual(cli.sweepListArgs(), ["list", "--all", "--quiet"])
    XCTAssertEqual(
      cli.sweepRefs(from: "mactions-abc\nsomeones-db\nmactions-xyz\n"),
      ["mactions-abc", "mactions-xyz"])
    // One-time default-kernel install (system start only prompts for it).
    XCTAssertEqual(cli.daemonPrepareArgs(), ["system", "kernel", "set", "--recommended"])
    XCTAssertTrue(cli.displayName.contains("Apple"))
  }

  // MARK: Running-state classifier

  func testParseIsRunning() {
    let cli = ContainerCLI(executable: "/x")
    XCTAssertTrue(cli.parseIsRunning(from: "running"))
    XCTAssertTrue(cli.parseIsRunning(from: #"{"status":"running"}"#))
    XCTAssertFalse(cli.parseIsRunning(from: "exited"))
    XCTAssertFalse(cli.parseIsRunning(from: "created"))
    XCTAssertFalse(cli.parseIsRunning(from: ""))
  }

  // MARK: Container naming + factory

  func testContainerNameCarriesMactionsPrefixWithoutDoubling() {
    // A bare id gets the prefix...
    let bare = LinuxContainerProvider(id: "host-9f2", image: "img", cli: ContainerCLI(executable: "/x"))
    XCTAssertEqual(bare.containerName, "mactions-host-9f2")
    // ...but an already-prefixed id (what the orchestrator hands us) is left as-is.
    let prefixed = LinuxContainerProvider(id: "mactions-host-9f2", image: "img", cli: ContainerCLI(executable: "/x"))
    XCTAssertEqual(prefixed.containerName, "mactions-host-9f2")
  }

  func testFactoryStampsLinuxProvider() {
    let factory = LinuxContainerProviderFactory(
      image: "ghcr.io/actions/actions-runner:latest", cli: ContainerCLI(executable: "/x"))
    let provider = factory.makeProvider(name: "mactions-testmac-abc")
    XCTAssertEqual(provider.id, "mactions-testmac-abc")
    XCTAssertTrue(provider is LinuxContainerProvider)
    XCTAssertTrue(factory.kind.contains("Linux container"))
    XCTAssertTrue(factory.kind.contains("Apple container"))
    XCTAssertFalse(provider.isRunning)
  }

  func testDetectInstalledCLIDoesNotUseFallbackRuntimeOnPreMacOS26() {
    // Linux is Apple-container-only. On a pre-26 macOS, detection must return nil
    // even if a docker/colima install happens to exist on the host.
    let cli = LinuxContainerProviderFactory.detectInstalledCLI(
      operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    XCTAssertNil(cli)
  }

  // MARK: Teardown guard

  func testStopIsIdempotentAndDoesNotCrashWithNoProcess() {
    // No container was ever started; stop() just runs cleanup() (an rm via a
    // non-existent CLI path, harmless) and the `cleaned` guard makes a second
    // call a safe no-op.
    let p = LinuxContainerProvider(
      id: "abc", image: "img", cli: ContainerCLI(executable: "/nonexistent/container"))
    XCTAssertFalse(p.isRunning)
    p.stop()
    XCTAssertFalse(p.isRunning)
    p.stop()  // must not crash / re-run teardown effects
    XCTAssertFalse(p.isRunning)
  }
}
