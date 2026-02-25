/*
This file encapsulates all notification behavior for the menu bar app. It is responsible
for requesting notification permissions and dispatching threshold alerts according to the
user-selected delivery mode.

It exists separately because notification policy is an integration boundary with macOS
frameworks and should not be mixed into status refresh or menu rendering logic.

This file talks to `ThresholdEvent` and `LimitLensSettings` to determine what to alert,
and it talks to `UserNotifications` and `AppKit` to deliver banner and/or sound behavior.
*/

import AppKit
import Foundation
import LimitLensCore
import UserNotifications

enum NotificationSendResult {
    case sent
    case skippedDisabled
    case soundOnly
    case blockedByPermission
    case failed(String)
}

enum NotificationAuthorizationState: String {
    case notDetermined = "not-determined"
    case denied = "denied"
    case authorized = "authorized"
    case provisional = "provisional"
    case ephemeral = "ephemeral"
    case unknown = "unknown"
}

@MainActor
final class NotificationCoordinator {
    private let center = UNUserNotificationCenter.current()
    private(set) var authorizationState: NotificationAuthorizationState = .notDetermined

    func requestPermissions(completion: (@Sendable (NotificationAuthorizationState) -> Void)? = nil) {
        // We request both alert and sound so users can switch modes without re-prompt loops.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshAuthorizationState(completion: completion)
            }
        }
    }

    func refreshAuthorizationState(completion: (@Sendable (NotificationAuthorizationState) -> Void)? = nil) {
        center.getNotificationSettings { [weak self] settings in
            let mapped = Self.mapStatus(settings.authorizationStatus)
            Task { @MainActor in
                self?.authorizationState = mapped
                completion?(mapped)
            }
        }
    }

    func send(event: ThresholdEvent, mode: NotificationMode, completion: (@Sendable (NotificationSendResult) -> Void)? = nil) {
        switch mode {
        case .off:
            completion?(.skippedDisabled)
            return
        case .sound:
            // Sound-only mode intentionally avoids NotificationCenter banners.
            NSSound.beep()
            completion?(.soundOnly)
            return
        case .banner, .soundAndBanner:
            break
        }

        if authorizationState == .denied {
            // If banners are blocked, sound+banner still degrades to sound so users get a signal.
            if mode == .soundAndBanner {
                NSSound.beep()
                completion?(.soundOnly)
            } else {
                completion?(.blockedByPermission)
            }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "LimitLens Threshold Reached"
        content.subtitle = event.provider.defaultDisplayName
        content.body = "Crossed \(event.threshold)% at \(String(format: "%.2f", event.observedPercent))%."

        if mode == .soundAndBanner {
            content.sound = .default
        }

        // Immediate delivery keeps the warning aligned with the live status transition.
        let request = UNNotificationRequest(
            identifier: "limitlens.threshold.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            Task { @MainActor in
                if let error {
                    completion?(.failed(error.localizedDescription))
                } else {
                    completion?(.sent)
                }
            }
        }
    }

    func authorizationSummaryText() -> String {
        switch authorizationState {
        case .authorized, .provisional, .ephemeral:
            return "Allowed"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not Determined"
        case .unknown:
            return "Unknown"
        }
    }

    nonisolated private static func mapStatus(_ status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }
}
