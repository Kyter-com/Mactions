import XCTest

@testable import MactionsCore

/// Covers the pure `ps`-output parser (the part that buckets process RSS). The
/// host-stats path uses live Mach calls and isn't unit-tested here.
final class MemorySamplerTests: XCTestCase {
  func testParseProcessRSSBucketsByCommand() {
    let runsRoot = "/Users/me/.mactions/runs"
    // Mimics `ps -axo pid=,rss=,command=`: right-aligned pid + rss, then command.
    let output = """
          1   12345 /Applications/VMware Fusion.app/Contents/Library/vmware-vmx -x /tmp/win.vmx
         42   20000 /Users/me/.mactions/runs/mactions-host-abc/run.sh --jitconfig xyz
        999    5000 /sbin/launchd
        777    8000 /Users/me/.mactions/Mactions
      """
    let r = MemorySampler.parseProcessRSS(output, runsRootPath: runsRoot, ownPID: 777)
    XCTAssertEqual(r.windows, 12345 * 1024)  // vmware-vmx → Windows VM
    XCTAssertEqual(r.runners, 20000 * 1024)  // under runs-root → local runner
    XCTAssertEqual(r.app, 8000 * 1024)  // own pid → this app
  }

  func testParseProcessRSSOwnPIDTakesPrecedenceOverCommandMatch() {
    // Even if our own process command happens to contain the runs-root path, the
    // pid match wins so we never double-count it as a runner.
    let output = "  777  4096 /Users/me/.mactions/runs/whatever Mactions"
    let r = MemorySampler.parseProcessRSS(output, runsRootPath: "/Users/me/.mactions/runs", ownPID: 777)
    XCTAssertEqual(r.app, 4096 * 1024)
    XCTAssertEqual(r.runners, 0)
  }

  func testParseProcessRSSIgnoresGarbage() {
    let r = MemorySampler.parseProcessRSS("\n\nnotanumber blah\n   \n", runsRootPath: "/x", ownPID: 1)
    XCTAssertEqual(r.windows, 0)
    XCTAssertEqual(r.runners, 0)
    XCTAssertEqual(r.app, 0)
  }
}
