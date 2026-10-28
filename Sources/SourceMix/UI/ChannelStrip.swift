import AppKit
import SwiftUI

/// Picker for where a stream plays: left ear, both, right ear, or mono.
struct ChannelMenu: View {
    @Binding var mode: ChannelMode
    var compact = false

    var body: some View {
        Menu {
            Picker("Channel", selection: $mode) {
                ForEach(ChannelMode.allCases) { m in
                    Label(m.menuTitle, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(mode.shortLabel)
                .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
                .monospaced()
                .foregroundStyle(mode == .stereo ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .glassCircle(tint: mode == .stereo ? nil : .accentColor)
        .help("Output channel: \(mode.label)")
    }
}

extension ChannelMode {
    var menuTitle: String {
        switch self {
        case .stereo: "Stereo (both ears)"
        case .left: "Left ear only"
        case .right: "Right ear only"
        case .mono: "Mono (both ears)"
        }
    }
}

/// A full-height mixer strip for one source.
struct ChannelStrip: View {
    @Bindable var source: AudioSource
    var sliderHeight: CGFloat = 220
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: source.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .saturation(source.isPlaying ? 1 : 0.2)
                    .opacity(source.isPlaying ? 1 : 0.6)
                PeakDot(processor: source.processor)
                    .padding(2)
                    .background(.background, in: Circle())
                    .offset(x: 3, y: 3)
            }

            VStack(spacing: 2) {
                Text(source.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(statusText)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(source.errorText == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            VolumeSlider(value: $source.settings.position,
                         levels: ProcessorLevels(processor: source.processor),
                         isMuted: source.settings.muted,
                         accessibilityName: "\(source.name) volume")
                .frame(height: sliderHeight)
                .padding(.vertical, 4)

            HStack(spacing: 6) {
                GlassIconButton(systemImage: source.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                tint: .red, isOn: source.settings.muted,
                                help: source.settings.muted ? "Unmute \(source.name)" : "Mute \(source.name)") {
                    source.toggleMute()
                }
                ChannelMenu(mode: $source.settings.channel)
            }

            Button {
                openWindow(id: "equalizer", value: source.id)
            } label: {
                Label("EQ", systemImage: "slider.vertical.3")
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(source.settings.isEQActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            }
            .controlSize(.small)
            .glassButtonStyle()
            .help("Open the 15-band equalizer for \(source.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(width: 116)
        .glassSurface(cornerRadius: 24)
        .help(source.errorText ?? "")
        .contextMenu {
            Button(source.settings.muted ? "Unmute" : "Mute") { source.toggleMute() }
            Button("Reset Volume") { source.settings.position = SourceSettings.unityPosition }
            Button("Open Equalizer…") { openWindow(id: "equalizer", value: source.id) }
            Divider()
            Button("Reset All Settings") { source.settings = .default }
        }
    }

    private var statusText: String {
        if source.errorText != nil { return "Can't capture" }
        if !source.isPlaying && !source.settings.muted { return "Idle · \(source.settings.levelText)" }
        return source.settings.levelText
    }
}

/// Master strip for the default output device.
struct OutputStrip: View {
    @Environment(MixerStore.self) private var store
    var sliderHeight: CGFloat = 220

    var body: some View {
        let volume = Binding(get: { store.systemVolume }, set: { store.setSystemVolume($0) })
        VStack(spacing: 10) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 22, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 34, height: 34)

            VStack(spacing: 2) {
                Text("Output")
                    .font(.callout.weight(.semibold))
                Text(store.systemMuted ? "Muted" : "\(Int((store.systemVolume * 100).rounded()))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            VolumeSlider(value: volume,
                         levels: CombinedLevels(processors: store.sources.compactMap(\.processor)),
                         isMuted: store.systemMuted,
                         tint: .primary,
                         unityMark: nil,
                         defaultValue: 0.5,
                         accessibilityName: "Output volume")
                .frame(height: sliderHeight)
                .padding(.vertical, 4)
                .disabled(!store.systemHasVolume)

            GlassIconButton(systemImage: store.systemMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            tint: .red, isOn: store.systemMuted,
                            help: store.systemMuted ? "Unmute output" : "Mute output") {
                store.setSystemMuted(!store.systemMuted)
            }

            Text(store.outputName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(width: 116)
        .glassSurface(cornerRadius: 24, tint: .accentColor.opacity(0.15))
    }
}
