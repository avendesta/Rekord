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
    static let outputFolderBookmarkKey = "outputFolderBookmark"
    static let includeMicrophoneKey = "includeMicrophoneDefault"
    static let hotkeyKey = "hotkey"
    static let inputDeviceUIDKey = "inputDeviceUID"
    static let lastRecordingModeKey = "lastRecordingMode"

    static let defaultOutputFolder = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Rekord", isDirectory: true)

    /// Where recordings go. A folder chosen in Settings is remembered as a security-scoped bookmark,
    /// which is what lets the sandboxed Mac App Store build keep writing outside its container; the
    /// direct-download build also accepts a plain stored path from older versions.
    static var outputFolder: URL {
        if let data = UserDefaults.standard.data(forKey: outputFolderBookmarkKey), let url = resolve(bookmark: data) {
            return url
        }
        guard let path = UserDefaults.standard.string(forKey: outputFolderKey), !path.isEmpty else {
            return defaultOutputFolder
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Remembers a folder the user picked in an open panel (or forgets it with nil).
    static func setOutputFolder(_ url: URL?) {
        stopAccessingOutputFolder()
        guard let url else {
            UserDefaults.standard.removeObject(forKey: outputFolderBookmarkKey)
            UserDefaults.standard.removeObject(forKey: outputFolderKey)
            return
        }
        UserDefaults.standard.set(url.path, forKey: outputFolderKey)
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: outputFolderBookmarkKey)
        }
    }

    // The folder's security scope stays open for as long as the app runs.
    private static var accessedFolder: URL?

    private static func stopAccessingOutputFolder() {
        accessedFolder?.stopAccessingSecurityScopedResource()
        accessedFolder = nil
    }

    private static func resolve(bookmark data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        if accessedFolder?.path != url.path {
            stopAccessingOutputFolder()
            if url.startAccessingSecurityScopedResource() { accessedFolder = url }
        }
        if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: outputFolderBookmarkKey)
        }
        return url
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
