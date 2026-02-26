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
        FileSystemSupport.latestFile(
            in: antigravityLogsRoot,
            matching: { fileURL in
                guard fileURL.lastPathComponent == "Claude VSCode.log" else {
                    return false
                }

                let path = fileURL.path.lowercased()
                // We intentionally scan all `window*` folders, not only `window1`.
                return path.contains("/exthost/anthropic.claude-code/")
            }
        )
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
        FileSystemSupport.latestFile(
            in: antigravityLogsRoot,
            matching: { fileURL in
                guard fileURL.lastPathComponent == "Codex.log" else {
                    return false
                }

                let path = fileURL.path.lowercased()
                // Different extension variants can emit Codex.log, so we match by host path.
                return path.contains("/exthost/")
            }
        )
    }
}

public struct ExternalCommandProviderAdapter: ProviderAdapter {
    private struct ExternalSnapshotPayload: Decodable {
        let confidence: ConfidenceLevel?
        let currentUsagePercent: Double?
        let windowResetAt: Date?
        let tokenUsage: TokenUsage?
        let contextUsage: ContextUsage?
        let appVersion: String?
        let extraUsageEnabled: Bool?
        let currentStatusSummary: String?
        let historicalSignals: [HistoricalSignal]?
        let sourceFiles: [String]?
        let errors: [String]?
    }

    public let descriptor: ProviderDescriptor
    private let definition: ExternalProviderDefinition

    public init(definition: ExternalProviderDefinition) {
        let id = definition.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = definition.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortLabel = definition.shortLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.descriptor = ProviderDescriptor(
            id: id,
            displayName: displayName.isEmpty ? ProviderName(rawValue: id).defaultDisplayName : displayName,
            shortLabel: shortLabel.isEmpty ? String((displayName.isEmpty ? id : displayName).prefix(3)) : shortLabel
        )
        self.definition = definition
    }

    public func collect(using settings: LimitLensSettings) -> ProviderSnapshot {
        let provider = ProviderName(rawValue: descriptor.id)
        let timeoutSeconds = TimeInterval(max(1, definition.timeoutSeconds))
        let result = ProcessSupport.run(
            executable: definition.command,
            arguments: definition.arguments,
            timeoutSeconds: timeoutSeconds
        )

        guard result.exitCode == 0 else {
            return ProviderSnapshot(
                provider: provider,
                providerDisplayName: descriptor.displayName,
                providerShortLabel: descriptor.shortLabel,
                confidence: .unavailable,
                currentStatusSummary: "External adapter command failed.",
                sourceFiles: [],
                errors: [result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("Command exited with status \(result.exitCode).")]
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard
            let payloadData = result.stdout.data(using: .utf8),
            let payload = try? decoder.decode(ExternalSnapshotPayload.self, from: payloadData)
        else {
            return ProviderSnapshot(
                provider: provider,
                providerDisplayName: descriptor.displayName,
                providerShortLabel: descriptor.shortLabel,
                confidence: .unavailable,
                currentStatusSummary: "External adapter output is not valid JSON snapshot payload.",
                sourceFiles: [],
                errors: ["Expected JSON on stdout for provider \(descriptor.id)."]
            )
        }

        let pressure = payload.currentUsagePercent.map(safePercent)
        let summary = payload.currentStatusSummary?.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty(
            pressure.map { "\(String(format: "%.2f", $0))% used" } ?? "External adapter reported metrics."
        ) ?? "External adapter reported metrics."

        return ProviderSnapshot(
            provider: provider,
            providerDisplayName: descriptor.displayName,
            providerShortLabel: descriptor.shortLabel,
            confidence: payload.confidence ?? (pressure == nil ? .medium : .high),
            currentUsagePercent: pressure,
            windowResetAt: payload.windowResetAt,
            tokenUsage: payload.tokenUsage,
            contextUsage: payload.contextUsage,
            appVersion: payload.appVersion,
            extraUsageEnabled: payload.extraUsageEnabled,
            currentStatusSummary: summary,
            historicalSignals: payload.historicalSignals ?? [],
            sourceFiles: payload.sourceFiles ?? [],
            errors: payload.errors ?? []
        )
    }
}

private func extractRateLimitSignal(from fileURL: URL, kind: String) -> HistoricalSignal? {
    let tail = FileSystemSupport.readTail(from: fileURL, maxBytes: 1_048_576)
    return ProviderParsing.parseLatestRateLimitSignal(from: tail, kind: kind)
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
