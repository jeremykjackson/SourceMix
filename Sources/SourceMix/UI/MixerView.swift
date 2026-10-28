import AppKit
import SwiftUI

/// The full mixer window.
struct MixerView: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if store.permission != .authorized {
                PermissionBanner()
            }

            ScrollView(.horizontal) {
                GlassGroup(spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        OutputStrip()
                        if store.sources.isEmpty {
                            EmptySourcesCard()
                        } else {
                            ForEach(store.sources) { source in
                                ChannelStrip(source: source)
                                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.sources.map(\.id))
                }
            }
            .scrollIndicators(.automatic)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .padding(.top, 34)
        .frame(minWidth: 420, minHeight: 470)
        .containerBackground(.ultraThinMaterial, for: .window)
        .onAppear { DockPolicy.windowOpened() }
        .onDisappear { DockPolicy.windowClosed() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.vertical.3")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("SourceMix").font(.title3.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsMenu()
        }
    }

    private var subtitle: String {
        let playing = store.sources.filter(\.isPlaying).count
        switch playing {
        case 0: return "No apps playing · \(store.outputName)"
        case 1: return "1 app playing · \(store.outputName)"
        default: return "\(playing) apps playing · \(store.outputName)"
        }
    }
}

struct EmptySourcesCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text("Nothing Playing")
                .font(.headline)
            Text("Apps appear here as soon as they start making sound.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 220, height: 380)
        .glassSurface(cornerRadius: 24)
    }
}

struct PermissionBanner: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow Audio Capture").font(.headline)
                Text("SourceMix needs permission to capture each app's audio before it can change its volume, EQ or channel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if store.permission == .denied {
                Button("Open Settings") { AudioCapturePermission.openSystemSettings() }
                    .glassButtonStyle(prominent: true)
            } else {
                Button("Allow…") { store.requestPermission() }
                    .glassButtonStyle(prominent: true)
            }
        }
        .padding(14)
        .glassSurface(cornerRadius: 18, tint: .orange.opacity(0.2))
    }
}

/// Gear menu shared by the window and the menu bar panel.
struct SettingsMenu: View {
    @Environment(MixerStore.self) private var store
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Menu {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    LoginItem.set(on)
                    launchAtLogin = LoginItem.isEnabled
                }
            Button("Reset All Sources") { store.resetAll() }
            Divider()
            Button("About SourceMix") {
                NSApp.activate()
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            Button("Quit SourceMix") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .glassCircle()
        .help("Settings")
    }
}
