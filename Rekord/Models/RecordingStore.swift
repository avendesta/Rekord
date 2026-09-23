import AppKit
import Foundation

/// Loads past sessions by scanning the Rekord folder for `session.json` files.
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var combining: Set<URL> = []
    @Published private(set) var combineError: String?

    static var rootFolder: URL { AppSettings.outputFolder }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: Self.rootFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []

        // Folders without a readable session.json (old test dirs, crashed sessions) are skipped.
        recordings = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
                  let metadata = try? decoder.decode(RecordingSession.Metadata.self, from: data)
            else { return nil }
            return Recording(folder: folder, metadata: metadata)
        }
        .sorted { $0.startDate > $1.startDate }
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.folder])
    }

    func combine(_ recording: Recording) {
        guard !combining.contains(recording.id) else { return }
        combining.insert(recording.id)
        combineError = nil
        Task.detached {
            let result = Result { try CombineEngine.combine(folder: recording.folder, metadata: recording.metadata) }
            await MainActor.run {
                self.combining.remove(recording.id)
                if case .failure(let error) = result { self.combineError = error.localizedDescription }
                self.reload()
            }
        }
    }

    func moveToTrash(_ recording: Recording) {
        do {
            try FileManager.default.trashItem(at: recording.folder, resultingItemURL: nil)
        } catch {
            NSSound.beep()
        }
        reload()
    }
}
