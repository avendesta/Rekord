import Carbon.HIToolbox
import XCTest
@testable import Rekord

final class HotkeyTests: XCTestCase {
    func testDefaultDisplay() {
        XCTAssertEqual(Hotkey.default.display, "⇧⌘9")
    }

    func testDisplayOrdersModifiersLikeMacOS() {
        let all = Hotkey(keyCode: kVK_ANSI_R, modifiers: cmdKey | shiftKey | optionKey | controlKey, keyLabel: "R")
        XCTAssertEqual(all.display, "⌃⌥⇧⌘R")
    }

    func testCodableRoundTrip() throws {
        let hotkey = Hotkey(keyCode: kVK_ANSI_K, modifiers: optionKey | cmdKey, keyLabel: "K")
        let decoded = try JSONDecoder().decode(Hotkey.self, from: JSONEncoder().encode(hotkey))
        XCTAssertEqual(decoded, hotkey)
    }
}

final class MetadataTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testRoundTripKeepsEveryField() throws {
        let original = RecordingSession.Metadata(
            startDate: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 12.5, includeMicrophone: true,
            files: ["system.caf", "mic.caf"], systemSampleRate: 48_000, micSampleRate: 44_100, micOffsetSeconds: -0.02)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoded = try decoder().decode(RecordingSession.Metadata.self, from: encoder.encode(original))

        XCTAssertEqual(decoded.startDate, original.startDate)
        XCTAssertEqual(decoded.durationSeconds, 12.5)
        XCTAssertEqual(decoded.files, original.files)
        XCTAssertEqual(decoded.micSampleRate, 44_100)
        XCTAssertEqual(decoded.micOffsetSeconds, -0.02)
    }

    func testSystemOnlySessionDecodesWithoutMicFields() throws {
        let json = """
        {"startDate":"2026-09-24T08:00:00Z","durationSeconds":3,"includeMicrophone":false,
         "files":["system.caf"],"systemSampleRate":48000}
        """
        let metadata = try decoder().decode(RecordingSession.Metadata.self, from: Data(json.utf8))
        XCTAssertFalse(metadata.includeMicrophone)
        XCTAssertNil(metadata.micSampleRate)
        XCTAssertNil(metadata.micOffsetSeconds)
    }
}

/// These touch the app's real UserDefaults (the tests run inside the app), so they restore what they change.
@MainActor
final class StorageTests: XCTestCase {
    private let keys = [AppSettings.outputFolderKey, AppSettings.outputFolderBookmarkKey]
    private var saved: [String: Any] = [:]
    private var root: URL!

    override func setUpWithError() throws {
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testOutputFolderDefaultsToDocumentsRekord() {
        XCTAssertEqual(AppSettings.outputFolder, AppSettings.defaultOutputFolder)
        XCTAssertTrue(AppSettings.defaultOutputFolder.path.hasSuffix("Documents/Rekord"))
    }

    func testOutputFolderUsesAStoredPath() {
        UserDefaults.standard.set(root.path, forKey: AppSettings.outputFolderKey)
        XCTAssertEqual(AppSettings.outputFolder.path, root.path)
    }

    func testChosenFolderIsRememberedAndCanBeCleared() {
        AppSettings.setOutputFolder(root)
        XCTAssertEqual(AppSettings.outputFolder.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)

        AppSettings.setOutputFolder(nil)
        XCTAssertEqual(AppSettings.outputFolder, AppSettings.defaultOutputFolder)
    }

    private func writeSession(_ name: String, start: String, in parent: URL) throws {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = """
        {"startDate":"\(start)","durationSeconds":5,"includeMicrophone":false,"files":["system.caf"],"systemSampleRate":48000}
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent("session.json"))
    }

    func testStoreListsSessionsNewestFirstAndSkipsOtherFolders() throws {
        try writeSession("2026-09-20_10-00-00", start: "2026-09-20T10:00:00Z", in: root)
        try writeSession("2026-09-24_09-00-00", start: "2026-09-24T09:00:00Z", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("no-session-json"), withIntermediateDirectories: true)
        let broken = root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("session.json"))
        UserDefaults.standard.set(root.path, forKey: AppSettings.outputFolderKey)

        let store = RecordingStore()
        store.reload()

        XCTAssertEqual(store.recordings.map { $0.folder.lastPathComponent }, ["2026-09-24_09-00-00", "2026-09-20_10-00-00"])
        XCTAssertEqual(store.recordings.first?.duration, 5)
        XCTAssertFalse(store.recordings.first?.isCombined ?? true)
    }

    func testStoreIsEmptyWhenTheFolderDoesNotExist() {
        UserDefaults.standard.set(root.appendingPathComponent("missing").path, forKey: AppSettings.outputFolderKey)
        let store = RecordingStore()
        store.reload()
        XCTAssertTrue(store.recordings.isEmpty)
    }
}
