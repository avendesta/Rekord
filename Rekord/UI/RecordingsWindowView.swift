import SwiftUI

struct RecordingsWindowView: View {
    @ObservedObject var store: RecordingStore
    @State private var selection: URL?

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
                // Selection is drawn by the rows themselves: the system highlight would turn their text white.
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
    }

    private func row(_ recording: Recording, showsDate: Bool) -> some View {
        RecordingRowView(
            recording: recording,
            showsDate: showsDate,
            isSelected: selection == recording.id,
            activity: store.combining.contains(recording.id) ? "Mixing system + mic into combined.caf" : nil,
            transcript: transcriptState(of: recording),
            onTranscribe: { store.transcribe(recording) },
            onOpenTranscript: { store.openTranscript(recording) },
            onReveal: { store.reveal(recording) },
            onDelete: { store.moveToTrash(recording) }
        )
        .listRowSeparator(.hidden)
        .onTapGesture { selection = recording.id }
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
