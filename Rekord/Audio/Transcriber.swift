import AVFoundation
import Speech

/// One stretch of recognized speech, timed from the start of its own track.
struct TranscriptSegment: Equatable {
    var start: Double
    var text: String
}

/// Turns the two tracks' segments into the text of `transcript.txt`.
enum Transcript {
    static let noSpeech = "(No speech detected)"

    /// `mic` is nil for a system-only recording, which gets no speaker labels. `micOffset` follows
    /// `session.json`: positive means the mic started later, so its times shift forward.
    static func render(system: [TranscriptSegment], mic: [TranscriptSegment]?, micOffset: Double = 0, timestamps: Bool = true) -> String {
        var lines: [(time: Double, text: String)] = []
        for segment in system {
            lines.append((segment.start + max(0, -micOffset), mic == nil ? segment.text : "Others: " + segment.text))
        }
        for segment in mic ?? [] {
            lines.append((segment.start + max(0, micOffset), "Me: " + segment.text))
        }
        guard !lines.isEmpty else { return noSpeech + "\n" }
        let long = lines.contains { $0.time >= 3600 }
        return lines.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }  // stable on ties
            .map { (timestamps ? "[\(timestamp($0.element.time, hours: long))] " : "") + $0.element.text + "\n" }
            .joined()
    }

    static func timestamp(_ seconds: Double, hours: Bool) -> String {
        let total = Int(seconds)
        return hours
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// On-device transcription with Apple's SpeechAnalyzer (macOS 26+). Audio never leaves the Mac;
/// the system may download a language model the first time a language is used.
enum Transcriber {
    enum TranscriberError: Error, LocalizedError {
        case unsupportedLanguage
        case missingAudio
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage: return "Transcription isn't available for the chosen language."
            case .missingAudio: return "This recording's audio file is missing."
            case .timedOut: return "Transcription took too long and was stopped."
            }
        }
    }

    /// False on macOS before 26 and on Macs the speech model doesn't support.
    static var isSupported: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    /// Writes `transcript.txt` into a recording's folder and returns its URL. Gives up after a time
    /// limit, so one recording the speech model chokes on can't hold up the ones queued behind it.
    @available(macOS 26, *)
    static func transcribe(folder: URL, metadata: RecordingSession.Metadata, language: String?, timestamps: Bool = true) async throws -> URL {
        let limit = max(120, metadata.durationSeconds * 2)
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await write(folder: folder, metadata: metadata, language: language, timestamps: timestamps) }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                throw TranscriberError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    @available(macOS 26, *)
    private static func write(folder: URL, metadata: RecordingSession.Metadata, language: String?, timestamps: Bool) async throws -> URL {
        let preferred = language.map(Locale.init(identifier:)) ?? .current
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred)
        if locale == nil, language == nil {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let locale else { throw TranscriberError.unsupportedLanguage }

        let system = try await segments(of: folder.appendingPathComponent("system.caf"), locale: locale)
        let mic = metadata.includeMicrophone
            ? try await segments(of: folder.appendingPathComponent("mic.caf"), locale: locale)
            : nil
        let text = Transcript.render(system: system, mic: mic, micOffset: metadata.micOffsetSeconds ?? 0, timestamps: timestamps)

        let url = folder.appendingPathComponent("transcript.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @available(macOS 26, *)
    private static func segments(of url: URL, locale: Locale) async throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw TranscriberError.missingAudio }
        let file = try AVAudioFile(forReading: url)
        // The analyzer never finishes on a file with no audio in it.
        guard file.length > 0 else { return [] }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        var segments: [TranscriptSegment] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(TranscriptSegment(start: result.range.start.seconds, text: text)) }
        }
        _ = analyzer  // kept alive until the results end
        return segments
    }
}
