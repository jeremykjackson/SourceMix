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
    private(set) var tap: ProcessTap?
    @ObservationIgnored var onSettingsChanged: ((AudioSource) -> Void)?
    @ObservationIgnored var lastTapStart = Date.distantPast
    @ObservationIgnored var lastCallbackCount = -1
    @ObservationIgnored var restartCount = 0

    var processor: StreamProcessor? { tap?.processor }
    var isTapped: Bool { tap?.isRunning == true }

    init(id: String, name: String, icon: NSImage, settings: SourceSettings) {
        self.id = id
        self.name = name
        self.icon = icon
        self.settings = settings
    }

    func startTap(outputDevice: AudioDeviceID, reason: String) {
        log.notice("(Re)starting tap for \(self.name, privacy: .public) – \(reason, privacy: .public)")
        stopTap()
        lastTapStart = Date()
        lastCallbackCount = -1
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
    /// Non-nil while processing is paused because the current output is a
    /// virtual/aggregate device that another app relays (e.g. Teams Audio).
    private(set) var bypassReason: String?

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

        log.notice("Launch: default output \(self.outputDevice.name, privacy: .public) (\(self.outputDevice)); devices \(Self.deviceListDescription(), privacy: .public)")
        listeners.append(PropertyListener(object: .system, selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            let now = (try? AudioObjectID.defaultOutputDevice()) ?? .unknownObject
            log.notice("macOS reports default output changed → \(now.name, privacy: .public) (\(now)); our taps running: \(self?.sources.filter(\.isTapped).count ?? 0)")
            self?.defaultOutputChanged()
        })
        listeners.append(PropertyListener(object: .system, selector: kAudioHardwarePropertyDevices) {
            log.notice("Audio device list changed: \(Self.deviceListDescription(), privacy: .public)")
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
        // Always follow the output chosen in macOS (Sound settings / Control
        // Center / the app that selected it). SourceMix never changes it.
        outputDevice = (try? AudioObjectID.defaultOutputDevice()) ?? .unknownObject
        systemOutput.attach(to: outputDevice)
        readSystemOutput()
        updateBypass()
    }

    private func updateBypass() {
        let reason: String?
        if !outputDevice.isValid {
            reason = "No output device is selected."
        } else if outputDevice.isVirtualOrAggregate {
            reason = "Your Mac's output is set to “\(outputDevice.name)”, a virtual device another app relays. SourceMix is paused until a regular output (speakers, headphones…) is selected in Sound settings."
        } else {
            reason = nil
        }
        if reason != bypassReason {
            bypassReason = reason
            if let reason {
                log.notice("Bypassing: \(reason, privacy: .public)")
                for source in sources { source.stopTap() }
            } else {
                log.notice("Bypass cleared; output \(self.outputDevice.name, privacy: .public)")
            }
        }
    }

    private func defaultOutputChanged() {
        let newDevice = (try? AudioObjectID.defaultOutputDevice()) ?? .unknownObject
        guard newDevice != outputDevice else { return }
        log.notice("Default output changed to \(newDevice.name, privacy: .public) (\(newDevice))")
        attachToDefaultOutput()
        guard canTap else { return }
        for source in sources {
            source.startTap(outputDevice: outputDevice, reason: "output device changed")
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
            if let bundleID, Self.ignoredBundleIDs.contains(bundleID) { continue }
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
                // Rebuild the tap only when the app gained a new audio
                // process (e.g. a new browser tab helper), and at most every
                // few seconds – churn here is expensive and glitchy.
                let tapped = Set(source.tap?.processObjects ?? source.processObjects)
                source.processObjects = group.objects
                let added = Set(group.objects).subtracting(tapped)
                if !added.isEmpty, canTap, now.timeIntervalSince(source.lastTapStart) > 3 {
                    source.startTap(outputDevice: outputDevice, reason: "new audio process(es) \(added.sorted())")
                }
            } else if group.playing {
                let source = AudioSource(id: key, name: group.name,
                                         icon: group.icon ?? Self.fallbackIcon(for: key),
                                         settings: saved[key] ?? .default)
                source.processObjects = group.objects
                source.isPlaying = true
                source.onSettingsChanged = { [weak self] s in self?.settingsChanged(s) }
                log.notice("New source \(group.name, privacy: .public) [\(key, privacy: .public)] objects \(group.objects, privacy: .public)")
                if canTap { source.startTap(outputDevice: outputDevice, reason: "started playing") }
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
                log.notice("Retiring source \(source.name, privacy: .public): \(alive ? "idle" : "process gone", privacy: .public)")
                source.stopTap()
                byID[key] = nil
                changed = true
            } else if canTap && source.tap == nil {
                // No tap yet, or the last attempt failed: retry, gently.
                if source.errorText == nil || now.timeIntervalSince(source.lastTapStart) > 10 {
                    source.startTap(outputDevice: outputDevice, reason: source.errorText == nil ? "no tap" : "retry after error")
                }
            } else if let processor = source.processor, canTap {
                // Watchdog: if the IO callback stopped running, the app stays
                // muted by its tap – restart it rather than leave silence.
                let count = processor.callbackCount
                if count == source.lastCallbackCount,
                   now.timeIntervalSince(source.lastTapStart) > 2,
                   now.timeIntervalSince(source.lastTapStart) > Double(min(30, 3 << min(source.restartCount, 3))) {
                    source.restartCount += 1
                    log.error("IO stalled for \(source.name, privacy: .public) (callbacks stuck at \(count)); restart #\(source.restartCount)")
                    source.startTap(outputDevice: outputDevice, reason: "IO watchdog")
                } else {
                    source.lastCallbackCount = count
                }
            }
        }

        if changed || byID.count != sources.count {
            sources = byID.values.sorted { a, b in
                if a.isPlaying != b.isPlaying { return a.isPlaying }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    private var canTap: Bool { permission == .authorized && bypassReason == nil }

    /// Background services that report output constantly or must never be
    /// tapped (speech recognition, audio relays).
    private static let ignoredBundleIDs: Set<String> = [
        "com.apple.CoreSpeech",
        "com.apple.accessibility.heard",
        "com.apple.audio.Core-Audio-Driver-Service.helper",
        "com.apple.audiomxd"
    ]

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
        for source in sources where !source.settings.isDefault {
            let st = source.settings
            log.notice("Settings \(source.name, privacy: .public): pos \(st.position) gain \(st.gain) muted \(st.muted) ch \(st.channel.label, privacy: .public) eq \(st.isEQActive)")
        }
    }

    // MARK: Diagnostics

    /// Public (non-private) audio devices, e.g. "MacBook Pro Speakers(84,bltn) …".
    static func deviceListDescription() -> String {
        let devices = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, element: AudioObjectID.unknownObject)) ?? []
        return devices.map { "\($0.name)(\($0),\($0.transportType.fourCCString))" }.joined(separator: ", ")
    }

    func diagnosticsSnapshot() -> String {
        var lines: [String] = []
        let info = ProcessInfo.processInfo
        lines.append("SourceMix \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") on macOS \(info.operatingSystemVersionString)")
        lines.append("Date: \(Date())")
        lines.append("Permission: \(permission)")
        lines.append("Bypass: \(bypassReason ?? "no")")
        lines.append("Output: \(outputDevice.name) id \(outputDevice) uid \(outputDevice.deviceUID ?? "?") transport \(outputDevice.transportType.fourCCString) @ \(outputDevice.nominalSampleRate) Hz, streams out \(outputDevice.streamChannelSummary(scope: kAudioObjectPropertyScopeOutput)) in \(outputDevice.streamChannelSummary(scope: kAudioObjectPropertyScopeInput))")
        lines.append("Devices: \(Self.deviceListDescription())")
        lines.append("System volume \(systemVolume) muted \(systemMuted)")
        lines.append("Sources (\(sources.count)):")
        for s in sources {
            lines.append("• \(s.name) [\(s.id)] playing \(s.isPlaying) objects \(s.processObjects) error \(s.errorText ?? "none")")
            lines.append("    settings: pos \(s.settings.position) gain \(s.settings.gain) muted \(s.settings.muted) channel \(s.settings.channel.label) eqActive \(s.settings.isEQActive) eq \(s.settings.eqGains)")
            if let tap = s.tap {
                let p = tap.processor
                lines.append("    tap: running \(tap.isRunning) since \(tap.startedAt) aggregate \(tap.aggregateDeviceID) tapped \(tap.processObjects) callbacks \(p.callbackCount) empty \(p.emptyCallbackCount) filterResets \(p.filterResetCount) peak \(p.currentPeak) restarts \(s.restartCount)")
                lines.append("    layout: \(p.layoutDescription); aggregate streams in \(tap.aggregateDeviceID.streamChannelSummary(scope: kAudioObjectPropertyScopeInput)) out \(tap.aggregateDeviceID.streamChannelSummary(scope: kAudioObjectPropertyScopeOutput))")
            } else {
                lines.append("    tap: none")
            }
        }
        lines.append("All HAL processes:")
        for object in (try? AudioObjectID.processObjects()) ?? [] {
            lines.append("  \(object): pid \(object.processPID) \(object.processBundleID ?? "-") output \(object.processIsRunningOutput)")
        }
        return lines.joined(separator: "\n")
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
