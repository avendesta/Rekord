import AudioToolbox
import AVFoundation
import os

/// Captures output audio via the macOS 14.4+ Core Audio process-tap API
/// (`AudioHardwareCreateProcessTap` + a private aggregate device): the whole
/// system, or the processes of one app. Requires, in addition to standard mic
/// permission, the "Audio Recording" privacy grant introduced alongside this API.
final class SystemAudioRecorder {
    enum RecorderError: Error, LocalizedError {
        case alreadyRecording
        case sourceAppNotRunning
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
            case .sourceAppNotRunning: return "The app to record isn't running."
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
    /// Set while recording one app: its bundle ID and the tap's description, kept to update its processes.
    private var source: (bundleID: String, tap: CATapDescription)?
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private let ioQueue = DispatchQueue(label: "com.avendesta.rekord.systemaudiorecorder.io", qos: .userInitiated)
    private(set) var isRecording = false
    /// Host time (mach ticks) of the first delivered buffer; used for track sync.
    private(set) var firstBufferHostTime: UInt64?
    /// Audio that arrives during a pause is left out of the file.
    var pauseGate: PauseGate?
    private(set) var sampleRate: Double = 0
    /// True once any non-silent sample has arrived. A tap without the system audio
    /// permission delivers buffers of pure zeros, so this stays false in that case.
    private let sawAudioLock = OSAllocatedUnfairLock(initialState: false)
    var sawAudio: Bool { sawAudioLock.withLock { $0 } }
    /// Why the first failed write failed (a full disk, a folder that went away); nil while all is well.
    private let writeErrorLock = OSAllocatedUnfairLock<String?>(initialState: nil)
    var writeError: String? { writeErrorLock.withLock { $0 } }

    #if DEBUG
    private var bufferCount = 0
    #endif

    /// `sourceBundleID` records that one app; nil records everything the Mac plays.
    func start(to fileURL: URL, sourceBundleID: String? = nil) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        firstBufferHostTime = nil
        sawAudioLock.withLock { $0 = false }
        writeErrorLock.withLock { $0 = nil }

        Diagnostics.step("system: creating tap (one app: \(sourceBundleID != nil))")
        // 1. Create a tap on one app's processes, or on the whole system output.
        let tapDescription: CATapDescription
        if let sourceBundleID {
            let processes = AudioSourceApps.processObjects(forBundleID: sourceBundleID)
            guard !processes.isEmpty else { throw RecorderError.sourceAppNotRunning }
            tapDescription = CATapDescription(stereoMixdownOfProcesses: processes)
        } else {
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        var newTapID: AudioObjectID = .unknown
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr else { throw RecorderError.tapCreationFailed(status) }
        tapID = newTapID

        do {
            Diagnostics.step("system: creating aggregate device")
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

            Diagnostics.step("system: opening file")
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

            Diagnostics.step("system: installing IOProc")
            // 4. Install the IOProc on the aggregate device and start it.
            var newIOProcID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, ioQueue) { [weak self] _, inInputData, inInputTime, _, _ in
                guard let self else { return }
                if self.firstBufferHostTime == nil { self.firstBufferHostTime = inInputTime.pointee.mHostTime }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else { return }
                if !self.sawAudio, Self.hasSignal(buffer) { self.sawAudioLock.withLock { $0 = true } }
                do {
                    for piece in self.pauseGate?.pieces(of: buffer, startingAt: inInputTime.pointee.mHostTime) ?? [buffer] {
                        try self.audioFile?.write(from: piece)
                    }
                    #if DEBUG
                    self.bufferCount += 1
                    if self.bufferCount % 50 == 0 {
                        print("[Rekord][SystemAudioRecorder] wrote \(self.bufferCount) buffers")
                    }
                    #endif
                } catch {
                    print("[Rekord][SystemAudioRecorder] write error: \(error)")
                    self.writeErrorLock.withLock { if $0 == nil { $0 = error.localizedDescription } }
                }
            }
            guard status == noErr, let procID = newIOProcID else {
                throw RecorderError.ioProcCreationFailed(status)
            }
            ioProcID = procID

            Diagnostics.step("system: starting device")
            status = AudioDeviceStart(aggregateDeviceID, procID)
            guard status == noErr else { throw RecorderError.ioProcStartFailed(status) }
        } catch {
            teardown()
            throw error
        }

        Diagnostics.step("system: started")
        if let sourceBundleID {
            source = (sourceBundleID, tapDescription)
            var address = Self.processListAddress
            AudioObjectAddPropertyListener(.system, &address, Self.processListChanged, Unmanaged.passUnretained(self).toOpaque())
        }
        isRecording = true
    }

    // MARK: - Following one app's processes

    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // A C function, not a block: a block listener can't be removed again from Swift, because
    // each call wraps the closure in a new block and Core Audio matches listeners by pointer.
    private static let processListChanged: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return noErr }
        let recorder = Unmanaged<SystemAudioRecorder>.fromOpaque(clientData).takeUnretainedValue()
        DispatchQueue.main.async { [weak recorder] in recorder?.updateTappedProcesses() }
        return noErr
    }

    /// An app's audio helpers come and go (one may only start with the meeting, and the app may
    /// be reopened), so the tap is pointed at the app's current processes whenever the list changes.
    private func updateTappedProcesses() {
        guard let source, tapID.isValid else { return }
        let processes = AudioSourceApps.processObjects(forBundleID: source.bundleID)
        // Nothing to tap while the app is closed; the tap stays as it is until it comes back.
        guard !processes.isEmpty, Set(processes) != Set(source.tap.processes) else { return }
        source.tap.processes = processes
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The property's value is the description object itself, passed as a pointer to the reference.
        let status = withUnsafePointer(to: source.tap) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        #if DEBUG
        print("[Rekord][SystemAudioRecorder] tap now follows processes \(processes) (status \(status))")
        #endif
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
        Diagnostics.step("system: teardown")
        if source != nil {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListener(.system, &address, Self.processListChanged, Unmanaged.passUnretained(self).toOpaque())
            source = nil
        }
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
