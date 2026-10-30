import SwiftUI
import AppKit
import UserNotifications

@main
struct UsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
                .preferredColorScheme(appearanceColorScheme)
        } label: {
            MenuBarLabel(model: model)
                .preferredColorScheme(appearanceColorScheme)
        }
        .menuBarExtraStyle(.window)

        Window("Usage Tracker", id: "dashboard") {
            DashboardView(model: model)
                .preferredColorScheme(appearanceColorScheme)
        }
        .defaultSize(width: 1_000, height: 680)

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(appearanceColorScheme)
        }
    }

    private var appearanceColorScheme: ColorScheme? {
        switch model.settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
