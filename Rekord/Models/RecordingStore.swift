import AppKit
import Combine
import Foundation

/// Loads past sessions by scanning the Rekord folder for `session.json` files.
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var combining: Set<URL> = []
    @Published private(set) var combineError: String?
    /// Recordings waiting for or having their transcript made; the first one is running.
    @Published private(set) var transcriptQueue: [URL] = []
    /// Why a recording's last transcription failed, shown on its row until it is retried.
    @Published private(set) var transcriptErrors: [URL: String] = [:]
    /// Recordings whose mixdown failed; not retried until the next launch.
    private var failed: Set<URL> = []

    private var sessionObserver: AnyCancellable?

    static var rootFolder: URL { AppSettings.outputFolder }

    /// Reloads whenever the session changes state, so a finished recording is listed, mixed and
    /// transcribed even if no window is open. Deferred a turn: `stop()` writes session.json after
    /// it changes state.
    func follow(_ session: RecordingSession) {
        sessionObserver = session.$state
            .removeDuplicates()
            .scan((State.idle, State.idle)) { ($0.1, $1) }
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] previous, current in
                guard let self else { return }
                self.reload()
                // Only a recording that just finished is transcribed unasked; older ones have a button.
                if case .recording = previous, current == .idle, AppSettings.transcribeRecordings,
                   let folder = session?.lastSessionFolder,
                   let recording = self.recordings.first(where: { $0.folder.path == folder.path }) {
                    self.transcribe(recording)
                }
            }
    }
    private typealias State = RecordingSession.State

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

        // Every recording with a mic track gets its mixdown, without the user asking.
        // Skipped when an audio file is missing (a folder someone tidied by hand): it can never succeed.
        for recording in recordings where recording.includesMicrophone && !recording.isCombined && !failed.contains(recording.id) && recording.hasAudio {
            combine(recording)
        }
    }

    /// Queues a recording for transcription; also the retry after a failure.
    func transcribe(_ recording: Recording) {
        guard Transcriber.isSupported, !transcriptQueue.contains(recording.id) else { return }
        transcriptErrors[recording.id] = nil
        transcriptQueue.append(recording.id)
        if transcriptQueue.count == 1 { transcribeNext() }
    }

    private func transcribeNext() {
        guard #available(macOS 26, *), let id = transcriptQueue.first else { return }
        guard let recording = recordings.first(where: { $0.id == id }) else {
            transcriptQueue.removeFirst()  // trashed while it waited
            return transcribeNext()
        }
        let language = AppSettings.transcriptionLanguage
        let timestamps = AppSettings.transcriptTimestamps
        Task.detached {
            var failure: String?
            do {
                _ = try await Transcriber.transcribe(folder: recording.folder, metadata: recording.metadata, language: language, timestamps: timestamps)
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [failure] in
                self.transcriptQueue.removeAll { $0 == id }
                self.transcriptErrors[id] = failure
                self.reload()
                self.transcribeNext()
            }
        }
    }

    func openTranscript(_ recording: Recording) {
        NSWorkspace.shared.open(recording.transcriptURL)
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.folder])
    }

    private func combine(_ recording: Recording) {
        guard !combining.contains(recording.id) else { return }
        combining.insert(recording.id)
        Task.detached {
            let result = Result { try CombineEngine.combine(folder: recording.folder, metadata: recording.metadata) }
            await MainActor.run {
                self.combining.remove(recording.id)
                if case .failure(let error) = result {
                    self.failed.insert(recording.id)
                    self.combineError = error.localizedDescription
                }
                self.reload()
            }
        }
    }

    /// Where a trashed recording came from and where the Trash put it, which is what Undo needs.
    struct Trashed: Equatable {
        let original: URL
        let inTrash: URL
    }

    /// Moves recordings (folder, audio and transcript together) to the Trash and returns the ones
    /// that actually went; a folder that is already gone is not reported as trashed.
    @discardableResult
    func moveToTrash(_ recordings: [Recording]) -> [Trashed] {
        var trashed: [Trashed] = []
        for recording in recordings {
            var inTrash: NSURL?
            do {
                try FileManager.default.trashItem(at: recording.folder, resultingItemURL: &inTrash)
                if let inTrash = inTrash as URL? { trashed.append(Trashed(original: recording.folder, inTrash: inTrash)) }
            } catch {
                NSSound.beep()
            }
        }
        reload()
        return trashed
    }

    /// Puts trashed recordings back where they were. Returns false if any could not be restored
    /// (the Trash was emptied, or the original place is taken).
    @discardableResult
    func restore(_ trashed: [Trashed]) -> Bool {
        var allRestored = true
        for item in trashed {
            do {
                try FileManager.default.moveItem(at: item.inTrash, to: item.original)
            } catch {
                allRestored = false
            }
        }
        reload()
        return allRestored
    }
}
