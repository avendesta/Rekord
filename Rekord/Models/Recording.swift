import Foundation

/// One past session on disk, described by its folder and `session.json`.
struct Recording: Identifiable {
    let folder: URL
    let metadata: RecordingSession.Metadata

    var id: URL { folder }
    var startDate: Date { metadata.startDate }
    var name: String? { metadata.name }
    var duration: TimeInterval { metadata.durationSeconds }
    var includesMicrophone: Bool { metadata.includeMicrophone }
    var isCombined: Bool { Track.combined.url(in: folder) != nil }
    /// False when a track's file has been removed from the folder.
    var hasAudio: Bool {
        Track.system.url(in: folder) != nil && (!includesMicrophone || Track.mic.url(in: folder) != nil)
    }
    /// What the user hears for this recording: the mix when there is a mic track, else the system
    /// track. Nil while the mix isn't made yet, or when the file is gone or holds no audio.
    var playableURL: URL? {
        guard let url = (includesMicrophone ? Track.combined : Track.system).url(in: folder) else { return nil }
        // ponytail: a CAF that is all header (4096 bytes) holds no audio. An M4A always does, since
        // empty tracks are never compressed. Read the file's length instead if that ever changes.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return url.pathExtension == "m4a" || size > 4096 ? url : nil
    }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.txt") }
    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcriptURL.path) }

    /// The transcript headed by what the recording is: its name (if any), when it was made and how long it is.
    func transcriptForSharing(locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return nil }
        let when = startDate.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone))
        let total = Int(duration)
        let length = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
        let title = name.map { "\($0)\n" } ?? ""
        return "\(title)Recorded \(when) · \(length)\n\n\(transcript)"
    }
}
