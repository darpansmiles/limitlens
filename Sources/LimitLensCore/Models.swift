/*
This file defines the domain entities that every LimitLens component shares. These
models are the semantic backbone for provider parsing, threshold evaluation, CLI rendering,
and menu bar presentation.

It exists as a separate file because cross-target type drift is the fastest way to make
a multi-interface system incoherent. Centralizing all core entities here keeps the CLI and
menu app speaking the same language.

This file talks to the rest of the system in both directions. Parsers in `ProviderAdapters`
construct these models, policy code in `ThresholdEngine` evaluates them, and both executables
consume them for rendering and notifications.
*/

import Foundation

public struct ProviderDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let shortLabel: String

    public init(id: String, displayName: String, shortLabel: String) {
        self.id = id
        self.displayName = displayName
        self.shortLabel = shortLabel
    }
}

public enum ProviderName: Codable, Hashable, Comparable, Sendable {
    case codex
    case claude
    case antigravity
    case custom(String)

    public init(rawValue: String) {
        switch rawValue {
        case "codex":
            self = .codex
        case "claude":
            self = .claude
        case "antigravity":
            self = .antigravity
        default:
            self = .custom(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        case .antigravity:
            return "antigravity"
        case .custom(let id):
            return id
        }
    }

    public var defaultDisplayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .antigravity:
            return "Antigravity"
        case .custom(let id):
            // Custom provider IDs are normalized slugs, so title-casing is a readable default.
            return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public static let builtInOrder: [ProviderName] = [.codex, .claude, .antigravity]

    public static func < (lhs: ProviderName, rhs: ProviderName) -> Bool {
        let lhsIndex = builtInOrder.firstIndex(of: lhs)
        let rhsIndex = builtInOrder.firstIndex(of: rhs)

        // Built-ins stay in deterministic product order, custom providers sort by slug.
        switch (lhsIndex, rhsIndex) {
        case let (left?, right?):
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.rawValue < rhs.rawValue
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = ProviderName(rawValue: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ConfidenceLevel: String, Codable, Sendable {
    case high
    case medium
    case low
    case unavailable
}

public enum NotificationMode: String, Codable, CaseIterable, Sendable {
    case off
    case sound
    case banner
    case soundAndBanner = "sound+banner"
}

public struct TokenUsage: Codable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct ContextUsage: Codable, Sendable {
    public let tokens: Int
    public let threshold: Int

    public init(tokens: Int, threshold: Int) {
        self.tokens = tokens
        self.threshold = threshold
    }

    public var percentUsed: Double {
        guard threshold > 0 else { return 0 }
        return (Double(tokens) / Double(threshold)) * 100
    }
}

public struct HistoricalSignal: Codable, Sendable {
    public let kind: String
    public let observedAt: Date
    public let details: String

    public init(kind: String, observedAt: Date, details: String) {
        self.kind = kind
        self.observedAt = observedAt
        self.details = details
    }
}

public struct ProviderSnapshot: Codable, Sendable {
    public let provider: ProviderName
    public var providerDisplayName: String
    public var providerShortLabel: String
    public var confidence: ConfidenceLevel
    public var currentUsagePercent: Double?
    public var windowResetAt: Date?
    public var tokenUsage: TokenUsage?
    public var contextUsage: ContextUsage?
    public var appVersion: String?
    public var extraUsageEnabled: Bool?
    public var currentStatusSummary: String
    public var historicalSignals: [HistoricalSignal]
    public var sourceFiles: [String]
    public var errors: [String]

    public init(
        provider: ProviderName,
        providerDisplayName: String? = nil,
        providerShortLabel: String? = nil,
        confidence: ConfidenceLevel,
        currentUsagePercent: Double? = nil,
        windowResetAt: Date? = nil,
        tokenUsage: TokenUsage? = nil,
        contextUsage: ContextUsage? = nil,
        appVersion: String? = nil,
        extraUsageEnabled: Bool? = nil,
        currentStatusSummary: String,
        historicalSignals: [HistoricalSignal] = [],
        sourceFiles: [String] = [],
        errors: [String] = []
    ) {
        self.provider = provider
        self.providerDisplayName = providerDisplayName ?? provider.defaultDisplayName
        self.providerShortLabel = providerShortLabel ?? String(provider.defaultDisplayName.prefix(3))
        self.confidence = confidence
        self.currentUsagePercent = currentUsagePercent
        self.windowResetAt = windowResetAt
        self.tokenUsage = tokenUsage
        self.contextUsage = contextUsage
        self.appVersion = appVersion
        self.extraUsageEnabled = extraUsageEnabled
        self.currentStatusSummary = currentStatusSummary
        self.historicalSignals = historicalSignals
        self.sourceFiles = sourceFiles
        self.errors = errors
    }

    public var pressurePercent: Double? {
        // Prefer explicit provider quota percentages over inferred context pressure.
        if let currentUsagePercent {
            return currentUsagePercent
        }
        if let contextUsage {
            return contextUsage.percentUsed
        }
        return nil
    }
}

public struct GlobalSnapshot: Codable, Sendable {
    public let capturedAt: Date
    public let providers: [ProviderSnapshot]

    public init(capturedAt: Date, providers: [ProviderSnapshot]) {
        self.capturedAt = capturedAt
        self.providers = providers
    }

    public func provider(_ name: ProviderName) -> ProviderSnapshot? {
        providers.first { $0.provider == name }
    }
}

public struct ThresholdEvent: Codable, Sendable {
    public let provider: ProviderName
    public let threshold: Int
    public let observedPercent: Double
    public let triggeredAt: Date

    public init(provider: ProviderName, threshold: Int, observedPercent: Double, triggeredAt: Date) {
        self.provider = provider
        self.threshold = threshold
        self.observedPercent = observedPercent
        self.triggeredAt = triggeredAt
    }
}

public struct LimitLensSettings: Codable, Sendable {
    public var codexSessionsPath: String
    public var claudeProjectsPath: String
    public var antigravityLogsPath: String
    public var refreshIntervalSeconds: Int
    public var defaultThresholds: [Int]
    public var perProviderThresholds: [String: [Int]]
    public var notificationMode: NotificationMode
    public var notificationCooldownMinutes: Int
    public var launchAtLogin: Bool

    public static let `default` = LimitLensSettings(
        codexSessionsPath: "~/.codex/sessions",
        claudeProjectsPath: "~/.claude/projects",
        antigravityLogsPath: "~/Library/Application Support/Antigravity/logs",
        refreshIntervalSeconds: 60,
        defaultThresholds: [70, 75, 80, 85, 90, 95],
        perProviderThresholds: [:],
        notificationMode: .soundAndBanner,
        notificationCooldownMinutes: 30,
        launchAtLogin: true
    )

    public func thresholds(for provider: ProviderName) -> [Int] {
        // Provider-specific thresholds override global defaults when configured.
        let providerKey = provider.rawValue
        let values = perProviderThresholds[providerKey] ?? defaultThresholds
        return values
            .filter { (0...100).contains($0) }
            .sorted()
    }
}

public struct ThresholdRuntimeState: Codable, Sendable {
    public var lastPercentByProvider: [String: Double]
    public var lastNotifiedByProviderThreshold: [String: Date]

    public init(
        lastPercentByProvider: [String: Double] = [:],
        lastNotifiedByProviderThreshold: [String: Date] = [:]
    ) {
        self.lastPercentByProvider = lastPercentByProvider
        self.lastNotifiedByProviderThreshold = lastNotifiedByProviderThreshold
    }

    public static var empty: ThresholdRuntimeState {
        ThresholdRuntimeState()
    }
}
