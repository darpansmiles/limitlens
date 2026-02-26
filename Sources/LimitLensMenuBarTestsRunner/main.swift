/*
This file is a lightweight verification harness for menu-bar support components. It
tests launch-agent lifecycle behavior and notification authorization transition policy
without starting the AppKit event loop.

It exists as a dedicated executable because these checks need to run in CI and local
terminals as deterministic assertions, independent from interactive UI runtime.

This file talks to `LaunchAtLoginManager` and `NotificationCoordinator` through their
public APIs and validates expected behavior for state transitions and side effects.
*/

import Foundation
import LimitLensCore
import LimitLensMenuBarSupport

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private struct MenuBarSupportTestsRunner {
    private(set) var passed = 0
    private(set) var failed = 0

    mutating func runAll() {
        run("Notification delivery plan transitions are permission-aware") {
            try Self.expect(
                NotificationCoordinator.deliveryPlan(mode: .off, authorizationState: .authorized) == .skip,
                "Expected off mode to skip delivery"
            )
            try Self.expect(
                NotificationCoordinator.deliveryPlan(mode: .sound, authorizationState: .denied) == .soundOnly,
                "Expected sound mode to avoid notification center"
            )
            try Self.expect(
                NotificationCoordinator.deliveryPlan(mode: .banner, authorizationState: .denied) == .blocked,
                "Expected banner mode to block when denied"
            )
            try Self.expect(
                NotificationCoordinator.deliveryPlan(mode: .soundAndBanner, authorizationState: .denied) == .soundOnly,
                "Expected sound+banner to degrade to sound when denied"
            )
            try Self.expect(
                NotificationCoordinator.deliveryPlan(mode: .banner, authorizationState: .authorized) == .banner(withSound: false),
                "Expected banner mode to remain banner when permission exists"
            )
            try Self.expect(
                NotificationCoordinator.deliveryPlan(mode: .soundAndBanner, authorizationState: .authorized) == .banner(withSound: true),
                "Expected sound+banner to keep sound when permission exists"
            )
            try Self.expect(
                NotificationCoordinator.deliveryPlan(mode: .banner, authorizationState: .notDetermined) == .blocked,
                "Expected banner mode to remain blocked until permission is decided"
            )
            try Self.expect(
                NotificationCoordinator.deliveryPlan(mode: .soundAndBanner, authorizationState: .notDetermined) == .soundOnly,
                "Expected sound+banner to degrade to sound while permission is undecided"
            )
        }

        run("LaunchAtLoginManager writes and removes launch agent lifecycle artifacts") {
            let home = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: home) }

            var invocations: [[String]] = []
            let manager = LaunchAtLoginManager(
                homeDirectory: home,
                label: "com.limitlens.tests",
                userID: "501",
                commandRunner: { executable, arguments in
                    invocations.append([executable] + arguments)
                    return ProcessResult(exitCode: 0, stdout: "", stderr: "")
                }
            )

            let enabled = manager.setEnabled(true, executablePath: "/tmp/LimitLensMenuBar")
            switch enabled {
            case .success:
                break
            case .failure(let message):
                throw TestFailure(description: "Expected launch enable success, got failure: \(message)")
            }

            try Self.expect(FileManager.default.fileExists(atPath: manager.launchAgentURL.path), "Expected launch agent file to be created")

            let plistData = try Data(contentsOf: manager.launchAgentURL)
            let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
            let programArgs = plist?["ProgramArguments"] as? [String]
            try Self.expect(programArgs == ["/tmp/LimitLensMenuBar"], "Expected ProgramArguments to include executable path")

            try Self.expect(invocations.contains(where: { $0.contains("bootstrap") }), "Expected bootstrap command invocation")
            try Self.expect(invocations.contains(where: { $0.contains("bootout") }), "Expected bootout command invocation")

            let disabled = manager.setEnabled(false, executablePath: nil)
            switch disabled {
            case .success:
                break
            case .failure(let message):
                throw TestFailure(description: "Expected launch disable success, got failure: \(message)")
            }

            try Self.expect(!FileManager.default.fileExists(atPath: manager.launchAgentURL.path), "Expected launch agent file to be removed")
        }

        run("LaunchAtLoginManager rejects enable requests without executable path") {
            let home = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: home) }

            let manager = LaunchAtLoginManager(homeDirectory: home, label: "com.limitlens.tests", userID: "501")
            let result = manager.setEnabled(true, executablePath: nil)

            switch result {
            case .success:
                throw TestFailure(description: "Expected missing executable path failure")
            case .failure:
                break
            }
        }
    }

    private mutating func run(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("[PASS] \(name)")
        } catch {
            failed += 1
            print("[FAIL] \(name)")
            print("       \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw TestFailure(description: message)
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let path = base.appendingPathComponent("limitlens-menubar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
}

private var runner = MenuBarSupportTestsRunner()
runner.runAll()

print("\nResult: \(runner.passed) passed, \(runner.failed) failed")
exit(runner.failed == 0 ? 0 : 1)
