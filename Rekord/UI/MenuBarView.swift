import SwiftUI

/// The menu bar popup: recording status and the main action first, navigation second.
struct MenuBarView: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var store: RecordingStore
    var hotkeyError: String?
    @Environment(\.openWindow) private var openWindow
    @State private var micName = ""
    @AppStorage(AppSettings.audioSourceBundleIDKey) private var sourceBundleID = ""
    @State private var sourceApps: [AudioSourceApps.App] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rekord")
                .font(.headline)
                .padding(.bottom, 10)

            // Only as tall as what it says: every state without a problem is one line, so the popup
            // grows only to show one.
            StatusView(session: session)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 16)

            primaryButton
                .padding(.bottom, 14)

            sourceRow
                .padding(.bottom, 10)

            microphoneRow

            if let hotkeyError {
                Label(hotkeyError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
                    .padding(.top, 10)
            }

            Divider().padding(.vertical, 6)

            MenuRow(title: "Recent Recordings", systemImage: "clock.arrow.circlepath",
                    trailing: "\(store.recordings.count)", showsChevron: true) {
                openWindow(id: "recordings")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuRow(title: "Settings…", systemImage: "gearshape") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider().padding(.vertical, 6)

            MenuRow(title: "Quit Rekord") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { refresh() }
        // The popup view outlives each opening, so refresh when its window comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    /// What is recorded can't change once a recording has begun.
    private var isLocked: Bool { session.isRecording || session.state == .starting }

    private func refresh() {
        store.reload()
        micName = AudioInputDevices.currentInputName()
        sourceApps = AudioSourceApps.all()
    }

    @ViewBuilder
    private var primaryButton: some View {
        if session.isRecording {
            // Pause is the lesser action; Stop stays the obvious way to finish.
            HStack(spacing: 8) {
                Button {
                    session.isPaused ? session.resume() : session.pause()
                } label: {
                    Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 78)  // one width for both words, so the buttons don't shift
                }
                .buttonStyle(.bordered)
                Button {
                    session.stop()
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.large)
        } else {
            Button {
                session.start()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(session.state == .starting)
        }
    }

    /// What the system track holds: everything the Mac plays, or one app.
    private var sourceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text("Source")
            Spacer(minLength: 8)
            Picker("Source", selection: $sourceBundleID) {
                Text("All System Audio").tag("")
                ForEach(sourceApps) { app in
                    Text(app.name).tag(app.bundleID)
                }
                // A chosen app that's closed right now: keep it selectable so the choice isn't lost.
                if !sourceBundleID.isEmpty, !sourceApps.contains(where: { $0.bundleID == sourceBundleID }) {
                    Text("\(AudioSourceApps.name(forBundleID: sourceBundleID)) (not running)").tag(sourceBundleID)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 150, alignment: .trailing)
            .disabled(isLocked)
        }
        // On the row, not the control: it says why the control is off.
        .help(isLocked ? "Source can't be changed while recording." : "")
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
                .disabled(isLocked)
        }
        .help(isLocked ? "Microphone can't be changed while recording." : "")
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
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(since))
                    status("circle.fill", String(format: "Recording · %02d:%02d", seconds / 60, seconds % 60), tint: .red)
                }
                // Under the timer, not in its place: the recording is still running.
                if session.systemSilenceWarning {
                    // Cause unknown: nothing may be playing, or the permission may be off.
                    warning(session.activeSourceApp.map { "Not receiving audio from \($0)" } ?? "Not receiving system audio",
                            actionTitle: "Check Permissions…", issue: .systemAudio)
                }
            }
        case .paused(let recorded):
            status("pause.circle.fill", String(format: "Paused · %02d:%02d", Int(recorded) / 60, Int(recorded) % 60), tint: .orange)
        case .idle:
            if let issue = session.permissionIssue {
                warning(issue == .microphone ? "Microphone permission required" : "System Audio Recording permission required",
                        actionTitle: "Open System Settings…", issue: issue)
            } else if let error = session.lastError {
                warning("Recording problem", detail: error)
            } else {
                // Quiet: nothing is happening, and the colours are kept for when something is.
                status("circle", "Ready to record", tint: .secondary).foregroundStyle(.secondary)
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
    /// The one app being recorded, if not everything.
    var source: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No \(source.map { "audio from \($0)" } ?? "system audio") detected yet. If something is playing, allow Rekord under System Audio Recording.")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Open Privacy Settings…") { PermissionsManager.openSettings(for: .systemAudio) }
        }
    }
}

#Preview {
    MenuBarView(session: RecordingSession(), store: RecordingStore(), hotkeyError: nil)
}
