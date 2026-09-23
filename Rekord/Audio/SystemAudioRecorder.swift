import AudioToolbox
import AVFoundation
import os

/// Captures system-wide output audio via the macOS 14.4+ Core Audio process-tap
/// API (`AudioHardwareCreateProcessTap` + a private aggregate device), rather
/// than tapping any single process. Requires an unsandboxed app and, in
/// addition to standard mic permission, the "Audio Recording" privacy grant
/// introduced alongside this API.
final class SystemAudioRecorder {
    enum RecorderError: Error, LocalizedError {
        case alreadyRecording
        case tapCreationFailed(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case ioProcStartFailed(OSStatus)
        case propertyReadFailed(String, OSStatus)
        case streamFormatUnavailable
        case fileCreationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "Already recording system audio."
            case .tapCreationFailed(let status): return "Failed to create process tap (\(status))."
            case .aggregateDeviceCreationFailed(let status): return "Failed to create aggregate device (\(status))."
            case .ioProcCreationFailed(let status): return "Failed to create audio I/O proc (\(status))."
            case .ioProcStartFailed(let status): return "Failed to start audio device (\(status))."
            case .propertyReadFailed(let name, let status): return "Failed to read \(name) (\(status))."
            case .streamFormatUnavailable: return "Tap stream format unavailable."
            case .fileCreationFailed(let error): return "Failed to create audio file: \(error.localizedDescription)"
            }
        }
    }

    private var tapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private let ioQueue = DispatchQueue(label: "com.avendesta.rekord.systemaudiorecorder.io", qos: .userInitiated)
    private(set) var isRecording = false
    /// Host time (mach ticks) of the first delivered buffer; used for track sync.
    private(set) var firstBufferHostTime: UInt64?
    private(set) var sampleRate: Double = 0
    /// True once any non-silent sample has arrived. A tap without the system audio
    /// permission delivers buffers of pure zeros, so this stays false in that case.
    private let sawAudioLock = OSAllocatedUnfairLock(initialState: false)
    var sawAudio: Bool { sawAudioLock.withLock { $0 } }

    #if DEBUG
    private var bufferCount = 0
    #endif

    func start(to fileURL: URL) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        firstBufferHostTime = nil
        sawAudioLock.withLock { $0 = false }

        // 1. Create a whole-system output tap (not tied to any one process).
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        var newTapID: AudioObjectID = .unknown
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr else { throw RecorderError.tapCreationFailed(status) }
        tapID = newTapID

        do {
            // 2. Pair the tap with the real default output device in a private
            // aggregate device — a tap alone has no clock to run against.
            let outputDeviceID: AudioObjectID = try readProperty(
                on: .system,
                selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                defaultValue: .unknown
            )
            let outputUID: String = try readStringProperty(on: outputDeviceID, selector: kAudioDevicePropertyDeviceUID)

            let aggregateUID = UUID().uuidString
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Rekord-SystemTap-\(aggregateUID)",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                    ]
                ]
            ]

            var newAggregateID: AudioObjectID = .unknown
            status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
            guard status == noErr else { throw RecorderError.aggregateDeviceCreationFailed(status) }
            aggregateDeviceID = newAggregateID

            // 3. Read the tap's stream format and open the output file.
            var asbd: AudioStreamBasicDescription = try readProperty(
                on: tapID,
                selector: kAudioTapPropertyFormat,
                defaultValue: AudioStreamBasicDescription()
            )
            guard let format = AVAudioFormat(streamDescription: &asbd) else {
                throw RecorderError.streamFormatUnavailable
            }

            let settings: [String: Any] = [
                AVFormatIDKey: asbd.mFormatID,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount
            ]
            do {
                audioFile = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
            } catch {
                throw RecorderError.fileCreationFailed(error)
            }

            sampleRate = format.sampleRate
            #if DEBUG
            bufferCount = 0
            #endif

            // 4. Install the IOProc on the aggregate device and start it.
            var newIOProcID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, ioQueue) { [weak self] _, inInputData, inInputTime, _, _ in
                guard let self else { return }
                if self.firstBufferHostTime == nil { self.firstBufferHostTime = inInputTime.pointee.mHostTime }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else { return }
                if !self.sawAudio, Self.hasSignal(buffer) { self.sawAudioLock.withLock { $0 = true } }
                do {
                    try self.audioFile?.write(from: buffer)
                    #if DEBUG
                    self.bufferCount += 1
                    if self.bufferCount % 50 == 0 {
                        print("[Rekord][SystemAudioRecorder] wrote \(self.bufferCount) buffers")
                    }
                    #endif
                } catch {
                    print("[Rekord][SystemAudioRecorder] write error: \(error)")
                }
            }
            guard status == noErr, let procID = newIOProcID else {
                throw RecorderError.ioProcCreationFailed(status)
            }
            ioProcID = procID

            status = AudioDeviceStart(aggregateDeviceID, procID)
            guard status == noErr else { throw RecorderError.ioProcStartFailed(status) }
        } catch {
            teardown()
            throw error
        }

        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        teardown()
        isRecording = false
        #if DEBUG
        print("[Rekord][SystemAudioRecorder] stopped, total buffers written: \(bufferCount)")
        #endif
    }

    private func teardown() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        audioFile = nil
    }

    private static func hasSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) where abs(channels[channel][frame]) > 1e-6 {
                return true
            }
        }
        return false
    }

    // MARK: - Core Audio property helpers

    private func readProperty<T>(
        on objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var dataSize = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr else {
            throw RecorderError.propertyReadFailed(String(selector), status)
        }
        return value
    }

    private func readStringProperty(
        on objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        let cfValue: CFString = try readProperty(on: objectID, selector: selector, defaultValue: "" as CFString)
        return cfValue as String
    }
}

private extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown
    var isValid: Bool { self != .unknown }
}
