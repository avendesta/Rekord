import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Gives a recording a short title from its transcript, with Apple's on-device language model
/// (macOS 26 with Apple Intelligence). Nothing leaves the Mac.
enum TranscriptNamer {
    /// False where the model isn't there: before macOS 26, no Apple Intelligence, not downloaded yet.
    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// The text to read. The model's window is small (about 4,000 tokens), so a long transcript is
    /// cut down to its start, a stretch from the middle, and its end.
    static func excerpt(of transcript: String, limit: Int = 6000) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let part = limit / 3
        let middle = text.index(text.startIndex, offsetBy: (text.count - part) / 2)
        return [String(text.prefix(part)), String(text[middle...].prefix(part)), String(text.suffix(part))].joined(separator: "\n…\n")
    }

    /// A model's answer made fit to show as a name: one line, no quotes or closing full stop, short.
    static func clean(_ raw: String) -> String? {
        var title = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*# ").union(.whitespacesAndNewlines))
        if title.hasSuffix(".") { title.removeLast() }
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if title.count > 60 {
            // Cut at a word, not in the middle of one.
            let head = String(title.prefix(60))
            title = (head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head) + "…"
        }
        return title.isEmpty ? nil : title
    }

    /// Too little said to name: a transcript with no speech, or a few words.
    static func hasEnoughToName(_ transcript: String) -> Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines) != Transcript.noSpeech
            && Transcript.words(of: transcript).count >= 15
    }

    /// Nil when there is too little to go on or the model has nothing usable to say.
    static func name(for transcript: String) async throws -> String? {
        guard hasEnoughToName(transcript) else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return try await generate(from: transcript) }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    @Generable
    struct RecordingTitle {
        @Guide(description: "A title of three to six words, never longer, in the language of the transcript, with no quotes and no full stop at the end.")
        var title: String
    }

    @available(macOS 26, *)
    private static func generate(from transcript: String) async throws -> String? {
        // A transcript in a language that takes more tokens per character can overflow the window;
        // each overflow retries with less of it.
        for limit in [6000, 3000, 1200] {
            let session = LanguageModelSession(instructions: "You name recordings of meetings and calls. Read the transcript and give the recording a short title, three to six words, that says what it is about.")
            do {
                let answer = try await session.respond(
                    to: "Transcript:\n\(excerpt(of: transcript, limit: limit))",
                    generating: RecordingTitle.self,
                    options: GenerationOptions(temperature: 0.3))
                return clean(answer.content.title)
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                continue
            }
        }
        return nil
    }
    #endif
}
