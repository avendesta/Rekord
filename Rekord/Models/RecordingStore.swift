import AppKit
import AVFoundation
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
    private var isTranscribing = false
    /// Recordings to convert to M4A once their mix and transcript no longer need the originals.
    @Published private(set) var pendingCompression: Set<URL> = []
    /// The one being converted; they go one at a time.
    @Published private(set) var compressing: URL?

    private var sessionObserver: AnyCancellable?
    private weak var session: RecordingSession?

    static var rootFolder: URL { AppSettings.outputFolder }

    /// Reloads whenever the session changes state, so a finished recording is listed, mixed and
    /// transcribed even if no window is open. Deferred a turn: `stop()` writes session.json after
    /// it changes state.
    func follow(_ session: RecordingSession) {
        self.session = session
        sessionObserver = session.$state
            .removeDuplicates()
            .scan((State.idle, State.idle)) { ($0.1, $1) }
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] previous, current in
                guard let self else { return }
                self.reload()
                // Only a recording that just finished is transcribed and compressed unasked; older
                // ones have a button for each.
                if previous != .idle, previous != .starting, current == .idle,
                   let folder = session?.lastSessionFolder,
                   let recording = self.recordings.first(where: { $0.folder.path == folder.path }) {
                    if AppSettings.compressRecordings { self.pendingCompression.insert(recording.id) }
                    if AppSettings.transcribeRecordings { self.transcribe(recording) }
                    self.compressNext()
                }
            }
    }
    private typealias State = RecordingSession.State

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: Self.rootFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []

        // The recording in progress has its session.json already, but isn't one to list, mix or play yet.
        let active = session.flatMap { $0.isRecording ? $0.lastSessionFolder?.path : nil }

        // Folders without a readable session.json (old test dirs) are skipped.
        recordings = folders.compactMap { folder in
            guard folder.path != active, let metadata = try? RecordingSession.Metadata.read(from: folder) else { return nil }
            return Recording(folder: folder, metadata: Self.finished(metadata, in: folder))
        }
        .sorted { $0.startDate > $1.startDate }

        removeExpiredAudio()

        // Every recording with a mic track gets its mixdown, without the user asking.
        // Skipped when an audio file is missing (a folder someone tidied by hand): it can never succeed.
        for recording in recordings where recording.includesMicrophone && !recording.isCombined && !failed.contains(recording.id) && recording.hasAudio {
            combine(recording)
        }
        compressNext()
    }

    /// A recording that was never stopped (a crash, a force quit) still has the zero length written
    /// when it started. Its real length is the system track's, which CAF keeps readable unclosed.
    private static func finished(_ metadata: RecordingSession.Metadata, in folder: URL) -> RecordingSession.Metadata {
        guard metadata.durationSeconds == 0, let url = Track.system.url(in: folder),
              let file = try? AVAudioFile(forReading: url), file.length > 0 else { return metadata }
        // ponytail: the mic/system offset of a crashed recording is unknown, so its mix assumes
        // both tracks started together. Write the offset into session.json mid-recording if that shows.
        var metadata = metadata
        metadata.durationSeconds = Double(file.length) / file.fileFormat.sampleRate
        try? metadata.write(to: folder)
        return metadata
    }

    /// Moves the audio of old recordings to the Trash, keeping the transcript and the name. Only
    /// recordings that have a transcript qualify, so nothing is ever left with neither.
    private func removeExpiredAudio(now: Date = Date()) {
        let days = AppSettings.audioRetentionDays
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for recording in recordings where recording.startDate < cutoff && recording.hasTranscript {
            // Leave alone anything still being worked on.
            guard !combining.contains(recording.id), compressing != recording.id,
                  !transcriptQueue.contains(recording.id), !pendingCompression.contains(recording.id) else { continue }
            for track in Track.allCases {
                for file in [track.original(in: recording.folder), track.original(in: recording.folder).deletingPathExtension().appendingPathExtension("m4a")]
                where FileManager.default.fileExists(atPath: file.path) {
                    try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
                }
            }
        }
    }

    /// Recordings that still have CAF audio worth converting.
    var compressible: [Recording] { recordings.filter { AudioCompressor.needsCompression(folder: $0.folder) } }

    /// Converts every existing recording to M4A (the Settings button).
    func compressAll() {
        pendingCompression.formUnion(compressible.map(\.id))
        compressNext()
    }

    /// Starts the next conversion that is safe to run: the mix is made (or can't be) and nothing
    /// is transcribing the recording, since conversion deletes the files those read.
    private func compressNext() {
        guard compressing == nil else { return }
        pendingCompression = pendingCompression.filter { id in recordings.contains { $0.id == id } }
        for recording in recordings where pendingCompression.contains(recording.id) {
            guard AudioCompressor.needsCompression(folder: recording.folder) else {
                pendingCompression.remove(recording.id)
                continue
            }
            let mixSettled = !recording.includesMicrophone || recording.isCombined || failed.contains(recording.id) || !recording.hasAudio
            guard mixSettled, !combining.contains(recording.id), !transcriptQueue.contains(recording.id) else { continue }
            compressing = recording.id
            Task.detached {
                try? AudioCompressor.compress(folder: recording.folder, metadata: recording.metadata)  // on failure the CAF stays
                await MainActor.run {
                    self.compressing = nil
                    self.pendingCompression.remove(recording.id)
                    self.reload()
                    self.transcribeNext()
                }
            }
            return
        }
    }

    /// Queues a recording for transcription; also the retry after a failure.
    func transcribe(_ recording: Recording) {
        guard Transcriber.isSupported, !transcriptQueue.contains(recording.id) else { return }
        transcriptErrors[recording.id] = nil
        transcriptQueue.append(recording.id)
        transcribeNext()
    }

    private func transcribeNext() {
        guard #available(macOS 26, *), !isTranscribing, let id = transcriptQueue.first else { return }
        guard let recording = recordings.first(where: { $0.id == id }) else {
            transcriptQueue.removeFirst()  // trashed while it waited
            return transcribeNext()
        }
        guard compressing != id else { return }  // its files are being replaced; resumed when that ends
        isTranscribing = true
        let language = AppSettings.transcriptionLanguage
        let timestamps = AppSettings.transcriptTimestamps
        let includeMicrophone = AppSettings.transcriptIncludesMicrophone
        Task.detached {
            var failure: String?
            do {
                _ = try await Transcriber.transcribe(folder: recording.folder, metadata: recording.metadata, language: language, timestamps: timestamps,
                                                     includeMicrophone: includeMicrophone)
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [failure] in
                self.isTranscribing = false
                self.transcriptQueue.removeAll { $0 == id }
                self.transcriptErrors[id] = failure
                self.reload()
                self.transcribeNext()
            }
        }
    }

    /// Gives a recording a display name; an empty name goes back to showing its time. Only
    /// session.json changes, so every file path stays as it is.
    func rename(_ recording: Recording, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var metadata = try? RecordingSession.Metadata.read(from: recording.folder) else { return }
        metadata.name = trimmed.isEmpty ? nil : trimmed
        do {
            try metadata.write(to: recording.folder)
        } catch {
            NSSound.beep()
        }
        reload()
    }

    /// Puts the transcript on the clipboard under a short header, so it explains itself when
    /// pasted somewhere else, such as into an AI assistant.
    func copyTranscript(_ recording: Recording) {
        guard let text = recording.transcriptForSharing() else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
