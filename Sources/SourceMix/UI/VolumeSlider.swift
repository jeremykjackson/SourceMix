import SwiftUI

/// Supplies recent peak levels (oldest first, 0…1) for the waveform overlay.
protocol LevelHistoryProvider {
    func levels(into buffer: inout [Float])
}

struct ProcessorLevels: LevelHistoryProvider {
    let processor: StreamProcessor?
    func levels(into buffer: inout [Float]) {
        if let processor {
            processor.peakHistory(into: &buffer)
        } else {
            if buffer.count != StreamProcessor.historyLength {
                buffer = Array(repeating: 0, count: StreamProcessor.historyLength)
            } else {
                for i in buffer.indices { buffer[i] = 0 }
            }
        }
    }
}

/// Combined (max) level of several processors – used by the Output strip.
struct CombinedLevels: LevelHistoryProvider {
    let processors: [StreamProcessor]
    func levels(into buffer: inout [Float]) {
        let n = StreamProcessor.historyLength
        if buffer.count != n { buffer = Array(repeating: 0, count: n) }
        for i in 0..<n { buffer[i] = 0 }
        var scratch = [Float](repeating: 0, count: n)
        for p in processors {
            p.peakHistory(into: &scratch)
            for i in 0..<n where scratch[i] > buffer[i] { buffer[i] = scratch[i] }
        }
    }
}

private final class WaveScratch {
    var buffer = [Float](repeating: 0, count: StreamProcessor.historyLength)
}

/// Tall capsule volume slider. The light-grey track carries a slightly darker,
/// live waveform of the source; the accent fill shows the current level.
struct VolumeSlider: View {
    @Binding var value: Double
    var levels: any LevelHistoryProvider
    var isMuted = false
    var tint: Color = .accentColor
    var unityMark: Double? = SourceSettings.unityPosition
    var defaultValue: Double = SourceSettings.unityPosition
    var width: CGFloat = 34
    var accessibilityName = "Volume"

    @State private var scratch = WaveScratch()
    @State private var isDragging = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let knobH: CGFloat = 16
            let travel = max(1, h - knobH)
            let knobY = (1 - CGFloat(value)) * travel

            ZStack(alignment: .top) {
                // Light grey track
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))

                // Level fill (bottom → value)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Capsule(style: .continuous)
                        .fill(isMuted ? AnyShapeStyle(Color.secondary.opacity(0.35))
                                      : AnyShapeStyle(tint.gradient.opacity(0.85)))
                        .frame(height: max(w, h - knobY))
                }

                // Slightly darker live waveform over the track
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    Canvas { context, size in
                        levels.levels(into: &scratch.buffer)
                        drawWaveform(context: context, size: size, values: scratch.buffer)
                    }
                }
                .clipShape(Capsule(style: .continuous))
                .allowsHitTesting(false)

                // Unity tick
                if let unityMark {
                    let y = (1 - CGFloat(unityMark)) * travel + knobH / 2
                    Capsule()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: w * 0.36, height: 2)
                        .offset(y: y - 1)
                        .allowsHitTesting(false)
                }

                // Knob
                Capsule(style: .continuous)
                    .fill(.white)
                    .frame(width: w + 6, height: knobH)
                    .shadow(color: .black.opacity(isDragging ? 0.3 : 0.18), radius: isDragging ? 5 : 3, y: 1)
                    .overlay {
                        Capsule().strokeBorder(.black.opacity(0.06), lineWidth: 0.5)
                    }
                    .scaleEffect(isDragging ? 1.08 : 1)
                    .offset(y: knobY)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        let v = 1 - Double((g.location.y - knobH / 2) / travel)
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

    /// Gentle magnetic snap to the unity mark.
    private func snap(_ v: Double) -> Double {
        if let unityMark, abs(v - unityMark) < 0.015 { return unityMark }
        return v
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize, values: [Float]) {
        let n = values.count
        guard n > 1 else { return }
        let midX = size.width / 2
        let maxHalf = size.width * 0.46
        let step = size.height / CGFloat(n - 1)

        // Oldest at the top, newest at the bottom: the waveform scrolls upward.
        var left = Path()
        var right: [CGPoint] = []
        right.reserveCapacity(n)
        for i in 0..<n {
            let amp = CGFloat(sqrt(max(0, values[i]))) * maxHalf
            let y = CGFloat(i) * step
            let pL = CGPoint(x: midX - amp, y: y)
            if i == 0 { left.move(to: pL) } else { left.addLine(to: pL) }
            right.append(CGPoint(x: midX + amp, y: y))
        }
        for p in right.reversed() { left.addLine(to: p) }
        left.closeSubpath()

        let shade = colorScheme == .dark ? Color.black.opacity(0.35) : Color.black.opacity(0.14)
        context.fill(left, with: .color(shade))
    }
}

/// Small horizontal level meter used where space is tight.
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
