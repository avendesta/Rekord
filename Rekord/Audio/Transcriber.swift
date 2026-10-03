import AVFoundation
import Speech

/// One stretch of recognized speech, timed from the start of its own track.
struct TranscriptSegment: Equatable {
    var start: Double
    var text: String
    /// Where the speech stops; nil is treated as a segment with no length.
    var end: Double?
}

/// Turns the two tracks' segments into the text of `transcript.txt`.
enum Transcript {
    static let noSpeech = "(No speech detected)"

    /// `mic` is nil for a system-only recording, which gets no speaker labels. `micOffset` follows
    /// `session.json`: positive means the mic started later, so its times shift forward.
    static func render(system: [TranscriptSegment], mic: [TranscriptSegment]?, micOffset: Double = 0, timestamps: Bool = true) -> String {
        let mic = mic.map { withoutEcho(mic: $0, system: system, micOffset: micOffset) }
        typealias Line = (time: Double, end: Double, speaker: String?, text: String)
        var lines: [Line] = []
        for segment in system {
            let shift = max(0, -micOffset)
            lines.append((segment.start + shift, (segment.end ?? segment.start) + shift, mic == nil ? nil : "Others", segment.text))
        }
        for segment in mic ?? [] {
            let shift = max(0, micOffset)
            lines.append((segment.start + shift, (segment.end ?? segment.start) + shift, "Me", segment.text))
        }
        guard !lines.isEmpty else { return noSpeech + "\n" }
        let sorted = lines.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }  // stable on ties
            .map(\.element)

        // One paragraph per stretch of one person talking: it reads as prose and is shorter to
        // paste. A new one starts when the speaker changes, after a pause, or when it gets long.
        var paragraphs: [Line] = []
        for line in sorted {
            if let last = paragraphs.last, last.speaker == line.speaker,
               line.time - last.end <= paragraphPause, line.time - last.time < paragraphLength {
                paragraphs[paragraphs.count - 1].text += " " + line.text
                paragraphs[paragraphs.count - 1].end = max(last.end, line.end)
            } else {
                paragraphs.append(line)
            }
        }
        let long = paragraphs.contains { $0.time >= 3600 }
        return paragraphs.map {
            (timestamps ? "[\(timestamp($0.time, hours: long))] " : "") + ($0.speaker.map { $0 + ": " } ?? "") + $0.text
        }.joined(separator: "\n\n") + "\n"
    }

    /// A silence longer than this, in seconds, starts a new paragraph.
    static let paragraphPause = 3.0
    /// A paragraph that has run this long, in seconds, is closed at the next sentence.
    static let paragraphLength = 60.0

    /// Drops the microphone segments that are only the meeting coming out of the speakers.
    ///
    /// With speakers, the mic hears the meeting, so each sentence is transcribed twice: from the
    /// system track and, at the same moment, from the mic track. A mic segment counts as such an
    /// echo when most of its words appear, in order, in what the system track said within a couple
    /// of seconds of it. Time and words must both match, so what the user really said is kept,
    /// even while someone else is talking.
    static func withoutEcho(mic: [TranscriptSegment], system: [TranscriptSegment], micOffset: Double) -> [TranscriptSegment] {
        let micShift = max(0, micOffset), systemShift = max(0, -micOffset)
        let heard = system.map { (from: $0.start + systemShift, to: ($0.end ?? $0.start) + systemShift, words: words(of: $0.text)) }
        return mic.filter { segment in
            let said = words(of: segment.text)
            guard !said.isEmpty else { return false }
            let from = segment.start + micShift - echoWindow, to = (segment.end ?? segment.start) + micShift + echoWindow
            let nearby = heard.filter { $0.to >= from && $0.from <= to }
            // A word or two ("Yeah.", "Okay, thanks") turns up in other people's sentences by chance,
            // so something that short is only an echo of a line that says exactly the same.
            if said.count < 3 { return !nearby.contains { $0.words == said } }
            let shared = longestCommonSubsequence(said, nearby.flatMap(\.words))
            return Double(shared) / Double(said.count) < echoShare
        }
    }

    /// Seconds either side of a mic segment in which the system track is searched for the same words.
    static let echoWindow = 2.0
    /// The share of a mic segment's words that must be found for it to count as an echo.
    static let echoShare = 0.75

    static func words(of text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }.map(String.init)
    }

    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                current[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return previous[b.count]
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
    static func transcribe(folder: URL, metadata: RecordingSession.Metadata, language: String?, timestamps: Bool = true,
                           includeMicrophone: Bool = true) async throws -> URL {
        let limit = max(120, metadata.durationSeconds * 2)
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await write(folder: folder, metadata: metadata, language: language, timestamps: timestamps,
                                includeMicrophone: includeMicrophone)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                throw TranscriberError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    @available(macOS 26, *)
    private static func write(folder: URL, metadata: RecordingSession.Metadata, language: String?, timestamps: Bool,
                              includeMicrophone: Bool) async throws -> URL {
        let preferred = language.map(Locale.init(identifier:)) ?? .current
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred)
        if locale == nil, language == nil {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let locale else { throw TranscriberError.unsupportedLanguage }

        let system = try await segments(of: Track.system.url(in: folder) ?? Track.system.original(in: folder), locale: locale)
        let mic = metadata.includeMicrophone && includeMicrophone
            ? try await segments(of: Track.mic.url(in: folder) ?? Track.mic.original(in: folder), locale: locale)
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
            if !text.isEmpty {
                segments.append(TranscriptSegment(start: result.range.start.seconds, text: text, end: result.range.end.seconds))
            }
        }
        _ = analyzer  // kept alive until the results end
        return segments
    }
}
