import AppKit
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Audio capture permission

/// Wraps the TCC "Audio Capture" permission that process taps require.
/// Uses the TCC SPI when present (same approach as Apple's sample code
/// community ports); falls back to "unknown" so the first tap triggers the
/// system prompt.
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflight: PreflightFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }()

    private static let request: RequestFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFn.self)
    }()

    static var status: Status {
        guard let preflight else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func requestAccess(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let request else {
            Task { @MainActor in completion(true) }
            return
        }
        request(service, nil) { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Process ownership

enum ProcessOwnership {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    private static let responsible: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    /// The user-facing app that owns `pid` (e.g. Google Chrome for a
    /// "Google Chrome Helper" renderer, Safari for a WebKit GPU process).
    static func owningApplication(for pid: pid_t) -> NSRunningApplication? {
        if let responsible {
            let owner = responsible(pid)
            if owner > 0, let app = NSRunningApplication(processIdentifier: owner), app.bundleURL != nil {
                return app
            }
        }
        return NSRunningApplication(processIdentifier: pid)
    }
}

// MARK: - System output (default device volume / mute)

/// Reads and writes the default output device's main volume and mute.
@MainActor
final class SystemOutput {
    private(set) var deviceID: AudioDeviceID = .unknownObject
    private var listeners: [PropertyListener] = []
    var onChange: (() -> Void)?

    func attach(to device: AudioDeviceID) {
        deviceID = device
        listeners = [
            PropertyListener(object: device, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                             scope: kAudioDevicePropertyScopeOutput) { [weak self] in self?.onChange?() },
            PropertyListener(object: device, selector: kAudioDevicePropertyMute,
                             scope: kAudioDevicePropertyScopeOutput) { [weak self] in self?.onChange?() }
        ]
    }

    var deviceName: String {
        deviceID.readString(kAudioObjectPropertyName) ?? "Output"
    }

    var volume: Float {
        get {
            (try? deviceID.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                scope: kAudioDevicePropertyScopeOutput, default: Float32(0))) ?? 0
        }
        set {
            var address = AudioObjectPropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                     scope: kAudioDevicePropertyScopeOutput)
            var value = Float32(min(1, max(0, newValue)))
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    var hasVolumeControl: Bool {
        deviceID.hasProperty(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    }

    var isMuted: Bool {
        get {
            ((try? deviceID.read(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, default: UInt32(0))) ?? 0) != 0
        }
        set {
            var address = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
            var value = UInt32(newValue ? 1 : 0)
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }
}
