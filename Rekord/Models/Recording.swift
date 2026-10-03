import Foundation

/// One past session on disk, described by its folder and `session.json`.
struct Recording: Identifiable {
    let folder: URL
    let metadata: RecordingSession.Metadata

    var id: URL { folder }
    var startDate: Date { metadata.startDate }
    var duration: TimeInterval { metadata.durationSeconds }
    var includesMicrophone: Bool { metadata.includeMicrophone }
    var combinedURL: URL { folder.appendingPathComponent("combined.caf") }
    var isCombined: Bool { FileManager.default.fileExists(atPath: combinedURL.path) }
    /// False when a track's file has been removed from the folder.
    var hasAudio: Bool {
        (["system.caf"] + (includesMicrophone ? ["mic.caf"] : []))
            .allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
    /// What the user hears for this recording: the mix when there is a mic track, else the system
    /// track. Nil while the mix isn't made yet or the file is gone.
    var playableURL: URL? {
        let url = includesMicrophone ? combinedURL : folder.appendingPathComponent("system.caf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.txt") }
    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcriptURL.path) }
}
