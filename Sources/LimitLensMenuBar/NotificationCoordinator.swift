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

final class NotificationCoordinator {
    private let center = UNUserNotificationCenter.current()

    func requestPermissions() {
        // We request both alert and sound so users can switch modes without re-prompt loops.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func send(event: ThresholdEvent, mode: NotificationMode) {
        switch mode {
        case .off:
            return
        case .sound:
            // Sound-only mode intentionally avoids NotificationCenter banners.
            NSSound.beep()
            return
        case .banner, .soundAndBanner:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = "LimitLens Threshold Reached"
        content.subtitle = event.provider.rawValue.capitalized
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
        center.add(request) { _ in }
    }
}
