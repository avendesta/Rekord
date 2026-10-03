import SwiftUI

struct RecordingsWindowView: View {
    @ObservedObject var store: RecordingStore
    @ObservedObject var session: RecordingSession
    @StateObject private var player = PlaybackController()
    @State private var selection: Set<URL> = []

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
                List(selection: $selection) {
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
                .onDeleteCommand { confirmTrash(selected) }
                .onKeyPress(.space) {
                    guard !session.isRecording, selected.count == 1, selected[0].playableURL != nil else { return .ignored }
                    withAnimation(.easeInOut(duration: 0.15)) { player.toggle(selected[0]) }
                    return .handled
                }
            }
        }
        .frame(minWidth: 400, minHeight: 220)
        .navigationSubtitle(store.recordings.isEmpty ? "" : "\(store.recordings.count) recording\(store.recordings.count == 1 ? "" : "s")")
        .onAppear { store.reload() }
        .onDisappear { player.stop() }
        // Rekord records everything the Mac plays, so playback would end up in the new recording.
        .onChange(of: session.isRecording) { if session.isRecording { player.stop() } }
        .onChange(of: store.recordings.map(\.id)) {
            if let active = player.activeID, !store.recordings.contains(where: { $0.id == active }) { player.stop() }
        }
        .toolbar {
            if !selected.isEmpty {
                ToolbarItem {
                    Text("\(selected.count) selected").foregroundStyle(.secondary)
                }
                ToolbarItem {
                    Button { confirmTrash(selected) } label: { Label("Delete Selected Recordings", systemImage: "trash") }
                        .help(selected.count == 1 ? "Move Recording to Trash" : "Move \(selected.count) Recordings to Trash")
                }
            }
        }
    }

    /// The selection, minus anything that has since left the list.
    private var selected: [Recording] { store.recordings.filter { selection.contains($0.id) } }

    // NSAlert rather than .confirmationDialog: the latter can dismiss the menu bar popover.
    private func confirmTrash(_ recordings: [Recording]) {
        guard let first = recordings.first else { return }
        let alert = NSAlert()
        let (title, text) = Self.trashPrompt(count: recordings.count,
            single: first.startDate.formatted(date: .abbreviated, time: .shortened))
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if recordings.contains(where: { $0.id == player.activeID }) { player.stop() }
        store.moveToTrash(recordings)
        selection.subtract(recordings.map(\.id))
    }

    static func trashPrompt(count: Int, single: String) -> (title: String, text: String) {
        let transcripts = "Associated transcript files will also be moved to the Trash."
        return count == 1
            ? ("Move This Recording to Trash?", "\(single)\n\(transcripts)")
            : ("Move \(count) Recordings to Trash?", "These recordings will be moved to the Trash.\n\(transcripts)")
    }

    private func row(_ recording: Recording, showsDate: Bool) -> some View {
        RecordingRowView(
            recording: recording,
            showsDate: showsDate,
            isSelected: selection.contains(recording.id),
            playback: playbackState(of: recording),
            player: player,
            onTogglePlay: { withAnimation(.easeInOut(duration: 0.15)) { player.toggle(recording) } },
            activity: store.combining.contains(recording.id) ? "Mixing system + mic into combined.caf" : nil,
            transcript: transcriptState(of: recording),
            onTranscribe: { store.transcribe(recording) },
            onOpenTranscript: { store.openTranscript(recording) },
            onReveal: { store.reveal(recording) },
            // Trashing a selected row trashes the whole selection, as in Finder.
            onDelete: { confirmTrash(selection.contains(recording.id) ? selected : [recording]) }
        )
        .frame(maxWidth: 640, alignment: .leading)
        .listRowSeparator(.hidden)
        .tag(recording.id)
    }

    private func playbackState(of recording: Recording) -> RecordingRowView.PlaybackState {
        if session.isRecording { return .unavailable("Playback is unavailable while recording.") }
        guard recording.playableURL != nil else { return .unavailable("Audio file unavailable") }
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
