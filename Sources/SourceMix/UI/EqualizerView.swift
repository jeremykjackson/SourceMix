import AppKit
import SwiftUI

/// Per-source equalizer and routing page.
struct EqualizerView: View {
    let sourceID: String
    @Environment(MixerStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let source = store.source(id: sourceID) {
                EqualizerContent(source: source)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "speaker.zzz")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("This source has stopped playing.")
                        .font(.headline)
                    Text("Its settings are saved and will apply the next time it plays.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Close") { dismiss() }
                        .glassButtonStyle()
                }
                .padding(40)
                .frame(width: 760, height: 420)
            }
        }
        .containerBackground(.ultraThinMaterial, for: .window)
        .onAppear { DockPolicy.windowOpened() }
        .onDisappear { DockPolicy.windowClosed() }
    }
}

private struct EqualizerContent: View {
    @Bindable var source: AudioSource

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            GlassGroup(spacing: 14) {
                VStack(spacing: 14) {
                    // Frequency response + 15 bands
                    VStack(spacing: 10) {
                        ResponseCurve(gains: source.settings.eqGains, enabled: source.settings.eqEnabled)
                            .frame(height: 70)
                            .padding(.horizontal, 6)

                        HStack(alignment: .bottom, spacing: 0) {
                            DBScale()
                            ForEach(0..<EQBands.count, id: \.self) { band in
                                EQBandSlider(gain: bandBinding(band),
                                             label: EQBands.label(for: band),
                                             enabled: source.settings.eqEnabled)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(height: 230)
                    }
                    .padding(16)
                    .glassSurface(cornerRadius: 24)

                    HStack(spacing: 14) {
                        mixCard
                        channelCard
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .padding(.top, 34)
        .frame(width: 780)
    }

    private func bandBinding(_ band: Int) -> Binding<Double> {
        Binding(
            get: { source.settings.eqGains[band] },
            set: { source.settings.eqGains[band] = $0 }
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: source.icon)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name).font(.title3.weight(.semibold))
                Text("15-Band Equalizer").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            Menu {
                ForEach(EQPreset.all) { preset in
                    Button(preset.name) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            source.settings.eqGains = preset.gains
                            source.settings.eqEnabled = true
                        }
                    }
                }
            } label: {
                Label(currentPresetName, systemImage: "list.bullet")
            }
            .fixedSize()
            .glassButtonStyle()

            Button("Reset") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { source.resetEQ() }
            }
            .glassButtonStyle()
            .disabled(!source.settings.eqGains.contains { $0 != 0 })

            Toggle("EQ", isOn: $source.settings.eqEnabled)
                .toggleStyle(.switch)
                .help("Turn the equalizer on or off for \(source.name)")
        }
    }

    private var currentPresetName: String {
        EQPreset.all.first { $0.gains == source.settings.eqGains }?.name ?? "Custom"
    }

    private var mixCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Volume").font(.headline)
            HStack(spacing: 10) {
                GlassIconButton(systemImage: source.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                tint: .red, isOn: source.settings.muted, size: 28,
                                help: source.settings.muted ? "Unmute" : "Mute") {
                    source.toggleMute()
                }
                Slider(value: $source.settings.position, in: 0...1)
                    .disabled(source.settings.muted)
                Text(source.settings.levelText)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            Text("100% is the app's original level; the top of the slider adds up to +9 dB.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22)
    }

    private var channelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Channel").font(.headline)
            Picker("Channel", selection: $source.settings.channel) {
                Text("Left").tag(ChannelMode.left)
                Text("Stereo").tag(ChannelMode.stereo)
                Text("Right").tag(ChannelMode.right)
                Text("Mono").tag(ChannelMode.mono)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(channelHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22)
    }

    private var channelHelp: String {
        switch source.settings.channel {
        case .stereo: "Plays normally in both ears."
        case .left: "Folded to mono and played only in your left ear."
        case .right: "Folded to mono and played only in your right ear."
        case .mono: "Folded to mono and played equally in both ears."
        }
    }
}

// MARK: - Band slider

private struct EQBandSlider: View {
    @Binding var gain: Double
    let label: String
    var enabled = true
    @State private var dragging = false

    private let range = EQBands.range

    var body: some View {
        VStack(spacing: 6) {
            Text(gain == 0 ? "0" : String(format: "%+.1f", gain))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(gain == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(height: 12)

            GeometryReader { geo in
                let h = geo.size.height
                let knob: CGFloat = 14
                let travel = h - knob
                let frac = (gain - range.lowerBound) / (range.upperBound - range.lowerBound)
                let y = (1 - CGFloat(frac)) * travel
                let mid = travel / 2

                ZStack(alignment: .top) {
                    Capsule().fill(Color.primary.opacity(0.08)).frame(width: 6)
                    // Fill from 0 dB to the knob
                    Capsule()
                        .fill(enabled ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                        .frame(width: 6, height: max(2, abs(y - mid)))
                        .offset(y: min(y, mid) + knob / 2)
                    Rectangle()
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 14, height: 1)
                        .offset(y: mid + knob / 2)
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(dragging ? 0.3 : 0.2), radius: dragging ? 4 : 2, y: 1)
                        .scaleEffect(dragging ? 1.15 : 1)
                        .offset(y: y)
                }
                .frame(width: geo.size.width, height: h)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            let f = 1 - Double((g.location.y - knob / 2) / travel)
                            var v = range.lowerBound + min(1, max(0, f)) * (range.upperBound - range.lowerBound)
                            v = (v * 2).rounded() / 2          // 0.5 dB steps
                            if abs(v) < 0.5 { v = 0 }
                            gain = v
                        }
                        .onEnded { _ in dragging = false }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded { gain = 0 })
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: dragging)
            }

            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(height: 12)
        }
        .opacity(enabled ? 1 : 0.55)
        .accessibilityElement()
        .accessibilityLabel("\(label) hertz")
        .accessibilityValue(String(format: "%+.1f decibels", gain))
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: gain = min(range.upperBound, gain + 0.5)
            case .decrement: gain = max(range.lowerBound, gain - 0.5)
            @unknown default: break
            }
        }
        .help("\(label) Hz · double-click to reset")
    }
}

private struct DBScale: View {
    var body: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: 12)
            GeometryReader { geo in
                let h = geo.size.height - 14
                ZStack(alignment: .topTrailing) {
                    ForEach([12, 6, 0, -6, -12], id: \.self) { db in
                        Text(db > 0 ? "+\(db)" : "\(db)")
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .offset(y: CGFloat(12 - db) / 24 * h + 7 - 6)
                    }
                }
                .frame(width: geo.size.width, alignment: .trailing)
            }
            Color.clear.frame(height: 12)
        }
        .frame(width: 26)
    }
}

// MARK: - Frequency response

private struct ResponseCurve: View {
    let gains: [Double]
    let enabled: Bool

    var body: some View {
        Canvas { context, size in
            let lo = log10(20.0), hi = log10(20_000.0)
            let points = 160
            var path = Path()
            var fill = Path()
            let zeroY = size.height / 2
            for i in 0...points {
                let t = Double(i) / Double(points)
                let f = pow(10, lo + t * (hi - lo))
                let db = enabled ? EQMath.responseDB(gains: gains, frequency: f) : 0
                let x = CGFloat(t) * size.width
                let y = zeroY - CGFloat(max(-15, min(15, db)) / 15) * (size.height / 2 - 2)
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                    fill.move(to: CGPoint(x: x, y: zeroY))
                }
                path.addLine(to: CGPoint(x: x, y: y))
                fill.addLine(to: CGPoint(x: x, y: y))
            }
            fill.addLine(to: CGPoint(x: size.width, y: zeroY))
            fill.closeSubpath()

            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: zeroY))
            zero.addLine(to: CGPoint(x: size.width, y: zeroY))
            context.stroke(zero, with: .color(.primary.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            context.fill(fill, with: .color(.accentColor.opacity(0.15)))
            context.stroke(path, with: .color(enabled ? .accentColor : .secondary), lineWidth: 2)
        }
        .animation(.easeOut(duration: 0.15), value: gains)
    }
}

enum EQMath {
    /// Combined magnitude response (dB) of the peaking filters at `frequency`.
    static func responseDB(gains: [Double], frequency: Double, sampleRate: Double = 48_000) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w), sin1 = sin(w), cos2 = cos(2 * w), sin2 = sin(2 * w)
        var total = 0.0
        for (band, g) in gains.enumerated() where abs(g) > 0.01 && band < EQBands.count {
            let a = pow(10, g / 40)
            let w0 = 2 * Double.pi * EQBands.frequencies[band] / sampleRate
            let alpha = sin(w0) / (2 * EQBands.q)
            let c = cos(w0)
            let b0 = 1 + alpha * a, b1 = -2 * c, b2 = 1 - alpha * a
            let a0 = 1 + alpha / a, a1 = -2 * c, a2 = 1 - alpha / a
            // H(e^jw) = (b0 + b1 e^-jw + b2 e^-2jw) / (a0 + a1 e^-jw + a2 e^-2jw)
            let nr = b0 + b1 * cos1 + b2 * cos2, ni = -(b1 * sin1 + b2 * sin2)
            let dr = a0 + a1 * cos1 + a2 * cos2, di = -(a1 * sin1 + a2 * sin2)
            let mag2 = (nr * nr + ni * ni) / max(1e-12, dr * dr + di * di)
            total += 10 * log10(max(1e-12, mag2))
        }
        return total
    }
}
