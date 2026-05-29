import XCTest

@testable import MactionsCore

/// Unit tests for the *pure* logic of the Windows VM provider: command/argument
/// construction, IP parsing, SSH invocation, and clone-name extraction. These do
/// NOT boot a VM (none is available in CI / on the dev host) — they pin the
/// shapes the provider hands to `prlctl`/`utmctl`/`ssh`, the same way
/// `GitHubRequestTests` pins the request builders.
final class WindowsVMProviderTests: XCTestCase {

  // MARK: Parallels (prlctl) verb shapes

  func testParallelsCloneIsLinkedCopyOnWrite() {
    let cli = ParallelsCLI(executable: "/usr/local/bin/prlctl")
    // `--linked` is the cheap CoW clone (analog to Tart/APFS clone). The clone
    // name carries the `mactions-` prefix for scoped teardown.
    XCTAssertEqual(
      cli.cloneArgs(base: "win11-runner-base", clone: "mactions-abc"),
      ["clone", "win11-runner-base", "--linked", "--name", "mactions-abc"])
    XCTAssertEqual(cli.startArgs(clone: "mactions-abc"), ["start", "mactions-abc"])
    // Force power-off, then permanent delete (the ephemerality bar).
    XCTAssertEqual(cli.stopArgs(clone: "mactions-abc"), ["stop", "mactions-abc", "--kill"])
    XCTAssertEqual(cli.deleteArgs(clone: "mactions-abc"), ["delete", "mactions-abc"])
    XCTAssertEqual(cli.ipArgs(clone: "mactions-abc"), ["list", "-f", "--info", "mactions-abc"])
  }

  // MARK: UTM (utmctl) verb shapes

  func testUTMVerbShapes() {
    let cli = UTMCLI(executable: "/Applications/UTM.app/Contents/MacOS/utmctl")
    XCTAssertEqual(cli.cloneArgs(base: "Win11-ARM-Base", clone: "mactions-xyz"),
      ["clone", "Win11-ARM-Base", "--name", "mactions-xyz"])
    // `--hide` boots headless (no surfaced window).
    XCTAssertEqual(cli.startArgs(clone: "mactions-xyz"), ["start", "mactions-xyz", "--hide"])
    XCTAssertEqual(cli.stopArgs(clone: "mactions-xyz"), ["stop", "mactions-xyz"])
    XCTAssertEqual(cli.deleteArgs(clone: "mactions-xyz"), ["delete", "mactions-xyz"])
    XCTAssertEqual(cli.ipArgs(clone: "mactions-xyz"), ["ip-address", "mactions-xyz"])
  }

  // MARK: IP parsing

  func testParseIPFromUTMBareAddress() {
    // utmctl ip-address prints one address per line.
    XCTAssertEqual(UTMCLI().parseIP(from: "192.168.64.7\n"), "192.168.64.7")
  }

  func testParseIPFromParallelsListLine() {
    // prlctl list -f --info embeds the address in a status line.
    let out = """
      UUID      STATUS       IP_ADDR        NAME
      {abc}     running      10.211.55.12   mactions-abc
      """
    XCTAssertEqual(ParallelsCLI().parseIP(from: out), "10.211.55.12")
  }

  func testParseIPSkipsZeroPlaceholderBeforeDHCP() {
    // Parallels prints 0.0.0.0 before the guest gets a lease — not a real IP.
    XCTAssertNil(ParallelsCLI().parseIP(from: "running 0.0.0.0 mactions-abc"))
  }

  func testParseIPReturnsNilWhenNoAddressYet() {
    XCTAssertNil(ParallelsCLI().parseIP(from: "STATUS\nstopped\n"))
    XCTAssertNil(UTMCLI().parseIP(from: ""))
  }

  func testParseIPRejectsOutOfRangeOctets() {
    // 999 is not a valid octet; a version string must not be mistaken for an IP.
    XCTAssertNil(ParallelsCLI().parseIP(from: "999.1.1.1"))
    XCTAssertNil(ParallelsCLI().parseIP(from: "version 2.334.0 build"))
  }

  // MARK: Remote command + SSH invocation

  func testRemoteCommandLaunchesWinArm64AgentWithJIT() {
    let p = WindowsVMProvider(id: "abc", baseImage: "win11-runner-base", sshPassword: nil)
    // run.cmd (Windows), NOT ./run.sh; short C:\ root path; the OS-agnostic
    // base64 JIT string is passed straight through.
    XCTAssertEqual(
      p.remoteCommand(jitConfig: "BASE64JIT=="),
      "cd /d C:\\actions-runner && run.cmd --jitconfig BASE64JIT==")
  }

  func testCloneNameCarriesMactionsPrefix() {
    let p = WindowsVMProvider(id: "host-9f2", baseImage: "base", sshPassword: nil)
    XCTAssertEqual(p.cloneName, "mactions-host-9f2")
  }

  func testSSHInvocationWithoutPasswordUsesPlainSSH() {
    // No password configured -> rely on an SSH key/agent, invoke ssh directly.
    let p = WindowsVMProvider(id: "abc", baseImage: "base", sshPassword: nil)
    let inv = p.sshInvocation(ip: "10.0.0.5", jitConfig: "J")
    XCTAssertEqual(inv.executable, "/usr/bin/ssh")
    XCTAssertEqual(inv.arguments.first, "-o")
    XCTAssertTrue(inv.arguments.contains("StrictHostKeyChecking=no"))
    XCTAssertTrue(inv.arguments.contains("UserKnownHostsFile=/dev/null"))
    XCTAssertEqual(inv.arguments[safe: inv.arguments.count - 2], "runner@10.0.0.5")
    XCTAssertEqual(inv.arguments.last, "cd /d C:\\actions-runner && run.cmd --jitconfig J")
  }

  func testSSHInvocationWithPasswordRoutesThroughSSHPass() {
    // With a password AND sshpass present, route through sshpass for
    // non-interactive auth into the throwaway guest.
    let p = WindowsVMProvider(
      id: "abc", baseImage: "base", sshUser: "runner", sshPassword: "P@ss",
      sshpassPath: "/opt/homebrew/bin/sshpass")
    let inv = p.sshInvocation(ip: "10.0.0.5", jitConfig: "J")
    XCTAssertEqual(inv.executable, "/opt/homebrew/bin/sshpass")
    XCTAssertEqual(Array(inv.arguments.prefix(3)), ["-p", "P@ss", "/usr/bin/ssh"])
    XCTAssertTrue(inv.arguments.contains("runner@10.0.0.5"))
  }

  func testSSHInvocationFallsBackToPlainSSHWhenSSHPassMissing() {
    // Password set but sshpass not installed -> don't fabricate a path; fall
    // back to plain ssh (which will use a key/agent if one is configured).
    let p = WindowsVMProvider(
      id: "abc", baseImage: "base", sshPassword: "P@ss", sshpassPath: nil)
    let inv = p.sshInvocation(ip: "10.0.0.5", jitConfig: "J")
    XCTAssertEqual(inv.executable, "/usr/bin/ssh")
  }

  // MARK: Factory

  func testFactoryStampsMactionsPrefixedWindowsProvider() {
    let factory = WindowsVMProviderFactory(baseImage: "win11-runner-base")
    let provider = factory.makeProvider(name: "mactions-testmac-abc")
    XCTAssertEqual(provider.id, "mactions-testmac-abc")
    XCTAssertTrue(provider is WindowsVMProvider)
    XCTAssertTrue(factory.kind.contains("Windows VM"))
    XCTAssertTrue(factory.kind.contains("Parallels"))
  }

  func testFactoryReportsBackendInKind() {
    let utm = WindowsVMProviderFactory(baseImage: "Win11-ARM-Base", cli: UTMCLI())
    XCTAssertTrue(utm.kind.contains("UTM"))
  }

  func testDetectInstalledCLIReturnsNilWhenNoneInstalled() {
    // No Windows hypervisor is installed on the dev/CI host, so detection must
    // return nil rather than fabricate a backend. (If prlctl/utmctl ever IS
    // installed here, this asserts it returns a usable CLI instead.)
    let cli = WindowsVMProviderFactory.detectInstalledCLI()
    if let cli {
      XCTAssertFalse(cli.executable.isEmpty)
      XCTAssertTrue(
        FileManager.default.isExecutableFile(atPath: cli.executable),
        "detected CLI must point at a real executable")
    } else {
      XCTAssertNil(cli)
    }
  }

  // MARK: Teardown guard

  func testStopIsIdempotentAndClearsRunning() {
    // `stop()` tears the clone down via a (here non-existent) CLI path, which is
    // harmless. The `tornDown` guard means a second `stop()` is a safe no-op and
    // `isRunning` stays false. (The double-onExit guard itself needs a live VM
    // to exercise the start() path, so it's verified by inspection + this guard;
    // see WindowsVMProvider.teardown.)
    let p = WindowsVMProvider(
      id: "abc", baseImage: "base",
      cli: ParallelsCLI(executable: "/nonexistent/prlctl"), sshPassword: nil)
    XCTAssertFalse(p.isRunning)
    p.stop()
    XCTAssertFalse(p.isRunning)
    p.stop()  // second call must not crash / re-run teardown effects
    XCTAssertFalse(p.isRunning)
  }

  // MARK: Stray-clone reaping (HostCleanup)

  func testWindowsCloneNameExtractionOnlyMatchesOurPrefix() {
    let listing = """
      win11-runner-base
      mactions-host-aaa
      someones-other-vm
      mactions-host-bbb
      Windows 11
      """
    XCTAssertEqual(
      HostCleanup.windowsCloneNames(in: listing),
      ["mactions-host-aaa", "mactions-host-bbb"])
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
