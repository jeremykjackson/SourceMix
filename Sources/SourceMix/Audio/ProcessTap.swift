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

    init(processObjects: [AudioObjectID], outputDevice: AudioDeviceID, processor: StreamProcessor) {
        self.processObjects = processObjects
        self.outputDevice = outputDevice
        self.processor = processor
    }

    deinit { stop() }

    func start(label: String) throws {
        guard !isRunning else { return }
        guard let outputUID = outputDevice.deviceUID else {
            throw CoreAudioError.status(kAudioHardwareBadDeviceError, "Read output device UID")
        }

        // 1. Tap the processes. `.mutedWhenTapped` silences their normal output
        //    while we hold the tap, so only our processed copy is heard.
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "SourceMix – \(label)"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var newTap = AudioObjectID.unknownObject
        try AudioHardwareCreateProcessTap(description, &newTap).check("Create process tap")
        tapID = newTap

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
                    kAudioSubTapDriftCompensationKey: true,
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
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, _, outOutputData, _ in
            ProcessTap.render(input: inInputData, output: outOutputData, processor: processor)
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
        log.notice("Started tap for \(label, privacy: .public): processes \(self.processObjects, privacy: .public), tap \(self.tapID), aggregate \(self.aggregateID), output \(outputUID, privacy: .public) @ \(self.outputDevice.nominalSampleRate) Hz, aggregate streams in \(self.aggregateID.streamChannelSummary(scope: kAudioObjectPropertyScopeInput), privacy: .public) out \(self.aggregateID.streamChannelSummary(scope: kAudioObjectPropertyScopeOutput), privacy: .public)")
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
                               processor: StreamProcessor) {
        let outList = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let lastChannelsSeen = inList.count > 0 ? Int(inList[inList.count - 1].mNumberChannels) : 0
        let outChannelsSeen = outList.count > 0 ? Int(outList[0].mNumberChannels) : 0
        guard inList.count > 0, outList.count > 0 else {
            processor.noteCallback(inBuffers: inList.count, inChannels: lastChannelsSeen,
                                   outBuffers: outList.count, outChannels: outChannelsSeen, hadInput: false)
            processor.decayMeter()
            return
        }

        // Tap streams are appended after any input streams of the output
        // device, so the tapped audio lives in the last buffer(s).
        let last = inList[inList.count - 1]
        guard let lastData = last.mData?.assumingMemoryBound(to: Float.self), last.mDataByteSize > 0 else {
            processor.noteCallback(inBuffers: inList.count, inChannels: lastChannelsSeen,
                                   outBuffers: outList.count, outChannels: outChannelsSeen, hadInput: false)
            processor.decayMeter()
            return
        }
        processor.noteCallback(inBuffers: inList.count, inChannels: lastChannelsSeen,
                               outBuffers: outList.count, outChannels: outChannelsSeen, hadInput: true)

        let inLeft: UnsafePointer<Float>
        let inRight: UnsafePointer<Float>
        let inStride: Int
        let inFrames: Int
        let lastChannels = Int(max(1, last.mNumberChannels))

        if lastChannels >= 2 {
            inLeft = UnsafePointer(lastData)
            inRight = UnsafePointer(lastData + 1)
            inStride = lastChannels
            inFrames = Int(last.mDataByteSize) / (MemoryLayout<Float>.size * lastChannels)
        } else if inList.count >= 2,
                  inList[inList.count - 2].mNumberChannels == 1,
                  let prev = inList[inList.count - 2].mData?.assumingMemoryBound(to: Float.self) {
            // Non-interleaved stereo: [.., L, R]
            inLeft = UnsafePointer(prev)
            inRight = UnsafePointer(lastData)
            inStride = 1
            inFrames = Int(last.mDataByteSize) / MemoryLayout<Float>.size
        } else {
            inLeft = UnsafePointer(lastData)
            inRight = UnsafePointer(lastData)
            inStride = 1
            inFrames = Int(last.mDataByteSize) / MemoryLayout<Float>.size
        }

        let first = outList[0]
        guard let outData = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let outChannels = Int(max(1, first.mNumberChannels))

        var outLeft: UnsafeMutablePointer<Float>? = outData
        var outRight: UnsafeMutablePointer<Float>?
        var outStride = outChannels
        var outFrames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)

        if outChannels >= 2 {
            outRight = outData + 1
        } else if outList.count >= 2, let second = outList[1].mData?.assumingMemoryBound(to: Float.self) {
            outRight = second
            outStride = 1
            outFrames = min(outFrames, Int(outList[1].mDataByteSize) / MemoryLayout<Float>.size)
        } else {
            // Mono output: both channels sum into the single buffer.
            outRight = outData
            outLeft = outData
        }

        let frames = min(inFrames, outFrames)
        guard frames > 0 else { return }
        processor.process(left: inLeft, right: inRight, inStride: inStride,
                          outLeft: outLeft, outRight: outRight, outStride: outStride,
                          frames: frames)
    }
}
