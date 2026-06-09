import XCTest

@testable import MactionsCore

/// Unit tests for the *pure* logic of the Linux container provider: command /
/// argument construction for both backends, the running-state classifier,
/// container naming, the factory, and the teardown guard. These do NOT launch a
/// container (no daemon in CI / on the dev host) — they pin the shapes the
/// provider hands to `docker` / Apple `container`, and that the JIT secret rides
/// in via the ENVIRONMENT, never the arg list.
final class LinuxContainerProviderTests: XCTestCase {

  // MARK: Docker CLI verb shapes

  func testDockerRunArgsAreEphemeralPinArm64AndPassJitViaEnv() {
    let cli = DockerCLI(executable: "/opt/homebrew/bin/docker")
    let args = cli.runArgs(name: "mactions-abc", image: "ghcr.io/actions/actions-runner:latest",
                           label: "mactions", cpus: 2, memoryGB: 6)
    XCTAssertEqual(args, [
      "run", "--rm", "--platform", "linux/arm64",
      "--name", "mactions-abc", "--label", "mactions",
      "--cpus", "2", "--memory", "6g",
      "-e", "ACTIONS_RUNNER_INPUT_JITCONFIG",
      "-e", "RUNNER_TOOL_CACHE=/home/runner/_work/_tool",
      "-e", "AGENT_TOOLSDIRECTORY=/home/runner/_work/_tool",
      "ghcr.io/actions/actions-runner:latest",
      "/home/runner/run.sh",
    ])
    // The official image has NO ENTRYPOINT/CMD — the run.sh command is required.
    XCTAssertEqual(args.last, "/home/runner/run.sh")
    // --rm guarantees the throwaway writable layer is gone on exit.
    XCTAssertTrue(args.contains("--rm"))
    // No bind-mounts / volumes / docker.sock (clean slate per job).
    XCTAssertFalse(args.contains("-v"))
    XCTAssertFalse(args.joined(separator: " ").contains("docker.sock"))
  }

  func testDockerLifecycleVerbShapes() {
    let cli = DockerCLI(executable: "/opt/homebrew/bin/docker")
    XCTAssertEqual(cli.stopArgs(name: "mactions-abc"), ["stop", "-t", "30", "mactions-abc"])
    XCTAssertEqual(cli.rmArgs(name: "mactions-abc"), ["rm", "-f", "mactions-abc"])
    XCTAssertEqual(cli.inspectArgs(name: "mactions-abc"), ["inspect", "-f", "{{.State.Status}}", "mactions-abc"])
    XCTAssertEqual(cli.pullArgs(image: "img:1"), ["pull", "--platform", "linux/arm64", "img:1"])
    XCTAssertEqual(cli.imageInspectArgs(image: "img:1"), ["image", "inspect", "img:1"])
    XCTAssertEqual(cli.daemonStatusArgs(), ["info"])
    // Sweep scopes by the mactions label; output is already ours → every line a ref.
    XCTAssertEqual(cli.sweepListArgs(), ["ps", "-aq", "--filter", "label=mactions"])
    XCTAssertEqual(cli.sweepRefs(from: "abc123\n\ndef456\n  "), ["abc123", "def456"])
    // docker/colima need no one-time daemon prep.
    XCTAssertEqual(cli.daemonPrepareArgs(), [])
    XCTAssertFalse(cli.daemonPrepareNeeded())
    // The docker binary has no daemon-start verb (`docker start` starts a
    // container) — empty, so AppState starts the actual daemon manager (Colima).
    XCTAssertEqual(cli.daemonStartArgs(), [])
    XCTAssertEqual(cli.jitEnvName, "ACTIONS_RUNNER_INPUT_JITCONFIG")
    XCTAssertTrue(cli.displayName.contains("Docker"))
  }

  // MARK: Apple `container` verb shapes (differ from docker's)

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
    let docker = DockerCLI(executable: "/x")
    XCTAssertTrue(docker.parseIsRunning(from: "running"))
    XCTAssertTrue(docker.parseIsRunning(from: "running\n"))
    XCTAssertFalse(docker.parseIsRunning(from: "exited"))
    XCTAssertFalse(docker.parseIsRunning(from: "created"))
    XCTAssertFalse(docker.parseIsRunning(from: ""))
  }

  // MARK: Container naming + factory

  func testContainerNameCarriesMactionsPrefixWithoutDoubling() {
    // A bare id gets the prefix...
    let bare = LinuxContainerProvider(id: "host-9f2", image: "img", cli: DockerCLI(executable: "/x"))
    XCTAssertEqual(bare.containerName, "mactions-host-9f2")
    // ...but an already-prefixed id (what the orchestrator hands us) is left as-is.
    let prefixed = LinuxContainerProvider(id: "mactions-host-9f2", image: "img", cli: DockerCLI(executable: "/x"))
    XCTAssertEqual(prefixed.containerName, "mactions-host-9f2")
  }

  func testFactoryStampsLinuxProvider() {
    let factory = LinuxContainerProviderFactory(
      image: "ghcr.io/actions/actions-runner:latest", cli: DockerCLI(executable: "/x"))
    let provider = factory.makeProvider(name: "mactions-testmac-abc")
    XCTAssertEqual(provider.id, "mactions-testmac-abc")
    XCTAssertTrue(provider is LinuxContainerProvider)
    XCTAssertTrue(factory.kind.contains("Linux container"))
    XCTAssertTrue(factory.kind.contains("Docker"))
    XCTAssertFalse(provider.isRunning)
  }

  func testDetectInstalledCLIPrefersAppleContainerOnlyOnMacOS26ARM() {
    // On a pre-26 macOS, never selects Apple container even if arm64 — falls
    // through to docker (or nil). We can't assert the exact result (depends on
    // what's installed on the host), but the call must not crash and must return
    // a conformer-or-nil.
    let cli = LinuxContainerProviderFactory.detectInstalledCLI(
      operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    if let cli {
      XCTAssertTrue(cli is DockerCLI, "pre-26 macOS must not select Apple container")
      XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.executable))
    } else {
      XCTAssertNil(cli)  // no docker installed on this host
    }
  }

  // MARK: Teardown guard

  func testStopIsIdempotentAndDoesNotCrashWithNoProcess() {
    // No container was ever started; stop() just runs cleanup() (an rm via a
    // non-existent CLI path, harmless) and the `cleaned` guard makes a second
    // call a safe no-op.
    let p = LinuxContainerProvider(
      id: "abc", image: "img", cli: DockerCLI(executable: "/nonexistent/docker"))
    XCTAssertFalse(p.isRunning)
    p.stop()
    XCTAssertFalse(p.isRunning)
    p.stop()  // must not crash / re-run teardown effects
    XCTAssertFalse(p.isRunning)
  }
}
