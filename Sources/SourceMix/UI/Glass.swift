import AppKit
import SwiftUI

// Liquid Glass on macOS 26 (Tahoe) with a material fallback on macOS 15.

extension View {
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 22, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    }
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tint.opacity(0.12))
                        }
                    }
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            }
        }
    }

    @ViewBuilder
    func glassCircle(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint).interactive(), in: .circle)
            } else {
                self.glassEffect(.regular.interactive(), in: .circle)
            }
        } else {
            self.background {
                Circle().fill(.regularMaterial)
                    .overlay { if let tint { Circle().fill(tint.opacity(0.25)) } }
                    .overlay { Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5) }
            }
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

/// Groups glass shapes so they blend and morph together on macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Round icon button used for mute / EQ / channel toggles.
struct GlassIconButton: View {
    let systemImage: String
    var tint: Color? = nil
    var isOn = false
    var size: CGFloat = 30
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isOn ? AnyShapeStyle(tint ?? .accentColor) : AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle(tint: isOn ? tint : nil)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Keeps the app out of the Dock unless one of its windows is open.
@MainActor
enum DockPolicy {
    static func windowOpened() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
    }

    static func windowClosed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let hasWindow = NSApp.windows.contains { window in
                window.isVisible && window.styleMask.contains(.titled) && window.canBecomeMain
            }
            if !hasWindow { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
