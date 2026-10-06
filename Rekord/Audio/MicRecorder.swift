import AVFoundation
import os

/// Records the microphone input to a file via AVAudioEngine's input node tap.
/// File writes happen off the realtime audio thread on `writeQueue`.
final class MicRecorder {
    enum RecorderError: Error, LocalizedError {
        case alreadyRecording
        case noInputDevice
        case fileCreationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "Already recording the microphone."
            case .noInputDevice: return "No microphone found. Connect one, or turn the microphone off."
            case .fileCreationFailed(let error): return "Failed to create audio file: \(error.localizedDescription)"
            }
        }
    }

    private var engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private let writeQueue = DispatchQueue(label: "com.avendesta.rekord.micrecorder.write")
    private(set) var isRecording = false
    /// Host time (mach ticks) of the first delivered buffer; used for track sync.
    private(set) var firstBufferHostTime: UInt64?
    private(set) var sampleRate: Double = 0
    /// Audio that arrives during a pause is left out of the file.
    var pauseGate: PauseGate?
    /// Why the first failed write failed (a full disk, a folder that went away); nil while all is well.
    private let writeErrorLock = OSAllocatedUnfairLock<String?>(initialState: nil)
    var writeError: String? { writeErrorLock.withLock { $0 } }

    #if DEBUG
    private var bufferCount = 0
    #endif

    func start(to fileURL: URL) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        // Fresh engine per recording so a changed input device is never served from a stale format.
        Diagnostics.step("mic: creating engine")
        engine = AVAudioEngine()
        let inputNode = engine.inputNode
        Diagnostics.step("mic: choosing device (chosen: \(AppSettings.inputDeviceUID != nil))")
        // Point only this engine at the chosen mic; the system default input is untouched.
        // A device that has been unplugged falls back to the default.
        if let uid = AppSettings.inputDeviceUID,
           let deviceID = AudioInputDevices.deviceID(forUID: uid),
           let unit = inputNode.audioUnit {
            var device = deviceID
            Diagnostics.step("mic: setting device \(deviceID)")
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioObjectID>.size))
            Diagnostics.step("mic: device set (status \(status))")
        }
        Diagnostics.step("mic: reading format")
        let format = inputNode.inputFormat(forBus: 0)
        // A Mac with no input device reports an empty format, and tapping that raises an exception.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        sampleRate = format.sampleRate
        firstBufferHostTime = nil
        writeErrorLock.withLock { $0 = nil }

        Diagnostics.step("mic: opening file (\(format.sampleRate) Hz, \(format.channelCount) ch)")
        do {
            audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }

        #if DEBUG
        bufferCount = 0
        #endif

        Diagnostics.step("mic: installing tap")
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self else { return }
            if self.firstBufferHostTime == nil { self.firstBufferHostTime = when.hostTime }
            self.writeQueue.async {
                do {
                    for piece in self.pauseGate?.pieces(of: buffer, startingAt: when.hostTime) ?? [buffer] {
                        try self.audioFile?.write(from: piece)
                    }
                    #if DEBUG
                    self.bufferCount += 1
                    if self.bufferCount % 50 == 0 {
                        print("[Rekord][MicRecorder] wrote \(self.bufferCount) buffers")
                    }
                    #endif
                } catch {
                    print("[Rekord][MicRecorder] write error: \(error)")
                    self.writeErrorLock.withLock { if $0 == nil { $0 = error.localizedDescription } }
                }
            }
        }

        Diagnostics.step("mic: preparing engine")
        engine.prepare()
        Diagnostics.step("mic: starting engine")
        do {
            try engine.start()
        } catch {
            // stop() does nothing before isRecording is set, so undo the tap and the file here.
            inputNode.removeTap(onBus: 0)
            writeQueue.sync { self.audioFile = nil }
            throw error
        }
        isRecording = true
        Diagnostics.step("mic: started")
    }

    func stop() {
        guard isRecording else { return }
        Diagnostics.step("mic: stopping")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writeQueue.sync {
            self.audioFile = nil
        }
        isRecording = false
        #if DEBUG
        print("[Rekord][MicRecorder] stopped, total buffers written: \(bufferCount)")
        #endif
    }
}
