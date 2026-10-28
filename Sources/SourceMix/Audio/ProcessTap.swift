import AudioToolbox
import CoreAudio
import Foundation
import OSLog

private let log = Logger(subsystem: "com.jeremyjackson.SourceMix", category: "Tap")

/// Captures (and silences) the audio of one or more processes via a Core Audio
/// process tap, runs it through a `StreamProcessor`, and plays the result on the
/// current output device through a private aggregate device.
final class ProcessTap {
    let processObjects: [AudioObjectID]
    let processor: StreamProcessor
    let outputDevice: AudioDeviceID

    private var tapID = AudioObjectID.unknownObject
    private var aggregateID = AudioObjectID.unknownObject
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.jeremyjackson.SourceMix.io", qos: .userInteractive)
    private(set) var isRunning = false
    private(set) var startedAt = Date()
    var aggregateDeviceID: AudioObjectID { aggregateID }

    /// Let the HAL varispeed the tap to follow the output clock.
    let driftCompensation: Bool
    /// Tap the output device's stream with all its channels instead of a
    /// stereo mixdown (only used when the output has more than two channels).
    let keepAllChannels: Bool
    private(set) var tapChannels = 2
    private(set) var tapSampleRate: Double = 0
    private(set) var usedMultichannelTap = false

    init(processObjects: [AudioObjectID], outputDevice: AudioDeviceID, processor: StreamProcessor,
         driftCompensation: Bool, keepAllChannels: Bool) {
        self.processObjects = processObjects
        self.outputDevice = outputDevice
        self.processor = processor
        self.driftCompensation = driftCompensation
        self.keepAllChannels = keepAllChannels
    }

    deinit { stop() }

    func start(label: String) throws {
        guard !isRunning else { return }
        guard let outputUID = outputDevice.deviceUID else {
            throw CoreAudioError.status(kAudioHardwareBadDeviceError, "Read output device UID")
        }

        // 1. Tap the processes. `.mutedWhenTapped` silences their normal output
        //    while we hold the tap, so only our processed copy is heard.
        let outputChannels = outputDevice.channelCount(scope: kAudioObjectPropertyScopeOutput)
        let description: CATapDescription
        if keepAllChannels && outputChannels > 2 {
            // Per-device-stream tap: keeps the output stream's full channel
            // layout instead of folding it to stereo.
            description = CATapDescription(processes: processObjects, deviceUID: outputUID, stream: 0)
            usedMultichannelTap = true
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: processObjects)
            usedMultichannelTap = false
        }
        description.uuid = UUID()
        description.name = "SourceMix – \(label)"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var newTap = AudioObjectID.unknownObject
        try AudioHardwareCreateProcessTap(description, &newTap).check("Create process tap")
        tapID = newTap
        if let format = try? tapID.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription()) {
            tapChannels = Int(max(1, format.mChannelsPerFrame))
            tapSampleRate = format.mSampleRate
        }

        // 2. Private aggregate device = real output device + the tap as an input.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SourceMix – \(label)",
            kAudioAggregateDeviceUIDKey: "com.jeremyjackson.SourceMix.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: driftCompensation,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]
            ]
        ]

        var newAggregate = AudioObjectID.unknownObject
        do {
            try AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate)
                .check("Create aggregate device")
        } catch {
            stop()
            throw error
        }
        aggregateID = newAggregate

        // 3. IO callback: tap input -> DSP -> device output.
        let processor = self.processor
        let tapChannels = self.tapChannels
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, _, outOutputData, _ in
            ProcessTap.render(input: inInputData, output: outOutputData, processor: processor, tapChannels: tapChannels)
        }
        do {
            try status.check("Create IO proc")
            ioProcID = procID
            try AudioDeviceStart(aggregateID, procID).check("Start aggregate device")
        } catch {
            stop()
            throw error
        }
        isRunning = true
        startedAt = Date()
        log.notice("Started tap for \(label, privacy: .public): processes \(self.processObjects, privacy: .public), tap \(self.tapID), aggregate \(self.aggregateID), output \(outputUID, privacy: .public) @ \(self.outputDevice.nominalSampleRate) Hz, tap \(self.tapChannels) ch @ \(self.tapSampleRate) Hz (\(self.usedMultichannelTap ? "device stream" : "stereo mixdown", privacy: .public)), drift compensation \(self.driftCompensation), aggregate streams in \(self.aggregateID.streamChannelSummary(scope: kAudioObjectPropertyScopeInput), privacy: .public) out \(self.aggregateID.streamChannelSummary(scope: kAudioObjectPropertyScopeOutput), privacy: .public)")
    }

    func stop() {
        if isRunning || tapID.isValid {
            log.notice("Stopping tap (aggregate \(self.aggregateID), tap \(self.tapID), callbacks \(self.processor.callbackCount), empty \(self.processor.emptyCallbackCount))")
        }
        if aggregateID.isValid, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknownObject
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknownObject
        }
        isRunning = false
    }

    // MARK: - Real-time render

    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               processor: StreamProcessor,
                               tapChannels: Int) {
        let outList = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let lastChannelsSeen = inList.count > 0 ? Int(inList[inList.count - 1].mNumberChannels) : 0
        let outChannelsSeen = outList.count > 0 ? Int(outList[0].mNumberChannels) : 0
        let io = processor.io
        io.inputCount = 0
        io.outputCount = 0
        let floatSize = MemoryLayout<Float>.size

        // Tap streams are appended after any input streams of the output
        // device, so the tapped audio lives in the last buffer — or, if the
        // HAL delivers it de-interleaved, the last `tapChannels` buffers.
        var inFrames = Int.max
        if let last = inList.last, let data = last.mData?.assumingMemoryBound(to: Float.self), last.mDataByteSize > 0 {
            let ch = Int(max(1, last.mNumberChannels))
            if ch >= 2 || tapChannels <= 1 {
                for c in 0..<ch { io.addInput(UnsafePointer(data + c), stride: ch) }
                inFrames = Int(last.mDataByteSize) / (floatSize * ch)
            } else {
                let count = min(tapChannels, inList.count)
                for i in (inList.count - count)..<inList.count {
                    let b = inList[i]
                    guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    io.addInput(UnsafePointer(d), stride: 1)
                    inFrames = min(inFrames, Int(b.mDataByteSize) / floatSize)
                }
            }
        }

        guard io.inputCount > 0, outList.count > 0 else {
            processor.noteCallback(inBuffers: inList.count, inChannels: lastChannelsSeen,
                                   outBuffers: outList.count, outChannels: outChannelsSeen, hadInput: false)
            processor.decayMeter()
            return
        }

        var outFrames = Int.max
        for buffer in outList {
            guard let d = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = Int(max(1, buffer.mNumberChannels))
            for c in 0..<ch { io.addOutput(d + c, stride: ch) }
            outFrames = min(outFrames, Int(buffer.mDataByteSize) / (floatSize * ch))
        }

        processor.noteCallback(inBuffers: inList.count, inChannels: lastChannelsSeen,
                               outBuffers: outList.count, outChannels: outChannelsSeen, hadInput: true)

        let frames = min(inFrames, outFrames)
        guard frames > 0, frames != Int.max else { return }
        processor.process(frames: frames)
    }
}
