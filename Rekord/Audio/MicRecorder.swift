import AVFoundation

/// Records the microphone input to a file via AVAudioEngine's input node tap.
/// File writes happen off the realtime audio thread on `writeQueue`.
final class MicRecorder {
    enum RecorderError: Error {
        case alreadyRecording
        case fileCreationFailed(Error)
    }

    private var engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private let writeQueue = DispatchQueue(label: "com.avendesta.rekord.micrecorder.write")
    private(set) var isRecording = false
    /// Host time (mach ticks) of the first delivered buffer; used for track sync.
    private(set) var firstBufferHostTime: UInt64?
    private(set) var sampleRate: Double = 0

    #if DEBUG
    private var bufferCount = 0
    #endif

    func start(to fileURL: URL) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        // Fresh engine per recording so a changed input device is never served from a stale format.
        engine = AVAudioEngine()
        let inputNode = engine.inputNode
        // Point only this engine at the chosen mic; the system default input is untouched.
        // A device that has been unplugged falls back to the default.
        if let uid = AppSettings.inputDeviceUID,
           let deviceID = AudioInputDevices.deviceID(forUID: uid),
           let unit = inputNode.audioUnit {
            var device = deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioObjectID>.size))
        }
        let format = inputNode.inputFormat(forBus: 0)
        sampleRate = format.sampleRate
        firstBufferHostTime = nil

        do {
            audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }

        #if DEBUG
        bufferCount = 0
        #endif

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self else { return }
            if self.firstBufferHostTime == nil { self.firstBufferHostTime = when.hostTime }
            self.writeQueue.async {
                do {
                    try self.audioFile?.write(from: buffer)
                    #if DEBUG
                    self.bufferCount += 1
                    if self.bufferCount % 50 == 0 {
                        print("[Rekord][MicRecorder] wrote \(self.bufferCount) buffers")
                    }
                    #endif
                } catch {
                    print("[Rekord][MicRecorder] write error: \(error)")
                }
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
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
