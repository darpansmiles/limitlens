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

public struct ProcessResult {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
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

        if process.isRunning {
            process.terminate()
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
