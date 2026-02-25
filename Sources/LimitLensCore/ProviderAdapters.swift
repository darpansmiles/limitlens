/*
This file contains provider-specific adapters that translate raw local artifacts into
normalized `ProviderSnapshot` values. Each adapter understands one provider's log and
metadata shape and isolates that parsing complexity from the rest of the system.

It exists separately because provider formats evolve independently. Keeping adapters
cohesive and isolated means one parser can change without destabilizing threshold policy,
CLI rendering, or menu bar behavior.

This file talks to filesystem/process support for raw inputs and emits shared models that
`SnapshotService`, `ThresholdEngine`, and user interfaces consume.
*/

import Foundation

public protocol ProviderAdapter {
    var descriptor: ProviderDescriptor { get }
    func collect(using settings: LimitLensSettings) -> ProviderSnapshot
}

public struct CodexAdapter: ProviderAdapter {
    public init() {}
    public let descriptor = ProviderDescriptor(id: ProviderName.codex.rawValue, displayName: "Codex", shortLabel: "Cdx")

    public func collect(using settings: LimitLensSettings) -> ProviderSnapshot {
        let provider = ProviderName(rawValue: descriptor.id)
        let codexRoot = expandHomePath(settings.codexSessionsPath)
        let codexVersion = extractCodexVersion()
        guard let latestFile = FileSystemSupport.latestFile(
            in: codexRoot,
            matching: { $0.pathExtension == "jsonl" }
        ) else {
            let summary = codexVersion.map { "No Codex session files found, version \($0)" }
                ?? "No Codex session files found."
            return ProviderSnapshot(
                provider: provider,
                providerDisplayName: descriptor.displayName,
                providerShortLabel: descriptor.shortLabel,
                confidence: codexVersion == nil ? .unavailable : .low,
                appVersion: codexVersion,
                currentStatusSummary: summary,
                errors: ["Missing session JSONL in \(codexRoot)"]
            )
        }

        let tail = FileSystemSupport.readTail(from: latestFile, maxBytes: 1_048_576)
        let parsed = ProviderParsing.parseCodexSessionTail(tail)

        let tokenUsage = parsed.tokenUsage
        let usagePercent = parsed.usagePercent
        let resetAt = parsed.resetAt
        let contextWindow = parsed.contextWindow

        var summary = "Usage unavailable"
        var confidence: ConfidenceLevel = .medium
        if let usagePercent {
            summary = "\(String(format: "%.2f", usagePercent))% used"
            confidence = .high
        } else if tokenUsage != nil {
            summary = "Token usage available"
            confidence = .medium
        } else {
            confidence = .low
        }

        if let contextWindow {
            summary += ", context window \(contextWindow)"
        }

        return ProviderSnapshot(
            provider: provider,
            providerDisplayName: descriptor.displayName,
            providerShortLabel: descriptor.shortLabel,
            confidence: confidence,
            currentUsagePercent: usagePercent,
            windowResetAt: resetAt,
            tokenUsage: tokenUsage,
            appVersion: codexVersion,
            currentStatusSummary: summary,
            sourceFiles: [latestFile.path]
        )
    }

    private func extractCodexVersion() -> String? {
        let result = ProcessSupport.run(executable: "codex", arguments: ["--version"])
        guard result.exitCode == 0 else {
            return nil
        }

        // We keep the first non-empty line so the summary remains compact and stable.
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

public struct ClaudeAdapter: ProviderAdapter {
    public init() {}
    public let descriptor = ProviderDescriptor(id: ProviderName.claude.rawValue, displayName: "Claude", shortLabel: "Cla")

    public func collect(using settings: LimitLensSettings) -> ProviderSnapshot {
        let provider = ProviderName(rawValue: descriptor.id)
        let claudeRoot = expandHomePath(settings.claudeProjectsPath)
        let antigravityLogsRoot = expandHomePath(settings.antigravityLogsPath)

        let latestConversationFile = FileSystemSupport.latestFile(
            in: claudeRoot,
            matching: { $0.pathExtension == "jsonl" }
        )

        let usageFromConversation = latestConversationFile.flatMap { extractClaudeUsage(from: $0) }
        let accountMetadata = extractClaudeAccountMetadata()
        let claudeLogFile = resolveClaudeLogFile(antigravityLogsRoot: antigravityLogsRoot)
        let contextUsage = claudeLogFile.flatMap { extractClaudeContextUsage(from: $0) }
        let rateLimitSignal = claudeLogFile.flatMap { extractRateLimitSignal(from: $0, kind: "claude_rate_limit") }

        let confidence: ConfidenceLevel
        if usageFromConversation != nil || contextUsage != nil {
            confidence = .medium
        } else if rateLimitSignal != nil {
            confidence = .low
        } else {
            confidence = .unavailable
        }

        var summaryParts: [String] = []
        if let usage = usageFromConversation {
            summaryParts.append("last in/out \(usage.inputTokens)/\(usage.outputTokens)")
        }
        if let contextUsage {
            summaryParts.append(
                "context \(contextUsage.tokens)/\(contextUsage.threshold)"
            )
        }
        if let hasExtraUsage = accountMetadata?.hasExtraUsageEnabled {
            summaryParts.append("extra-usage \(hasExtraUsage ? "on" : "off")")
        }
        if summaryParts.isEmpty {
            summaryParts.append("No current metrics")
        }

        var sources: [String] = []
        if let latestConversationFile {
            sources.append(latestConversationFile.path)
        }
        if let claudeLogFile {
            sources.append(claudeLogFile.path)
        }
        if let claudeAccountFile = accountMetadata?.sourceFile {
            sources.append(claudeAccountFile)
        }

        return ProviderSnapshot(
            provider: provider,
            providerDisplayName: descriptor.displayName,
            providerShortLabel: descriptor.shortLabel,
            confidence: confidence,
            tokenUsage: usageFromConversation,
            contextUsage: contextUsage,
            extraUsageEnabled: accountMetadata?.hasExtraUsageEnabled,
            currentStatusSummary: summaryParts.joined(separator: ", "),
            historicalSignals: rateLimitSignal.map { [$0] } ?? [],
            sourceFiles: sources,
            errors: sources.isEmpty ? ["No Claude data sources found"] : []
        )
    }

    private func extractClaudeUsage(from fileURL: URL) -> TokenUsage? {
        let tail = FileSystemSupport.readTail(from: fileURL, maxBytes: 1_048_576)
        return ProviderParsing.parseClaudeConversationTail(tail)
    }

    private func resolveClaudeLogFile(antigravityLogsRoot: String) -> URL? {
        guard let latestLogDirectory = FileSystemSupport.latestDirectory(in: antigravityLogsRoot) else {
            return nil
        }

        let logPath = latestLogDirectory
            .appendingPathComponent("window1")
            .appendingPathComponent("exthost")
            .appendingPathComponent("Anthropic.claude-code")
            .appendingPathComponent("Claude VSCode.log")

        return FileManager.default.fileExists(atPath: logPath.path) ? logPath : nil
    }

    private func extractClaudeContextUsage(from fileURL: URL) -> ContextUsage? {
        let tail = FileSystemSupport.readTail(from: fileURL, maxBytes: 1_048_576)
        return ProviderParsing.parseClaudeContextUsage(from: tail)
    }

    private func extractClaudeAccountMetadata() -> (hasExtraUsageEnabled: Bool, sourceFile: String)? {
        let path = expandHomePath("~/.claude.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauthAccount = object["oauthAccount"] as? [String: Any]
        else {
            return nil
        }

        let hasExtraUsageEnabled = (oauthAccount["hasExtraUsageEnabled"] as? Bool) ?? false
        return (hasExtraUsageEnabled, path)
    }
}

public struct AntigravityAdapter: ProviderAdapter {
    public init() {}
    public let descriptor = ProviderDescriptor(id: ProviderName.antigravity.rawValue, displayName: "Antigravity", shortLabel: "AG")

    public func collect(using settings: LimitLensSettings) -> ProviderSnapshot {
        let provider = ProviderName(rawValue: descriptor.id)
        let antigravityLogsRoot = expandHomePath(settings.antigravityLogsPath)
        let version = extractAntigravityVersion()
        let codexLogFile = resolveCodexExtensionLog(antigravityLogsRoot: antigravityLogsRoot)
        let rateLimitSignal = codexLogFile.flatMap { extractRateLimitSignal(from: $0, kind: "antigravity_rate_limit") }

        let confidence: ConfidenceLevel
        if version != nil {
            confidence = .medium
        } else if rateLimitSignal != nil {
            confidence = .low
        } else {
            confidence = .unavailable
        }

        var sources: [String] = []
        if let codexLogFile {
            sources.append(codexLogFile.path)
        }

        let summary = version.map { "version \($0)" } ?? "Version unavailable"

        return ProviderSnapshot(
            provider: provider,
            providerDisplayName: descriptor.displayName,
            providerShortLabel: descriptor.shortLabel,
            confidence: confidence,
            appVersion: version,
            currentStatusSummary: summary,
            historicalSignals: rateLimitSignal.map { [$0] } ?? [],
            sourceFiles: sources,
            errors: (version == nil && rateLimitSignal == nil) ? ["No Antigravity data sources found"] : []
        )
    }

    private func extractAntigravityVersion() -> String? {
        let result = ProcessSupport.run(executable: "antigravity", arguments: ["--version"])
        guard result.exitCode == 0 else {
            return nil
        }

        // We keep the first non-empty line as the user-visible semantic version value.
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func resolveCodexExtensionLog(antigravityLogsRoot: String) -> URL? {
        guard let latestLogDirectory = FileSystemSupport.latestDirectory(in: antigravityLogsRoot) else {
            return nil
        }

        let logPath = latestLogDirectory
            .appendingPathComponent("window1")
            .appendingPathComponent("exthost")
            .appendingPathComponent("openai.chatgpt")
            .appendingPathComponent("Codex.log")

        return FileManager.default.fileExists(atPath: logPath.path) ? logPath : nil
    }
}

private func extractRateLimitSignal(from fileURL: URL, kind: String) -> HistoricalSignal? {
    let tail = FileSystemSupport.readTail(from: fileURL, maxBytes: 1_048_576)
    return ProviderParsing.parseLatestRateLimitSignal(from: tail, kind: kind)
}
