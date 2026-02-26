/*
This file provides a tiny wrapper for invoking local shell commands and collecting
stdout/stderr safely. LimitLens uses this for lightweight runtime metadata checks,
like reading the installed Antigravity version.

It exists separately because process execution is a side-effect boundary that should
remain isolated from parsing logic. This makes failure handling explicit and keeps
adapters easier to test.

This file talks to provider adapters by returning command results and error context
without exposing low-level `Process` wiring to higher layers.
*/

import Foundation
import Darwin

public struct ProcessResult {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessSupport {
    public static func run(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval = 3
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: String(describing: error))
        }

        // We enforce a timeout so one hung command cannot stall the whole snapshot cycle.
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        var didTimeout = false
        if process.isRunning {
            didTimeout = true
            process.terminate()

            // Some child processes ignore SIGTERM; escalate to SIGKILL if needed.
            let gracefulDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < gracefulDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let exitCode = didTimeout ? -2 : process.terminationStatus

        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}
