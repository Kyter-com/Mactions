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

  // MARK: QEMU (mactions-qemu-vm helper) verb shapes + injection

  func testQEMUCLIVerbShapes() {
    // Every verb is `<helper> <verb> <clone>` (clone takes both base + clone).
    // Shape stability is what unit tests pin — the helper itself owns the
    // multi-process QEMU + swtpm orchestration the verbs trigger.
    let cli = QEMUCLI(executable: "/repo/scripts/mactions-qemu-vm",
                     clonesDir: "/state/clones")
    XCTAssertEqual(cli.cloneArgs(base: "win11-runner-base", clone: "mactions-abc"),
      ["clone", "win11-runner-base", "mactions-abc"])
    XCTAssertEqual(cli.startArgs(clone: "mactions-abc"), ["start", "mactions-abc"])
    XCTAssertEqual(cli.stopArgs(clone: "mactions-abc"), ["stop", "mactions-abc"])
    XCTAssertEqual(cli.forceStopArgs(clone: "mactions-abc"), ["stop", "mactions-abc"])
    XCTAssertEqual(cli.deleteArgs(clone: "mactions-abc"), ["delete", "mactions-abc"])
    XCTAssertEqual(cli.statusArgs(clone: "mactions-abc"), ["status", "mactions-abc"])
    XCTAssertTrue(cli.displayName.contains("QEMU"))
  }

  func testQEMUInjectionCopiesConfigFileIntoCloneDir() {
    // QEMU's helper attaches <clone-dir>/config.iso as a real -cdrom on start,
    // so injection is a plain copy to that path. No pre-existence guard needed
    // (the helper creates the clone dir before injection happens).
    let cli = QEMUCLI(executable: "/repo/scripts/mactions-qemu-vm",
                     clonesDir: "/state/clones")
    XCTAssertEqual(cli.cloneBundlePath(clone: "mactions-abc"), "/state/clones/mactions-abc")
    XCTAssertEqual(
      cli.injectionPlan(clone: "mactions-abc", clonePath: nil, configISO: "/tmp/c.iso"),
      .copyConfigFile(target: "/state/clones/mactions-abc/config.iso"))
    XCTAssertEqual(
      cli.injectionPlan(clone: "mactions-abc", clonePath: "/elsewhere", configISO: "/tmp/c.iso"),
      .copyConfigFile(target: "/elsewhere/config.iso"))
  }

  func testQEMUStatusParserMapsHelperOutputs() {
    // The helper prints exactly "running" or "stopped" — assert both parse,
    // and that the substring match doesn't fire false positives on common
    // synonyms.
    let cli = QEMUCLI(executable: "/x", clonesDir: "/y")
    XCTAssertTrue(cli.parseIsStopped(from: "stopped"))
    XCTAssertTrue(cli.parseIsStopped(from: "stopped\n"))
    XCTAssertFalse(cli.parseIsStopped(from: "running"))
    XCTAssertFalse(cli.parseIsStopped(from: ""))
  }

  // MARK: VMware Fusion (mactions-fusion-vm helper) verb shapes + injection

  func testVMwareCLIVerbShapes() {
    // Same `<helper> <verb> <clone>` shape as QEMU — the helper owns the vmrun
    // clone/start/stop/deleteVM orchestration; Swift only pins the arg shapes.
    let cli = VMwareCLI(executable: "/repo/scripts/mactions-fusion-vm",
                        clonesDir: "/state/fusion")
    XCTAssertEqual(cli.cloneArgs(base: "win11-runner-base", clone: "mactions-abc"),
      ["clone", "win11-runner-base", "mactions-abc"])
    XCTAssertEqual(cli.startArgs(clone: "mactions-abc"), ["start", "mactions-abc"])
    XCTAssertEqual(cli.stopArgs(clone: "mactions-abc"), ["stop", "mactions-abc"])
    XCTAssertEqual(cli.forceStopArgs(clone: "mactions-abc"), ["stop", "mactions-abc"])
    XCTAssertEqual(cli.deleteArgs(clone: "mactions-abc"), ["delete", "mactions-abc"])
    XCTAssertEqual(cli.statusArgs(clone: "mactions-abc"), ["status", "mactions-abc"])
    XCTAssertEqual(cli.baseStatusArgs(base: "win11-runner-base"), ["base-status", "win11-runner-base"])
    XCTAssertNil(cli.parseIP(from: "anything"))  // outbound model — no IP discovery
    XCTAssertTrue(cli.displayName.contains("VMware Fusion"))
  }

  func testVMwareInjectionCopiesConfigFileIntoCloneDir() {
    // The helper's `clone` step already wired the clone's sata0:0 CD to
    // <clone-dir>/config.iso, so injection is a plain copy to that path —
    // reusing .copyConfigFile, no new injection plumbing.
    let cli = VMwareCLI(executable: "/repo/scripts/mactions-fusion-vm",
                        clonesDir: "/state/fusion")
    XCTAssertEqual(cli.cloneBundlePath(clone: "mactions-abc"), "/state/fusion/mactions-abc")
    XCTAssertEqual(
      cli.injectionPlan(clone: "mactions-abc", clonePath: nil, configISO: "/tmp/c.iso"),
      .copyConfigFile(target: "/state/fusion/mactions-abc/config.iso"))
    XCTAssertEqual(
      cli.injectionPlan(clone: "mactions-abc", clonePath: "/elsewhere", configISO: "/tmp/c.iso"),
      .copyConfigFile(target: "/elsewhere/config.iso"))
  }

  func testVMwareStatusParserMapsHelperOutputs() {
    // Helper normalizes to exactly "running"/"stopped" (vmrun has no getstate);
    // base-status adds "in-use"/"no-snapshot"/"missing" — only "stopped" is ready.
    let cli = VMwareCLI(executable: "/x", clonesDir: "/y")
    XCTAssertTrue(cli.parseIsStopped(from: "stopped"))
    XCTAssertTrue(cli.parseIsStopped(from: "stopped\n"))
    XCTAssertFalse(cli.parseIsStopped(from: "running"))
    XCTAssertFalse(cli.parseIsStopped(from: "in-use"))
    XCTAssertFalse(cli.parseIsStopped(from: "no-snapshot"))
    XCTAssertFalse(cli.parseIsStopped(from: "missing"))
    XCTAssertFalse(cli.parseIsStopped(from: ""))
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

  func testDetectFreeFirstCLIPrefersFusionThenQEMUThenUTMThenParallels() {
    let cli = WindowsVMProviderFactory.detectFreeFirstCLI()
    guard let cli else { return }  // None installed — vacuously satisfied.
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: cli.executable),
      "free-first CLI must point at a real executable")
    // Free-first ordering: VMware Fusion (free + the PROVEN Win11-ARM backend) >
    // QEMU (headless but can't boot Win11-ARM here) > UTM (free, needs a GUI
    // session) > Parallels (paid). We test which one was picked against what's
    // actually installed on the host.
    let fusionAvailable =
      WindowsVMProviderFactory.fusionHelperPath != nil
      && FileManager.default.isExecutableFile(atPath: WindowsVMProviderFactory.fusionVmrunPath)
    let qemuAvailable =
      WindowsVMProviderFactory.qemuHelperPath != nil
      && FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/qemu-system-aarch64")
    let utmAvailable = FileManager.default.isExecutableFile(
      atPath: "/Applications/UTM.app/Contents/MacOS/utmctl")
    if fusionAvailable {
      XCTAssertTrue(cli is VMwareCLI, "Fusion present -> must prefer it (proven Win11-ARM, free)")
    } else if qemuAvailable {
      XCTAssertTrue(cli is QEMUCLI, "no Fusion, QEMU present -> prefer it (headless, free)")
    } else if utmAvailable {
      XCTAssertTrue(cli is UTMCLI, "no Fusion/QEMU, UTM present -> must prefer UTM (free)")
    } else {
      XCTAssertTrue(cli is ParallelsCLI, "only Parallels installed -> must pick it")
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
