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
}
