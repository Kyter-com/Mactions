// swift-tools-version: 6.0
import PackageDescription

// Mactions — a menubar macOS app that turns your Mac into an on-demand,
// ephemeral GitHub Actions runner host. Open the app, it brings runners
// online; quit it, they go offline.
//
// Two targets so the orchestration logic stays UI-free and unit-testable:
//   - MactionsCore  : pure-Foundation control plane (GitHub API, auth,
//                     orchestrator, VM/process providers). No SwiftUI.
//   - Mactions      : the SwiftUI/AppKit menubar app, depends on the core.
let package = Package(
  name: "Mactions",
  platforms: [.macOS(.v13)], // MenuBarExtra is macOS 13+
  // Expose MactionsCore as a library product so the Xcode app target (XcodeGen /
  // project.yml) can link it. `swift build`/`run`/`test` don't need this — they
  // build the targets directly — but an external consumer can only depend on a
  // product, not a bare target.
  products: [
    .library(name: "MactionsCore", targets: ["MactionsCore"])
  ],
  targets: [
    .target(name: "MactionsCore"),
    .executableTarget(
      name: "Mactions",
      dependencies: ["MactionsCore"],
      resources: [.process("Media.xcassets"), .copy("Mactions.icon")]
    ),
    .testTarget(
      name: "MactionsCoreTests",
      dependencies: ["MactionsCore"]
    ),
  ],
  swiftLanguageModes: [.v6]  // strict concurrency on — adopt Swift 6 fully
)
