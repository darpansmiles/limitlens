/*
This file holds small utility functions that are shared across adapters, renderers,
and runtime orchestration. The utilities focus on path handling, timestamp parsing,
and user-facing time formatting.

It exists as a separate file because these transformations are cross-cutting concerns.
Keeping them centralized avoids duplicated logic and subtle inconsistencies between CLI
and menu bar outputs.

This file talks to provider adapters by helping parse raw text into typed time values,
and it talks to output layers by formatting dates and relative durations for users.
*/

import Foundation

public enum TimeDeltaStyle {
    case past
    case future
}

public func expandHomePath(_ value: String) -> String {
    if value == "~" {
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
    if value.hasPrefix("~/") {
        let suffix = String(value.dropFirst(2))
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(suffix).path
    }
    return value
}

public func parseLogTimestamp(from line: String) -> Date? {
    // We only accept timestamps at the beginning of a line to avoid false positives.
    let prefixCount = "yyyy-MM-dd HH:mm:ss.SSS".count
    guard line.count >= prefixCount else {
        return nil
    }
    let prefix = String(line.prefix(prefixCount))
    return makeLogTimestampFormatter().date(from: prefix)
}

public func iso8601(_ date: Date) -> String {
    makeISOFormatter().string(from: date)
}

public func dualTimestamp(_ date: Date) -> String {
    // This dual format keeps local readability while preserving an absolute UTC anchor.
    let local = date.formatted(date: .numeric, time: .standard)
    return "\(local) [\(iso8601(date)) UTC]"
}

public func relativeAge(from date: Date, now: Date = Date(), futureLabel: String = "in") -> String {
    let deltaSeconds = Int(date.timeIntervalSince(now))
    let isFuture = deltaSeconds >= 0
    let absoluteSeconds = abs(deltaSeconds)

    if absoluteSeconds < 60 {
        return isFuture ? "\(futureLabel) <1m" : "<1m ago"
    }

    let minutes = Int(round(Double(absoluteSeconds) / 60.0))
    if minutes < 60 {
        return isFuture ? "\(futureLabel) \(minutes)m" : "\(minutes)m ago"
    }

    let hours = Int(round(Double(minutes) / 60.0))
    if hours < 24 {
        return isFuture ? "\(futureLabel) \(hours)h" : "\(hours)h ago"
    }

    let days = Int(round(Double(hours) / 24.0))
    return isFuture ? "\(futureLabel) \(days)d" : "\(days)d ago"
}

public func regexCaptureGroups(pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return nil
    }

    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: fullRange) else {
        return nil
    }

    var groups: [String] = []
    // Group 0 is the full match, so we start at 1 for captured groups.
    for index in 1..<match.numberOfRanges {
        let range = match.range(at: index)
        guard let swiftRange = Range(range, in: text) else {
            groups.append("")
            continue
        }
        groups.append(String(text[swiftRange]))
    }

    return groups
}

public func safePercent(_ value: Double) -> Double {
    min(max(value, 0), 100)
}

public func providerThresholdKey(provider: ProviderName, threshold: Int) -> String {
    "\(provider.rawValue)::\(threshold)"
}

private func makeLogTimestampFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    // Provider logs are local-time oriented in this environment.
    formatter.timeZone = .current
    return formatter
}

private func makeISOFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}
