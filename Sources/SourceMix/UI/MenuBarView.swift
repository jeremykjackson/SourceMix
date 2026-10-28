import AppKit
import SwiftUI

/// Compact mixer shown from the menu bar icon.
struct MenuBarView: View {
    @Environment(MixerStore.self) private var store

    private let stripWidth: CGFloat = 72
    private let sliderHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "slider.vertical.3")
                    .font(.headline)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("SourceMix").font(.headline)
                    Text(store.outputName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                SettingsMenu()
            }

            if store.permission != .authorized {
                PermissionBanner()
            }

            if let reason = store.bypassReason {
                BypassBanner(reason: reason)
            }

            ScrollView(.horizontal) {
                GlassGroup(spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        MiniOutputStrip(width: stripWidth, sliderHeight: sliderHeight)
                        ForEach(store.sources) { source in
                            MiniStrip(source: source, width: stripWidth, sliderHeight: sliderHeight)
                        }
                        if store.sources.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "waveform")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text("Nothing playing")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 170)
                            .frame(maxHeight: .infinity)
                            .glassSurface(cornerRadius: 20)
                        }
                    }
                    .padding(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .scrollIndicators(.never)
            .frame(width: panelWidth - 28)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                WindowManager.shared.showMixer()
            } label: {
                Label("Open SourceMix", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .glassButtonStyle()
        }
        .padding(14)
        .frame(width: panelWidth)
        .fixedSize()
    }

    /// Grows with the number of sources, up to five strips before scrolling.
    private var panelWidth: CGFloat {
        let strips = CGFloat(min(5, max(3, store.sources.count + 1)))
        return strips * stripWidth + (strips - 1) * 8 + 28 + 4
    }
}

private struct MiniStrip: View {
    @Bindable var source: AudioSource
    let width: CGFloat
    let sliderHeight: CGFloat

    var body: some View {
        VStack(spacing: 7) {
            Image(nsImage: source.icon)
                .resizable()
                .frame(width: 24, height: 24)
                .opacity(source.isPlaying ? 1 : 0.55)
                .help(source.name)
            Text(source.name)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: width - 10)
            VolumeSlider(value: $source.settings.position,
                         levels: ProcessorLevels(processor: source.processor),
                         isMuted: source.settings.muted,
                         width: 26,
                         accessibilityName: "\(source.name) volume")
                .frame(height: sliderHeight)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                GlassIconButton(systemImage: source.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                tint: .red, isOn: source.settings.muted, size: 26,
                                help: source.settings.muted ? "Unmute \(source.name)" : "Mute \(source.name)") {
                    source.toggleMute()
                }
                GlassIconButton(systemImage: "slider.vertical.3",
                                tint: .accentColor, isOn: source.settings.isEQActive, size: 26,
                                help: "Equalizer for \(source.name)") {
                    WindowManager.shared.showEqualizer(for: source.id)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .glassSurface(cornerRadius: 20)
        .contextMenu {
            Picker("Channel", selection: $source.settings.channel) {
                ForEach(ChannelMode.allCases) { Text($0.menuTitle).tag($0) }
            }
            Button("Reset Volume") { source.settings.position = SourceSettings.unityPosition }
        }
    }
}

private struct MiniOutputStrip: View {
    @Environment(MixerStore.self) private var store
    let width: CGFloat
    let sliderHeight: CGFloat

    var body: some View {
        let volume = Binding(get: { store.systemVolume }, set: { store.setSystemVolume($0) })
        VStack(spacing: 7) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 16))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24, height: 24)
            Text("Output")
                .font(.caption2.weight(.semibold))
            VolumeSlider(value: volume,
                         levels: CombinedLevels(processors: store.sources.compactMap(\.processor)),
                         isMuted: store.systemMuted,
                         tint: .primary,
                         unityMark: nil,
                         defaultValue: 0.5,
                         width: 26,
                         accessibilityName: "Output volume")
                .frame(height: sliderHeight)
                .disabled(!store.systemHasVolume)
            Spacer(minLength: 0)
            GlassIconButton(systemImage: store.systemMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            tint: .red, isOn: store.systemMuted, size: 26,
                            help: store.systemMuted ? "Unmute output" : "Mute output") {
                store.setSystemMuted(!store.systemMuted)
            }
        }
        .padding(.vertical, 10)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .glassSurface(cornerRadius: 20, tint: .accentColor.opacity(0.15))
    }
}

