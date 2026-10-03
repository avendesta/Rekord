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

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                note("Keeps Rekord available from the menu bar.")
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
                LabeledContent("Save recordings to") {
                    HStack {
                        Label(Self.shortPath(AppSettings.outputFolder), systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(AppSettings.outputFolder.path)
                        if !outputFolderPath.isEmpty {
                            Button("Reset") {
                                AppSettings.setOutputFolder(nil)
                                outputFolderPath = ""
                            }
                        }
                        Button("Choose…", action: chooseFolder)
                    }
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
                Picker("Input device", selection: $inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // A saved device that's currently unplugged: keep it selectable so the choice isn't lost.
                    if !inputDeviceUID.isEmpty, !inputDevices.contains(where: { $0.uid == inputDeviceUID }) {
                        Text("Disconnected device (using default)").tag(inputDeviceUID)
                    }
                }
                note("Used only by Rekord.")
                Toggle("Include microphone by default", isOn: $includeMicrophoneDefault)
                note("Default for new recordings.")
            }

            Section("Recordings") {
                Picker("Format", selection: $compressRecordings) {
                    Text("M4A (smaller)").tag(true)
                    Text("CAF (lossless)").tag(false)
                }
                note("Recordings are saved as CAF and, with M4A, converted when they finish.")
                LabeledContent(compressSummary) {
                    Button("Compress to M4A…", action: confirmCompressAll)
                        .disabled(store.compressible.isEmpty || !store.pendingCompression.isEmpty)
                }
                Picker("Delete audio after", selection: $audioRetentionDays) {
                    ForEach([7, 14, 30, 90], id: \.self) { Text("\($0) days").tag($0) }
                    Text("Never").tag(0)
                }
                note("Moves old audio to the Trash. The transcript and name are kept, and recordings without a transcript keep their audio.")
            }
        }
        .onAppear { store.reload() }
    }

    private var compressSummary: String {
        if !store.pendingCompression.isEmpty { return "Compressing \(store.pendingCompression.count)…" }
        let count = store.compressible.count
        return count == 0 ? "No CAF recordings to compress" : "\(count) CAF recording\(count == 1 ? "" : "s")"
    }

    private func confirmCompressAll() {
        let count = store.compressible.count
        let alert = NSAlert()
        alert.messageText = "Compress \(count) Recording\(count == 1 ? "" : "s") to M4A?"
        alert.informativeText = "The audio files are converted to M4A, which is much smaller, and the lossless CAF originals are deleted. This can't be undone."
        alert.addButton(withTitle: "Compress")
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
                    Toggle("Include microphone in transcripts", isOn: $transcriptIncludesMicrophone)
                    note("Turn off if your microphone picks up the meeting audio.")
                }
                Section {
                    note("Transcription is performed entirely on this Mac. Audio is never uploaded.\nTranscripts are saved alongside the recording.")
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

                // macOS has no way to ask whether System Audio Recording is allowed, so this reports
                // what the last recording actually received.
                LabeledContent("System Audio") {
                    switch systemAudioSeen {
                    case "yes": status("Allowed", "checkmark.circle.fill", .green)
                    case "no": status("No Audio in Last Recording", "exclamationmark.circle", .orange)
                    default: status("Not Checked Yet", "questionmark.circle", .secondary)
                    }
                }
                .help("macOS doesn't report this permission, so Rekord goes by whether the last recording received system audio.")
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
