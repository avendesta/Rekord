import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.outputFolderKey) private var outputFolderPath = ""
    @AppStorage(AppSettings.includeMicrophoneKey) private var includeMicrophoneDefault = true

    @ObservedObject var hotkey: HotkeyPopupController
    @AppStorage(AppSettings.inputDeviceUIDKey) private var inputDeviceUID = ""
    @State private var inputDevices: [AudioInputDevices.Device] = []
    @State private var capturingShortcut = false
    @State private var shortcutMonitor: Any?
    @State private var launchAtLogin = false
    @State private var needsApproval = false
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Text("Keeps Rekord running in the menu bar so the shortcut works from any app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if needsApproval {
                    Text("Approve Rekord in System Settings > General > Login Items.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Microphone") {
                Picker("Input device", selection: $inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // A saved device that's currently unplugged: keep it selectable so the choice isn't lost.
                    if !inputDeviceUID.isEmpty, !inputDevices.contains(where: { $0.uid == inputDeviceUID }) {
                        Text("Disconnected device (using default)").tag(inputDeviceUID)
                    }
                }
                Text("Only affects Rekord; your Mac's system input stays as it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                LabeledContent("Start / stop recording") {
                    Text(hotkey.hotkey.display)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Button(capturingShortcut ? "Press new shortcut… (Esc to cancel)" : "Change Shortcut") {
                        capturingShortcut ? stopCapturing() : startCapturing()
                    }
                    Button("Reset to Default") { hotkey.setHotkey(.default) }
                        .disabled(hotkey.hotkey == .default || capturingShortcut)
                }
                if let error = hotkey.registrationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Recordings") {
                LabeledContent("Save to") {
                    Text(AppSettings.outputFolder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose Folder…", action: chooseFolder)
                    Button("Reset to Default") {
                        AppSettings.setOutputFolder(nil)
                        outputFolderPath = ""
                    }
                        .disabled(outputFolderPath.isEmpty)
                }
                Toggle("Include microphone by default", isOn: $includeMicrophoneDefault)
                Text("Applies from the next launch to the menu's Include microphone toggle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Button("Microphone Settings…") { PermissionsManager.openSettings(for: .microphone) }
                    Button("System Audio Settings…") { PermissionsManager.openSettings(for: .systemAudio) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshLoginStatus()
            inputDevices = AudioInputDevices.all()
        }
        .onDisappear { stopCapturing() }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
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
