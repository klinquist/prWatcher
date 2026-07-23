import AppKit
import SwiftUI
import UserNotifications

@main
struct PRWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: PullRequestStore

    init() {
        LegacyPreferencesMigrator.migrateIfNeeded()
        _store = StateObject(wrappedValue: PullRequestStore())
    }

    var body: some Scene {
        WindowGroup("prWatcher") {
            ContentView(store: store)
                .frame(minWidth: 340, minHeight: 480)
                .onOpenURL { url in
                    NSWorkspace.shared.open(url)
                }
        }
        .defaultSize(width: 400, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Pull Requests") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView(store: store)
        }
    }
}

private enum LegacyPreferencesMigrator {
    private static let legacyBundleIdentifiers = [
        "com.local.prWatcher",
        "com.local.prVisualizer",
    ]

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        for legacyBundleIdentifier in legacyBundleIdentifiers {
            let migrationKey = "didMigratePreferencesFrom.\(legacyBundleIdentifier)"
            guard !defaults.bool(forKey: migrationKey) else { continue }
            defer { defaults.set(true, forKey: migrationKey) }
            guard let legacyPreferences = defaults.persistentDomain(
                forName: legacyBundleIdentifier
            ) else { continue }

            for (key, value) in legacyPreferences where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        DockIconVisibility.apply(
            isHidden: UserDefaults.standard.bool(forKey: DockIconVisibility.preferenceKey)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppRuntime.supportsUserNotifications {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) else { return }
            Self.moveToTopRight(window)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag, let window = sender.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let rawURL = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: rawURL) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    private static func moveToTopRight(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - window.frame.width - 12,
            y: visible.maxY - window.frame.height - 12
        )
        window.setFrameOrigin(origin)
    }
}

enum DockIconVisibility {
    static let preferenceKey = "hideDockIcon"

    static func apply(isHidden: Bool) {
        NSApplication.shared.setActivationPolicy(isHidden ? .accessory : .regular)
        if !isHidden {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

enum AppRuntime {
    /// UserNotifications raises an Objective-C exception when a SwiftPM executable is
    /// launched without a containing .app bundle. Never initialize it in that mode.
    static var supportsUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
}
