import AVFoundation

/// Offline mixdown of `system.caf` + `mic.caf` into `combined.caf`, aligning the
/// tracks with the first-buffer offset recorded in `session.json`.
enum CombineEngine {
    enum CombineError: Error, LocalizedError {
        case missingTrack
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .missingTrack: return "This recording has no mic track to combine."
            case .renderFailed: return "Mixdown failed."
            }
        }
    }

    static func combine(folder: URL, metadata: RecordingSession.Metadata) throws -> URL {
        guard metadata.includeMicrophone else { throw CombineError.missingTrack }

        let systemFile = try AVAudioFile(forReading: folder.appendingPathComponent("system.caf"))
        let micFile = try AVAudioFile(forReading: folder.appendingPathComponent("mic.caf"))
        let outputURL = folder.appendingPathComponent("combined.caf")

        let sampleRate = systemFile.processingFormat.sampleRate
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw CombineError.renderFailed
        }

        // Positive offset = mic started later, so pad the mic; negative pads the system track.
        let offset = metadata.micOffsetSeconds ?? 0
        let engine = AVAudioEngine()
        let tracks: [(file: AVAudioFile, delay: Double)] = [
            (systemFile, offset < 0 ? -offset : 0),
            (micFile, offset > 0 ? offset : 0)
        ]

        var totalSeconds = 0.0
        var players: [AVAudioPlayerNode] = []
        for track in tracks {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: track.file.processingFormat)
            if track.delay > 0 {
                let format = track.file.processingFormat
                let frames = AVAudioFrameCount(track.delay * format.sampleRate)
                if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                    silence.frameLength = frames // freshly allocated buffers are zeroed
                    player.scheduleBuffer(silence, completionHandler: nil)
                }
            }
            player.scheduleFile(track.file, at: nil, completionHandler: nil)
            players.append(player)
            totalSeconds = max(totalSeconds, track.delay + Double(track.file.length) / track.file.processingFormat.sampleRate)
        }

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: outFormat, maximumFrameCount: maxFrames)
        try engine.start()
        players.forEach { $0.play() }
        defer { engine.stop() }

        let outFile = try AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            throw CombineError.renderFailed
        }

        let totalFrames = AVAudioFramePosition(totalSeconds * sampleRate)
        while engine.manualRenderingSampleTime < totalFrames {
            let remaining = AVAudioFrameCount(totalFrames - engine.manualRenderingSampleTime)
            switch try engine.renderOffline(min(maxFrames, remaining), to: buffer) {
            case .success:
                try outFile.write(from: buffer)
            case .insufficientDataFromInputNode:
                break
            default:
                throw CombineError.renderFailed
            }
        }
        return outputURL
    }
}
