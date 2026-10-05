import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import Speech
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.outputFolderKey) private var outputFolderPath = ""
    @AppStorage(AppSettings.includeMicrophoneKey) private var includeMicrophoneDefault = true

    @ObservedObject var hotkey: HotkeyPopupController
    @ObservedObject var store: RecordingStore
    @ObservedObject var session: RecordingSession
    @AppStorage(AppSettings.compressKey) private var compressRecordings = true
    @AppStorage(AppSettings.audioRetentionDaysKey) private var audioRetentionDays = 7
    @AppStorage(AppSettings.inputDeviceUIDKey) private var inputDeviceUID = ""
    @AppStorage(AppSettings.transcribeKey) private var transcribeRecordings = true
    @AppStorage(AppSettings.transcriptionLanguageKey) private var transcriptionLanguage = ""
    @AppStorage(AppSettings.transcriptTimestampsKey) private var transcriptTimestamps = true
    @AppStorage(AppSettings.transcriptIncludesMicrophoneKey) private var transcriptIncludesMicrophone = true
    @State private var transcriptionLocales: [Locale] = []
    @State private var inputDevices: [AudioInputDevices.Device] = []
    @State private var capturingShortcut = false
    @State private var shortcutMonitor: Any?
    @State private var launchAtLogin = false
    @State private var needsApproval = false
    @State private var loginError: String?

    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @AppStorage(AppSettings.systemAudioSeenKey) private var systemAudioSeen = ""

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            audio.tabItem { Label("Audio", systemImage: "mic") }
            transcription.tabItem { Label("Transcription", systemImage: "text.bubble") }
            privacy.tabItem { Label("Privacy", systemImage: "lock") }
        }
        .formStyle(.grouped)
        // One size for every tab, so the window doesn't jump when switching.
        .frame(width: 600, height: 380)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onDisappear { stopCapturing() }
    }

    private func refresh() {
        refreshLoginStatus()
        inputDevices = AudioInputDevices.all()
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                // A second Text in a label is its explanation: it sits under the name in the same
                // row, where a row of its own would look like one more setting.
                Toggle(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)) {
                    Text("Launch at login")
                    Text("Keeps Rekord available from the menu bar.")
                }
                if needsApproval {
                    Text("Approve Rekord in System Settings > General > Login Items.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Recording shortcut") {
                    HStack {
                        Text(capturingShortcut ? "Press new shortcut… (Esc to cancel)" : hotkey.hotkey.display)
                            .font(capturingShortcut ? .body : .system(.body, design: .monospaced))
                            .foregroundStyle(capturingShortcut ? .secondary : .primary)
                        if hotkey.hotkey != .default, !capturingShortcut {
                            Button("Reset") { hotkey.setHotkey(.default) }
                        }
                        Button(capturingShortcut ? "Cancel" : "Change…") {
                            capturingShortcut ? stopCapturing() : startCapturing()
                        }
                    }
                }
                if let error = hotkey.registrationError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent {
                    HStack {
                        Label(Self.shortPath(AppSettings.outputFolder), systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(AppSettings.outputFolder.path)
                        // Not while recording: the recording would finish in a folder that is no
                        // longer listed, and the sandboxed build would lose its access to it mid-write.
                        Group {
                            if !outputFolderPath.isEmpty {
                                Button("Reset") {
                                    AppSettings.setOutputFolder(nil)
                                    outputFolderPath = ""
                                }
                            }
                            Button("Choose…", action: chooseFolder)
                        }
                        .disabled(session.isRecording || session.state == .starting)
                    }
                } label: {
                    Text("Save recordings to")
                    if session.isRecording { Text("Stop the current recording to change this folder.") }
                }
            }
        }
    }

    /// A folder inside the home folder is shown from there down, e.g. "Documents/Rekord".
    static func shortPath(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = url.standardizedFileURL.path, homePath = home.standardizedFileURL.path
        return path.hasPrefix(homePath + "/") ? String(path.dropFirst(homePath.count + 1)) : path
    }

    // MARK: Audio

    private var audio: some View {
        Form {
            Section("Microphone") {
                Picker(selection: $inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // A saved device that's currently unplugged: keep it selectable so the choice isn't lost.
                    if !inputDeviceUID.isEmpty, !inputDevices.contains(where: { $0.uid == inputDeviceUID }) {
                        Text("Disconnected device (using default)").tag(inputDeviceUID)
                    }
                } label: {
                    Text("Input device")
                    Text("This doesn't change your Mac's system input device.")
                }
                Toggle("Include microphone by default", isOn: $includeMicrophoneDefault)
            }

            Section("Recordings") {
                Picker(selection: $compressRecordings) {
                    Text("M4A (smaller)").tag(true)
                    Text("CAF (lossless)").tag(false)
                } label: {
                    Text("Format")
                    Text("Recordings are captured as CAF. When M4A is selected, Rekord converts them after recording ends.")
                }
                LabeledContent(compressSummary) {
                    Button("Convert to M4A…", action: confirmCompressAll)
                        .disabled(store.compressible.isEmpty || !store.pendingCompression.isEmpty)
                }
                Picker(selection: $audioRetentionDays) {
                    ForEach([7, 14, 30, 90], id: \.self) { Text("\($0) days").tag($0) }
                    Text("Never").tag(0)
                } label: {
                    Text("Delete audio after")
                    Text("Moves old audio to the Trash. The transcript and name are kept, and recordings without a transcript keep their audio.")
                }
            }
        }
        .onAppear { store.reload() }
    }

    private var compressSummary: String {
        if !store.pendingCompression.isEmpty { return "Converting \(store.pendingCompression.count)…" }
        let count = store.compressible.count
        return count == 0 ? "No CAF recordings to convert" : "\(count) CAF recording\(count == 1 ? "" : "s")"
    }

    private func confirmCompressAll() {
        let count = store.compressible.count
        let alert = NSAlert()
        alert.messageText = "Convert \(count) Recording\(count == 1 ? "" : "s") to M4A?"
        alert.informativeText = "The audio files are converted to M4A, which is much smaller, and the lossless CAF originals are deleted. This can't be undone."
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.compressAll() }
    }

    // MARK: Transcription

    @ViewBuilder
    private var transcription: some View {
        if Transcriber.isSupported {
            Form {
                Section {
                    Toggle("Transcribe new recordings automatically", isOn: $transcribeRecordings)
                    Picker("Language", selection: $transcriptionLanguage) {
                        Text("Same as this Mac").tag("")
                        ForEach(transcriptionLocales, id: \.identifier) { locale in
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .tag(locale.identifier)
                        }
                    }
                    Toggle("Show timestamps in transcripts", isOn: $transcriptTimestamps)
                    Toggle(isOn: $transcriptIncludesMicrophone) {
                        Text("Include microphone in transcripts")
                        Text("Turn off if your microphone picks up the meeting audio and lines appear twice.")
                    }
                }
                Section {
                    Text("Transcription is performed entirely on this Mac. Audio is never uploaded.\nTranscripts are saved alongside the recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .task {
                if #available(macOS 26, *) {
                    transcriptionLocales = await SpeechTranscriber.supportedLocales.sorted {
                        (Locale.current.localizedString(forIdentifier: $0.identifier) ?? "")
                            < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? "")
                    }
                }
            }
        } else {
            ContentUnavailableView("Transcription Needs macOS 26", systemImage: "text.bubble",
                                   description: Text("Update macOS to have Rekord transcribe your recordings."))
        }
    }

    // MARK: Privacy

    private var privacy: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Microphone") {
                    switch microphoneStatus {
                    case .authorized: status("Allowed", "checkmark.circle.fill", .green)
                    case .notDetermined: status("Not Asked Yet", "questionmark.circle", .secondary)
                    default: status("Not Allowed", "xmark.circle", .secondary)
                    }
                }
                Button("Open Microphone Settings…") { PermissionsManager.openSettings(for: .microphone) }
            }

            // Apart from the real permission above: macOS has no way to ask whether System Audio
            // Recording is allowed, so this is what the last recording actually received, and says so.
            Section {
                LabeledContent {
                    switch systemAudioSeen {
                    case "yes": status("Audio Detected", "checkmark.circle.fill", .green)
                    case "no": status("No Audio Detected", "exclamationmark.circle", .orange)
                    default: status("Not Checked Yet", "questionmark.circle", .secondary)
                    }
                } label: {
                    Text("System Audio")
                    Text("macOS doesn't report this permission, so Rekord goes by whether your last recording received system audio.")
                }
                Button("Open System Audio Settings…") { PermissionsManager.openSettings(for: .systemAudio) }
            }
        }
    }

    private func status(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
    }

    private func startCapturing() {
        capturingShortcut = true
        hotkey.suspend()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopCapturing()
                return nil
            }
            var modifiers = 0
            let flags = event.modifierFlags
            if flags.contains(.command) { modifiers |= cmdKey }
            if flags.contains(.option) { modifiers |= optionKey }
            if flags.contains(.control) { modifiers |= controlKey }
            if flags.contains(.shift) { modifiers |= shiftKey }
            // Global shortcuts need Cmd, Option or Control; Shift alone would hijack typing.
            guard modifiers & (cmdKey | optionKey | controlKey) != 0 else {
                NSSound.beep()
                return nil
            }
            let label = event.keyCode == UInt16(kVK_Space) ? "Space"
                : (event.charactersIgnoringModifiers?.uppercased().filter { !$0.isWhitespace }).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Key \(event.keyCode)"
            let captured = Hotkey(keyCode: Int(event.keyCode), modifiers: modifiers, keyLabel: label)
            stopCapturing(resume: false)
            hotkey.setHotkey(captured)
            return nil
        }
    }

    private func stopCapturing(resume: Bool = true) {
        guard capturingShortcut else { return }
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        capturingShortcut = false
        if resume { hotkey.resume() }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = AppSettings.outputFolder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.setOutputFolder(url)
            outputFolderPath = url.path
        }
    }
}
