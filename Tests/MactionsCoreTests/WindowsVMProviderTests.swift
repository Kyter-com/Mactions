import XCTest

@testable import MactionsCore

/// Unit tests for the *pure* logic of the Windows VM provider: command/argument
/// construction, IP parsing, the per-clone config-ISO + injection plans, the
/// power-state completion classifier, and clone-name extraction. These do NOT
/// boot a VM (none is available in CI / on the dev host) — they pin the shapes
/// the provider hands to `prlctl`/`utmctl`/`hdiutil`.
final class WindowsVMProviderTests: XCTestCase {

  // MARK: Parallels (prlctl) verb shapes

  func testParallelsCloneIsLinkedCopyOnWrite() {
    let cli = ParallelsCLI(executable: "/usr/local/bin/prlctl")
    XCTAssertEqual(
      cli.cloneArgs(base: "win11-runner-base", clone: "mactions-abc"),
      ["clone", "win11-runner-base", "--linked", "--name", "mactions-abc"])
    XCTAssertEqual(cli.startArgs(clone: "mactions-abc"), ["start", "mactions-abc"])
    XCTAssertEqual(cli.stopArgs(clone: "mactions-abc"), ["stop", "mactions-abc", "--kill"])
    XCTAssertEqual(cli.forceStopArgs(clone: "mactions-abc"), ["stop", "mactions-abc", "--kill"])
    XCTAssertEqual(cli.deleteArgs(clone: "mactions-abc"), ["delete", "mactions-abc"])
    XCTAssertEqual(cli.statusArgs(clone: "mactions-abc"), ["status", "mactions-abc"])
    XCTAssertEqual(cli.ipArgs(clone: "mactions-abc"), ["list", "mactions-abc", "--full", "--json"])
  }

  // MARK: UTM (utmctl) verb shapes

  func testUTMVerbShapes() {
    let cli = UTMCLI(executable: "/Applications/UTM.app/Contents/MacOS/utmctl")
    XCTAssertEqual(cli.cloneArgs(base: "Win11-ARM-Base", clone: "mactions-xyz"),
      ["clone", "Win11-ARM-Base", "--name", "mactions-xyz"])
    XCTAssertEqual(cli.startArgs(clone: "mactions-xyz"), ["start", "mactions-xyz", "--hide"])
    XCTAssertEqual(cli.stopArgs(clone: "mactions-xyz"), ["stop", "mactions-xyz"])
    XCTAssertEqual(cli.deleteArgs(clone: "mactions-xyz"), ["delete", "mactions-xyz"])
    XCTAssertEqual(cli.statusArgs(clone: "mactions-xyz"), ["status", "mactions-xyz"])
    XCTAssertEqual(cli.ipArgs(clone: "mactions-xyz"), ["ip-address", "mactions-xyz"])
  }

  // MARK: Per-clone config ISO (the headless JIT-delivery payload)

  func testConfigISOArgsFlagOrder() {
    XCTAssertEqual(
      WindowsImage.configISOArgs(sourceDir: "/tmp/stage", output: "/tmp/config.iso"),
      ["makehybrid", "-iso", "-joliet", "-ov", "-default-volume-name", "MACTIONS", "-o", "/tmp/config.iso", "/tmp/stage"])
    // Custom volume name flows through (right after -default-volume-name).
    XCTAssertEqual(
      WindowsImage.configISOArgs(sourceDir: "/s", output: "/o.iso", volumeName: "MX"),
      ["makehybrid", "-iso", "-joliet", "-ov", "-default-volume-name", "MX", "-o", "/o.iso", "/s"])
  }

  // MARK: Injection plans (how each backend delivers the config ISO)

  func testUTMInjectionOverwritesAFixedInBundleDrive() {
    // UTM has no attach verb: the clone bundle path is derived deterministically
    // and the plan overwrites the fixed in-bundle drive at <bundle>/Data/<name>.
    let cli = UTMCLI(documentsDir: "/docs", inBundleImageName: "cfg.img")
    XCTAssertEqual(cli.cloneBundlePath(clone: "mactions-abc"), "/docs/mactions-abc.utm")
    XCTAssertEqual(
      cli.injectionPlan(clone: "mactions-abc", clonePath: nil, configISO: "/tmp/c.iso"),
      .overwriteInBundleDrive(target: "/docs/mactions-abc.utm/Data/cfg.img"))
    // An explicitly-resolved clonePath is honored over the derived default.
    XCTAssertEqual(
      cli.injectionPlan(clone: "mactions-abc", clonePath: "/elsewhere/x.utm", configISO: "/tmp/c.iso"),
      .overwriteInBundleDrive(target: "/elsewhere/x.utm/Data/cfg.img"))
  }

  func testParallelsInjectionAttachesViaCLI() {
    // Parallels has a real attach verb — no in-bundle dance, and no bundle path.
    let cli = ParallelsCLI()
    XCTAssertNil(cli.cloneBundlePath(clone: "mactions-abc"))
    XCTAssertEqual(
      cli.injectionPlan(clone: "mactions-abc", clonePath: nil, configISO: "/tmp/c.iso"),
      .attachCommands([["set", "mactions-abc", "--device-set", "cdrom0", "--image", "/tmp/c.iso", "--connect"]]))
  }

  // MARK: Power-state completion classifier

  func testPhaseClassifierRequiresRunningBeforeStopped() {
    let p = WindowsVMProvider(id: "abc", baseImage: "base", cli: UTMCLI())
    // 'stopped' (fresh clone or self-powered-off) classifies as .stopped...
    XCTAssertEqual(p.phase(from: "stopped"), .stopped)
    // ...but live/transitional states are .running (so the boot gate passes)...
    XCTAssertEqual(p.phase(from: "started"), .running)
    XCTAssertEqual(p.phase(from: "VM 'x' is running"), .running)
    XCTAssertEqual(p.phase(from: "stopping"), .running)  // mid power-off, NOT yet stopped
    XCTAssertEqual(p.phase(from: "suspended"), .running)
    // ...and an unknown/empty read is .starting (keep polling, don't conclude).
    XCTAssertEqual(p.phase(from: ""), .starting)
    XCTAssertEqual(p.phase(from: "???"), .starting)
  }

  // MARK: IP parsing (unused on the outbound flow; kept for diagnostics)

  func testParseIPFromParallelsJSON() {
    let out = """
      [{"uuid":"{abc}","status":"running","ip_configured":"10.211.55.12","name":"mactions-abc"}]
      """
    XCTAssertEqual(ParallelsCLI().parseIP(from: out), "10.211.55.12")
  }

  func testParseIPParallelsIgnoresTextDumpAndUnleased() {
    XCTAssertNil(ParallelsCLI().parseIP(from: "ip=10.0.0.5/255.255.255.0 gw=10.0.0.1"))
    XCTAssertNil(ParallelsCLI().parseIP(from: #"[{"ip_configured":"-"}]"#))
    XCTAssertNil(ParallelsCLI().parseIP(from: #"[{"ip_configured":""}]"#))
  }

  func testParseIPUTMRejectsOutOfRangeMaskAndApipa() {
    XCTAssertNil(UTMCLI().parseIP(from: "999.1.1.1"))
    XCTAssertNil(UTMCLI().parseIP(from: "version 2.334.0 build"))
    XCTAssertNil(UTMCLI().parseIP(from: "169.254.10.5"))         // APIPA link-local
    XCTAssertNil(UTMCLI().parseIP(from: "255.255.255.0"))        // netmask/broadcast
    XCTAssertNil(UTMCLI().parseIP(from: "0.0.0.0\n"))            // pre-lease placeholder
    XCTAssertEqual(UTMCLI().parseIP(from: "192.168.64.7"), "192.168.64.7")
  }

  // MARK: Clone naming + factory

  func testCloneNameCarriesMactionsPrefix() {
    let p = WindowsVMProvider(id: "host-9f2", baseImage: "base")
    XCTAssertEqual(p.cloneName, "mactions-host-9f2")
  }

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
    let cli = WindowsVMProviderFactory.detectInstalledCLI()
    if let cli {
      XCTAssertTrue(
        FileManager.default.isExecutableFile(atPath: cli.executable),
        "detected CLI must point at a real executable")
    } else {
      XCTAssertNil(cli)
    }
  }

  func testDetectFreeFirstCLIPrefersUTMOrIsNilWhenNoneInstalled() {
    let cli = WindowsVMProviderFactory.detectFreeFirstCLI()
    if let cli {
      XCTAssertTrue(
        FileManager.default.isExecutableFile(atPath: cli.executable),
        "free-first CLI must point at a real executable")
      let utmctl = "/Applications/UTM.app/Contents/MacOS/utmctl"
      if FileManager.default.isExecutableFile(atPath: utmctl) {
        XCTAssertTrue(cli is UTMCLI, "UTM present -> must prefer the free UTM backend")
      }
    } else {
      XCTAssertNil(cli)
    }
  }

  // MARK: Teardown guard

  func testStopIsIdempotentAndClearsRunning() {
    // `stop()` tears the clone down via a (here non-existent) CLI path, which is
    // harmless. The `tornDown` guard means a second `stop()` is a safe no-op.
    let p = WindowsVMProvider(
      id: "abc", baseImage: "base",
      cli: ParallelsCLI(executable: "/nonexistent/prlctl"),
      stopSettleTimeout: 0.05, stopPollInterval: 0.01)
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
