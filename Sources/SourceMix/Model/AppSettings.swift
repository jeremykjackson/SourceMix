import Foundation
import Observation

/// How the peak limiter (soft clipper) is applied.
enum LimiterMode: Int, CaseIterable, Identifiable, Sendable {
    case whenBoosting = 0
    case always = 1
    case off = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .whenBoosting: "Only When Boosting"
        case .always: "Always"
        case .off: "Off"
        }
    }

    var detail: String {
        switch self {
        case .whenBoosting:
            "Peaks are only rounded off while a source is turned up past 100%. At or below 100% the audio passes through untouched."
        case .always:
            "Peaks louder than about 85% of full scale are always rounded off, even at 100%. Slightly safer for loud material, but very loud passages are gently compressed."
        case .off:
            "Never touch peaks. Boosting past 100% can clip and distort on loud material."
        }
    }
}

/// Whether the HAL may varispeed a tapped stream to follow the output clock.
enum DriftMode: Int, CaseIterable, Identifiable, Sendable {
    case automatic = 0
    case on = 1
    case off = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .on: "Always On"
        case .off: "Off"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Only enabled when an app is playing to a different device than your output, so its clock could drift. Normally the app and your output share one clock, so no resampling happens."
        case .on:
            "macOS may very slightly speed up or slow down every tapped stream to keep it in sync with your output. Inaudible, but not bit-for-bit."
        case .off:
            "Never resample. If an app plays to a different device than your output, you may hear an occasional click as the clocks drift apart."
        }
    }
}

/// How sources with more than two channels are handled.
enum SurroundMode: Int, CaseIterable, Identifiable, Sendable {
    case passThrough = 0
    case mixToStereo = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .passThrough: "Keep All Channels"
        case .mixToStereo: "Mix Down to Stereo"
        }
    }

    var detail: String {
        switch self {
        case .passThrough:
            "When your output has more than two channels (e.g. an HDMI receiver), every channel is kept. The EQ applies to the front left/right pair; the other channels get volume and mute. With stereo outputs like built-in speakers or headphones this has no effect."
        case .mixToStereo:
            "Every source is folded to stereo before processing, so surround content plays from the front speakers only."
        }
    }
}

/// App-wide preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    static let defaultLimiter = LimiterMode.whenBoosting
    static let defaultDrift = DriftMode.automatic
    static let defaultSurround = SurroundMode.passThrough

    enum Key: String { case limiter, drift, surround }

    var limiter: LimiterMode {
        didSet { save(.limiter, limiter.rawValue) }
    }
    var drift: DriftMode {
        didSet { save(.drift, drift.rawValue) }
    }
    var surround: SurroundMode {
        didSet { save(.surround, surround.rawValue) }
    }

    /// Called after a setting changes.
    @ObservationIgnored var onChange: ((Key) -> Void)?

    private static let prefix = "SourceMix.settings."

    private init() {
        let d = UserDefaults.standard
        limiter = d.object(forKey: Self.prefix + Key.limiter.rawValue).flatMap { ($0 as? Int).flatMap(LimiterMode.init) } ?? Self.defaultLimiter
        drift = d.object(forKey: Self.prefix + Key.drift.rawValue).flatMap { ($0 as? Int).flatMap(DriftMode.init) } ?? Self.defaultDrift
        surround = d.object(forKey: Self.prefix + Key.surround.rawValue).flatMap { ($0 as? Int).flatMap(SurroundMode.init) } ?? Self.defaultSurround
    }

    var isDefault: Bool {
        limiter == Self.defaultLimiter && drift == Self.defaultDrift && surround == Self.defaultSurround
    }

    func restoreDefaults() {
        limiter = Self.defaultLimiter
        drift = Self.defaultDrift
        surround = Self.defaultSurround
    }

    private func save(_ key: Key, _ value: Int) {
        UserDefaults.standard.set(value, forKey: Self.prefix + key.rawValue)
        onChange?(key)
    }
}
