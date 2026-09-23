import SwiftUI

struct MenuBarView: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var store: RecordingStore
    var hotkeyError: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rekord")
                .font(.headline)

            statusLine

            if let error = session.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                if let issue = session.permissionIssue {
                    Button("Open Privacy Settings…") { PermissionsManager.openSettings(for: issue) }
                }
            } else if PermissionsManager.microphoneDenied && session.includeMicrophone {
                Text("Microphone access is denied.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Open Privacy Settings…") { PermissionsManager.openSettings(for: .microphone) }
            }

            if let hotkeyError {
                Text(hotkeyError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if session.systemSilenceWarning {
                SilenceWarningView()
            }

            Toggle("Include microphone", isOn: $session.includeMicrophone)
                .disabled(isRecording)

            Button(isRecording ? "Stop" : "Start") {
                if isRecording {
                    session.stop()
                } else {
                    session.start()
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            Button("Recent Recordings… (\(store.recordings.count))") {
                openWindow(id: "recordings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .frame(maxWidth: .infinity)

            Button("Settings…") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .frame(maxWidth: .infinity)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
        .onAppear { store.reload() }
        .onChange(of: session.state) { _ in store.reload() }
    }

    private var isRecording: Bool {
        if case .recording = session.state { return true }
        return false
    }

    @ViewBuilder
    private var statusLine: some View {
        switch session.state {
        case .idle:
            Text("Idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .recording(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text("Recording… \(elapsed(from: since, to: context.date))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(start))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// Shown while recording when no system audio has arrived: most often a missing permission.
struct SilenceWarningView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No system audio detected yet. If something is playing, allow Rekord under System Audio Recording.")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Open Privacy Settings…") { PermissionsManager.openSettings(for: .systemAudio) }
        }
    }
}

#Preview {
    MenuBarView(session: RecordingSession(), store: RecordingStore(), hotkeyError: nil)
}
