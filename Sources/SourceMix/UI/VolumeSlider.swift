import SwiftUI

/// Supplies the current audio level (linear peak, 0…1+) for the meter bar.
protocol LevelHistoryProvider {
    func level() -> Float
}

struct ProcessorLevels: LevelHistoryProvider {
    let processor: StreamProcessor?
    func level() -> Float { processor?.currentPeak ?? 0 }
}

/// Loudest of several processors – used by the Output strip.
struct CombinedLevels: LevelHistoryProvider {
    let processors: [StreamProcessor]
    func level() -> Float { processors.map(\.currentPeak).max() ?? 0 }
}

/// Smooths raw peaks into a meter that rises instantly and falls gently.
private final class MeterBallistics {
    var display: Double = 0
    var lastUpdate = Date()

    func update(peak: Float, at now: Date) -> Double {
        let dt = min(0.25, now.timeIntervalSince(lastUpdate))
        lastUpdate = now
        // Map -54…0 dBFS onto 0…1 so quiet audio still moves the bar.
        let db = 20 * log10(max(Double(peak), 1e-6))
        let target = min(1, max(0, (db + 54) / 54))
        if target >= display {
            display = target
        } else {
            display = max(target, display - dt * 1.4)   // ~0.7 s full fall
        }
        return display
    }
}

/// Vertical volume slider: a thin light-grey track, an accent fill up to the
/// volume, a slightly darker level bar that rises and falls with the audio,
/// and a pill-shaped knob.
struct VolumeSlider: View {
    @Binding var value: Double
    var levels: any LevelHistoryProvider
    var isMuted = false
    var tint: Color = .accentColor
    var unityMark: Double? = SourceSettings.unityPosition
    var defaultValue: Double = SourceSettings.unityPosition
    /// Width of the touch area; the visible track is much thinner.
    var width: CGFloat = 34
    var accessibilityName = "Volume"

    @State private var meter = MeterBallistics()
    @State private var isDragging = false
    @Environment(\.colorScheme) private var colorScheme

    private let trackWidth: CGFloat = 6
    private let knobSize = CGSize(width: 20, height: 26)

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let travel = max(1, h - knobSize.height)
            let knobY = (1 - CGFloat(value)) * travel          // top of knob
            let knobCenter = knobY + knobSize.height / 2

            ZStack(alignment: .top) {
                // Thin light-grey track
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10))
                    .frame(width: trackWidth, height: h)

                // Volume fill (bottom → knob)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Capsule(style: .continuous)
                        .fill(isMuted ? AnyShapeStyle(Color.secondary.opacity(0.35))
                                      : AnyShapeStyle(tint.gradient))
                        .frame(width: trackWidth, height: max(trackWidth, h - knobCenter))
                }
                .frame(height: h)

                // Live level bar: slightly darker, rises and falls with the audio
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let level = meter.update(peak: levels.level(), at: context.date)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Capsule(style: .continuous)
                            .fill(meterColor)
                            .frame(width: trackWidth, height: level > 0.01 ? max(trackWidth, CGFloat(level) * h) : 0)
                    }
                    .frame(height: h)
                }
                .allowsHitTesting(false)

                // Unity tick
                if let unityMark {
                    let y = (1 - CGFloat(unityMark)) * travel + knobSize.height / 2
                    Capsule()
                        .fill(Color.primary.opacity(0.3))
                        .frame(width: trackWidth + 8, height: 2)
                        .offset(y: y - 1)
                        .allowsHitTesting(false)
                }

                // Pill knob – a slightly elongated circle
                Capsule(style: .continuous)
                    .fill(.white)
                    .frame(width: knobSize.width, height: knobSize.height)
                    .overlay { Capsule().strokeBorder(.black.opacity(0.08), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(isDragging ? 0.32 : 0.2), radius: isDragging ? 5 : 3, y: 1)
                    .scaleEffect(isDragging ? 1.1 : 1)
                    .offset(y: knobY)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        let v = 1 - Double((g.location.y - knobSize.height / 2) / travel)
                        value = snap(min(1, max(0, v)))
                    }
                    .onEnded { _ in isDragging = false }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = defaultValue })
        }
        .frame(width: width)
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
        .help("Drag to adjust · double-click to reset")
    }

    private var meterColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.45) : Color.black.opacity(0.22)
    }

    /// Gentle magnetic snap to the unity mark.
    private func snap(_ v: Double) -> Double {
        if let unityMark, abs(v - unityMark) < 0.015 { return unityMark }
        return v
    }
}

/// Small activity dot used where space is tight.
struct PeakDot: View {
    let processor: StreamProcessor?
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { _ in
            let p = Double(processor?.currentPeak ?? 0)
            Circle()
                .fill(p > 0.002 ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .opacity(p > 0.002 ? 0.6 + min(0.4, p) : 1)
        }
    }
}
