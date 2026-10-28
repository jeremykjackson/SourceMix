import AppKit
import CoreAudio
import Observation
import OSLog

private let log = Logger(subsystem: "com.jeremyjackson.SourceMix", category: "Mixer")

/// One app (or system service) that is producing audio.
@MainActor
@Observable
final class AudioSource: Identifiable {
    let id: String
    var name: String
    var icon: NSImage
    var isPlaying = false
    var lastActive = Date()
    var errorText: String?

    var settings: SourceSettings {
        didSet {
            guard settings != oldValue else { return }
            apply(settings, previous: oldValue)
            onSettingsChanged?(self)
        }
    }

    @ObservationIgnored var processObjects: [AudioObjectID] = []
    @ObservationIgnored private(set) var tap: ProcessTap?
    @ObservationIgnored var onSettingsChanged: ((AudioSource) -> Void)?

    var processor: StreamProcessor? { tap?.processor }
    var isTapped: Bool { tap?.isRunning == true }

    init(id: String, name: String, icon: NSImage, settings: SourceSettings) {
        self.id = id
        self.name = name
        self.icon = icon
        self.settings = settings
    }

    func startTap(outputDevice: AudioDeviceID) {
        stopTap()
        guard !processObjects.isEmpty, outputDevice.isValid else { return }
        let processor = StreamProcessor(sampleRate: outputDevice.nominalSampleRate)
        let tap = ProcessTap(processObjects: processObjects, outputDevice: outputDevice, processor: processor)
        // Configure before audio starts flowing so there is no full-volume blip.
        self.tap = tap
        apply(settings, previous: nil)
        do {
            try tap.start(label: name)
            errorText = nil
        } catch {
            log.error("Tap failed for \(self.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorText = error.localizedDescription
            self.tap = nil
        }
    }

    func stopTap() {
        tap?.stop()
        tap = nil
    }

    private func apply(_ s: SourceSettings, previous: SourceSettings?) {
        guard let processor = tap?.processor else { return }
        processor.setGain(Float(s.gain))
        processor.setMuted(s.muted)
        processor.setChannelMode(s.channel)
        if previous == nil || previous?.eqGains != s.eqGains || previous?.eqEnabled != s.eqEnabled {
            processor.setEQ(gains: s.eqGains, enabled: s.eqEnabled)
        }
    }

    // Convenience bindings
    func toggleMute() { settings.muted.toggle() }
    func resetEQ() { settings.eqGains = Array(repeating: 0, count: EQBands.count) }
}

/// Discovers audio-producing processes, owns their taps and exposes the
/// state the UI binds to.
@MainActor
@Observable
final class MixerStore {
    static let shared = MixerStore()

    private(set) var sources: [AudioSource] = []
    private(set) var permission: AudioCapturePermission.Status = .unknown
    private(set) var outputName = "Output"
    var systemVolume: Double = 0.5
    var systemMuted = false
    private(set) var systemHasVolume = true

    /// Sources that have gone quiet stay listed this long (unless customised).
    private let idleGrace: TimeInterval = 20

    @ObservationIgnored private var saved: [String: SourceSettings] = SettingsStore.load()
    @ObservationIgnored private var outputDevice: AudioDeviceID = .unknownObject
    @ObservationIgnored private let systemOutput = SystemOutput()
    @ObservationIgnored private var listeners: [PropertyListener] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        systemOutput.onChange = { [weak self] in self?.readSystemOutput() }
        attachToDefaultOutput()

        listeners.append(PropertyListener(object: .system, selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.defaultOutputChanged()
        })
        listeners.append(PropertyListener(object: .system, selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.refresh()
        })

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pollTimer?.tolerance = 0.3

        permission = AudioCapturePermission.status
        if permission != .authorized {
            requestPermission()
        }
        refresh()
    }

    func requestPermission() {
        AudioCapturePermission.requestAccess { [weak self] granted in
            guard let self else { return }
            self.permission = granted ? .authorized : .denied
            self.refresh()
        }
    }

    func shutdown() {
        persistNow()
        for source in sources { source.stopTap() }
    }

    // MARK: Output device

    private func attachToDefaultOutput() {
        outputDevice = (try? AudioObjectID.defaultOutputDevice()) ?? .unknownObject
        systemOutput.attach(to: outputDevice)
        readSystemOutput()
    }

    private func defaultOutputChanged() {
        let newDevice = (try? AudioObjectID.defaultOutputDevice()) ?? .unknownObject
        guard newDevice != outputDevice else { return }
        attachToDefaultOutput()
        for source in sources where source.isTapped || source.tap != nil {
            source.startTap(outputDevice: outputDevice)
        }
    }

    private func readSystemOutput() {
        outputName = systemOutput.deviceName
        systemHasVolume = systemOutput.hasVolumeControl
        systemVolume = Double(systemOutput.volume)
        systemMuted = systemOutput.isMuted
    }

    func setSystemVolume(_ value: Double) {
        systemVolume = value
        systemOutput.volume = Float(value)
        if systemMuted && value > 0 { setSystemMuted(false) }
    }

    func setSystemMuted(_ muted: Bool) {
        systemMuted = muted
        systemOutput.isMuted = muted
    }

    // MARK: Discovery

    private struct Group {
        var objects: [AudioObjectID] = []
        var playing = false
        var name = ""
        var icon: NSImage?
    }

    func refresh() {
        guard let objects = try? AudioObjectID.processObjects() else { return }
        let ownPID = getpid()
        var groups: [String: Group] = [:]

        for object in objects {
            let pid = object.processPID
            guard pid > 0, pid != ownPID else { continue }
            let bundleID = object.processBundleID
            let owner = ProcessOwnership.owningApplication(for: pid)
            if owner?.processIdentifier == ownPID { continue }

            let key = owner?.bundleIdentifier ?? bundleID ?? "pid.\(pid)"
            var group = groups[key] ?? Group()
            group.objects.append(object)
            group.playing = group.playing || object.processIsRunningOutput
            if group.name.isEmpty {
                group.name = Self.displayName(key: key, app: owner, bundleID: bundleID, pid: pid)
                group.icon = owner?.icon
            }
            groups[key] = group
        }

        let now = Date()
        var byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var changed = false

        for (key, group) in groups {
            if let source = byID[key] {
                if group.playing { source.lastActive = now }
                if source.isPlaying != group.playing {
                    source.isPlaying = group.playing
                    changed = true
                }
                if Set(source.processObjects) != Set(group.objects) {
                    source.processObjects = group.objects
                    if canTap { source.startTap(outputDevice: outputDevice) }
                }
            } else if group.playing {
                let source = AudioSource(id: key, name: group.name,
                                         icon: group.icon ?? Self.fallbackIcon(for: key),
                                         settings: saved[key] ?? .default)
                source.processObjects = group.objects
                source.isPlaying = true
                source.onSettingsChanged = { [weak self] s in self?.settingsChanged(s) }
                if canTap { source.startTap(outputDevice: outputDevice) }
                byID[key] = source
                changed = true
            }
        }

        // Retire sources whose processes are gone, or that have been idle a
        // while and carry no custom settings (keeps the app lightweight).
        for (key, source) in byID {
            let alive = groups[key] != nil
            let idleTooLong = !source.isPlaying && now.timeIntervalSince(source.lastActive) > idleGrace
            if !alive || (idleTooLong && source.settings.isDefault) {
                source.stopTap()
                byID[key] = nil
                changed = true
            } else if canTap && source.tap == nil && source.errorText == nil {
                source.startTap(outputDevice: outputDevice)
            }
        }

        if changed || byID.count != sources.count {
            sources = byID.values.sorted { a, b in
                if a.isPlaying != b.isPlaying { return a.isPlaying }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    private var canTap: Bool { permission == .authorized }

    // MARK: Settings

    private func settingsChanged(_ source: AudioSource) {
        saved[source.id] = source.settings
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.persistNow() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func persistNow() {
        SettingsStore.save(saved)
    }

    func source(id: String) -> AudioSource? { sources.first { $0.id == id } }

    func resetAll() {
        for source in sources { source.settings = .default }
    }

    // MARK: Naming

    private static let friendlyNames: [String: String] = [
        "com.apple.systemsoundserverd": "System Sounds",
        "com.apple.SystemSoundServer-macOS": "System Sounds",
        "com.apple.CoreSpeech": "Siri",
        "com.apple.assistantd": "Siri",
        "com.apple.speech.speechsynthesisd": "Speech",
        "com.apple.NotificationCenter": "Notifications",
        "com.apple.WebKit.GPU": "Web Content",
        "com.apple.avconferenced": "FaceTime",
        "com.apple.universalaccessd": "Accessibility"
    ]

    private static func displayName(key: String, app: NSRunningApplication?, bundleID: String?, pid: pid_t) -> String {
        if let friendly = friendlyNames[key] ?? bundleID.flatMap({ friendlyNames[$0] }) { return friendly }
        if let name = app?.localizedName, !name.isEmpty { return name }
        if let bundleID, let last = bundleID.split(separator: ".").last { return String(last) }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "Process \(pid)" : name
    }

    private static func fallbackIcon(for key: String) -> NSImage {
        let symbol = key.contains("systemsound") ? "bell.fill" : "app.dashed"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
    }
}
