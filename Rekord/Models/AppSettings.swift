import Carbon.HIToolbox
import Foundation

/// A global shortcut: Carbon key code + Carbon modifier mask, plus the key's label for display.
struct Hotkey: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var keyLabel: String

    static let `default` = Hotkey(keyCode: kVK_ANSI_9, modifiers: cmdKey | shiftKey, keyLabel: "9")

    var display: String {
        var result = ""
        if modifiers & controlKey != 0 { result += "⌃" }
        if modifiers & optionKey != 0 { result += "⌥" }
        if modifiers & shiftKey != 0 { result += "⇧" }
        if modifiers & cmdKey != 0 { result += "⌘" }
        return result + keyLabel
    }
}

/// User preferences, backed by UserDefaults. Views bind to the same keys with @AppStorage.
enum AppSettings {
    static let outputFolderKey = "outputFolderPath"
    static let includeMicrophoneKey = "includeMicrophoneDefault"
    static let hotkeyKey = "hotkey"
    static let inputDeviceUIDKey = "inputDeviceUID"
    static let lastRecordingModeKey = "lastRecordingMode"

    static let defaultOutputFolder = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Rekord", isDirectory: true)

    static var outputFolder: URL {
        guard let path = UserDefaults.standard.string(forKey: outputFolderKey), !path.isEmpty else {
            return defaultOutputFolder
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var includeMicrophoneDefault: Bool {
        UserDefaults.standard.object(forKey: includeMicrophoneKey) as? Bool ?? true
    }

    /// The mode last started from the shortcut popup; before any, follows the microphone default.
    static var lastRecordingMode: RecordingMode {
        get {
            UserDefaults.standard.string(forKey: lastRecordingModeKey).flatMap(RecordingMode.init(rawValue:))
                ?? (includeMicrophoneDefault ? .systemAndMicrophone : .systemOnly)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lastRecordingModeKey) }
    }

    /// UID of the chosen microphone; nil means follow the system default input.
    static var inputDeviceUID: String? {
        UserDefaults.standard.string(forKey: inputDeviceUIDKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var hotkey: Hotkey {
        get {
            UserDefaults.standard.data(forKey: hotkeyKey)
                .flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .default
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: hotkeyKey) }
    }
}
