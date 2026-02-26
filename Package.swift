// swift-tools-version: 6.0
/*
This file is the Swift Package manifest for LimitLens. It declares the package graph
for the shared core library, the production CLI executable, and the native menu bar
executable so the system can be built from one dependency boundary.

It exists as a separate file because SwiftPM resolves target topology, platform support,
and build outputs from this manifest. Keeping this as the single package contract avoids
splitting core logic across unrelated projects.

This file talks to all source targets by naming them and defining dependency direction:
`LimitLensCLI` depends on `LimitLensCore`, `LimitLensMenuBar` depends on both
`LimitLensCore` and `LimitLensMenuBarSupport`, and `LimitLensCore` remains
dependency-free to keep parser and policy logic reusable.
*/

import PackageDescription

let package = Package(
    name: "LimitLens",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        // The shared engine used by both user-facing executables.
        .library(name: "LimitLensCore", targets: ["LimitLensCore"]),
        // Shared menu-bar support logic that is testable without launching the app loop.
        .library(name: "LimitLensMenuBarSupport", targets: ["LimitLensMenuBarSupport"]),
        // Production terminal entrypoint.
        .executable(name: "limitlens", targets: ["LimitLensCLI"]),
        // Native menu bar executable.
        .executable(name: "LimitLensMenuBar", targets: ["LimitLensMenuBar"]),
        // Local unit test harness for parser and threshold policy checks.
        .executable(name: "limitlens-core-tests", targets: ["LimitLensCoreTestsRunner"]),
        // Local test harness for menu-bar support policies and launch lifecycle behavior.
        .executable(name: "limitlens-menubar-tests", targets: ["LimitLensMenuBarTestsRunner"]),
    ],
    targets: [
        .target(
            name: "LimitLensCore",
            path: "Sources/LimitLensCore"
        ),
        .target(
            name: "LimitLensMenuBarSupport",
            dependencies: ["LimitLensCore"],
            path: "Sources/LimitLensMenuBarSupport"
        ),
        .executableTarget(
            name: "LimitLensCLI",
            dependencies: ["LimitLensCore"],
            path: "Sources/LimitLensCLI"
        ),
        .executableTarget(
            name: "LimitLensMenuBar",
            dependencies: ["LimitLensCore", "LimitLensMenuBarSupport"],
            path: "Sources/LimitLensMenuBar",
            sources: [
                "SettingsWindowController.swift",
                "main.swift",
            ]
        ),
        .executableTarget(
            name: "LimitLensCoreTestsRunner",
            dependencies: ["LimitLensCore"],
            path: "Sources/LimitLensCoreTestsRunner",
            resources: [
                .process("Fixtures"),
            ]
        ),
        .executableTarget(
            name: "LimitLensMenuBarTestsRunner",
            dependencies: ["LimitLensCore", "LimitLensMenuBarSupport"],
            path: "Sources/LimitLensMenuBarTestsRunner"
        ),
    ]
)
