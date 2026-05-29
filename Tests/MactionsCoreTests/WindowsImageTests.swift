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

  /// Build a listid.php fixture in the REAL API shape: `response.builds` is an
  /// OBJECT keyed by stringified ints, NOT an array. Each tuple is
  /// (key, title, build, arch, uuid). `created` is filled in deterministically.
  private func buildsFixture(_ rows: [(String, String, String, String, String)]) -> Data {
    let entries =
      rows
      .enumerated()
      .map { i, r in
        let (k, title, build, arch, uuid) = r
        return
          "\"\(k)\":{\"title\":\"\(title)\",\"build\":\"\(build)\",\"arch\":\"\(arch)\",\"created\":\(1_780_000_000 + i),\"uuid\":\"\(uuid)\"}"
      }
      .joined(separator: ",")
    return Data(
      "{\"response\":{\"apiVersion\":\"1.0\",\"builds\":{\(entries)}},\"jsonApiVersion\":\"1.0\"}".utf8
    )
  }

  func testParseBuildsDecodesDictShapeAndKeepsOnlyArm64() {
    // Dict keyed by stringified ints (the shape the live API actually sends).
    let json = buildsFixture([
      ("1", "Windows 11, version 24H2 (arm64)", "26100.1742", "arm64", "aaa-111"),
      ("2", "Windows 11, version 24H2 (amd64)", "26100.1742", "amd64", "bbb-222"),
      ("4", "Cumulative update (arm64)", "26100.1300", "ARM64", "ccc-333"),
    ])
    let builds = WindowsImage.parseBuilds(json)
    XCTAssertEqual(builds.count, 2)  // amd64 row dropped
    // Dict iteration is UNORDERED — assert membership, never position.
    XCTAssertEqual(Set(builds.map(\.uuid)), ["aaa-111", "ccc-333"])  // "ARM64" matched case-insensitively
    XCTAssertEqual(builds.first(where: { $0.uuid == "aaa-111" })?.created, 1_780_000_000)
  }

  func testParseBuildsRejectsTheArrayShapeTheApiNeverSends() {
    // Regression guard: the old `[Row]` decoder accepted this; the dict decoder
    // must NOT — an array decode now fails → []. (This is the bug that shipped.)
    let arrayShape = Data(
      #"{"response":{"builds":[{"title":"Windows 11, version 25H2 (arm64)","build":"26200.1","arch":"arm64","uuid":"z"}]}}"#
        .utf8)
    XCTAssertTrue(WindowsImage.parseBuilds(arrayShape).isEmpty)
  }

  func testParseBuildsReturnsEmptyOnGarbageOrNoBuilds() {
    XCTAssertTrue(WindowsImage.parseBuilds(Data("not json".utf8)).isEmpty)
    XCTAssertTrue(WindowsImage.parseBuilds(Data(#"{"response":{}}"#.utf8)).isEmpty)
    // The REAL empty response is an empty DICT, not an empty array.
    XCTAssertTrue(WindowsImage.parseBuilds(Data(#"{"response":{"builds":{}}}"#.utf8)).isEmpty)
  }

  // MARK: GA / stable-channel selection (the wrong-channel bug)

  func testIsGABaseExcludesInsiderPreviewAndNotYetGA26H1() {
    let json = buildsFixture([
      ("1", "Windows 11 Insider Preview Feature Update (26220.8544)", "26220.8544", "arm64", "insider"),
      ("2", "Preview Update for Windows 11 (28000.2179)", "28000.2179", "arm64", "preview"),
      ("3", "Windows 11, version 26H1 (28000.2113)", "28000.2113", "arm64", "26h1-not-ga"),
      ("4", "Cumulative Update for .NET Framework (26100.1)", "26100.1", "arm64", "dotnet"),
      ("5", "Windows 11, version 25H2 (26200.8524)", "26200.8524", "arm64", "648c682d"),
    ])
    let ga = WindowsImage.parseBuilds(json).filter(WindowsImage.isGABase)
    XCTAssertEqual(ga.map(\.uuid), ["648c682d"])  // only the real GA survives
  }

  func testSelectLatestGAPicksHighestNumericGANotApiOrderNorRawMax() {
    // 26200.8524 (25H2 GA) must beat the lexically/numerically larger 28000.2113
    // (26H1 preview) and the newest-by-date Insider decoy. Order-independent.
    let json = buildsFixture([
      ("1", "Windows 11 Insider Preview (26300.1)", "26300.1", "arm64", "insider-decoy"),
      ("2", "Windows 11, version 26H1 (28000.2113)", "28000.2113", "arm64", "26h1"),
      ("3", "Windows 11, version 25H2 (26200.8524)", "26200.8524", "arm64", "648c682d"),
      ("4", "Windows 11, version 24H2 (26100.793)", "26100.793", "arm64", "24h2"),
    ])
    let chosen = WindowsImage.selectLatestGA(WindowsImage.parseBuilds(json))
    XCTAssertEqual(chosen?.uuid, "648c682d")
    XCTAssertEqual(chosen?.build, "26200.8524")
  }

  func testSelectLatestGAReturnsNilWhenNoStableBuildPresent() {
    // All Insider/preview → nil, so latestBuild() throws rather than shipping a
    // prerelease base image.
    let json = buildsFixture([
      ("1", "Windows 11 Insider Preview Feature Update (26220.8544)", "26220.8544", "arm64", "ins"),
      ("2", "Preview Update for Windows 11 (28000.2179)", "28000.2179", "arm64", "prev"),
    ])
    XCTAssertNil(WindowsImage.selectLatestGA(WindowsImage.parseBuilds(json)))
  }

  // MARK: Converter dependency check

  func testMissingConverterDependenciesMapsBinaryToBrewFormula() {
    // All present -> nothing missing.
    XCTAssertTrue(WindowsImage.missingConverterDependencies(lookup: { _ in true }).isEmpty)
    // None present -> the brew FORMULA names, not the binary names: aria2c→aria2,
    // wimlib-imagex→wimlib, mkisofs→cdrtools, chntpw→its tap. (The old expectation
    // hard-coded the binary names, which is exactly why `brew install aria2c …`
    // failed in the field.)
    let none = WindowsImage.missingConverterDependencies(lookup: { _ in false })
    XCTAssertEqual(none, ["aria2", "cabextract", "wimlib", "cdrtools", "minacle/chntpw/chntpw"])
  }

  func testMissingConverterDependenciesReportsOnlyTheAbsentOnes() {
    let missing = WindowsImage.missingConverterDependencies(lookup: { $0 != "chntpw" })
    XCTAssertEqual(missing, ["minacle/chntpw/chntpw"])
  }

  func testEveryConverterFormulaIsADistinctRealHomebrewArg() {
    // Guard against the shipped bug class: a binary name leaking through as a
    // formula. None of the formulae may equal a binary name that differs from it.
    for dep in WindowsImage.converterDependencies where dep.binary != dep.formula {
      XCTAssertNotEqual(
        dep.binary, dep.formula,
        "\(dep.binary) must map to its real formula, not itself")
    }
    XCTAssertEqual(WindowsImage.brewFormula(for: "aria2c"), "aria2")
    XCTAssertEqual(WindowsImage.brewFormula(for: "wimlib-imagex"), "wimlib")
    XCTAssertEqual(WindowsImage.brewFormula(for: "mkisofs"), "cdrtools")
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
