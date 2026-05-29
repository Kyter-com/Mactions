// swift-tools-version: 5.9
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
  targets: [
    .target(name: "MactionsCore"),
    .executableTarget(
      name: "Mactions",
      dependencies: ["MactionsCore"]
    ),
    .testTarget(
      name: "MactionsCoreTests",
      dependencies: ["MactionsCore"]
    ),
  ]
)
