import Foundation
import Synchronization

/// Where a stream's audio ends up.
enum ChannelMode: Int, Codable, CaseIterable, Identifiable, Sendable {
    case stereo = 0
    case left = 1
    case right = 2
    case mono = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .stereo: "Stereo"
        case .left: "Left"
        case .right: "Right"
        case .mono: "Mono"
        }
    }

    var shortLabel: String {
        switch self {
        case .stereo: "L R"
        case .left: "L"
        case .right: "R"
        case .mono: "M"
        }
    }

    var symbol: String {
        switch self {
        case .stereo: "speaker.wave.2"
        case .left: "l.circle"
        case .right: "r.circle"
        case .mono: "circle.circle"
        }
    }
}

/// ISO 1/1.5-octave, 15-band graphic EQ centre frequencies.
enum EQBands {
    static let frequencies: [Double] = [25, 40, 63, 100, 160, 250, 400, 630,
                                        1_000, 1_600, 2_500, 4_000, 6_300, 10_000, 16_000]
    static let count = 15
    static let q: Double = 2.1          // ≈ 2/3 octave bandwidth
    static let range: ClosedRange<Double> = -12...12

    static func label(for index: Int) -> String {
        let f = frequencies[index]
        if f >= 1_000 {
            let k = f / 1_000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(f))"
    }
}

/// Real-time DSP for one tapped stream: gain, mute, 15-band EQ, channel routing
/// and a peak-history ring buffer used to draw the waveform.
///
/// Parameters are written from the main thread and read from the Core Audio IO
/// thread through atomics; the IO path never allocates or locks.
final class StreamProcessor: @unchecked Sendable {
    static let historyLength = 96

    // Parameters (main -> audio)
    private let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let muted = Atomic<Bool>(false)
    private let channelMode = Atomic<Int>(ChannelMode.stereo.rawValue)
    private let eqEnabled = Atomic<Bool>(false)
    private let activeCoefficientSet = Atomic<Int>(0)

    // EQ: 2 coefficient sets × 15 bands × (b0 b1 b2 a1 a2)
    private let coefficients: UnsafeMutablePointer<Float>
    // Filter state: 2 channels × 15 bands × (z1 z2)
    private let state: UnsafeMutablePointer<Float>

    // Metering (audio -> main)
    private let history: UnsafeMutablePointer<Float>
    private let historyWrite = Atomic<Int>(0)
    private let latestPeakBits = Atomic<UInt32>(0)

    // Audio-thread-only state
    private var smoothedGain: Float = 1
    private var meterAccumulator: Float = 0
    private var meterFrames = 0
    private var sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        coefficients = .allocate(capacity: 2 * EQBands.count * 5)
        state = .allocate(capacity: 2 * EQBands.count * 2)
        history = .allocate(capacity: Self.historyLength)
        state.initialize(repeating: 0, count: 2 * EQBands.count * 2)
        history.initialize(repeating: 0, count: Self.historyLength)
        coefficients.initialize(repeating: 0, count: 2 * EQBands.count * 5)
        setEQ(gains: Array(repeating: 0, count: EQBands.count))
    }

    deinit {
        coefficients.deallocate()
        state.deallocate()
        history.deallocate()
    }

    // MARK: Parameter setters (main thread)

    func setGain(_ gain: Float) { gainBits.store(max(0, gain).bitPattern, ordering: .relaxed) }
    func setMuted(_ value: Bool) { muted.store(value, ordering: .relaxed) }
    func setChannelMode(_ mode: ChannelMode) { channelMode.store(mode.rawValue, ordering: .relaxed) }

    func setEQ(gains: [Double], enabled: Bool = true) {
        let flat = gains.allSatisfy { abs($0) < 0.05 }
        let next = 1 - activeCoefficientSet.load(ordering: .acquiring)
        let base = coefficients + next * EQBands.count * 5
        for band in 0..<EQBands.count {
            let c = Self.peaking(frequency: EQBands.frequencies[band],
                                 gainDB: band < gains.count ? gains[band] : 0,
                                 q: EQBands.q,
                                 sampleRate: sampleRate)
            for i in 0..<5 { base[band * 5 + i] = c[i] }
        }
        activeCoefficientSet.store(next, ordering: .releasing)
        eqEnabled.store(enabled && !flat, ordering: .releasing)
    }

    /// RBJ cookbook peaking filter, normalised so a0 == 1.
    private static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> [Float] {
        let f = min(frequency, sampleRate * 0.45)
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return [
            Float((1 + alpha * a) / a0),
            Float((-2 * cosw) / a0),
            Float((1 - alpha * a) / a0),
            Float((-2 * cosw) / a0),
            Float((1 - alpha / a) / a0)
        ]
    }

    // MARK: Metering (main thread)

    /// Most recent peak history, oldest first, values 0…1.
    func peakHistory(into buffer: inout [Float]) {
        let n = Self.historyLength
        if buffer.count != n { buffer = Array(repeating: 0, count: n) }
        let write = historyWrite.load(ordering: .acquiring)
        for i in 0..<n {
            buffer[i] = history[(write + i) % n]
        }
    }

    var currentPeak: Float { Float(bitPattern: latestPeakBits.load(ordering: .relaxed)) }

    // MARK: Audio thread

    /// Processes one IO cycle.
    /// - Parameters:
    ///   - left/right: input sample pointers (may be the same for mono input).
    ///   - inStride: distance between successive frames in the input buffers.
    ///   - outLeft/outRight: destination pointers (nil to discard).
    ///   - outStride: distance between successive frames in the output buffers.
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, inStride: Int,
                 outLeft: UnsafeMutablePointer<Float>?, outRight: UnsafeMutablePointer<Float>?, outStride: Int,
                 frames: Int) {
        let target: Float = muted.load(ordering: .relaxed) ? 0 : Float(bitPattern: gainBits.load(ordering: .relaxed))
        let mode = ChannelMode(rawValue: channelMode.load(ordering: .relaxed)) ?? .stereo
        let useEQ = eqEnabled.load(ordering: .acquiring)
        let coeff = coefficients + activeCoefficientSet.load(ordering: .acquiring) * EQBands.count * 5
        let bands = EQBands.count
        let framesPerMeterPoint = max(64, Int(sampleRate / 75)) // ~75 points/sec

        var g = smoothedGain
        var blockPeak: Float = 0

        for frame in 0..<frames {
            var l = left[frame * inStride]
            var r = right[frame * inStride]

            let p = max(abs(l), abs(r))
            if p > meterAccumulator { meterAccumulator = p }
            if p > blockPeak { blockPeak = p }

            if useEQ {
                l = Self.runEQ(l, channel: 0, coeff: coeff, state: state, bands: bands)
                r = Self.runEQ(r, channel: 1, coeff: coeff, state: state, bands: bands)
            }

            g += (target - g) * 0.0015
            l *= g
            r *= g

            switch mode {
            case .stereo: break
            case .left: l = (l + r) * 0.5; r = 0
            case .right: r = (l + r) * 0.5; l = 0
            case .mono: let m = (l + r) * 0.5; l = m; r = m
            }

            if let outLeft { outLeft[frame * outStride] += Self.softClip(l) }
            if let outRight { outRight[frame * outStride] += Self.softClip(r) }

            meterFrames += 1
            if meterFrames >= framesPerMeterPoint {
                pushMeter(meterAccumulator)
                meterAccumulator = 0
                meterFrames = 0
            }
        }
        smoothedGain = g
        latestPeakBits.store(blockPeak.bitPattern, ordering: .relaxed)
    }

    /// Records silence in the meter when the source isn't delivering audio.
    func decayMeter() {
        pushMeter(0)
        latestPeakBits.store(0, ordering: .relaxed)
    }

    private func pushMeter(_ value: Float) {
        let n = Self.historyLength
        let w = historyWrite.load(ordering: .relaxed)
        history[w] = min(1, value)
        historyWrite.store((w + 1) % n, ordering: .releasing)
    }

    @inline(__always)
    private static func runEQ(_ x: Float, channel: Int, coeff: UnsafeMutablePointer<Float>,
                              state: UnsafeMutablePointer<Float>, bands: Int) -> Float {
        var y = x
        let s = state + channel * bands * 2
        for b in 0..<bands {
            let c = coeff + b * 5
            let z = s + b * 2
            // Transposed direct form II
            let out = c[0] * y + z[0]
            z[0] = c[1] * y - c[3] * out + z[1]
            z[1] = c[2] * y - c[4] * out
            y = out
        }
        return y
    }

    @inline(__always)
    private static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.85
        let a = abs(x)
        guard a > knee else { return x }
        let over = (a - knee) / (1 - knee)
        let shaped = knee + (1 - knee) * tanh(over)
        return x < 0 ? -shaped : shaped
    }
}
