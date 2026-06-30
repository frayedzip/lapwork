//
//  NotificationManager.swift
//  LapWork
//
//  Thin wrapper around UNUserNotificationCenter for the "lap ended" banner.
//  Implements the delegate so banners appear even though LapWork is an
//  agent app (LSUIElement) running "in the foreground" with no windows.
//

import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    @MainActor static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    /// Ask once for permission to show banners + play notification sounds.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post the "lap finished" banner.
    @MainActor
    func postLapEnd(lapNumber: Int, gas: Double, playSound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Lap \(lapNumber) complete"
        content.body = String(format: "Lap %d done. Gas: %.1f min. Start the next lap when ready.",
                              lapNumber, gas)
        if playSound { content.sound = .default }

        // nil trigger → deliver immediately.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even while the app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
