/*
This file contains pure parsing helpers that translate raw provider log text into
normalized intermediate values. It exists to keep string/JSON interpretation deterministic
and testable without filesystem or process side effects.

It is separated from adapter orchestration because adapters handle source discovery,
while this file handles content interpretation. That boundary lets us unit-test parser
behavior directly using fixtures, including malformed payloads.

This file talks to shared model types such as `TokenUsage`, `ContextUsage`, and
`HistoricalSignal`, and it is used by `ProviderAdapters` plus parser-focused test cases.
*/

import Foundation

public struct CodexParsedMetrics: Sendable {
    public let tokenUsage: TokenUsage?
    public let usagePercent: Double?
    public let resetAt: Date?
    public let contextWindow: Int?

    public init(tokenUsage: TokenUsage?, usagePercent: Double?, resetAt: Date?, contextWindow: Int?) {
        self.tokenUsage = tokenUsage
        self.usagePercent = usagePercent
        self.resetAt = resetAt
        self.contextWindow = contextWindow
    }
}

public enum ProviderParsing {
    public static func parseCodexSessionTail(_ tail: String) -> CodexParsedMetrics {
        let lines = tail.split(whereSeparator: \.isNewline)

        // Reverse scan gives us the newest event first.
        for lineSlice in lines.reversed() {
            let line = String(lineSlice)
            guard let json = parseJSONLine(line) else {
                continue
            }

            guard json.string("type") == "event_msg" else {
                continue
            }

            let payload = json.dict("payload")
            guard payload?.string("type") == "token_count" else {
                continue
            }

            var tokenUsage: TokenUsage?
            var usagePercent: Double?
            var resetAt: Date?
            var contextWindow: Int?

            if let info = payload?.dict("info") {
                if let lastUsage = info.dict("last_token_usage") {
                    let input = lastUsage.int("input_tokens") ?? 0
                    let output = lastUsage.int("output_tokens") ?? 0
                    tokenUsage = TokenUsage(inputTokens: input, outputTokens: output)
                }
                contextWindow = info.int("model_context_window")
            }

            if let primary = payload?.dict("rate_limits")?.dict("primary") {
                usagePercent = primary.double("used_percent")
                if let resetEpoch = primary.double("resets_at") {
                    resetAt = Date(timeIntervalSince1970: resetEpoch)
                }
            }

            return CodexParsedMetrics(
                tokenUsage: tokenUsage,
                usagePercent: usagePercent,
                resetAt: resetAt,
                contextWindow: contextWindow
            )
        }

        return CodexParsedMetrics(tokenUsage: nil, usagePercent: nil, resetAt: nil, contextWindow: nil)
    }

    public static func parseClaudeConversationTail(_ tail: String) -> TokenUsage? {
        let lines = tail.split(whereSeparator: \.isNewline)

        var fallback: TokenUsage?

        // Prefer the latest non-zero usage event, but keep the newest valid fallback.
        for lineSlice in lines.reversed() {
            let line = String(lineSlice)
            guard let json = parseJSONLine(line) else {
                continue
            }

            guard
                let message = json.dict("message"),
                let usage = message.dict("usage")
            else {
                continue
            }

            let inTokens = usage.int("input_tokens") ?? 0
            let outTokens = usage.int("output_tokens") ?? 0
            let candidate = TokenUsage(inputTokens: inTokens, outputTokens: outTokens)

            if fallback == nil {
                fallback = candidate
            }

            if inTokens > 0 || outTokens > 0 {
                return candidate
            }
        }

        return fallback
    }

    public static func parseClaudeContextUsage(from logTail: String) -> ContextUsage? {
        let lines = logTail.split(whereSeparator: \.isNewline)

        // Parse from the bottom so we return the freshest context pressure value.
        for lineSlice in lines.reversed() {
            let line = String(lineSlice)
            guard line.contains("autocompact:") else {
                continue
            }

            guard let groups = regexCaptureGroups(
                pattern: "autocompact:\\s*tokens=(\\d+)\\s+threshold=(\\d+)",
                in: line
            ), groups.count == 2 else {
                continue
            }

            let tokens = Int(groups[0]) ?? 0
            let threshold = Int(groups[1]) ?? 0
            guard threshold > 0 else {
                continue
            }

            return ContextUsage(tokens: tokens, threshold: threshold)
        }

        return nil
    }

    public static func parseLatestRateLimitSignal(
        from logTail: String,
        kind: String
    ) -> HistoricalSignal? {
        let lines = logTail.split(whereSeparator: \.isNewline)

        // Rate-limit evidence is historical, so the latest matching line is sufficient.
        for lineSlice in lines.reversed() {
            let line = String(lineSlice)
            guard isRateLimitEvidenceLine(line) else {
                continue
            }

            // We require an explicit timestamp so signal freshness stays trustworthy.
            guard let observedAt = parseLogTimestamp(from: line) else {
                continue
            }
            return HistoricalSignal(kind: kind, observedAt: observedAt, details: line)
        }

        return nil
    }
}

private struct JSONLine {
    let storage: [String: Any]

    init(storage: [String: Any]) {
        self.storage = storage
    }

    func dict(_ key: String) -> JSONLine? {
        guard let value = storage[key] as? [String: Any] else {
            return nil
        }
        return JSONLine(storage: value)
    }

    func string(_ key: String) -> String? {
        storage[key] as? String
    }

    func int(_ key: String) -> Int? {
        if let value = storage[key] as? Int {
            return value
        }
        if let value = storage[key] as? Double {
            return Int(value)
        }
        if let value = storage[key] as? String {
            return Int(value)
        }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let value = storage[key] as? Double {
            return value
        }
        if let value = storage[key] as? Int {
            return Double(value)
        }
        if let value = storage[key] as? String {
            return Double(value)
        }
        return nil
    }
}

private func parseJSONLine(_ line: String) -> JSONLine? {
    guard let data = line.data(using: .utf8) else {
        return nil
    }

    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }

    return JSONLine(storage: object)
}

private func isRateLimitEvidenceLine(_ line: String) -> Bool {
    let lower = line.lowercased()

    if lower.contains("rate_limit") || lower.contains("rate limit") || lower.contains("ratelimit") {
        return true
    }
    if lower.contains("too many requests") || lower.contains("quota exceeded") {
        return true
    }

    guard regexCaptureGroups(pattern: "\\b429\\b", in: lower) != nil else {
        return false
    }

    // A bare number is noisy; we only trust 429 lines with HTTP/request semantics.
    return lower.contains("http") ||
        lower.contains("request") ||
        lower.contains("response") ||
        lower.contains("status")
}
