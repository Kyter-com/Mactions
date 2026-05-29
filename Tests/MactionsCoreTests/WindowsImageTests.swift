import XCTest

@testable import MactionsCore

/// Unit tests for the *pure* logic of the Windows base-image auto-update path:
/// build-id comparison, UUP-dump request/URL construction, listing parsing, and
/// the converter-dependency check. No network, no VM — these pin the shapes and
/// ordering the same way `RunnerInstaller`/`GitHubRequestTests` do.
final class WindowsImageTests: XCTestCase {

  // MARK: Build-id comparison (the "is a newer Windows out?" core)

  func testCompareBuildsNumericNotLexical() {
    // Lexically "26100.9" > "26100.10"; numerically it's older. We must order
    // dotted segments as integers, or we'd miss a real update.
    XCTAssertEqual(WindowsImage.compareBuilds("26100.9", "26100.10"), .orderedAscending)
    XCTAssertEqual(WindowsImage.compareBuilds("26100.10", "26100.9"), .orderedDescending)
    XCTAssertEqual(WindowsImage.compareBuilds("26100.1742", "26100.1742"), .orderedSame)
  }

  func testCompareBuildsMajorSegmentWins() {
    XCTAssertEqual(WindowsImage.compareBuilds("22631.4000", "26100.1"), .orderedAscending)
    XCTAssertEqual(WindowsImage.compareBuilds("26100.1", "22631.4000"), .orderedDescending)
  }

  func testCompareBuildsMissingTrailingSegmentTreatedAsZero() {
    XCTAssertEqual(WindowsImage.compareBuilds("26100", "26100.0"), .orderedSame)
    XCTAssertEqual(WindowsImage.compareBuilds("26100", "26100.1"), .orderedAscending)
  }

  func testUpdateAvailableWhenLatestIsNewer() {
    XCTAssertTrue(WindowsImage.updateAvailable(installed: "26100.1742", latest: "26100.2000"))
    XCTAssertFalse(WindowsImage.updateAvailable(installed: "26100.2000", latest: "26100.1742"))
    XCTAssertFalse(WindowsImage.updateAvailable(installed: "26100.2000", latest: "26100.2000"))
  }

  func testUpdateAvailableWhenNothingBuiltYet() {
    // No recorded image (nil/empty) -> there's always "an update available".
    XCTAssertTrue(WindowsImage.updateAvailable(installed: nil, latest: "26100.1"))
    XCTAssertTrue(WindowsImage.updateAvailable(installed: "   ", latest: "26100.1"))
  }

  // MARK: UUP dump request construction

  func testLatestBuildsRequestShape() {
    let req = WindowsImage.latestBuildsRequest()
    let url = req.url!
    XCTAssertEqual(url.scheme, "https")
    XCTAssertEqual(url.host, "api.uupdump.net")
    XCTAssertEqual(url.path, "/listid.php")
    XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
    XCTAssertEqual(items.first { $0.name == "search" }?.value, "Windows 11 arm64")
    XCTAssertEqual(items.first { $0.name == "sortByDate" }?.value, "1")
  }

  func testLatestBuildsRequestHonorsCustomSearch() {
    let req = WindowsImage.latestBuildsRequest(search: "cumulative arm64")
    let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
    XCTAssertEqual(items.first { $0.name == "search" }?.value, "cumulative arm64")
  }

  // MARK: Listing parsing

  func testParseBuildsKeepsOnlyArm64AndPreservesOrder() {
    let json = """
      {
        "response": {
          "apiVersion": "1.0",
          "builds": [
            {"title": "Feature update to Windows 11 24H2 (arm64)", "build": "26100.1742",
             "arch": "arm64", "uuid": "aaa-111"},
            {"title": "Feature update to Windows 11 24H2 (amd64)", "build": "26100.1742",
             "arch": "amd64", "uuid": "bbb-222"},
            {"title": "Cumulative update (arm64)", "build": "26100.1300",
             "arch": "ARM64", "uuid": "ccc-333"}
          ]
        },
        "jsonApiVersion": "1.0"
      }
      """.data(using: .utf8)!
    let builds = WindowsImage.parseBuilds(json)
    XCTAssertEqual(builds.count, 2)  // amd64 row dropped
    XCTAssertEqual(builds.first?.uuid, "aaa-111")  // newest-first order preserved
    XCTAssertEqual(builds.first?.build, "26100.1742")
    XCTAssertEqual(builds[1].uuid, "ccc-333")  // "ARM64" matches case-insensitively
  }

  func testParseBuildsReturnsEmptyOnGarbageOrNoBuilds() {
    XCTAssertTrue(WindowsImage.parseBuilds(Data("not json".utf8)).isEmpty)
    XCTAssertTrue(WindowsImage.parseBuilds(Data(#"{"response":{}}"#.utf8)).isEmpty)
    XCTAssertTrue(WindowsImage.parseBuilds(Data(#"{"response":{"builds":[]}}"#.utf8)).isEmpty)
  }

  // MARK: Converter dependency check

  func testMissingConverterDependenciesMapsBinaryToBrewFormula() {
    // All present -> nothing missing.
    XCTAssertTrue(WindowsImage.missingConverterDependencies(lookup: { _ in true }).isEmpty)
    // None present -> the brew formula names (wimlib-imagex -> wimlib).
    let none = WindowsImage.missingConverterDependencies(lookup: { _ in false })
    XCTAssertEqual(none, ["aria2c", "cabextract", "wimlib", "chntpw"])
  }

  func testMissingConverterDependenciesReportsOnlyTheAbsentOnes() {
    let missing = WindowsImage.missingConverterDependencies(lookup: { $0 != "chntpw" })
    XCTAssertEqual(missing, ["chntpw"])
  }

  // MARK: Recorded base-image build round-trips off the run-sweep path

  func testBaseImageBuildFileLivesAtMactionsRootNotUnderRuns() {
    // Must survive go-online run sweeps (which wipe runs/), so it's a sibling.
    let file = WindowsImage.baseImageBuildFile()
    XCTAssertEqual(file.lastPathComponent, "windows-base.build")
    XCTAssertEqual(file.deletingLastPathComponent().path, HostCleanup.mactionsRoot().path)
    XCTAssertFalse(file.path.contains("/runs/"))
  }
}
