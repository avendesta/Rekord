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
    /// Asks for confirmation itself, and covers the whole selection when this row is part of one.
    let onDelete: () -> Void

    // No case named `none`: on an optional that would silently mean nil.
    enum TranscriptState: Equatable {
        case notStarted, inProgress, ready, failed(String)
    }

    @State private var isHovered = false

    /// Actions appear only for the row being pointed at or selected.
    private var isActive: Bool { isHovered || isSelected }

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
                    .tooltip(activity)
                    .accessibilityLabel(activity)
            }
            // A fixed column, so the states sit in the same place on every row.
            transcriptControl
                .controlSize(.small)
                .frame(width: 112, alignment: .trailing)
            // File management stays out of the way until the row is pointed at or selected.
            HStack(spacing: 6) {
                Button(action: onReveal) { Label("Reveal in Finder", systemImage: "folder") }
                    .tooltip("Reveal in Finder")
                Button(action: onDelete) { Label("Move to Trash", systemImage: "trash") }
                    .tooltip("Move to Trash…")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .showOnly(when: isActive)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(isHovered && !isSelected ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            switch transcript {
            case .ready?: Button("Open Transcript", action: onOpenTranscript)
            case .notStarted?, .failed?: Button("Transcribe", action: onTranscribe)
            default: EmptyView()
            }
            Button("Reveal in Finder", action: onReveal)
            Divider()
            Button("Move to Trash…", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var transcriptControl: some View {
        switch transcript {
        case .notStarted?:
            Button(action: onTranscribe) { Label("Transcribe", systemImage: "text.badge.plus") }
                .tooltip("Make a transcript of this recording")
                .showOnly(when: isActive)
        case .inProgress?:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .ready?:
            Button(action: onOpenTranscript) { Label("Open Transcript", systemImage: "doc.text") }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .tooltip("Open Transcript")
                .showOnly(when: isActive)
        case .failed(let reason)?:
            // A failure stays visible: it is a status, not just an action.
            Button(action: onTranscribe) { Label("Try Again", systemImage: "exclamationmark.triangle") }
                .tooltip(reason)
        case nil:
            EmptyView()
        }
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

    /// `.help()` doesn't show its tooltip on controls inside a List row here, so the tip is set on an AppKit view.
    func tooltip(_ text: String) -> some View {
        overlay(Tooltip(text: text))
    }
}

private struct Tooltip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView { ClickThroughView() }
    func updateNSView(_ view: NSView, context: Context) { view.toolTip = text }

    /// Shows a tooltip but lets clicks reach the button underneath.
    private final class ClickThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
