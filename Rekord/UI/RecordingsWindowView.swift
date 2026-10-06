import SwiftUI

struct RecordingsWindowView: View {
    @ObservedObject var store: RecordingStore
    @ObservedObject var session: RecordingSession
    @StateObject private var player = PlaybackController()
    /// The last deletion, while its Undo message is showing.
    @State private var undoable: [RecordingStore.Trashed] = []
    /// When the Undo message goes away by itself; nil while the pointer rests on it, which holds
    /// it open with `undoTimeLeft` still to run.
    @State private var undoDeadline: Date?
    @State private var undoTimeLeft: TimeInterval = 0
    /// The row the keyboard acts on. Not a List's selection: a List hides tooltips on its controls.
    @State private var selection: URL?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.combineError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
            if store.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings", systemImage: "waveform")
                } description: {
                    Text("Start a recording from the menu bar or press \(AppSettings.hotkey.display).")
                }
            } else {
                // A plain scrolling stack, not a List: tooltips don't appear on controls inside List
                // rows. The selection and the keys are done by hand instead.
                ScrollViewReader { proxy in
                ScrollView {
                    // Always grouped by day: the header carries the date, so rows only need the time.
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                        ForEach(Self.sections(of: store.recordings), id: \.title) { section in
                            Section {
                                ForEach(section.recordings) { row($0) }
                            } header: {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.background)  // rows scroll underneath a pinned header
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                // Clicking away from a name being edited ends the edit, which saves it.
                .contentShape(Rectangle())
                .onTapGesture {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    takeKeyboard()
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: [.down, .repeat], action: handleKey)
                .onChange(of: selection) { if let selection { proxy.scrollTo(selection) } }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 220)
        .navigationSubtitle(store.recordings.isEmpty ? "" : "\(store.recordings.count) recording\(store.recordings.count == 1 ? "" : "s")")
        .onAppear {
            store.reload()
            takeKeyboard()
        }
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
                .onHover { inside in
                    if inside, let deadline = undoDeadline {
                        undoTimeLeft = max(0, deadline.timeIntervalSinceNow)
                        undoDeadline = nil
                    } else if !inside, undoDeadline == nil {
                        undoDeadline = Date().addingTimeInterval(undoTimeLeft)
                    }
                }
                // Tied to the message: a new deadline restarts the wait, and the wait ends with the
                // message, however it goes away.
                .task(id: undoDeadline) {
                    guard let undoDeadline else { return }
                    try? await Task.sleep(for: .seconds(undoDeadline.timeIntervalSinceNow))
                    if !Task.isCancelled { dismissUndo() }
                }
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Rekord records everything the Mac plays, so playback would end up in the new recording.
        .onChange(of: session.isRecording) { if session.isRecording { player.stop() } }
        .onChange(of: store.recordings.map(\.id)) {
            if let active = player.activeID, !store.recordings.contains(where: { $0.id == active }) { player.stop() }
            if let selection, !store.recordings.contains(where: { $0.id == selection }) { self.selection = nil }
        }
    }

    /// Focused a turn later, once whatever had the keyboard has let go of it.
    private func takeKeyboard() {
        DispatchQueue.main.async { listFocused = true }
    }

    /// Up and down move the selection, Space plays or pauses it, Delete moves it to the Trash.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Typing in a name being edited belongs to the field.
        if NSApp.keyWindow?.firstResponder is NSText { return .ignored }
        let recordings = store.recordings
        guard !recordings.isEmpty else { return .ignored }
        let index = selection.flatMap { id in recordings.firstIndex { $0.id == id } }
        // The Delete key arrives as U+007F, which SwiftUI's `.delete` does not match.
        if press.key == .deleteForward || press.characters == "\u{7F}" {
            guard press.modifiers.subtracting(.command).isEmpty, let index else { return .ignored }
            if press.phase == .down { trash(recordings[index]) }
            return .handled
        }
        switch press.key {
        case .upArrow, .downArrow:
            guard press.modifiers.isEmpty else { return .ignored }
            let step = press.key == .downArrow ? 1 : -1
            let next = index.map { min(max($0 + step, 0), recordings.count - 1) } ?? (step > 0 ? 0 : recordings.count - 1)
            selection = recordings[next].id
        case .space:
            guard press.modifiers.isEmpty, let index else { return .ignored }
            if press.phase == .down { togglePlay(recordings[index]) }  // a held key doesn't flicker it
        default:
            return .ignored
        }
        return .handled
    }

    private func togglePlay(_ recording: Recording) {
        if case .unavailable = playbackState(of: recording) { return NSSound.beep() }
        withAnimation(.easeInOut(duration: 0.15)) { player.toggle(recording) }
    }

    /// Straight to the Trash, with no dialog: an Undo message follows, and the recording can also
    /// be put back from the Trash in Finder.
    private func trash(_ recording: Recording) {
        if recording.id == player.activeID { player.stop() }
        // One animation for both: the rows close the gap as the Undo message comes in.
        let position = store.recordings.firstIndex { $0.id == recording.id }
        withAnimation(.easeOut(duration: 0.2)) { undoable = store.moveToTrash([recording]) }  // empty if nothing was actually trashed
        undoDeadline = Date().addingTimeInterval(7)
        // The next row takes over the selection, so Delete can be pressed again down the list.
        if !undoable.isEmpty, let position, !store.recordings.isEmpty {
            selection = store.recordings[min(position, store.recordings.count - 1)].id
        }
    }

    private func undo() {
        let items = undoable
        dismissUndo()
        let restored = withAnimation(.easeOut(duration: 0.2)) { store.restore(items) }
        if !restored { NSSound.beep() }
        if let first = items.first?.original { selection = first }
        takeKeyboard()
    }

    private func dismissUndo() {
        withAnimation(.easeIn(duration: 0.2)) { undoable = [] }
    }


    private func row(_ recording: Recording) -> some View {
        RecordingRowView(
            recording: recording,
            playback: playbackState(of: recording),
            player: player,
            onTogglePlay: { togglePlay(recording) },
            activity: store.combining.contains(recording.id) ? "Preparing…"
                : store.compressing == recording.id ? "Converting…" : nil,
            transcript: transcriptState(of: recording),
            onTranscribe: { store.transcribe(recording) },
            onOpenTranscript: { store.openTranscript(recording) },
            onCopyTranscript: { store.copyTranscript(recording) },
            onRename: { store.rename(recording, to: $0) },
            onEndRename: takeKeyboard,
            isSelected: selection == recording.id,
            onReveal: { store.reveal(recording) },
            onDelete: { trash(recording) }
        )
        .frame(maxWidth: 640, alignment: .leading)
        .simultaneousGesture(TapGesture().onEnded {
            selection = recording.id
            takeKeyboard()
        })
    }

    private func playbackState(of recording: Recording) -> RecordingRowView.PlaybackState {
        if session.isRecording { return .unavailable("Playback is unavailable while recording.") }
        guard recording.hasAudio else {
            return .unavailable(recording.hasTranscript ? "Audio was removed. The transcript is still available." : "Audio file can't be found.")
        }
        guard recording.playableURL != nil else {
            return .unavailable(recording.includesMicrophone && !recording.isCombined ? "Still preparing this recording…" : "This recording contains no playable audio.")
        }
        guard player.activeID == recording.id else { return .idle }
        return player.isPlaying ? .playing : .paused
    }

    private func transcriptState(of recording: Recording) -> RecordingRowView.TranscriptState? {
        // Nothing to offer where transcription isn't available or the audio is gone.
        guard Transcriber.isSupported, recording.hasAudio || recording.hasTranscript else { return nil }
        // Transcripts are made one at a time; the first in the queue is the one running.
        if let place = store.transcriptQueue.firstIndex(of: recording.id) { return place == 0 ? .inProgress : .queued }
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
