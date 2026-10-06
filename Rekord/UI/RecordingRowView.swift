import SwiftUI

struct RecordingRowView: View {
    let recording: Recording
    var playback: PlaybackState = .idle
    /// Only read by the scrubber of the row being played.
    var player: PlaybackController?
    var onTogglePlay: () -> Void = {}
    /// What Rekord is doing to this recording in the background, if anything.
    var activity: String?
    /// Nil where transcription isn't available, which hides the transcript control.
    var transcript: TranscriptState?
    var onTranscribe: () -> Void = {}
    var onOpenTranscript: () -> Void = {}
    var onCopyTranscript: () -> Void = {}
    var onRename: (String) -> Void = { _ in }
    /// The row the arrow keys are on.
    var isSelected = false
    let onReveal: () -> Void
    /// Not confirmed: the window offers Undo.
    let onDelete: () -> Void

    enum PlaybackState: Equatable {
        case unavailable(String), idle, playing, paused
    }

    // No case named `none`: on an optional that would silently mean nil.
    enum TranscriptState: Equatable {
        case notStarted, queued, inProgress, ready, failed(String)
    }

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    /// File actions appear only for the row being pointed at, and its transcript action stands out.
    private var isActive: Bool { isHovered }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            playButton
            VStack(alignment: .leading, spacing: 2) {
                title
                // The day is in the section header and every recording has system audio, so the
                // line only says what varies: the time (when a name took its place), length, mic, and
                // anything Rekord is still doing to it.
                HStack(spacing: 4) {
                    Text((recording.name == nil ? "" : "\(time) · ") + duration)
                    if recording.includesMicrophone {
                        Text("·")
                        Image(systemName: "mic.fill")
                            .imageScale(.small)
                            .help("Microphone included")
                            .accessibilityLabel("Microphone included")
                    }
                    if let activity {
                        Text("·")
                        ProgressView().controlSize(.mini)
                        Text(activity).lineLimit(1)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // Only the recording being listened to grows a scrubber; every other row stays compact.
                if playback == .playing || playback == .paused, let player {
                    PlaybackBar(player: player, clock: player.clock)
                        .padding(.top, 4)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 8)
            // A fixed column, so the states sit in the same place on every row.
            transcriptControl
                .frame(width: 124, alignment: .trailing)
            // File management stays out of the way until the row is pointed at.
            HStack(spacing: 6) {
                Button(action: onReveal) { Label("Reveal in Finder", systemImage: "folder") }
                    .help("Reveal in Finder")
                Button(action: onDelete) { Label("Move to Trash", systemImage: "trash") }
                    .help("Move to Trash")
                    .padding(.leading, 6)  // set apart from the everyday controls
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .showOnly(when: isActive)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            switch playback {
            case .idle, .paused: Button("Play", action: onTogglePlay)
            case .playing: Button("Pause", action: onTogglePlay)
            case .unavailable: EmptyView()
            }
            switch transcript {
            case .ready?:
                Button("Open Transcript", action: onOpenTranscript)
                Button("Copy Transcript", action: onCopyTranscript)  // only here: it isn't worth a button on every row
            case .notStarted?, .failed?: Button("Transcribe", action: onTranscribe)
            default: EmptyView()
            }
            Button("Rename…", action: beginRenaming)
            Button("Reveal in Finder", action: onReveal)
            Divider()
            Button("Move to Trash", role: .destructive, action: onDelete)
        }
    }

    /// Blue is for the recording being listened to, so its scrubber reads as part of it; the row the
    /// keyboard is on and the row under the pointer are neutral grey.
    private var background: Color {
        if playback == .playing || playback == .paused { return Color.accentColor.opacity(0.08) }
        if isSelected { return Color.primary.opacity(0.1) }
        return isHovered ? Color.primary.opacity(0.05) : .clear
    }

    /// The name, or the time when there is none; double-click (or Rename… in the menu) edits it in place.
    @ViewBuilder
    private var title: some View {
        if isRenaming {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .focused($nameFieldFocused)
                .onSubmit { finishRenaming(save: true) }
                .onExitCommand { finishRenaming(save: false) }
                // Clicking elsewhere takes the focus away, which saves.
                .onChange(of: nameFieldFocused) { if !nameFieldFocused { finishRenaming(save: true) } }
        } else {
            Text(recording.name ?? time)
                .lineLimit(1)
                .truncationMode(.tail)
                .onTapGesture(count: 2, perform: beginRenaming)
        }
    }

    private var time: String { recording.startDate.formatted(date: .omitted, time: .shortened) }

    private func beginRenaming() {
        draftName = recording.name ?? ""
        isRenaming = true
        // Focused a turn later, once the field exists; AppKit then selects its text.
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func finishRenaming(save: Bool) {
        guard isRenaming else { return }
        isRenaming = false
        if save, draftName.trimmingCharacters(in: .whitespacesAndNewlines) != (recording.name ?? "") { onRename(draftName) }
    }

    private var playButton: some View {
        let unavailable: String? = { if case .unavailable(let why) = playback { return why } else { return nil } }()
        return Button(action: onTogglePlay) {
            Label(playback == .playing ? "Pause" : "Play", systemImage: playback == .playing ? "pause.fill" : "play.fill")
                .labelStyle(.iconOnly)
                .font(.system(size: 11))
                // Grey when idle, solid blue with Pause while playing, outlined blue with Play while paused.
                .foregroundStyle(playback == .playing ? Color.white : playback == .paused ? Color.accentColor : unavailable != nil ? Color.primary.opacity(0.3) : Color.primary)
                .frame(width: 26, height: 26)
                .background(playback == .playing ? Color.accentColor
                            : playback == .paused ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.08), in: Circle())
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: playback == .paused ? 1 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .disabled(unavailable != nil)
        .help(unavailable ?? (playback == .playing ? "Pause" : "Play"))
        .padding(.top, 3)
    }

    @ViewBuilder
    private var transcriptControl: some View {
        // Every state shows at rest, so the list can be scanned for what has a transcript. A transcript
        // that exists is quiet text; one still to be made is a bordered button, so the two differ by
        // shape and not only by wording.
        switch transcript {
        case .notStarted?:
            Button(action: onTranscribe) { Label("Transcribe", systemImage: "waveform") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Make a transcript of this recording")
                .accessibilityLabel("Transcribe recording")
        case .queued?:
            Label("Waiting…", systemImage: "clock")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .help("Waiting for another transcript to finish")
                .accessibilityLabel("Waiting to transcribe")
        case .inProgress?:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Transcription in progress")
        case .ready?:
            Button(action: onOpenTranscript) { quiet(Label("Transcript", systemImage: "doc.text")) }
                .buttonStyle(.plain)
                .help("Open Transcript")
                .accessibilityLabel("Open Transcript")
        case .failed(let reason)?:
            // A failure stays visible: it is a status, not just an action.
            Button(action: onTranscribe) { Label("Try Again", systemImage: "exclamationmark.triangle") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(reason)
                .accessibilityLabel("Transcription failed. Try again.")
        case nil:
            EmptyView()
        }
    }

    private func quiet(_ label: some View) -> some View {
        // In a plain button: a borderless one dims this further, until it is hard to read.
        label.font(.subheadline).foregroundStyle(isActive ? .primary : .secondary).contentShape(Rectangle())
    }

    private var duration: String {
        let seconds = Int(recording.duration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private extension View {
    /// Keeps the view's space but hides it, also from clicks and VoiceOver (the context menu has the same actions).
    func showOnly(when visible: Bool) -> some View {
        opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
    }
}

/// Elapsed time, scrubber and total time for the recording being played.
private struct PlaybackBar: View {
    let player: PlaybackController
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.format(clock.time))
            Slider(value: Binding(get: { clock.time }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 0.1))
                .controlSize(.small)
                .accessibilityLabel("Playback position")
            Text(Self.format(player.duration))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: 320)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
