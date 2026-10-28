import Foundation

/// User-adjustable settings for one audio source, persisted per app.
struct SourceSettings: Codable, Equatable, Sendable {
    /// Slider position 0…1. Unity gain (100 %) sits at `unityPosition`, leaving
    /// the top quarter of the slider for up to +9 dB of boost.
    var position: Double = SourceSettings.unityPosition
    var muted = false
    var channel: ChannelMode = .stereo
    var eqGains: [Double] = Array(repeating: 0, count: EQBands.count)
    var eqEnabled = true

    static let unityPosition = 0.75
    static let maxBoostDB = 9.0
    static let `default` = SourceSettings()

    var isDefault: Bool { self == .default }
    var isEQActive: Bool { eqEnabled && eqGains.contains { abs($0) >= 0.05 } }

    /// Linear gain for a slider position.
    static func gain(for position: Double) -> Double {
        let p = min(1, max(0, position))
        if p <= unityPosition {
            let x = p / unityPosition
            return x * x * x             // cubic taper ≈ perceptual fade
        }
        let boost = (p - unityPosition) / (1 - unityPosition) * maxBoostDB
        return pow(10, boost / 20)
    }

    var gain: Double { Self.gain(for: position) }

    /// Human-readable level: 0–100 % below unity, then "+x dB".
    var levelText: String {
        if muted { return "Muted" }
        if position <= Self.unityPosition {
            return "\(Int((position / Self.unityPosition * 100).rounded()))%"
        }
        let db = (position - Self.unityPosition) / (1 - Self.unityPosition) * Self.maxBoostDB
        return String(format: "+%.1f dB", db)
    }
}

struct EQPreset: Identifiable, Hashable {
    let name: String
    let gains: [Double]
    var id: String { name }

    //                       25   40   63  100  160  250  400  630   1k 1.6k 2.5k   4k 6.3k  10k  16k
    static let all: [EQPreset] = [
        EQPreset(name: "Flat",          gains: [ 0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0]),
        EQPreset(name: "Bass Boost",    gains: [ 6,   6,   5,   4,   3,   1.5, 0,   0,   0,   0,   0,   0,   0,   0,   0]),
        EQPreset(name: "Bass Cut",      gains: [-8,  -7,  -6,  -4,  -2,  -1,   0,   0,   0,   0,   0,   0,   0,   0,   0]),
        EQPreset(name: "Treble Boost",  gains: [ 0,   0,   0,   0,   0,   0,   0,   0,   0,   1,   2,   3.5, 5,   6,   6]),
        EQPreset(name: "Vocal",         gains: [-4,  -3,  -2,  -1,   0,   1,   2.5, 3.5, 4,   3.5, 2.5, 1,   0,  -1,  -2]),
        EQPreset(name: "Loudness",      gains: [ 5,   4.5, 3.5, 2,   0.5, 0,  -1,  -1,   0,   0,   0.5, 1.5, 3,   4,   4.5]),
        EQPreset(name: "Speech",        gains: [-12, -10, -7,  -4,  -1,   1,   3,   4,   4,   3,   2,   1,  -1,  -3,  -6]),
        EQPreset(name: "Night Mode",    gains: [-6,  -5,  -4,  -2,   0,   0,   1,   1,   1,   1,   0,  -1,  -2,  -4,  -5])
    ]
}

/// Persists settings per source key (usually the app's bundle identifier).
enum SettingsStore {
    private static let key = "SourceMix.sourceSettings.v1"

    static func load() -> [String: SourceSettings] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: SourceSettings].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func save(_ all: [String: SourceSettings]) {
        let trimmed = all.filter { !$0.value.isDefault }
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
