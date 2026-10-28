import AppKit
import ServiceManagement
import SwiftUI

@main
struct SourceMixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item, popover and windows are AppKit-hosted (see
        // WindowManager) so they always size to their content.
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Runs quietly in the menu bar; windows only appear on request.
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            WindowManager.shared.installStatusItem()
            MixerStore.shared.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MixerStore.shared.shutdown()
        }
    }
}

/// "Launch at Login" via the modern ServiceManagement API.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("SourceMix: could not update login item: \(error.localizedDescription)")
        }
    }
}
