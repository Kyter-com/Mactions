import XCTest

@testable import MactionsCore

/// Pins the pure `FleetPlan` model — the per-`(repo, platform)` config that
/// replaces the old flat globals. The highest-regression bits are `migrate()`
/// (a wrong migration strands an existing user with no fleets after upgrade) and
/// the `Codable` round-trip (a non-`String`-keyed platforms dict would encode to
/// brittle JSON). Mirrors `RunnerOSTests`.
final class FleetPlanTests: XCTestCase {

  // MARK: Migration off the legacy flat keys

  func testMigrateMacOnlyReproducesTheFlatFleet() {
    let plan = FleetPlan.migrate(
      repoFullNames: ["acme/web", "acme/api"],
      oses: [.macOS], labels: ["self-hosted", "macOS", "mactions"],
      runnersPerRepo: 2, windowsImageReady: false, linuxImageReady: false)

    XCTAssertEqual(plan.repos.map(\.id), ["acme/web", "acme/api"])
    let web = plan.repos[0]
    XCTAssertEqual(web.config(for: .macOS)?.count, 2)
    XCTAssertEqual(web.config(for: .macOS)?.labels, ["self-hosted", "macOS", "mactions"])
    XCTAssertEqual(web.config(for: .macOS)?.enabled, true)
    XCTAssertNil(web.config(for: .windows))
    XCTAssertNil(web.config(for: .linux))
    // Every repo gets the same macOS config (the old uniform behavior).
    XCTAssertEqual(plan.repos[1].config(for: .macOS)?.count, 2)
  }

  func testMigrateSkipsWindowsWhenImageNotReady() {
    // Windows selected but its base image isn't built → NOT enabled (mirrors the
    // old goOnline readiness gate, which never spun a Windows fleet without an image).
    let plan = FleetPlan.migrate(
      repoFullNames: ["acme/web"], oses: [.macOS, .windows],
      labels: ["self-hosted", "macOS", "mactions"], runnersPerRepo: 1,
      windowsImageReady: false, linuxImageReady: false)
    XCTAssertNil(plan.repos[0].config(for: .windows))
  }

  func testMigrateEnablesWindowsAndLinuxWhenReady() {
    let plan = FleetPlan.migrate(
      repoFullNames: ["acme/web"], oses: [.macOS, .windows, .linux],
      labels: ["self-hosted", "macOS", "mactions"], runnersPerRepo: 3,
      windowsImageReady: true, linuxImageReady: true)
    let web = plan.repos[0]
    XCTAssertEqual(web.config(for: .windows)?.enabled, true)
    XCTAssertEqual(web.config(for: .windows)?.count, 1)  // migrate reproduces the legacy 1-VM fleet
    XCTAssertEqual(web.config(for: .windows)?.labels, RunnerOS.windows.defaultLabels)
    XCTAssertEqual(web.config(for: .linux)?.labels, RunnerOS.linux.defaultLabels)
    // macOS still honors the per-repo count.
    XCTAssertEqual(web.config(for: .macOS)?.count, 3)
  }

  func testMigrateDefaultPlatformsGatedOnReadiness() {
    // Windows selected but its image isn't built → not seeded as a new-repo
    // default (macOS is always the floor).
    let notReady = FleetPlan.migrate(
      repoFullNames: ["a/b"], oses: [.macOS, .windows], labels: ["self-hosted"],
      runnersPerRepo: 1, windowsImageReady: false, linuxImageReady: false)
    XCTAssertEqual(notReady.defaultPlatforms, ["macOS"])
    // Both ready → both included, in stable RunnerOS.allCases order.
    let ready = FleetPlan.migrate(
      repoFullNames: ["a/b"], oses: [.macOS, .windows, .linux], labels: ["self-hosted"],
      runnersPerRepo: 1, windowsImageReady: true, linuxImageReady: true)
    XCTAssertEqual(ready.defaultPlatforms, ["macOS", "windows", "linux"])
  }

  func testMigrateEmptyLabelsFallBackToDefault() {
    let plan = FleetPlan.migrate(
      repoFullNames: ["acme/web"], oses: [.macOS], labels: [],
      runnersPerRepo: 1, windowsImageReady: false, linuxImageReady: false)
    XCTAssertEqual(plan.repos[0].config(for: .macOS)?.labels, RunnerOS.macOS.defaultLabels)
  }

  func testMigrateIgnoresLegacyCustomLabels() {
    let plan = FleetPlan.migrate(
      repoFullNames: ["acme/web"], oses: [.macOS], labels: ["self-hosted", "custom"],
      runnersPerRepo: 1, windowsImageReady: false, linuxImageReady: false)
    XCTAssertEqual(plan.repos[0].config(for: .macOS)?.labels, RunnerOS.macOS.defaultLabels)
    XCTAssertEqual(plan.defaultMacOSLabels, RunnerOS.macOS.defaultLabels)
  }

  func testMigrateDropsUnparseableRepoNames() {
    let plan = FleetPlan.migrate(
      repoFullNames: ["acme/web", "not-a-full-name", ""], oses: [.macOS],
      labels: ["self-hosted"], runnersPerRepo: 1, windowsImageReady: false,
      linuxImageReady: false)
    XCTAssertEqual(plan.repos.map(\.id), ["acme/web"])
  }

  // MARK: Codable round-trip (the non-String-key regression)

  func testCodableRoundTripPreservesPlatformsDict() throws {
    let original = FleetPlan(
      repos: [
        RepoPlan(
          repo: RepoRef(owner: "acme", name: "web"),
          platforms: [
            RunnerOS.macOS.rawValue: PlatformConfig(
              enabled: true, count: 2, labels: ["self-hosted", "macOS", "mactions"]),
            RunnerOS.linux.rawValue: PlatformConfig(
              enabled: false, count: 1, labels: RunnerOS.linux.defaultLabels),
          ])
      ])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(FleetPlan.self, from: data)
    XCTAssertEqual(decoded, original)
    XCTAssertEqual(decoded.repos[0].config(for: .macOS)?.count, 2)
    XCTAssertEqual(decoded.repos[0].config(for: .linux)?.enabled, false)
  }

  func testPlatformsEncodeAsAJSONObjectKeyedByRawValue() throws {
    let plan = FleetPlan(repos: [
      RepoPlan(
        repo: RepoRef(owner: "a", name: "b"),
        platforms: [RunnerOS.macOS.rawValue: PlatformConfig(enabled: true, count: 1, labels: ["x"])])
    ])
    let json = String(data: try JSONEncoder().encode(plan), encoding: .utf8) ?? ""
    // The platforms dict must serialize as a keyed object, not a flat array.
    XCTAssertTrue(json.contains("\"macOS\""))
  }

  // MARK: enabledCombos / invalidCombos

  func testEnabledCombosSkipsDisabledAndUnconfigured() {
    let plan = FleetPlan(repos: [
      RepoPlan(
        repo: RepoRef(owner: "acme", name: "web"),
        platforms: [
          RunnerOS.macOS.rawValue: PlatformConfig(enabled: true, count: 2, labels: ["self-hosted", "macOS"]),
          RunnerOS.linux.rawValue: PlatformConfig(enabled: false, count: 1, labels: ["self-hosted"]),
        ]),
      RepoPlan(
        repo: RepoRef(owner: "acme", name: "api"),
        platforms: [RunnerOS.linux.rawValue: PlatformConfig(enabled: true, count: 1, labels: RunnerOS.linux.defaultLabels)]),
    ])
    let combos = plan.enabledCombos()
    XCTAssertEqual(combos.count, 2)
    XCTAssertEqual(combos[0].repo.fullName, "acme/web")
    XCTAssertEqual(combos[0].os, .macOS)
    XCTAssertEqual(combos[1].repo.fullName, "acme/api")
    XCTAssertEqual(combos[1].os, .linux)
  }

  func testInvalidCombosFlagsEmptyOrSelfHostedlessLabels() {
    let plan = FleetPlan(repos: [
      RepoPlan(
        repo: RepoRef(owner: "acme", name: "web"),
        platforms: [
          RunnerOS.macOS.rawValue: PlatformConfig(enabled: true, count: 1, labels: []),         // empty
          RunnerOS.linux.rawValue: PlatformConfig(enabled: true, count: 1, labels: ["mactions"]), // no self-hosted
        ]),
      RepoPlan(
        repo: RepoRef(owner: "acme", name: "api"),
        platforms: [RunnerOS.macOS.rawValue: PlatformConfig(enabled: true, count: 1, labels: ["self-hosted", "macOS"])]),  // valid
    ])
    let invalid = plan.invalidCombos()
    XCTAssertEqual(invalid.count, 2)
    XCTAssertTrue(invalid.allSatisfy { $0.repo.fullName == "acme/web" })
  }

  // MARK: Mutation

  func testAddRepoSeedsDefaultPlatformsAndIsIdempotent() {
    var plan = FleetPlan(
      defaultMacOSLabels: ["self-hosted", "custom"],
      defaultMacOSCount: 3,
      defaultPlatforms: ["macOS", "linux"])
    plan.addRepo(RepoRef(owner: "acme", name: "web"))
    plan.addRepo(RepoRef(owner: "acme", name: "web"))  // dupe → no-op
    XCTAssertEqual(plan.repos.count, 1)
    XCTAssertEqual(plan.repos[0].config(for: .macOS)?.count, 3)
    XCTAssertEqual(plan.repos[0].config(for: .macOS)?.labels, RunnerOS.macOS.defaultLabels)
    XCTAssertEqual(plan.repos[0].config(for: .linux)?.count, 1)
    XCTAssertEqual(plan.repos[0].config(for: .macOS)?.enabled, true)
  }

  func testDefaultCountsArePerOSAndClamped() {
    var plan = FleetPlan(defaultMacOSCount: 2)

    XCTAssertEqual(plan.defaultCount(for: .macOS), 2)
    XCTAssertEqual(plan.defaultCount(for: .windows), 1)
    XCTAssertEqual(plan.defaultCount(for: .linux), 1)

    plan.setDefaultCount(4, for: .windows)
    plan.setDefaultCount(99, for: .linux)
    plan.setDefaultCount(0, for: .macOS)

    XCTAssertEqual(plan.defaultCount(for: .windows), 4)
    XCTAssertEqual(plan.defaultCount(for: .linux), 5)
    XCTAssertEqual(plan.defaultCount(for: .macOS), 1)
    XCTAssertEqual(plan.defaultMacOSCount, 1)
  }

  func testSeedUsesPerOSDefaultCounts() {
    var plan = FleetPlan(defaultMacOSCount: 2)
    plan.setDefaultCount(3, for: .windows)
    plan.setDefaultCount(4, for: .linux)

    XCTAssertEqual(plan.seed(for: .macOS).count, 2)
    XCTAssertEqual(plan.seed(for: .windows).count, 3)
    XCTAssertEqual(plan.seed(for: .linux).count, 4)
  }

  func testNormalizeWorkflowLabelsPinsLegacySavedCustomLabels() {
    var plan = FleetPlan(
      repos: [
        RepoPlan(
          repo: RepoRef(owner: "a", name: "b"),
          platforms: [
            RunnerOS.macOS.rawValue: PlatformConfig(
              enabled: true, count: 4, labels: ["self-hosted", "custom"]),
            RunnerOS.linux.rawValue: PlatformConfig(
              enabled: false, count: 2, labels: ["self-hosted", "Linux"]),
          ])
      ],
      defaultMacOSLabels: ["self-hosted", "custom"],
      defaultMacOSCount: 3)

    plan.normalizeWorkflowLabels()

    XCTAssertEqual(plan.defaultMacOSLabels, RunnerOS.macOS.defaultLabels)
    XCTAssertEqual(plan.repos[0].config(for: .macOS)?.labels, RunnerOS.macOS.defaultLabels)
    XCTAssertEqual(plan.repos[0].config(for: .macOS)?.count, 4)
    XCTAssertEqual(plan.repos[0].config(for: .linux)?.labels, RunnerOS.linux.defaultLabels)
    XCTAssertEqual(plan.repos[0].config(for: .linux)?.count, 2)
    XCTAssertEqual(plan.repos[0].config(for: .linux)?.enabled, false)
  }

  func testSetCountClampsToOneThroughFive() {
    var plan = FleetPlan(repos: [RepoPlan(repo: RepoRef(owner: "a", name: "b"))])
    plan.setPlatform(.macOS, enabled: true, in: "a/b")
    plan.setCount(99, os: .macOS, in: "a/b")
    XCTAssertEqual(plan.repos[0].config(for: .macOS)?.count, 5)
    plan.setCount(0, os: .macOS, in: "a/b")
    XCTAssertEqual(plan.repos[0].config(for: .macOS)?.count, 1)
  }

  func testSetCountAppliesToWindowsAndLinux() {
    // The per-combo count is no longer macOS-only — Windows/Linux honor it too
    // (go-online's RAM/CPU budget caps the realized total, but the plan stores
    // the requested count for every platform), and the 1...5 clamp still holds.
    var plan = FleetPlan(repos: [RepoPlan(repo: RepoRef(owner: "a", name: "b"))])
    plan.setPlatform(.windows, enabled: true, in: "a/b")
    plan.setCount(3, os: .windows, in: "a/b")
    plan.setCount(99, os: .linux, in: "a/b")  // seeds a disabled linux placeholder
    XCTAssertEqual(plan.repos[0].config(for: .windows)?.count, 3)
    XCTAssertEqual(plan.repos[0].config(for: .linux)?.count, 5)  // clamped to 5
  }

  // MARK: Summary

  func testSummaryShowsCountOnlyForPlatformsAboveOne() {
    var plan = RepoPlan(repo: RepoRef(owner: "a", name: "b"))
    plan.platforms[RunnerOS.macOS.rawValue] =
      PlatformConfig(enabled: true, count: 1, labels: ["self-hosted"])
    plan.platforms[RunnerOS.windows.rawValue] =
      PlatformConfig(enabled: true, count: 3, labels: ["self-hosted"])
    // A lone runner stays implicit; >1 shows `×N`. Order follows RunnerOS.allCases.
    XCTAssertEqual(plan.summary(), "macOS · Windows ×3")
  }

  func testSummaryNudgesWhenNoPlatformsEnabled() {
    let plan = RepoPlan(repo: RepoRef(owner: "a", name: "b"))
    XCTAssertEqual(plan.summary(), "No platforms — open Configure")
  }

  // MARK: All-repos scope

  /// A plan persisted BEFORE the `allRepos` field existed must decode unchanged
  /// (the field is optional on purpose), and the flag must round-trip once set.
  func testAllReposDecodesCompatAndRoundTrips() throws {
    let legacy = Data(
      #"{"repos": [], "defaultMacOSLabels": ["self-hosted"], "defaultMacOSCount": 1, "defaultPlatforms": ["macOS"]}"#
        .utf8)
    let plan = try JSONDecoder().decode(FleetPlan.self, from: legacy)
    XCTAssertFalse(plan.isAllRepos)
    XCTAssertEqual(plan.defaultCount(for: .macOS), 1)
    XCTAssertEqual(plan.defaultCount(for: .windows), 1)

    var enabled = plan
    enabled.allRepos = true
    let decoded = try JSONDecoder().decode(
      FleetPlan.self, from: JSONEncoder().encode(enabled))
    XCTAssertTrue(decoded.isAllRepos)
  }

  /// Discovery routes a queued job to the default platforms whose SEED labels
  /// satisfy the job's `runs-on` set — and only to platforms the defaults
  /// actually enable.
  func testDiscoveryMatchesRoutesByDefaultPlatformSeeds() {
    let plan = FleetPlan(defaultPlatforms: ["macOS", "linux"], allRepos: true)

    // Matches the macOS seed labels (subset, case-insensitive).
    XCTAssertEqual(
      plan.discoveryMatches(for: [["self-hosted", "macos"]]), [.macOS])
    // Matches the Linux seed (which carries ARM64).
    XCTAssertEqual(
      plan.discoveryMatches(for: [["self-hosted", "Linux", "ARM64"]]), [.linux])
    // A Windows job can't route anywhere: windows isn't a default platform.
    XCTAssertEqual(
      plan.discoveryMatches(for: [["self-hosted", "Windows", "mactions"]]), [])
    // Hosted-runner jobs route nowhere.
    XCTAssertEqual(plan.discoveryMatches(for: [["ubuntu-latest"]]), [])
    // One sweep can match several platforms at once.
    XCTAssertEqual(
      plan.discoveryMatches(for: [
        ["self-hosted", "macOS", "mactions"], ["self-hosted", "Linux", "ARM64", "mactions"],
      ]),
      [.macOS, .linux])
  }
}
