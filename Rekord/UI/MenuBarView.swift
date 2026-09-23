import SwiftUI

/// The menu bar popup: recording status and the main action first, navigation second.
struct MenuBarView: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var store: RecordingStore
    var hotkeyError: String?
    @Environment(\.openWindow) private var openWindow
    @State private var micName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rekord")
                .font(.headline)
                .padding(.bottom, 10)

            // Fixed minimum height so the popup doesn't jump between Ready / Recording / Warning.
            StatusView(session: session)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                .padding(.bottom, 10)

            primaryButton
                .padding(.bottom, 14)

            microphoneRow

            if let hotkeyError {
                Label(hotkeyError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
                    .padding(.top, 10)
            }

            Divider().padding(.vertical, 10)

            MenuRow(title: "Recent Recordings", systemImage: "clock.arrow.circlepath",
                    trailing: "\(store.recordings.count)", showsChevron: true) {
                openWindow(id: "recordings")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuRow(title: "Settings…", systemImage: "gearshape") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider().padding(.vertical, 10)

            MenuRow(title: "Quit Rekord", isSecondary: true) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { refresh() }
        // The popup view outlives each opening, so refresh when its window comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
        .onChange(of: session.state) { _ in store.reload() }
    }

    private func refresh() {
        store.reload()
        micName = AudioInputDevices.currentInputName()
    }

    private var primaryButton: some View {
        Button {
            session.isRecording ? session.stop() : session.start()
        } label: {
            Label(session.isRecording ? "Stop Recording" : "Start Recording",
                  systemImage: session.isRecording ? "stop.circle.fill" : "record.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(session.isRecording ? .red : .accentColor)
        .disabled(session.state == .starting)
    }

    private var microphoneRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.includeMicrophone ? "mic.fill" : "mic.slash")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone")
                if PermissionsManager.microphoneDenied && session.includeMicrophone {
                    Text("Access denied")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open System Settings…") { PermissionsManager.openSettings(for: .microphone) }
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    Text(micName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(session.includeMicrophone ? 1 : 0.6)
                }
            }
            Spacer(minLength: 8)
            Toggle("Microphone", isOn: $session.includeMicrophone)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(session.isRecording || session.state == .starting)
        }
    }
}

/// What Rekord is doing right now, including failures. The symbol and wording carry
/// the meaning, so state never depends on colour alone.
private struct StatusView: View {
    @ObservedObject var session: RecordingSession

    var body: some View {
        switch session.state {
        case .starting:
            status("circle.dotted", "Starting recording…", tint: .secondary)
        case .recording(let since):
            if session.systemSilenceWarning {
                // Cause unknown: nothing may be playing, or the permission may be off.
                warning("Not receiving system audio", actionTitle: "Check permissions…", issue: .systemAudio)
            } else {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(since))
                    status("circle.fill", String(format: "Recording · %02d:%02d", seconds / 60, seconds % 60), tint: .red)
                }
            }
        case .idle:
            if let issue = session.permissionIssue {
                warning(issue == .microphone ? "Microphone permission required" : "System Audio Recording permission required",
                        actionTitle: "Open System Settings…", issue: issue)
            } else if let error = session.lastError {
                warning("Recording problem", detail: error)
            } else {
                status("circle", "Ready to record", tint: .secondary)
            }
        }
    }

    private func status(_ symbol: String, _ title: String, tint: Color) -> some View {
        Label {
            Text(title).font(.subheadline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    private func warning(_ title: String, detail: String? = nil, actionTitle: String? = nil,
                         issue: PermissionsManager.Issue? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(title).font(.subheadline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 22)
            }
            if let actionTitle, let issue {
                Button(actionTitle) { PermissionsManager.openSettings(for: issue) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.leading, 22)
            }
        }
    }
}

/// Lightweight navigation row: no chrome until hovered, like a native menu item.
private struct MenuRow: View {
    let title: String
    var systemImage: String?
    var trailing: String?
    var showsChevron = false
    var isSecondary = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .foregroundStyle(isSecondary ? .secondary : .primary)
                Spacer()
                if let trailing {
                    Text(trailing).foregroundStyle(.secondary)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6) // let the hover highlight extend past the content edge
        .onHover { hovering = $0 }
    }
}

/// Shown in the hotkey popup while recording when no system audio has arrived.
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
