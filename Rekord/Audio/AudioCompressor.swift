import AVFoundation

/// One of a recording's audio files. Recordings are written as CAF, which survives a crash, and
/// may be compressed to M4A afterwards, so readers ask here rather than assuming an extension.
enum Track: String, CaseIterable {
    case system, mic, combined

    /// The track's file in a recording folder: the compressed one if there is one, else the original.
    func url(in folder: URL) -> URL? {
        ["m4a", "caf"]
            .map { folder.appendingPathComponent("\(rawValue).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func original(in folder: URL) -> URL { folder.appendingPathComponent("\(rawValue).caf") }
}

/// Replaces a finished recording's CAF files with M4A (AAC), roughly a tenth of the size or less.
enum AudioCompressor {
    enum CompressorError: Error {
        case lengthMismatch
    }

    /// A CAF that is all header (4096 bytes) holds no audio and is left as it is.
    private static func holdsAudio(_ caf: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: caf.path)[.size] as? Int) ?? 0) > 4096
    }

    static func needsCompression(folder: URL) -> Bool {
        Track.allCases.contains { holdsAudio($0.original(in: folder)) }
    }

    /// Compresses every track that is still CAF and records the new file names in session.json.
    static func compress(folder: URL, metadata: RecordingSession.Metadata) throws {
        for track in Track.allCases where holdsAudio(track.original(in: folder)) {
            try compress(track.original(in: folder))
        }
        // Read again: the recording may have been renamed while its audio was being converted.
        var metadata = (try? RecordingSession.Metadata.read(from: folder)) ?? metadata
        metadata.files = Track.allCases.compactMap { $0.url(in: folder)?.lastPathComponent }
        try metadata.write(to: folder)
    }

    /// The original is only removed once the M4A has been read back at exactly the same length.
    @discardableResult
    static func compress(_ caf: URL) throws -> URL {
        let m4a = caf.deletingPathExtension().appendingPathExtension("m4a")
        let temp = caf.deletingPathExtension().appendingPathExtension("tmp.m4a")
        try? FileManager.default.removeItem(at: temp)
        do {
            let frames = try AVAudioFile(forReading: caf).length
            // 64 kbps a channel is plenty for speech; some sample rates don't allow it, so fall
            // back to whatever the encoder picks by itself.
            do {
                try encode(caf, to: temp, bitRatePerChannel: 64_000)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                try encode(caf, to: temp, bitRatePerChannel: nil)
            }
            guard try AVAudioFile(forReading: temp).length == frames else { throw CompressorError.lengthMismatch }
            try? FileManager.default.removeItem(at: m4a)
            try FileManager.default.moveItem(at: temp, to: m4a)
            try FileManager.default.removeItem(at: caf)
            return m4a
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func encode(_ source: URL, to destination: URL, bitRatePerChannel: Int?) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]
        if let bitRatePerChannel { settings[AVEncoderBitRateKey] = bitRatePerChannel * Int(format.channelCount) }
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw CompressorError.lengthMismatch }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            try output.write(from: buffer)
        }
    }
}
