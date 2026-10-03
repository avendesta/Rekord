import SwiftUI

struct RecordingRowView: View {
    let recording: Recording
    /// In a date section the day is in the header, so the row shows only the time.
    var showsDate = true
    var isSelected = false
    /// What Rekord is doing to this recording in the background, if anything.
    var activity: String?
    /// Nil where transcription isn't available, which hides the transcript control.
    var transcript: TranscriptState?
    var onTranscribe: () -> Void = {}
    var onOpenTranscript: () -> Void = {}
    let onReveal: () -> Void
    let onDelete: () -> Void

    // No case named `none`: on an optional that would silently mean nil.
    enum TranscriptState: Equatable {
        case notStarted, inProgress, ready, failed(String)
    }

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showsDate
                     ? recording.startDate.formatted(date: .abbreviated, time: .shortened)
                     : recording.startDate.formatted(date: .omitted, time: .shortened))
                Text("\(duration) · \(recording.includesMicrophone ? "System + Microphone" : "System Audio")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let activity {
                ProgressView().controlSize(.small)
                    .help(activity)
            }
            transcriptControl
            // File management stays out of the way until the row is pointed at or selected.
            HStack(spacing: 6) {
                Button(action: onReveal) { Image(systemName: "folder") }
                    .help("Reveal in Finder")
                Button(action: confirmDelete) { Image(systemName: "trash") }
                    .help("Move to Trash…")
            }
            .opacity(isHovered || isSelected ? 1 : 0)
            .allowsHitTesting(isHovered || isSelected)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : isHovered ? Color.primary.opacity(0.06) : .clear)
                .padding(.horizontal, 6)
        )
        .contextMenu {
            switch transcript {
            case .ready?: Button("Open Transcript", action: onOpenTranscript)
            case .notStarted?, .failed?: Button("Transcribe", action: onTranscribe)
            default: EmptyView()
            }
            Button("Reveal in Finder", action: onReveal)
            Divider()
            Button("Move to Trash…", role: .destructive, action: confirmDelete)
        }
    }

    @ViewBuilder
    private var transcriptControl: some View {
        switch transcript {
        case .notStarted?:
            Button("Transcribe", action: onTranscribe)
                .help("Make a transcript of this recording")
        case .inProgress?:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.subheadline).foregroundStyle(.secondary)
            }
        case .ready?:
            Button(action: onOpenTranscript) { Label("Transcript", systemImage: "doc.text") }
                .help("Open the transcript")
        case .failed(let reason)?:
            Button(action: onTranscribe) { Label("Try Again", systemImage: "exclamationmark.triangle") }
                .help(reason)
        case nil:
            EmptyView()
        }
    }

    private var duration: String {
        let seconds = Int(recording.duration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // NSAlert rather than .confirmationDialog: the latter can dismiss the menu bar popover.
    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Move this recording to the Trash?"
        alert.informativeText = recording.startDate.formatted(date: .abbreviated, time: .shortened)
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { onDelete() }
    }
}
