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

final class RecordingSectionTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testSectionTitles() {
        let now = date("2026-10-03T12:00:00Z")
        func title(_ iso: String) -> String { RecordingsWindowView.sectionTitle(for: date(iso), now: now, calendar: calendar) }
        XCTAssertEqual(title("2026-10-03T00:05:00Z"), "Today")
        XCTAssertEqual(title("2026-10-02T23:59:00Z"), "Yesterday")
        XCTAssertEqual(title("2026-09-29T08:00:00Z"), "Sep 29")
        XCTAssertEqual(title("2025-12-31T08:00:00Z"), "Dec 31, 2025")
    }

    func testRecordingsAreGroupedByDayInOrder() {
        let now = date("2026-10-03T12:00:00Z")
        let recordings = ["2026-10-03T08:00:00Z", "2026-10-03T07:00:00Z", "2026-10-02T22:00:00Z", "2026-09-29T08:00:00Z"].map {
            Recording(folder: URL(fileURLWithPath: "/tmp/\($0)"), metadata: .init(
                startDate: date($0), durationSeconds: 1, includeMicrophone: false, files: [],
                systemSampleRate: 48_000, micSampleRate: nil, micOffsetSeconds: nil))
        }
        let sections = RecordingsWindowView.sections(of: recordings, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "Sep 29"])
        XCTAssertEqual(sections.map(\.recordings.count), [2, 1, 1])
    }
}

final class MetadataTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testALinkedTranscriptIsNotATranscript() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rekord-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = Recording(folder: folder, metadata: .init(
            startDate: Date(), durationSeconds: 5, includeMicrophone: false, files: [], systemSampleRate: 48_000,
            micSampleRate: nil, micOffsetSeconds: nil))
        let transcript = folder.appendingPathComponent("transcript.txt")

        XCTAssertFalse(recording.hasTranscript)
        try "hello\n".write(to: transcript, atomically: true, encoding: .utf8)
        XCTAssertTrue(recording.hasTranscript)
        XCTAssertNotNil(recording.transcriptForSharing())

        // The same name as a link to some other file, which is what a planted folder would hold.
        let other = folder.appendingPathComponent("other.command")
        try "#!/bin/sh\n".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: transcript)
        try FileManager.default.createSymbolicLink(at: transcript, withDestinationURL: other)
        XCTAssertFalse(recording.hasTranscript)
        XCTAssertNil(recording.transcriptFile)
        XCTAssertNil(recording.transcriptForSharing())
    }

    func testOutOfRangeNumbersMakeTheFileUnreadable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rekord-limits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func read(_ key: String? = nil, _ value: Double = 0) throws -> RecordingSession.Metadata {
            var json: [String: Any] = ["startDate": "2026-10-05T12:00:00Z", "durationSeconds": 5.0, "includeMicrophone": true,
                                       "files": [String](), "systemSampleRate": 48_000.0, "micSampleRate": 48_000.0, "micOffsetSeconds": 0.1]
            if let key { json[key] = value }
            try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("session.json"))
            return try RecordingSession.Metadata.read(from: folder)
        }
        XCTAssertEqual(try read().durationSeconds, 5)
        XCTAssertThrowsError(try read("durationSeconds", 1e30))
        XCTAssertThrowsError(try read("durationSeconds", -1))
        XCTAssertThrowsError(try read("micOffsetSeconds", 1e30))
        XCTAssertThrowsError(try read("micOffsetSeconds", -1e30))
        XCTAssertThrowsError(try read("systemSampleRate", 0))
        XCTAssertThrowsError(try read("micSampleRate", 1e30))
    }

    func testRoundTripKeepsEveryField() throws {
        let original = RecordingSession.Metadata(
            startDate: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 12.5, includeMicrophone: true,
            files: ["system.caf", "mic.caf"], systemSampleRate: 48_000, micSampleRate: 44_100, micOffsetSeconds: -0.02,
            sourceApp: "zoom.us")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoded = try decoder().decode(RecordingSession.Metadata.self, from: encoder.encode(original))

        XCTAssertEqual(decoded.startDate, original.startDate)
        XCTAssertEqual(decoded.durationSeconds, 12.5)
        XCTAssertEqual(decoded.files, original.files)
        XCTAssertEqual(decoded.micSampleRate, 44_100)
        XCTAssertEqual(decoded.micOffsetSeconds, -0.02)
        XCTAssertEqual(decoded.sourceApp, "zoom.us")
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
        XCTAssertNil(metadata.sourceApp)
    }
}

final class AudioSourceTests: XCTestCase {
    func testHelpersInsideTheAppBundleBelongToTheApp() {
        let zoom = "/Applications/zoom.us.app"
        XCTAssertTrue(AudioSourceApps.owns(bundlePath: zoom, executablePath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us"))
        XCTAssertTrue(AudioSourceApps.owns(
            bundlePath: zoom, executablePath: "/Applications/zoom.us.app/Contents/Frameworks/aomhost.app/Contents/MacOS/aomhost"))
        XCTAssertTrue(AudioSourceApps.owns(bundlePath: zoom + "/", executablePath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us"))
    }

    func testOtherAppsAreNotMistakenForHelpers() {
        // A neighbour whose path merely starts with the same characters is a different app.
        XCTAssertFalse(AudioSourceApps.owns(
            bundlePath: "/Applications/Google Chrome.app",
            executablePath: "/Applications/Google Chrome.app Canary/Contents/MacOS/Google Chrome Canary"))
        XCTAssertFalse(AudioSourceApps.owns(bundlePath: "/Applications/zoom.us.app", executablePath: "/usr/bin/afplay"))
        XCTAssertFalse(AudioSourceApps.owns(bundlePath: "/Applications/zoom.us.app", executablePath: ""))
    }

    func testAnAppThatIsNotRunningHasNothingToRecord() {
        XCTAssertTrue(AudioSourceApps.processObjects(forBundleID: "com.avendesta.rekord.no-such-app").isEmpty)
        XCTAssertEqual(AudioSourceApps.name(forBundleID: "com.avendesta.rekord.no-such-app"), "com.avendesta.rekord.no-such-app")
    }

    func testRekordDoesNotOfferItselfOrSafari() {
        let listed = Set(AudioSourceApps.all().map(\.bundleID))
        XCTAssertFalse(listed.contains(Bundle.main.bundleIdentifier ?? ""))
        XCTAssertFalse(listed.contains("com.apple.Safari"))
    }
}

/// These touch the app's real UserDefaults (the tests run inside the app), so they restore what they change.
@MainActor
final class StorageTests: XCTestCase {
    private let keys = [AppSettings.outputFolderKey, AppSettings.outputFolderBookmarkKey, AppSettings.transcribeKey,
                        AppSettings.audioRetentionDaysKey]
    private var saved: [String: Any] = [:]
    private var root: URL!

    override func setUpWithError() throws {
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(false, forKey: AppSettings.transcribeKey)  // no speech model in these tests
        UserDefaults.standard.set(0, forKey: AppSettings.audioRetentionDaysKey)  // only the retention test removes audio
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

    func testFolderIsShownRelativeToHome() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(SettingsView.shortPath(URL(fileURLWithPath: "/Users/someone/Documents/Rekord"), home: home), "Documents/Rekord")
        XCTAssertEqual(SettingsView.shortPath(URL(fileURLWithPath: "/Volumes/Audio/Rekord"), home: home), "/Volumes/Audio/Rekord")
        XCTAssertEqual(SettingsView.shortPath(URL(fileURLWithPath: "/Users/someone-else/x"), home: home), "/Users/someone-else/x")
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

    func testARecordingThatWasNeverStoppedIsListedWithItsRealLength() throws {
        // What a crash leaves behind: the session.json written at the start, and the audio so far.
        let folder = root.appendingPathComponent("crashed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTestTrack(at: folder.appendingPathComponent("system.caf"), seconds: 0.5, level: 0.1)
        try RecordingSession.Metadata(
            startDate: Date(), durationSeconds: 0, includeMicrophone: false, files: ["system.caf"],
            systemSampleRate: 48_000, micSampleRate: nil, micOffsetSeconds: nil
        ).write(to: folder)
        UserDefaults.standard.set(root.path, forKey: AppSettings.outputFolderKey)

        let store = RecordingStore()
        store.reload()

        XCTAssertEqual(store.recordings.first?.duration ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(try RecordingSession.Metadata.read(from: folder).durationSeconds, 0.5, accuracy: 0.01)
    }

    func testStoreMixesMicRecordingsOnItsOwn() throws {
        try writeSession("system-only", start: "2026-09-20T10:00:00Z", in: root)
        let withMic = root.appendingPathComponent("with-mic", isDirectory: true)
        try FileManager.default.createDirectory(at: withMic, withIntermediateDirectories: true)
        try writeTestTrack(at: withMic.appendingPathComponent("system.caf"), seconds: 0.5, level: 0.25)
        try writeTestTrack(at: withMic.appendingPathComponent("mic.caf"), seconds: 0.5, level: 0.25)
        let json = """
        {"startDate":"2026-09-24T09:00:00Z","durationSeconds":0.5,"includeMicrophone":true,
         "files":["system.caf","mic.caf"],"systemSampleRate":48000,"micSampleRate":48000,"micOffsetSeconds":0}
        """
        try Data(json.utf8).write(to: withMic.appendingPathComponent("session.json"))
        UserDefaults.standard.set(root.path, forKey: AppSettings.outputFolderKey)

        let store = RecordingStore()
        store.reload()

        let mixed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            store.combining.isEmpty && FileManager.default.fileExists(atPath: withMic.appendingPathComponent("combined.caf").path)
        }, object: nil)
        wait(for: [mixed], timeout: 10)
        XCTAssertNil(store.combineError)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("system-only").path), ["session.json"])
    }

    private func recording(_ name: String, mic: Bool, files: [String: Double]) throws -> Recording {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, seconds) in files { try writeTestTrack(at: folder.appendingPathComponent(file), seconds: seconds, level: 0.1) }
        return Recording(folder: folder, metadata: .init(
            startDate: Date(), durationSeconds: 1, includeMicrophone: mic, files: [],
            systemSampleRate: 48_000, micSampleRate: nil, micOffsetSeconds: nil))
    }

    func testPlaybackUsesTheMixForMicRecordings() throws {
        XCTAssertEqual(try recording("a", mic: true, files: ["system.caf": 1, "mic.caf": 1, "combined.caf": 1]).playableURL?.lastPathComponent, "combined.caf")
        XCTAssertNil(try recording("b", mic: true, files: ["system.caf": 1, "mic.caf": 1]).playableURL)  // mix not made yet
        XCTAssertEqual(try recording("c", mic: false, files: ["system.caf": 1]).playableURL?.lastPathComponent, "system.caf")
        XCTAssertNil(try recording("d", mic: false, files: [:]).playableURL)
        XCTAssertNil(try recording("e", mic: false, files: ["system.caf": 0]).playableURL)  // recorded, but no audio in it
    }

    func testPlayerIgnoresMissingAndEmptyAudio() throws {
        let player = PlaybackController()
        player.toggle(try recording("missing", mic: false, files: [:]))
        XCTAssertNil(player.activeID)
        player.toggle(try recording("empty", mic: false, files: ["system.caf": 0]))
        XCTAssertNil(player.activeID)
        XCTAssertFalse(player.isPlaying)
    }

    func testPlayerSwitchesSeeksAndStops() throws {
        let first = try recording("first", mic: false, files: ["system.caf": 2])
        let second = try recording("second", mic: false, files: ["system.caf": 1])
        let player = PlaybackController()
        defer { player.stop() }

        player.toggle(first)
        XCTAssertEqual(player.activeID, first.id)
        XCTAssertEqual(player.duration, 2, accuracy: 0.05)
        player.seek(to: 99)
        XCTAssertLessThan(player.clock.time, 2)

        player.toggle(second)  // only one at a time
        XCTAssertEqual(player.activeID, second.id)
        XCTAssertEqual(player.duration, 1, accuracy: 0.05)

        player.stop()
        XCTAssertNil(player.activeID)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.clock.time, 0)
    }

    func testTrashedRecordingCanBePutBack() throws {
        try writeSession("2026-09-20_10-00-00", start: "2026-09-20T10:00:00Z", in: root)
        try Data("hello".utf8).write(to: root.appendingPathComponent("2026-09-20_10-00-00/transcript.txt"))
        UserDefaults.standard.set(root.path, forKey: AppSettings.outputFolderKey)
        let store = RecordingStore()
        store.reload()

        let trashed = store.moveToTrash(store.recordings)
        XCTAssertEqual(trashed.count, 1)
        XCTAssertTrue(store.recordings.isEmpty)

        XCTAssertTrue(store.restore(trashed))
        XCTAssertEqual(store.recordings.map { $0.folder.lastPathComponent }, ["2026-09-20_10-00-00"])
        XCTAssertTrue(store.recordings[0].hasTranscript)  // the transcript travels with the recording

        XCTAssertFalse(store.restore(trashed))  // nothing left in the Trash to restore: reported, not faked
    }

    func testTrashingAMissingRecordingReportsNothing() throws {
        try writeSession("gone", start: "2026-09-20T10:00:00Z", in: root)
        UserDefaults.standard.set(root.path, forKey: AppSettings.outputFolderKey)
        let store = RecordingStore()
        store.reload()
        let recording = try XCTUnwrap(store.recordings.first)
        try FileManager.default.removeItem(at: recording.folder)

        XCTAssertTrue(store.moveToTrash([recording]).isEmpty)
    }

    @MainActor
    func testStoreCompressesExistingRecordingsOnRequest() throws {
        let withMic = try recording("with-mic", mic: true, files: ["system.caf": 0.5, "mic.caf": 0.5])
        let json = """
        {"startDate":"2026-09-24T09:00:00Z","durationSeconds":0.5,"includeMicrophone":true,
         "files":["system.caf","mic.caf"],"systemSampleRate":48000,"micSampleRate":48000,"micOffsetSeconds":0}
        """
        try Data(json.utf8).write(to: withMic.folder.appendingPathComponent("session.json"))
        UserDefaults.standard.set(root.path, forKey: AppSettings.outputFolderKey)
        let store = RecordingStore()
        store.reload()  // starts the mix; nothing is compressed unasked
        XCTAssertTrue(store.pendingCompression.isEmpty)

        store.compressAll()

        // The mix has to exist first, then all three files are converted and the originals removed.
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            store.pendingCompression.isEmpty && store.compressing == nil && store.combining.isEmpty
        }, object: nil)
        wait(for: [done], timeout: 15)
        let names = try FileManager.default.contentsOfDirectory(atPath: withMic.folder.path).sorted()
        XCTAssertEqual(names, ["combined.m4a", "mic.m4a", "session.json", "system.m4a"])
        XCTAssertTrue(store.compressible.isEmpty)
    }

    func testCopiedTranscriptSaysWhatItIs() throws {
        func make(_ folder: String, name: String?, seconds: Double) throws -> Recording {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("[00:03] Others: Shall we start?\n".utf8).write(to: url.appendingPathComponent("transcript.txt"))
            return Recording(folder: url, metadata: .init(
                startDate: Date(timeIntervalSince1970: 1_790_000_000), durationSeconds: seconds, includeMicrophone: true,
                files: [], systemSampleRate: 48_000, micSampleRate: nil, micOffsetSeconds: nil, name: name))
        }
        let locale = Locale(identifier: "en_US"), utc = TimeZone(identifier: "UTC")!

        XCTAssertEqual(try make("a", name: "Weekly planning", seconds: 754).transcriptForSharing(locale: locale, timeZone: utc),
                       "Weekly planning\nRecorded Sep 21, 2026 at 2:13\u{202F}PM · 12:34\n\n[00:03] Others: Shall we start?\n")
        XCTAssertEqual(try make("b", name: nil, seconds: 3725).transcriptForSharing(locale: locale, timeZone: utc),
                       "Recorded Sep 21, 2026 at 2:13\u{202F}PM · 1:02:05\n\n[00:03] Others: Shall we start?\n")
        XCTAssertNil(Recording(folder: root.appendingPathComponent("none"), metadata: try make("c", name: nil, seconds: 1).metadata).transcriptForSharing())
    }

    func testOldAudioIsRemovedButTheTranscriptStays() throws {
        /// A system-only session `daysOld` days ago, with real audio and, if asked, a transcript
        /// written the same day (or `transcriptDaysOld` days ago).
        func session(_ name: String, daysOld: Double, transcript: Bool, text: String = "Hello.\n",
                     transcriptDaysOld: Double? = nil) throws -> URL {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeTestTrack(at: folder.appendingPathComponent("system.caf"), seconds: 0.2, level: 0.1)
            try AudioCompressor.compress(folder.appendingPathComponent("system.caf"))
            try RecordingSession.Metadata(
                startDate: Date().addingTimeInterval(-daysOld * 86_400), durationSeconds: 0.2, includeMicrophone: false,
                files: ["system.m4a"], systemSampleRate: 48_000, micSampleRate: nil, micOffsetSeconds: nil, name: "Kept name"
            ).write(to: folder)
            if transcript {
                let url = folder.appendingPathComponent("transcript.txt")
                try Data(text.utf8).write(to: url)
                let written = Date().addingTimeInterval(-(transcriptDaysOld ?? daysOld) * 86_400)
                try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path)
            }
            return folder
        }
        func files(_ folder: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() }
        let old = try session("old", daysOld: 8, transcript: true)
        let oldWithoutTranscript = try session("old-no-transcript", daysOld: 8, transcript: false)
        let recent = try session("recent", daysOld: 6, transcript: true)
        let justTranscribed = try session("old-just-transcribed", daysOld: 30, transcript: true, transcriptDaysOld: 0)
        let noWords = try session("old-no-words", daysOld: 8, transcript: true, text: Transcript.noSpeech + "\n")
        UserDefaults.standard.set(root.path, forKey: AppSettings.outputFolderKey)
        let store = RecordingStore()

        store.reload()  // retention is off in these tests: nothing goes
        XCTAssertEqual(try files(old), ["session.json", "system.m4a", "transcript.txt"])

        UserDefaults.standard.set(7, forKey: AppSettings.audioRetentionDaysKey)
        store.reload()

        XCTAssertEqual(try files(old), ["session.json", "transcript.txt"])
        XCTAssertEqual(try files(oldWithoutTranscript), ["session.json", "system.m4a"])  // never left with neither
        XCTAssertEqual(try files(recent), ["session.json", "system.m4a", "transcript.txt"])
        XCTAssertEqual(try files(justTranscribed), ["session.json", "system.m4a", "transcript.txt"])  // time to read it first
        XCTAssertEqual(try files(noWords), ["session.json", "system.m4a", "transcript.txt"])  // the audio is all there is
        let kept = try XCTUnwrap(store.recordings.first { $0.folder.lastPathComponent == "old" })
        XCTAssertEqual(kept.name, "Kept name")
        XCTAssertTrue(kept.hasTranscript && !kept.hasAudio)
        XCTAssertNil(kept.playableURL)
    }

    func testAudioIsKeptForAWeekByDefault() {
        UserDefaults.standard.removeObject(forKey: AppSettings.audioRetentionDaysKey)
        XCTAssertEqual(AppSettings.audioRetentionDays, 7)
    }

    func testRenamingChangesOnlyTheDisplayName() throws {
        try writeSession("2026-09-20_10-00-00", start: "2026-09-20T10:00:00Z", in: root)
        UserDefaults.standard.set(root.path, forKey: AppSettings.outputFolderKey)
        let store = RecordingStore()
        store.reload()
        XCTAssertNil(store.recordings[0].name)  // older session files have no name

        store.rename(store.recordings[0], to: "  Weekly planning meeting \n")
        XCTAssertEqual(store.recordings[0].name, "Weekly planning meeting")
        XCTAssertEqual(store.recordings[0].folder.lastPathComponent, "2026-09-20_10-00-00")  // the folder is untouched
        XCTAssertEqual(store.recordings[0].duration, 5)

        store.rename(store.recordings[0], to: "   ")  // an empty name goes back to the time
        XCTAssertNil(store.recordings[0].name)
        let json = try String(contentsOf: store.recordings[0].folder.appendingPathComponent("session.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("\"name\""))
    }

    func testStoreIsEmptyWhenTheFolderDoesNotExist() {
        UserDefaults.standard.set(root.appendingPathComponent("missing").path, forKey: AppSettings.outputFolderKey)
        let store = RecordingStore()
        store.reload()
        XCTAssertTrue(store.recordings.isEmpty)
    }
}
