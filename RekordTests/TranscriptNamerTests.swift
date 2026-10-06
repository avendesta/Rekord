import XCTest
@testable import Rekord

final class TranscriptNamerTests: XCTestCase {
    func testCleanMakesAnAnswerFitToShow() {
        XCTAssertEqual(TranscriptNamer.clean("\"Weekly planning call.\""), "Weekly planning call")
        XCTAssertEqual(TranscriptNamer.clean("  **Budget review**\nand some more"), "Budget review")
        XCTAssertEqual(TranscriptNamer.clean("Team   standup \t notes"), "Team standup notes")
        XCTAssertNil(TranscriptNamer.clean("   \"\" "))
        XCTAssertLessThanOrEqual(TranscriptNamer.clean(String(repeating: "word ", count: 40))!.count, 61)
    }

    func testAShortTranscriptIsKeptAndALongOneIsCutToItsStartMiddleAndEnd() {
        XCTAssertEqual(TranscriptNamer.excerpt(of: "  short text \n"), "short text")
        let long = "START " + String(repeating: "a", count: 5000) + " MIDDLE " + String(repeating: "b", count: 5000) + " END"
        let cut = TranscriptNamer.excerpt(of: long, limit: 600)
        XCTAssertLessThan(cut.count, 700)
        XCTAssertTrue(cut.hasPrefix("START"))
        XCTAssertTrue(cut.hasSuffix("END"))
        XCTAssertEqual(cut.components(separatedBy: "\n…\n").count, 3)
    }

    func testTooLittleSaidIsNotNamed() async throws {
        XCTAssertFalse(TranscriptNamer.hasEnoughToName(Transcript.noSpeech + "\n"))
        XCTAssertFalse(TranscriptNamer.hasEnoughToName("[00:01] Me: Yeah okay thanks"))
        XCTAssertTrue(TranscriptNamer.hasEnoughToName(String(repeating: "we need to talk about the budget ", count: 3)))
        let name = try await TranscriptNamer.name(for: "Hello hello")
        XCTAssertNil(name)
    }

    @MainActor func testAGeneratedNameIsReplaceableButATypedOneIsNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rekord-name-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("rec")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The store reloads from the save folder, so point that at the temporary one and put it back.
        let defaults = UserDefaults.standard
        let savedPath = defaults.object(forKey: AppSettings.outputFolderKey), savedBookmark = defaults.object(forKey: AppSettings.outputFolderBookmarkKey)
        AppSettings.setOutputFolder(root)
        defer {
            defaults.set(savedPath, forKey: AppSettings.outputFolderKey)
            defaults.set(savedBookmark, forKey: AppSettings.outputFolderBookmarkKey)
            try? FileManager.default.removeItem(at: root)
        }
        let metadata = RecordingSession.Metadata(
            startDate: Date(), durationSeconds: 5, includeMicrophone: false, files: [], systemSampleRate: 48_000,
            micSampleRate: nil, micOffsetSeconds: nil)
        try metadata.write(to: folder)
        let store = RecordingStore()

        store.applyGeneratedName("Budget review", in: folder)
        var read = try RecordingSession.Metadata.read(from: folder)
        XCTAssertEqual(read.name, "Budget review")
        XCTAssertEqual(read.nameIsGenerated, true)

        store.applyGeneratedName("Another title", in: folder)  // its own earlier name may be replaced
        XCTAssertEqual(try RecordingSession.Metadata.read(from: folder).name, "Another title")

        // Renaming through the store, as the Recordings window does, makes the name the user's own.
        store.rename(try XCTUnwrap(store.recordings.first), to: "My own name")
        store.applyGeneratedName("Generated again", in: folder)
        read = try RecordingSession.Metadata.read(from: folder)
        XCTAssertEqual(read.name, "My own name")
        XCTAssertNil(read.nameIsGenerated)

        // Confirming a generated name unchanged goes through the same call, so it is kept too.
        store.applyGeneratedName("Ignored", in: folder)
        XCTAssertEqual(try RecordingSession.Metadata.read(from: folder).name, "My own name")
    }

    func testNamingIsOffUntilChosen() {
        let saved = UserDefaults.standard.object(forKey: AppSettings.autoNameKey)
        defer { UserDefaults.standard.set(saved, forKey: AppSettings.autoNameKey) }
        UserDefaults.standard.removeObject(forKey: AppSettings.autoNameKey)
        XCTAssertFalse(AppSettings.autoNameRecordings)
    }
}
