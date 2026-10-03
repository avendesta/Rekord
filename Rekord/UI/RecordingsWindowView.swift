import SwiftUI

struct RecordingsWindowView: View {
    @ObservedObject var store: RecordingStore
    @ObservedObject var session: RecordingSession
    @StateObject private var player = PlaybackController()
    /// The last deletion, while its Undo message is showing.
    @State private var undoable: [RecordingStore.Trashed] = []
    @State private var undoTimeout: Task<Void, Never>?

    /// A short list reads fine as it is; day headers only earn their space once it grows.
    static let groupingThreshold = 8

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.combineError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
            if store.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings Yet", systemImage: "waveform")
                } description: {
                    Text("Start a recording from the menu bar or press \(AppSettings.hotkey.display).")
                }
            } else {
                List {
                    if store.recordings.count < Self.groupingThreshold {
                        ForEach(store.recordings) { row($0, showsDate: true) }
                    } else {
                        ForEach(Self.sections(of: store.recordings), id: \.title) { section in
                            Section(section.title) {
                                ForEach(section.recordings) { row($0, showsDate: false) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 400, minHeight: 220)
        .navigationSubtitle(store.recordings.isEmpty ? "" : "\(store.recordings.count) recording\(store.recordings.count == 1 ? "" : "s")")
        .onAppear { store.reload() }
        .onDisappear {
            player.stop()
            dismissUndo()
        }
        .overlay(alignment: .bottom) {
            if !undoable.isEmpty {
                HStack(spacing: 14) {
                    Text("Recording moved to Trash")
                    Button("Undo", action: undo)
                        .buttonStyle(.link)
                        .keyboardShortcut("z", modifiers: .command)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Rekord records everything the Mac plays, so playback would end up in the new recording.
        .onChange(of: session.isRecording) { if session.isRecording { player.stop() } }
        .onChange(of: store.recordings.map(\.id)) {
            if let active = player.activeID, !store.recordings.contains(where: { $0.id == active }) { player.stop() }
        }
    }

    /// Straight to the Trash, with no dialog: an Undo message follows, and the recording can also
    /// be put back from the Trash in Finder.
    private func trash(_ recording: Recording) {
        if recording.id == player.activeID { player.stop() }
        let trashed = store.moveToTrash([recording])

        undoTimeout?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { undoable = trashed }  // empty if nothing was actually trashed
        guard !trashed.isEmpty else { return }
        undoTimeout = Task {
            try? await Task.sleep(for: .seconds(7))
            if !Task.isCancelled { withAnimation(.easeIn(duration: 0.2)) { undoable = [] } }
        }
    }

    private func undo() {
        let items = undoable
        dismissUndo()
        if !store.restore(items) { NSSound.beep() }
    }

    private func dismissUndo() {
        undoTimeout?.cancel()
        withAnimation(.easeIn(duration: 0.2)) { undoable = [] }
    }


    private func row(_ recording: Recording, showsDate: Bool) -> some View {
        RecordingRowView(
            recording: recording,
            showsDate: showsDate,
            playback: playbackState(of: recording),
            player: player,
            onTogglePlay: { withAnimation(.easeInOut(duration: 0.15)) { player.toggle(recording) } },
            activity: store.combining.contains(recording.id) ? "Mixing system + mic into combined.caf" : nil,
            transcript: transcriptState(of: recording),
            onTranscribe: { store.transcribe(recording) },
            onOpenTranscript: { store.openTranscript(recording) },
            onReveal: { store.reveal(recording) },
            onDelete: { trash(recording) }
        )
        .frame(maxWidth: 640, alignment: .leading)
        .listRowSeparator(.hidden)
    }

    private func playbackState(of recording: Recording) -> RecordingRowView.PlaybackState {
        if session.isRecording { return .unavailable("Playback is unavailable while recording.") }
        guard recording.hasAudio else { return .unavailable("Audio file unavailable") }
        guard recording.playableURL != nil else {
            return .unavailable(recording.includesMicrophone && !recording.isCombined ? "Still preparing this recording…" : "This recording has no audio.")
        }
        guard player.activeID == recording.id else { return .idle }
        return player.isPlaying ? .playing : .paused
    }

    private func transcriptState(of recording: Recording) -> RecordingRowView.TranscriptState? {
        // Nothing to offer where transcription isn't available or the audio is gone.
        guard Transcriber.isSupported, recording.hasAudio || recording.hasTranscript else { return nil }
        if store.transcriptQueue.contains(recording.id) { return .inProgress }
        if let reason = store.transcriptErrors[recording.id] { return .failed(reason) }
        return recording.hasTranscript ? .ready : .notStarted
    }

    /// Recordings (already newest first) split by day: Today, Yesterday, then the date.
    static func sections(of recordings: [Recording], now: Date = Date(), calendar: Calendar = .current)
        -> [(title: String, recordings: [Recording])] {
        var sections: [(title: String, recordings: [Recording])] = []
        for recording in recordings {
            let title = sectionTitle(for: recording.startDate, now: now, calendar: calendar)
            if sections.last?.title == title {
                sections[sections.count - 1].recordings.append(recording)
            } else {
                sections.append((title, [recording]))
            }
        }
        return sections
    }

    static func sectionTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle().month(.abbreviated).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }
}
