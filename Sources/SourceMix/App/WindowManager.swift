import AppKit
import SwiftUI

/// Owns the menu bar item, its popover and the app's windows.
///
/// AppKit hosting is used instead of SwiftUI's MenuBarExtra / Window scenes so
/// the popover and windows always size themselves to their content (e.g. when
/// a "Mixing Paused" banner appears or a new source starts playing).
@MainActor
final class WindowManager: NSObject, NSWindowDelegate, NSPopoverDelegate {
    static let shared = WindowManager()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var mixerWindow: NSWindow?
    private var equalizerWindows: [String: NSWindow] = [:]

    // MARK: Menu bar

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "SourceMix")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let host = NSHostingController(rootView: MenuBarView().environment(MixerStore.shared))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    // MARK: Windows

    func showMixer() {
        closePopover()
        if mixerWindow == nil {
            mixerWindow = makeWindow(title: "SourceMix",
                                     root: MixerView().environment(MixerStore.shared))
            mixerWindow?.center()
        }
        present(mixerWindow)
    }

    private var settingsWindow: NSWindow?

    func showSettings() {
        closePopover()
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "SourceMix Settings", root: SettingsView())
            settingsWindow?.center()
        }
        present(settingsWindow)
    }

    func showEqualizer(for sourceID: String) {
        closePopover()
        if equalizerWindows[sourceID] == nil {
            let name = MixerStore.shared.source(id: sourceID)?.name ?? "Equalizer"
            let window = makeWindow(title: "\(name) Equalizer",
                                    root: EqualizerView(sourceID: sourceID).environment(MixerStore.shared))
            window.identifier = NSUserInterfaceItemIdentifier("eq.\(sourceID)")
            window.center()
            equalizerWindows[sourceID] = window
        }
        present(equalizerWindows[sourceID])
    }

    func closeEqualizer(for sourceID: String) {
        equalizerWindows[sourceID]?.performClose(nil)
    }

    private func makeWindow<Content: View>(title: String, root: Content) -> NSWindow {
        let host = NSHostingController(rootView: root.background(VisualEffectBackground().ignoresSafeArea()))
        // min == max == the SwiftUI content's fixed size, so Auto Layout keeps
        // the window exactly as big as its content, growing/shrinking with it.
        host.sizingOptions = [.minSize, .maxSize]
        // Give the window its real size up front (the hosting view reports
        // zero until it has been laid out, which left the window invisible).
        let initial = host.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: initial),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.setContentSize(initial)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.delegate = self
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        DockPolicy.windowOpened()
        if let host = window.contentViewController {
            host.view.layoutSubtreeIfNeeded()
            let size = host.view.fittingSize
            if size.width > 10, size.height > 10, window.frame.width < 20 || window.frame.height < 20 {
                window.setContentSize(size)
                window.center()
            }
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow { settingsWindow = nil }
        if let id = window.identifier?.rawValue, id.hasPrefix("eq.") {
            equalizerWindows[String(id.dropFirst(3))] = nil
        }
        DockPolicy.windowClosed()
    }
}

/// Behind-window blur for the app's windows (Liquid Glass–style backdrop).
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
