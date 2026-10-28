import AppKit
import ServiceManagement
import SwiftUI

@main
struct SourceMixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MixerStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            Image(systemName: "slider.vertical.3")
                .accessibilityLabel("SourceMix")
        }
        .menuBarExtraStyle(.window)

        Window("SourceMix", id: "mixer") {
            MixerView()
                .environment(store)
        }
        .defaultSize(width: 820, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)

        WindowGroup("Equalizer", id: "equalizer", for: String.self) { $sourceID in
            EqualizerView(sourceID: sourceID ?? "")
                .environment(store)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Runs quietly in the menu bar; windows only appear on request.
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
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
