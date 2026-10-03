import SwiftUI

struct RecordingRowView: View {
    let recording: Recording
    var isCombining = false
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                Text("\(duration) · \(recording.includesMicrophone ? "system + mic" : "system only")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCombining {
                ProgressView().controlSize(.small)
                    .help("Mixing system + mic into combined.caf")
            }
            Button(action: onReveal) { Image(systemName: "folder") }
                .help("Reveal in Finder")
            Button(action: confirmDelete) { Image(systemName: "trash") }
                .help("Move to Trash")
        }
        .buttonStyle(.borderless)
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
