import SwiftUI

struct RecordingsWindowView: View {
    @ObservedObject var store: RecordingStore

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.combineError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
            if store.recordings.isEmpty {
                Text("No recordings yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.recordings) { recording in
                    RecordingRowView(
                        recording: recording,
                        isCombining: store.combining.contains(recording.id),
                        onCombine: { store.combine(recording) },
                        onReveal: { store.reveal(recording) },
                        onDelete: { store.moveToTrash(recording) }
                    )
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 320)
        .onAppear { store.reload() }
    }
}
