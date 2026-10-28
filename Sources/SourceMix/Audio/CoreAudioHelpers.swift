import CoreAudio
import Foundation

enum CoreAudioError: LocalizedError {
    case status(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case let .status(code, what):
            return "\(what) failed (OSStatus \(code) – \(code.fourCC))"
        }
    }
}

extension OSStatus {
    /// Throws when the status is not `noErr`.
    func check(_ what: @autoclosure () -> String) throws {
        guard self == noErr else { throw CoreAudioError.status(self, what()) }
    }

    var fourCC: String {
        let n = UInt32(bitPattern: self)
        let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return String(bytes: bytes, encoding: .ascii) ?? "\(self)"
        }
        return "\(self)"
    }
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknownObject = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknownObject }

    // MARK: Generic reads

    func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 default value: T) throws -> T {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        try AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result)
            .check("Read \(selector.fourCCString) on \(self)")
        return result
    }

    func readArray<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: T) throws -> [T] {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        try AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
            .check("Size \(selector.fourCCString)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var items = [T](repeating: element, count: count)
        try items.withUnsafeMutableBytes { raw in
            try AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw.baseAddress!)
                .check("Read \(selector.fourCCString)")
        }
        return Array(items.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    func readString(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    func hasProperty(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var address = AudioObjectPropertyAddress(selector, scope: scope, element: element)
        return AudioObjectHasProperty(self, &address)
    }

    // MARK: System

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID.unknownObject)
    }

    static func processObjects() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, element: AudioObjectID.unknownObject)
    }

    // MARK: Devices

    var deviceUID: String? { readString(kAudioDevicePropertyDeviceUID) }

    var nominalSampleRate: Double {
        (try? read(kAudioDevicePropertyNominalSampleRate, default: Float64(48_000))) ?? 48_000
    }

    /// e.g. "[2, 2]" – channel count of each stream in the given scope.
    func streamChannelSummary(scope: AudioObjectPropertyScope) -> String {
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return "[]" }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw) == noErr else { return "[?]" }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return "[" + list.map { String($0.mNumberChannels) }.joined(separator: ", ") + "]"
    }

    var name: String { readString(kAudioObjectPropertyName) ?? "?" }

    var transportType: UInt32 {
        (try? read(kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0
    }

    /// True for software devices (Teams Audio, Zoom, BlackHole, Loopback…) and
    /// aggregate / multi-output devices. Audio sent to these is usually relayed
    /// by another app, so SourceMix must not reroute or tap it.
    var isVirtualOrAggregate: Bool {
        let t = transportType
        return t == kAudioDeviceTransportTypeVirtual
            || t == kAudioDeviceTransportTypeAggregate
            || t == kAudioDeviceTransportTypeAutoAggregate
            || (deviceUID ?? "").localizedCaseInsensitiveContains("loopback")
    }

    // MARK: Process objects

    var processPID: pid_t { (try? read(kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1 }
    var processBundleID: String? { readString(kAudioProcessPropertyBundleID) }
    var processIsRunningOutput: Bool {
        ((try? read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0
    }
}

extension UInt32 {
    var fourCCString: String {
        let bytes = [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(self)"
    }
}

/// Small wrapper around AudioObjectAddPropertyListenerBlock that removes itself on deinit.
final class PropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue

    init(object: AudioObjectID,
         selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         handler: @escaping @MainActor () -> Void) {
        self.objectID = object
        self.address = AudioObjectPropertyAddress(selector, scope: scope)
        self.queue = .main
        self.block = { _, _ in MainActor.assumeIsolated { handler() } }
        AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}
