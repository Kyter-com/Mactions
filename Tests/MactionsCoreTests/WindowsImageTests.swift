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

  // MARK: GA-selection allowlist parity (Swift <-> the prepare-windows-image script)

  /// The GA-major allowlist + the non-base title-substring excludes are hand-
  /// maintained in BOTH `WindowsImage` (Swift) and `scripts/prepare-windows-image`
  /// (Python). They MUST stay identical or the app's update nudge and the script's
  /// actual image selection silently disagree (one builds/accepts a major the
  /// other rejects). This is the drift guard the bump-one-forget-the-other failure
  /// mode needs — same spirit as `testEveryConverterFormulaIsADistinctRealHomebrewArg`.
  func testGAAllowlistAndExcludesMatchThePrepareScript() {
    // #filePath is the absolute compile-time path, so this resolves regardless of cwd.
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/MactionsCoreTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
    let scriptURL = repoRoot.appendingPathComponent("scripts/prepare-windows-image")
    guard let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
      return XCTFail("could not read \(scriptURL.path) to check GA-allowlist parity")
    }

    // ALLOWED_MAJORS = {22000, 22621, ...} — one line; pull the ints between { }.
    guard
      let majorsLine = script.split(separator: "\n").first(where: {
        $0.contains("ALLOWED_MAJORS") && $0.contains("{")
      }),
      let open = majorsLine.firstIndex(of: "{"),
      let close = majorsLine.firstIndex(of: "}")
    else {
      return XCTFail("couldn't locate ALLOWED_MAJORS = {…} in prepare-windows-image")
    }
    let scriptMajors = Set(
      majorsLine[majorsLine.index(after: open)..<close]
        .split(separator: ",")
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    XCTAssertEqual(
      scriptMajors, WindowsImage.knownGAMajors,
      "knownGAMajors drifted from the script's ALLOWED_MAJORS — bump BOTH together")

    // EXCLUDE = ( "insider", …, "update for windows 11 (" ) — spans lines, and one
    // entry contains a '(', so scan the quoted strings between EXCLUDE=( and the
    // first ')' (no ')' appears inside the strings).
    guard let exStart = script.range(of: "EXCLUDE = (") else {
      return XCTFail("couldn't locate EXCLUDE = (…) in prepare-windows-image")
    }
    let afterExclude = script[exStart.upperBound...]
    guard let exEnd = afterExclude.firstIndex(of: ")") else {
      return XCTFail("unterminated EXCLUDE tuple in prepare-windows-image")
    }
    var scriptExcludes: [String] = []
    var inString = false
    var current = ""
    for ch in afterExclude[..<exEnd] {
      if ch == "\"" {
        if inString { scriptExcludes.append(current); current = "" }
        inString.toggle()
      } else if inString {
        current.append(ch)
      }
    }
    XCTAssertEqual(
      Set(scriptExcludes), Set(WindowsImage.nonBaseTitleSubstrings),
      "nonBaseTitleSubstrings drifted from the script's EXCLUDE — bump BOTH together")
  }

  // MARK: Maintenance reason (the "does the base need a rebuild, and why?" core)

  private var cur: Int { WindowsImage.currentProvisioningRecipeVersion }

  func testMaintenanceReasonUpToDate() {
    let r = WindowsImage.maintenanceReason(
      recordedBuild: "26200.8524", recordedRecipe: cur, latestBuild: "26200.8524")
    XCTAssertEqual(r, .upToDate)
    XCTAssertFalse(r.needsRebuild)
    XCTAssertNil(WindowsImage.maintenanceNotice(for: r))
  }

  func testMaintenanceReasonOSBuildOnly() {
    let r = WindowsImage.maintenanceReason(
      recordedBuild: "26200.8000", recordedRecipe: cur, latestBuild: "26200.8524")
    XCTAssertEqual(r, .osBuildAvailable(latest: "26200.8524"))
    XCTAssertTrue(r.needsRebuild)
    XCTAssertEqual(WindowsImage.maintenanceNotice(for: r)?.contains("26200.8524"), true)
  }

  func testMaintenanceReasonRecipeOnly() {
    // Same OS build, older recipe → the NEW dimension this feature adds (e.g. the
    // base was built before the MinGit→PortableGit/bash bump).
    let r = WindowsImage.maintenanceReason(
      recordedBuild: "26200.8524", recordedRecipe: cur - 1, latestBuild: "26200.8524")
    XCTAssertEqual(r, .provisioningOutdated)
    XCTAssertTrue(r.needsRebuild)
  }

  func testMaintenanceReasonBoth() {
    let r = WindowsImage.maintenanceReason(
      recordedBuild: "26200.8000", recordedRecipe: cur - 1, latestBuild: "26200.8524")
    XCTAssertEqual(r, .both(latest: "26200.8524"))
    XCTAssertTrue(r.needsRebuild)
  }

  func testMaintenanceReasonNilRecipeIsStale() {
    // A base built before recipe-versioning (no windows-base.recipe) → treated as
    // stale, since those predate the bash/PortableGit fix.
    let r = WindowsImage.maintenanceReason(
      recordedBuild: "26200.8524", recordedRecipe: nil, latestBuild: "26200.8524")
    XCTAssertEqual(r, .provisioningOutdated)
  }

  func testMaintenanceReasonNoNetworkSuppressesOSClaimButNotRecipe() {
    // latestBuild nil (offline / check not run): never falsely claim an OS update…
    XCTAssertEqual(
      WindowsImage.maintenanceReason(
        recordedBuild: "26200.8000", recordedRecipe: cur, latestBuild: nil),
      .upToDate)
    // …but recipe staleness is a local comparison, so it still surfaces.
    XCTAssertEqual(
      WindowsImage.maintenanceReason(
        recordedBuild: "26200.8000", recordedRecipe: cur - 1, latestBuild: nil),
      .provisioningOutdated)
  }

  func testMaintenanceReasonNotBuilt() {
    for build in [nil, "", "   "] as [String?] {
      let r = WindowsImage.maintenanceReason(
        recordedBuild: build, recordedRecipe: nil, latestBuild: "26200.8524")
      XCTAssertEqual(r, .notBuilt)
      XCTAssertFalse(r.needsRebuild)
      XCTAssertNil(WindowsImage.maintenanceNotice(for: r))
    }
  }

  func testBaseImageRecipeFileLivesAtMactionsRootNotUnderRuns() {
    let file = WindowsImage.baseImageRecipeFile()
    XCTAssertEqual(file.lastPathComponent, "windows-base.recipe")
    XCTAssertEqual(file.deletingLastPathComponent().path, HostCleanup.mactionsRoot().path)
    XCTAssertFalse(file.path.contains("/runs/"))
  }

  // MARK: Recipe-version parity (Swift <-> the prepare-windows-image script)

  /// `WindowsImage.currentProvisioningRecipeVersion` (the comparison value) MUST
  /// equal `PROVISIONING_RECIPE_VERSION` in `scripts/prepare-windows-image` (the
  /// authority stamped into the base). If they drift, the app either never nudges
  /// for a real recipe change or nags forever after a rebuild. Same drift-guard
  /// spirit as the GA-allowlist parity test above.
  func testRecipeVersionConstantMatchesPrepareScript() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let scriptURL = repoRoot.appendingPathComponent("scripts/prepare-windows-image")
    guard let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
      return XCTFail("could not read \(scriptURL.path) to check recipe-version parity")
    }
    guard
      let line = script.split(separator: "\n").first(where: {
        $0.hasPrefix("PROVISIONING_RECIPE_VERSION=")
      })
    else {
      return XCTFail("couldn't locate PROVISIONING_RECIPE_VERSION=<int> in prepare-windows-image")
    }
    let raw = String(line.dropFirst("PROVISIONING_RECIPE_VERSION=".count))
      .trimmingCharacters(in: .whitespaces)
    guard let scriptVersion = Int(raw) else {
      return XCTFail("PROVISIONING_RECIPE_VERSION is not an int: \(line)")
    }
    XCTAssertEqual(
      scriptVersion, WindowsImage.currentProvisioningRecipeVersion,
      "currentProvisioningRecipeVersion drifted from PROVISIONING_RECIPE_VERSION — bump BOTH together")
  }

  /// BASE.md decision test: 7-Zip is a convenience tool, not a runner/OS
  /// semantic — and its old install (recipe ≤v11) was pinned to a 404-able URL,
  /// non-fatal, and never on PATH, so bases silently varied in whether they had
  /// it at all. Recipe v12 removed it; this guard keeps the install (and its
  /// flaky pinned download) from quietly returning. Workflows that need 7-Zip
  /// install it themselves — see PARITY.md. (PortableGit being a "7-Zip
  /// self-extractor" is fine: the SFX is self-contained and needs no installed
  /// 7-Zip.)
  func testBootstrapDoesNotInstallSevenZip() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrapURL = repoRoot.appendingPathComponent("scripts/bootstrap.ps1")
    guard let script = try? String(contentsOf: bootstrapURL, encoding: .utf8) else {
      return XCTFail("could not read \(bootstrapURL.path) to check the 7-Zip removal")
    }
    XCTAssertFalse(
      script.contains("7-zip.org"),
      "bootstrap.ps1 must not download 7-Zip — it fails the BASE.md decision test (removed in recipe v12)")
    XCTAssertFalse(
      script.contains("Installing 7-Zip"),
      "bootstrap.ps1 must not install 7-Zip — workflows install it themselves (PARITY.md)")
  }

  /// GitHub-hosted Windows images set the LocalMachine execution policy to
  /// Unrestricted. Mactions keeps the same narrow scope/value so explicit
  /// `shell: powershell` steps can run the runner's temporary wrapper script
  /// without baking extra tools into the image.
  func testBootstrapSetsHostedWindowsPowerShellExecutionPolicyBeforeSentinel() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrapURL = repoRoot.appendingPathComponent("scripts/bootstrap.ps1")
    guard let script = try? String(contentsOf: bootstrapURL, encoding: .utf8) else {
      return XCTFail("could not read \(bootstrapURL.path) to check PowerShell policy parity")
    }

    let policyCommand =
      "Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force"
    guard let policyRange = script.range(of: policyCommand) else {
      return XCTFail("bootstrap.ps1 must set LocalMachine execution policy to Unrestricted")
    }
    guard
      let sentinelRange = script.range(
        of: "New-Item -ItemType File -Force -Path (Join-Path $RunnerRoot '.mactions-provisioned')")
    else {
      return XCTFail("could not locate the provisioning sentinel write in bootstrap.ps1")
    }

    XCTAssertLessThan(
      policyRange.lowerBound.utf16Offset(in: script),
      sentinelRange.lowerBound.utf16Offset(in: script),
      "execution policy must be applied before the base is stamped provisioned")
  }

  /// Both launchers run bootstrap.ps1 with `-ExecutionPolicy Bypass`, so the
  /// Process scope overrides LocalMachine and Set-ExecutionPolicy raises a
  /// statement-terminating "ExecutionPolicyOverride" SecurityException AFTER
  /// persisting the value. Under $ErrorActionPreference='Stop' an unhandled
  /// override killed bootstrap before the sentinel (live base-build failure,
  /// 2026-06-05). Guard the handling: the expected override must be tolerated
  /// (try/catch on SecurityException) AND the outcome must be verified via
  /// Get-ExecutionPolicy so a genuine write failure still fails the build.
  func testBootstrapToleratesExecutionPolicyOverrideAndVerifiesItPersisted() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrapURL = repoRoot.appendingPathComponent("scripts/bootstrap.ps1")
    guard let script = try? String(contentsOf: bootstrapURL, encoding: .utf8) else {
      return XCTFail("could not read \(bootstrapURL.path) to check the override handling")
    }

    // Assert the exact try/catch adjacency — not just that a catch appears
    // somewhere later — so a refactor can't leave the policy line bare while a
    // SecurityException catch on some other try still satisfies the grep.
    let guardedPolicy = """
      try {
        Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force
      } catch [System.Security.SecurityException] {
      """
    guard let catchRange = script.range(of: guardedPolicy) else {
      return XCTFail(
        "bootstrap.ps1 must wrap the Set-ExecutionPolicy parity write in a try whose catch "
          + "tolerates the expected ExecutionPolicyOverride SecurityException — without it, the "
          + "Bypass launcher's Process-scope override kills bootstrap before the sentinel")
    }

    // Swallowing the error is only safe because the outcome is re-checked: the
    // LocalMachine value must be read back AND a mismatch must fail the build.
    let verifyRead = "Get-ExecutionPolicy -Scope LocalMachine"
    guard let verifyRange = script.range(of: verifyRead) else {
      return XCTFail(
        "bootstrap.ps1 must verify the LocalMachine policy persisted after tolerating the override")
    }
    XCTAssertLessThan(
      catchRange.lowerBound.utf16Offset(in: script),
      verifyRange.lowerBound.utf16Offset(in: script),
      "the persisted-policy verification must follow the tolerated override")

    let verifyGuard = """
      if ($lmPolicy -ne 'Unrestricted') {
        throw
      """
    XCTAssertNotNil(
      script.range(of: verifyGuard),
      "the read-back must throw on mismatch — a verify that never fails would let a "
        + "non-parity base be stamped provisioned and snapshotted")
  }

  /// GitHub-hosted Windows images enable the OS-level Win32 long-path registry
  /// switch in Configure-BaseImage.ps1. Mactions mirrors that exact OS setting
  /// (without changing Git core.longpaths, which hosted Git does not set) so
  /// post-checkout tooling can use deep paths before the base is stamped valid.
  func testBootstrapEnablesHostedWindowsLongPathsBeforeSentinel() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrapURL = repoRoot.appendingPathComponent("scripts/bootstrap.ps1")
    guard let script = try? String(contentsOf: bootstrapURL, encoding: .utf8) else {
      return XCTFail("could not read \(bootstrapURL.path) to check long-path parity")
    }

    let longPathCommand =
      "Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem' `\n  -Name 'LongPathsEnabled' -Value 1"
    guard let longPathRange = script.range(of: longPathCommand) else {
      return XCTFail("bootstrap.ps1 must enable the hosted Windows LongPathsEnabled registry value")
    }
    guard
      let sentinelRange = script.range(
        of: "New-Item -ItemType File -Force -Path (Join-Path $RunnerRoot '.mactions-provisioned')")
    else {
      return XCTFail("could not locate the provisioning sentinel write in bootstrap.ps1")
    }

    XCTAssertLessThan(
      longPathRange.lowerBound.utf16Offset(in: script),
      sentinelRange.lowerBound.utf16Offset(in: script),
      "long-path parity must be applied before the base is stamped provisioned")

    XCTAssertNotNil(
      script.range(of: "Get-ItemPropertyValue -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem' `\n  -Name 'LongPathsEnabled'"),
      "bootstrap.ps1 must verify LongPathsEnabled after writing it")
    XCTAssertNil(
      script.range(of: "git config --system core.longpaths"),
      "Mactions should not set Git core.longpaths as part of this parity change; hosted Git does not set it")
    XCTAssertNil(
      script.range(of: "git config --global core.longpaths"),
      "Mactions should not set Git core.longpaths as part of this parity change; hosted Git does not set it")
  }

  /// Hosted Install-Git.ps1 does more than install Git: it sets system
  /// safe.directory, disables interactive GCM prompts, and seeds known_hosts for
  /// GitHub/Azure DevOps SSH remotes. Mactions keeps its PortableGit installer
  /// for unattended ARM64 reliability, but mirrors those post-install semantics.
  func testBootstrapMirrorsHostedGitPostInstallSemantics() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrapURL = repoRoot.appendingPathComponent("scripts/bootstrap.ps1")
    guard let script = try? String(contentsOf: bootstrapURL, encoding: .utf8) else {
      return XCTFail("could not read \(bootstrapURL.path) to check Git post-install parity")
    }

    XCTAssertNotNil(
      script.range(of: "config --system --add safe.directory '*'"),
      "bootstrap.ps1 must mirror hosted Git's system safe.directory setting")
    XCTAssertNotNil(
      script.range(of: "[Environment]::SetEnvironmentVariable('GCM_INTERACTIVE', 'Never', 'Machine')"),
      "bootstrap.ps1 must disable interactive Git Credential Manager prompts machine-wide")
    XCTAssertNotNil(
      script.range(of: "ssh-keyscan.exe"),
      "bootstrap.ps1 must use Git's ssh-keyscan to seed known_hosts like hosted Windows")
    XCTAssertNotNil(
      script.range(of: "-t rsa,ecdsa,ed25519 github.com"),
      "bootstrap.ps1 must seed GitHub SSH host keys")
    XCTAssertNotNil(
      script.range(of: "-t rsa ssh.dev.azure.com"),
      "bootstrap.ps1 must seed Azure DevOps SSH host keys")
    XCTAssertNotNil(
      script.range(of: "C:\\ProgramData\\ssh\\ssh_known_hosts"),
      "bootstrap.ps1 must write the system OpenSSH known_hosts file")
    XCTAssertNotNil(
      script.range(of: "etc\\ssh\\ssh_known_hosts"),
      "bootstrap.ps1 must write Git for Windows' bundled OpenSSH known_hosts file")
    XCTAssertNotNil(
      script.range(of: "config --system --get-all safe.directory"),
      "bootstrap.ps1 must verify the system safe.directory value before writing the sentinel")
    XCTAssertNotNil(
      script.range(of: "[Environment]::GetEnvironmentVariable('GCM_INTERACTIVE', 'Machine')"),
      "bootstrap.ps1 must verify GCM_INTERACTIVE before writing the sentinel")
  }

  /// Recipe v13: Git must land at the hosted layout — C:\Program Files\Git —
  /// so workflows hardcoding hosted paths (bash.EXE, usr\bin tools) resolve on
  /// a Mactions runner, and the machine PATH must carry the same Git dirs
  /// hosted's install produces: \cmd + the mingw \bin + \usr\bin (the
  /// installer's PathOption=CmdTools — "Git and the optional Unix tools") plus
  /// \bin (Install-Git.ps1's Add-MachinePathItem). usr\bin is what makes
  /// sed/awk/grep resolve from pwsh/cmd steps on hosted (issue #37 V4) —
  /// appended, so System32's find/sort still win, same as hosted. Also guards
  /// the PS 5.1 Start-Process pitfall: -ArgumentList is joined WITHOUT
  /// quoting, so the SFX -o target (now space-containing) must be
  /// embedded-quoted or it splits into two argv tokens and Git silently lands
  /// at "C:\Program".
  func testBootstrapInstallsGitAtHostedProgramFilesLayout() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrapURL = repoRoot.appendingPathComponent("scripts/bootstrap.ps1")
    guard let script = try? String(contentsOf: bootstrapURL, encoding: .utf8) else {
      return XCTFail("could not read \(bootstrapURL.path) to check the Git install layout")
    }

    XCTAssertNotNil(
      script.range(of: "$gitDir = Join-Path $env:ProgramFiles 'Git'"),
      "PortableGit must extract to C:\\Program Files\\Git — the hosted layout")
    XCTAssertNil(
      script.range(of: "'C:\\Git'"),
      "the pre-v13 C:\\Git install root must not return — hardcoded hosted paths would break again")
    XCTAssertNotNil(
      script.range(of: "-o`\"$gitDir`\""),
      "the SFX -o<dir> argument must be embedded-quoted (PS 5.1 Start-Process does not quote args with spaces)")
    XCTAssertNotNil(
      script.range(of: "Join-Path $env:ProgramFiles 'Git\\cmd\\git.exe'"),
      "the sentinel gate must require git.exe at the hosted location")
    XCTAssertNotNil(
      script.range(of: "Join-Path $env:ProgramFiles 'Git\\bin\\bash.exe'"),
      "the sentinel gate must require bash.exe at the hosted location")
    // The machine-PATH append must cover the full hosted composition: cmd, bin,
    // the mingw bin dir (clangarm64 on ARM64 payloads), and usr\bin.
    XCTAssertNotNil(
      script.range(of: "foreach ($p in $gitPathDirs)"),
      "the machine-PATH append must iterate the hosted Git dir set")
    XCTAssertNotNil(
      script.range(of: "$gitUsrBin = Join-Path $gitDir 'usr\\bin'"),
      "usr\\bin must join the machine PATH — hosted's PathOption=CmdTools puts it there, making sed/awk/grep resolve from pwsh/cmd steps")
    XCTAssertNotNil(
      script.range(of: "@('clangarm64', 'mingw64')"),
      "the mingw bin dir must be detected for both ARM64 (clangarm64) and legacy (mingw64) payload layouts")
  }

  /// Recipe v13: UAC must mirror hosted's Disable-UserAccessControl EXACTLY —
  /// ConsentPromptBehaviorAdmin=0 with EnableLUA left at 1. Recipes ≤v12 set
  /// EnableLUA=0, which broke every UWP/MSIX/Store launch ("This app can't be
  /// activated when UAC is disabled") — a failure hosted does not have. The
  /// full admin token comes from the MactionsRunOnce task's -RunLevel Highest,
  /// not from killing UAC.
  func testBootstrapMirrorsHostedUACPolicyBeforeSentinel() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrapURL = repoRoot.appendingPathComponent("scripts/bootstrap.ps1")
    guard let script = try? String(contentsOf: bootstrapURL, encoding: .utf8) else {
      return XCTFail("could not read \(bootstrapURL.path) to check UAC parity")
    }

    guard
      let writeRange = script.range(of: "-Name 'ConsentPromptBehaviorAdmin' -Value 0 -Force")
    else {
      return XCTFail("bootstrap.ps1 must set ConsentPromptBehaviorAdmin=0 (hosted's exact UAC write)")
    }
    XCTAssertNil(
      script.range(of: "EnableLUA -Value"),
      "bootstrap.ps1 must NOT touch EnableLUA — hosted leaves UAC on; the task's RunLevel Highest supplies the admin token")
    XCTAssertNotNil(
      script.range(of: "-Name 'ConsentPromptBehaviorAdmin'", range: writeRange.upperBound..<script.endIndex),
      "bootstrap.ps1 must read ConsentPromptBehaviorAdmin back to verify it persisted")
    XCTAssertNotNil(
      script.range(of: "-RunLevel Highest"),
      "the MactionsRunOnce task must keep -RunLevel Highest — with UAC on it is the only source of the full admin token")
    guard
      let sentinelRange = script.range(
        of: "New-Item -ItemType File -Force -Path (Join-Path $RunnerRoot '.mactions-provisioned')")
    else {
      return XCTFail("could not locate the provisioning sentinel write in bootstrap.ps1")
    }
    XCTAssertLessThan(
      writeRange.lowerBound.utf16Offset(in: script),
      sentinelRange.lowerBound.utf16Offset(in: script),
      "UAC parity must be applied before the base is stamped provisioned")
  }

  /// Recipe v13: hosted runners run UTC (the Azure image default); a fresh
  /// Win11 install from US media defaults to Pacific. The base must set and
  /// verify UTC before the sentinel so time-zone-sensitive steps see the
  /// hosted value.
  func testBootstrapSetsHostedUTCTimeZoneBeforeSentinel() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrapURL = repoRoot.appendingPathComponent("scripts/bootstrap.ps1")
    guard let script = try? String(contentsOf: bootstrapURL, encoding: .utf8) else {
      return XCTFail("could not read \(bootstrapURL.path) to check time-zone parity")
    }

    guard let setRange = script.range(of: "tzutil /s 'UTC'") else {
      return XCTFail("bootstrap.ps1 must set the time zone to UTC (hosted parity)")
    }
    XCTAssertNotNil(
      script.range(of: "tzutil /g"),
      "bootstrap.ps1 must read the time zone back to verify it persisted")
    guard
      let sentinelRange = script.range(
        of: "New-Item -ItemType File -Force -Path (Join-Path $RunnerRoot '.mactions-provisioned')")
    else {
      return XCTFail("could not locate the provisioning sentinel write in bootstrap.ps1")
    }
    XCTAssertLessThan(
      setRange.lowerBound.utf16Offset(in: script),
      sentinelRange.lowerBound.utf16Offset(in: script),
      "time-zone parity must be applied before the base is stamped provisioned")
  }

  /// Recipe v11 (issue #37 V2): bootstrap.ps1 bakes the hosted-parity
  /// runner-IDENTITY env at Machine scope so the per-clone runner service reads
  /// it on every JIT-per-job boot (the VM provider injects nothing but the JIT
  /// disc). ImageOS MUST be a real GitHub whitelist token (win19/win22/win25) —
  /// `win25` is the latest Server proxy for the Win11-ARM base — because a
  /// present-but-invalid value hard-fails whitelist-checking setup-* actions
  /// (worse than unset). Both the SET and the sentinel VERIFY are asserted, same
  /// as the GCM_INTERACTIVE pattern.
  func testBootstrapBakesHostedRunnerIdentityEnv() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrapURL = repoRoot.appendingPathComponent("scripts/bootstrap.ps1")
    guard let script = try? String(contentsOf: bootstrapURL, encoding: .utf8) else {
      return XCTFail("could not read \(bootstrapURL.path) to check runner-identity env parity")
    }

    // SET (Machine scope) — the three identity vars.
    XCTAssertNotNil(
      script.range(of: "[Environment]::SetEnvironmentVariable('ImageOS', 'win25', 'Machine')"),
      "bootstrap.ps1 must bake ImageOS=win25 at Machine scope (latest whitelist-safe proxy)")
    XCTAssertNotNil(
      script.range(of: "[Environment]::SetEnvironmentVariable('RUNNER_TOOL_CACHE', 'C:\\hostedtoolcache\\windows', 'Machine')"),
      "bootstrap.ps1 must bake the hosted RUNNER_TOOL_CACHE path at Machine scope")
    XCTAssertNotNil(
      script.range(of: "[Environment]::SetEnvironmentVariable('AGENT_TOOLSDIRECTORY', 'C:\\hostedtoolcache\\windows', 'Machine')"),
      "bootstrap.ps1 must bake AGENT_TOOLSDIRECTORY equal to RUNNER_TOOL_CACHE (hosted sets both)")

    // ImageOS must NEVER be the literal 'Windows' / a non-whitelist value:
    // whitelist-checking setup-* actions hard-fail on anything outside
    // win19/win22/win25 — strictly worse than leaving it unset.
    XCTAssertNil(
      script.range(of: "SetEnvironmentVariable('ImageOS', 'Windows'"),
      "ImageOS must be a GitHub whitelist token (win19/win22/win25), never the literal 'Windows'")

    // VERIFY before the sentinel — a swallowed SetEnvironmentVariable must fail
    // the build, not ship a base that mis-advertises ImageOS.
    XCTAssertNotNil(
      script.range(of: "[Environment]::GetEnvironmentVariable('ImageOS', 'Machine')"),
      "bootstrap.ps1 must verify ImageOS before writing the sentinel")
    XCTAssertNotNil(
      script.range(of: "[Environment]::GetEnvironmentVariable('RUNNER_TOOL_CACHE', 'Machine')"),
      "bootstrap.ps1 must verify RUNNER_TOOL_CACHE before writing the sentinel")
    XCTAssertNotNil(
      script.range(of: "[Environment]::GetEnvironmentVariable('AGENT_TOOLSDIRECTORY', 'Machine')"),
      "bootstrap.ps1 must verify AGENT_TOOLSDIRECTORY before writing the sentinel")
  }

  /// Hosted Configure-System.ps1 disables Windows Update by policy/service so
  /// background OS updates cannot slow or reboot a job. Mactions mirrors that
  /// deterministic behavior, but not the hosted script's broad root scheduled
  /// task disable because our MactionsRunOnce task lives at the root path.
  func testBootstrapDisablesWindowsUpdateWithoutDisablingRootScheduledTasks() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrapURL = repoRoot.appendingPathComponent("scripts/bootstrap.ps1")
    guard let script = try? String(contentsOf: bootstrapURL, encoding: .utf8) else {
      return XCTFail("could not read \(bootstrapURL.path) to check Windows Update parity")
    }

    guard let policyRange = script.range(of: "Name = 'NoAutoUpdate'; Value = 1") else {
      return XCTFail("bootstrap.ps1 must set the hosted Windows NoAutoUpdate policy")
    }
    XCTAssertNotNil(
      script.range(of: "Name = 'AUOptions'; Value = 1"),
      "bootstrap.ps1 must set hosted Windows AUOptions policy")
    XCTAssertNotNil(
      script.range(of: "Name = 'DoNotConnectToWindowsUpdateInternetLocations'; Value = 1"),
      "bootstrap.ps1 must block Windows Update internet locations like hosted Windows")
    XCTAssertNotNil(
      script.range(of: "Name = 'DisableWindowsUpdateAccess'; Value = 1"),
      "bootstrap.ps1 must set hosted Windows DisableWindowsUpdateAccess policy")
    XCTAssertNotNil(
      script.range(of: "Name = 'AllowTelemetry'; Value = 0"),
      "bootstrap.ps1 must set the hosted Windows telemetry policy")
    XCTAssertNotNil(
      script.range(of: "Set-ItemProperty -Path $wuServicePath -Name Start -Value 4 -Force"),
      "bootstrap.ps1 must disable the Windows Update service start value")
    XCTAssertNotNil(
      script.range(of: "'wuauserv', 'DiagTrack', 'dmwappushservice', 'SysMain', 'gupdate', 'gupdatem'"),
      "bootstrap.ps1 must disable the hosted Windows update/telemetry service subset")

    let taskPaths =
      #"foreach ($taskPath in @('\Microsoft\Windows\UpdateOrchestrator\', '\Microsoft\Windows\WindowsUpdate\'))"#
    XCTAssertNotNil(
      script.range(of: taskPaths),
      "bootstrap.ps1 must only disable Windows Update scheduled-task paths")
    XCTAssertNil(
      script.range(of: #"foreach ($taskPath in @('\',"#),
      "bootstrap.ps1 must not disable the root scheduled-task path; MactionsRunOnce lives there")
    XCTAssertNil(
      script.range(of: #"Get-ScheduledTask -TaskPath '\'"#),
      "bootstrap.ps1 must not disable root scheduled tasks")

    guard
      let sentinelRange = script.range(
        of: "New-Item -ItemType File -Force -Path (Join-Path $RunnerRoot '.mactions-provisioned')")
    else {
      return XCTFail("could not locate the provisioning sentinel write in bootstrap.ps1")
    }
    XCTAssertLessThan(
      policyRange.lowerBound.utf16Offset(in: script),
      sentinelRange.lowerBound.utf16Offset(in: script),
      "Windows Update policy must be applied before the base is stamped provisioned")

    let verifyNoAutoUpdate = "NoAutoUpdate is '$noAutoUpdate' after policy write (expected 1)"
    guard let verifyRange = script.range(of: verifyNoAutoUpdate) else {
      return XCTFail("bootstrap.ps1 must verify NoAutoUpdate before writing the sentinel")
    }
    XCTAssertLessThan(
      verifyRange.lowerBound.utf16Offset(in: script),
      sentinelRange.lowerBound.utf16Offset(in: script),
      "Windows Update policy verification must happen before the provisioning sentinel")
    XCTAssertNotNil(
      script.range(of: "DisableWindowsUpdateAccess is '$disableWUAccess' after policy write (expected 1)"),
      "bootstrap.ps1 must verify DisableWindowsUpdateAccess after writing it")
    XCTAssertNotNil(
      script.range(of: "wuauserv Start is '$wuStart' after service disable (expected 4)"),
      "bootstrap.ps1 must verify wuauserv is disabled after writing it")
    XCTAssertNotNil(
      script.range(of: "AllowTelemetry is '$telemetry' after policy write (expected 0)"),
      "bootstrap.ps1 must verify telemetry policy after writing it")
  }

  /// Hosted Configure-WindowsDefender.ps1 disables Defender scan/monitoring
  /// settings and excludes the job disks. Mactions mirrors that deterministic
  /// CI behavior best-effort, but keeps the upstream Win11-ARM exception: do not
  /// set the BlockAtFirstSeen preference because Defender remediates it during
  /// image build on that platform.
  func testBootstrapAppliesHostedWindowsDefenderBestEffortBeforeSentinel() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrapURL = repoRoot.appendingPathComponent("scripts/bootstrap.ps1")
    guard let script = try? String(contentsOf: bootstrapURL, encoding: .utf8) else {
      return XCTFail("could not read \(bootstrapURL.path) to check Defender parity")
    }

    guard let defenderRange = script.range(of: "Set-MpPreference @preference -ErrorAction Stop")
    else {
      return XCTFail("bootstrap.ps1 must apply hosted Windows Defender preferences")
    }
    guard
      let sentinelRange = script.range(
        of: "New-Item -ItemType File -Force -Path (Join-Path $RunnerRoot '.mactions-provisioned')")
    else {
      return XCTFail("could not locate the provisioning sentinel write in bootstrap.ps1")
    }

    XCTAssertLessThan(
      defenderRange.lowerBound.utf16Offset(in: script),
      sentinelRange.lowerBound.utf16Offset(in: script),
      "Defender parity must be applied before the base is stamped provisioned")

    for required in [
      "@{ DisableArchiveScanning = $true }",
      "@{ DisableAutoExclusions = $true }",
      "@{ DisableBehaviorMonitoring = $true }",
      "@{ DisableCatchupFullScan = $true }",
      "@{ DisableCatchupQuickScan = $true }",
      "@{ DisableIntrusionPreventionSystem = $true }",
      "@{ DisableRealtimeMonitoring = $true }",
      "@{ DisableScriptScanning = $true }",
      "@{ DisableIOAVProtection = $true }",
      "@{ DisablePrivacyMode = $true }",
      "@{ DisableScanningNetworkFiles = $true }",
      "@{ MAPSReporting = 0 }",
      "@{ PUAProtection = 0 }",
      "@{ SignatureDisableUpdateOnStartupWithoutEngine = $true }",
      "@{ SubmitSamplesConsent = 2 }",
      "@{ ScanAvgCPULoadFactor = 5; ExclusionPath = @('D:\\', 'C:\\') }",
      "@{ ScanScheduleDay = 8 }",
      "@{ EnableControlledFolderAccess = 'Disable' }",
      "@{ EnableNetworkProtection = 'Disabled' }",
      "ForceDefenderPassiveMode",
      "$defenderPreference = Get-MpPreference",
      "Hosted-parity Defender policy did not fully persist",
      "Defender parity is best-effort like actions/runner-images",
    ] {
      XCTAssertNotNil(
        script.range(of: required),
        "bootstrap.ps1 is missing hosted Defender parity fragment: \(required)")
    }

    XCTAssertNil(
      script.range(of: "throw \"Hosted-parity Defender policy"),
      "Defender preference persistence must not block the provisioning sentinel")
    XCTAssertNil(
      script.range(of: "throw \"Set-MpPreference failed"),
      "Set-MpPreference failures must be warnings, matching actions/runner-images' best-effort behavior")
    XCTAssertNil(
      script.range(of: "throw 'Set-MpPreference is not available"),
      "Missing Set-MpPreference should not block an otherwise usable runner base")

    XCTAssertNil(
      script.range(of: "@{ DisableBlockAtFirstSeen"),
      "bootstrap.ps1 must keep the official Win11-ARM exception and not set DisableBlockAtFirstSeen")
  }

  func testFusionBaseCopiesGuestBootstrapLogBeforeNoSentinelFailure() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let scriptURL = repoRoot.appendingPathComponent("scripts/fusion-windows-base")
    guard let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
      return XCTFail("could not read \(scriptURL.path) to check guest-log capture")
    }

    for required in [
      "GUEST_BOOTSTRAP_LOG=\"${MACTIONS_ROOT}/logs/base-build-bootstrap.log\"",
      "copy_guest_bootstrap_log()",
      "copy_guest_bootstrap_log \"$GUEST_BOOTSTRAP_LOG\" || true",
      "Guest log (if captured): ${GUEST_BOOTSTRAP_LOG}",
      "rm -f \"${MACTIONS_ROOT}/logs/base-build-bootstrap.log\"",
      "rm -f \"${MACTIONS_ROOT}/logs/base-build-bootstrap-timeout.log\"",
    ] {
      XCTAssertNotNil(
        script.range(of: required),
        "fusion-windows-base is missing guest-log capture fragment: \(required)")
    }

    guard
      let liveCopyRange = script.range(
        of: "A bootstrap script can fail and power off before the sentinel"),
      let noSentinelFailureRange = script.range(of: "guest powered off WITHOUT the provisioning sentinel")
    else {
      return XCTFail("could not locate live guest-log copy or no-sentinel failure")
    }
    XCTAssertLessThan(
      liveCopyRange.lowerBound.utf16Offset(in: script),
      noSentinelFailureRange.lowerBound.utf16Offset(in: script),
      "fusion-windows-base must copy bootstrap.log while the VM is still running, before guest-ops disappear")
  }

  // MARK: Base health stamp (informational; written by fusion-windows-base)

  func testBaseHealthFileLivesAtMactionsRootNotUnderRuns() {
    let file = WindowsImage.baseHealthFile()
    XCTAssertEqual(file.lastPathComponent, "windows-base.health")
    XCTAssertEqual(file.deletingLastPathComponent().path, HostCleanup.mactionsRoot().path)
    XCTAssertFalse(file.path.contains("/runs/"))
  }

  /// Parses the exact `key=value` shape fusion-windows-base writes (incl. the
  /// optional `guest_log=` line), tolerates unknown keys (forward-compatible),
  /// and returns `nil` for an empty/garbage file rather than a hollow value.
  func testParseBaseHealth() {
    let full = """
      built=2026-06-03T19:42:10Z
      elapsed_secs=1820
      tools=up
      guest_log=/Users/x/.mactions/logs/base-build-bootstrap.log
      """
    let health = WindowsImage.parseBaseHealth(full)
    XCTAssertEqual(health?.builtAt, "2026-06-03T19:42:10Z")
    XCTAssertEqual(health?.elapsedSecs, 1820)
    XCTAssertEqual(health?.toolsUp, true)
    XCTAssertEqual(health?.guestLogPath, "/Users/x/.mactions/logs/base-build-bootstrap.log")

    // The guest-log copy is best-effort — its line may simply be absent.
    let noLog = WindowsImage.parseBaseHealth("built=2026-06-03T19:42:10Z\nelapsed_secs=90\ntools=up\n")
    XCTAssertEqual(noLog?.guestLogPath, nil)
    XCTAssertEqual(noLog?.toolsUp, true)

    // Unknown keys are ignored, known ones still land.
    let future = WindowsImage.parseBaseHealth("tools=up\nshiny_new_key=42\n")
    XCTAssertEqual(future?.toolsUp, true)

    // Garbage / empty → nil, not a hollow all-defaults value.
    XCTAssertNil(WindowsImage.parseBaseHealth(""))
    XCTAssertNil(WindowsImage.parseBaseHealth("no equals signs here\njust words\n"))
  }
}
