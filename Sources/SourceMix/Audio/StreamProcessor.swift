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
    private let limiter = Atomic<Int>(LimiterMode.whenBoosting.rawValue)
    private let activeCoefficientSet = Atomic<Int>(0)

    // EQ: 2 coefficient sets × 15 bands × (b0 b1 b2 a1 a2)
    private let coefficients: UnsafeMutablePointer<Float>
    // Filter state: 2 channels × 15 bands × (z1 z2)
    private let state: UnsafeMutablePointer<Float>

    // Metering (audio -> main)
    private let history: UnsafeMutablePointer<Float>
    private let historyWrite = Atomic<Int>(0)
    private let latestPeakBits = Atomic<UInt32>(0)

    // Health / diagnostics (audio -> main)
    private let callbacks = Atomic<Int>(0)
    private let silentCallbacks = Atomic<Int>(0)
    private let layoutBits = Atomic<Int>(0)
    private let nonFiniteResets = Atomic<Int>(0)

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
    func setLimiter(_ mode: LimiterMode) { limiter.store(mode.rawValue, ordering: .relaxed) }

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

    /// Number of IO callbacks so far (used by the stall watchdog).
    var callbackCount: Int { callbacks.load(ordering: .relaxed) }
    /// Callbacks that delivered no usable tap input.
    var emptyCallbackCount: Int { silentCallbacks.load(ordering: .relaxed) }
    /// Times the EQ state was reset after producing NaN/Inf.
    var filterResetCount: Int { nonFiniteResets.load(ordering: .relaxed) }

    /// Buffer layout seen by the IO callback, packed as
    /// inBuffers | inChannelsOfLast<<8 | outBuffers<<16 | outChannelsOfFirst<<24.
    var layoutDescription: String {
        let v = layoutBits.load(ordering: .relaxed)
        return "in: \(v & 0xFF) buffers (last has \((v >> 8) & 0xFF) ch), out: \((v >> 16) & 0xFF) buffers (first has \((v >> 24) & 0xFF) ch)"
    }

    func noteCallback(inBuffers: Int, inChannels: Int, outBuffers: Int, outChannels: Int, hadInput: Bool) {
        callbacks.wrappingAdd(1, ordering: .relaxed)
        if !hadInput { silentCallbacks.wrappingAdd(1, ordering: .relaxed) }
        let packed = (inBuffers & 0xFF) | (inChannels & 0xFF) << 8 | (outBuffers & 0xFF) << 16 | (outChannels & 0xFF) << 24
        layoutBits.store(packed, ordering: .relaxed)
    }

    // MARK: Audio thread

    /// Channel pointers for one IO cycle, filled by the render callback.
    /// Preallocated so the audio thread never allocates.
    final class ChannelIO {
        static let maxChannels = 32
        let input = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: maxChannels)
        let inputStride = UnsafeMutablePointer<Int>.allocate(capacity: maxChannels)
        let output = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: maxChannels)
        let outputStride = UnsafeMutablePointer<Int>.allocate(capacity: maxChannels)
        var inputCount = 0
        var outputCount = 0

        init() {
            input.initialize(repeating: nil, count: Self.maxChannels)
            inputStride.initialize(repeating: 1, count: Self.maxChannels)
            output.initialize(repeating: nil, count: Self.maxChannels)
            outputStride.initialize(repeating: 1, count: Self.maxChannels)
        }

        deinit {
            input.deallocate(); inputStride.deallocate()
            output.deallocate(); outputStride.deallocate()
        }

        func addInput(_ p: UnsafePointer<Float>, stride: Int) {
            guard inputCount < Self.maxChannels else { return }
            input[inputCount] = p; inputStride[inputCount] = stride; inputCount += 1
        }

        func addOutput(_ p: UnsafeMutablePointer<Float>, stride: Int) {
            guard outputCount < Self.maxChannels else { return }
            output[outputCount] = p; outputStride[outputCount] = stride; outputCount += 1
        }
    }

    /// Owned by the IO thread.
    let io = ChannelIO()

    /// Processes one IO cycle using the channels registered in `io`.
    ///
    /// With unity gain, a flat (bypassed) EQ, Stereo routing and the limiter
    /// not engaged, every sample is copied unchanged (bit-transparent).
    func process(frames: Int) {
        let nIn = io.inputCount
        let nOut = io.outputCount
        guard nIn > 0, nOut > 0, frames > 0 else { return }

        let target: Float = muted.load(ordering: .relaxed) ? 0 : Float(bitPattern: gainBits.load(ordering: .relaxed))
        let mode = ChannelMode(rawValue: channelMode.load(ordering: .relaxed)) ?? .stereo
        let limiterMode = LimiterMode(rawValue: limiter.load(ordering: .relaxed)) ?? .whenBoosting
        let useEQ = eqEnabled.load(ordering: .acquiring)
        let coeff = coefficients + activeCoefficientSet.load(ordering: .acquiring) * EQBands.count * 5
        let bands = EQBands.count
        let framesPerMeterPoint = max(64, Int(sampleRate / 75)) // ~75 points/sec

        let inL = io.input[0]!, sL = io.inputStride[0]
        let inR = nIn > 1 ? io.input[1]! : inL
        let sR = nIn > 1 ? io.inputStride[1] : sL
        let extraIn = max(0, nIn - 2)
        // Extra (surround) channels that have somewhere to go in Stereo mode.
        let extraPassed = max(0, min(nIn, nOut) - 2)
        let extraScale: Float = extraIn > 0 ? 0.5 / Float(extraIn) : 0

        var g = smoothedGain
        var blockPeak: Float = 0

        for frame in 0..<frames {
            var l = inL[frame * sL]
            var r = inR[frame * sR]
            if !l.isFinite { l = 0 }
            if !r.isFinite { r = 0 }

            var p = max(abs(l), abs(r))

            if useEQ {
                l = Self.runEQ(l, channel: 0, coeff: coeff, state: state, bands: bands)
                r = Self.runEQ(r, channel: 1, coeff: coeff, state: state, bands: bands)
            }

            // Gain smoothing; lands exactly on the target so unity stays exact.
            if g != target {
                g += (target - g) * 0.0015
                if abs(target - g) < 1e-6 { g = target }
            }
            if g != 1 {
                l *= g
                r *= g
            }

            // Extra input channels (surround / LFE etc.)
            var extraSum: Float = 0
            if extraIn > 0 {
                for c in 2..<nIn {
                    var x = io.input[c]![frame * io.inputStride[c]]
                    if !x.isFinite { x = 0 }
                    let a = abs(x); if a > p { p = a }
                    x *= g
                    if mode == .stereo, c - 2 < extraPassed {
                        io.output[c]![frame * io.outputStride[c]] += limit(x, mode: limiterMode, gain: g)
                    } else {
                        extraSum += x
                    }
                }
            }

            switch mode {
            case .stereo:
                // Channels the output can't carry are folded into L/R.
                if extraSum != 0 { l += extraSum * extraScale; r += extraSum * extraScale }
            case .left:
                l = (l + r) * 0.5 + extraSum * extraScale; r = 0
            case .right:
                r = (l + r) * 0.5 + extraSum * extraScale; l = 0
            case .mono:
                let m = (l + r) * 0.5 + extraSum * extraScale; l = m; r = m
            }

            if !l.isFinite { l = 0 }
            if !r.isFinite { r = 0 }
            l = limit(l, mode: limiterMode, gain: g)
            r = limit(r, mode: limiterMode, gain: g)

            if nOut >= 2 {
                io.output[0]![frame * io.outputStride[0]] += l
                io.output[1]![frame * io.outputStride[1]] += r
            } else {
                io.output[0]![frame * io.outputStride[0]] += (l + r) * 0.5
            }

            if p > meterAccumulator { meterAccumulator = p }
            if p > blockPeak { blockPeak = p }
            meterFrames += 1
            if meterFrames >= framesPerMeterPoint {
                pushMeter(meterAccumulator)
                meterAccumulator = 0
                meterFrames = 0
            }
        }
        smoothedGain = g.isFinite ? g : target
        latestPeakBits.store(blockPeak.isFinite ? blockPeak.bitPattern : 0, ordering: .relaxed)

        // A filter that blew up (NaN/Inf) would silence the stream forever;
        // detect it and reset the state.
        if useEQ {
            let count = 2 * EQBands.count * 2
            var bad = false
            for i in 0..<count where !state[i].isFinite { bad = true; break }
            if bad {
                state.update(repeating: 0, count: count)
                nonFiniteResets.wrappingAdd(1, ordering: .relaxed)
            }
        }
    }

    @inline(__always)
    private func limit(_ x: Float, mode: LimiterMode, gain: Float) -> Float {
        switch mode {
        case .off: return x
        case .always: return Self.softClip(x)
        case .whenBoosting: return gain > 1 ? Self.softClip(x) : x
        }
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
