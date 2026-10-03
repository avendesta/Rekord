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
    var transcriptURL: URL { folder.appendingPathComponent("transcript.txt") }
    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcriptURL.path) }
}
