import Speech
import XCTest
@testable import Rekord

final class TranscriptTests: XCTestCase {
    private func seg(_ start: Double, _ text: String) -> TranscriptSegment { .init(start: start, text: text) }

    func testInterleavesBothTracksByTime() {
        let text = Transcript.render(
            system: [seg(3, "Shall we start?"), seg(70, "Good.")],
            mic: [seg(7, "Yes, two updates.")])
        XCTAssertEqual(text, """
        [00:03] Others: Shall we start?
        [00:07] Me: Yes, two updates.
        [01:10] Others: Good.

        """)
    }

    func testLateMicShiftsMicLines() {
        let text = Transcript.render(system: [seg(4, "A")], mic: [seg(3, "B")], micOffset: 2)
        XCTAssertEqual(text, "[00:04] Others: A\n[00:05] Me: B\n")
    }

    func testEarlyMicShiftsSystemLines() {
        let text = Transcript.render(system: [seg(3, "A")], mic: [seg(4, "B")], micOffset: -2)
        XCTAssertEqual(text, "[00:04] Me: B\n[00:05] Others: A\n")
    }

    func testSystemOnlyRecordingHasNoSpeakerLabels() {
        XCTAssertEqual(Transcript.render(system: [seg(1, "Hello.")], mic: nil), "[00:01] Hello.\n")
    }

    func testNoSpeechIsStatedRatherThanLeftEmpty() {
        XCTAssertEqual(Transcript.render(system: [], mic: []), "(No speech detected)\n")
    }

    func testTimestampsCanBeLeftOut() {
        let text = Transcript.render(system: [seg(3, "A")], mic: [seg(7, "B")], timestamps: false)
        XCTAssertEqual(text, "Others: A\nMe: B\n")
    }

    func testLongRecordingsShowHours() {
        let text = Transcript.render(system: [seg(5, "A"), seg(3725, "B")], mic: nil)
        XCTAssertEqual(text, "[0:00:05] A\n[1:02:05] B\n")
    }

    func testSameTimeKeepsOthersBeforeMe() {
        XCTAssertEqual(Transcript.render(system: [seg(1, "A")], mic: [seg(1, "B")]), "[00:01] Others: A\n[00:01] Me: B\n")
    }
}

/// Runs the real speech model, so it only runs where the English model is already installed
/// (a developer's Mac that has used transcription); elsewhere, including CI, it is skipped.
final class TranscriberTests: XCTestCase {
    func testTranscribesBothTracksOfARecording() async throws {
        guard #available(macOS 26, *), Transcriber.isSupported else { throw XCTSkip("Needs macOS 26") }
        guard await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == "en-US" }) else {
            throw XCTSkip("The en-US speech model isn't installed")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try speak("Shall we start with the roadmap?", to: folder.appendingPathComponent("system.caf"))
        try speak("Yes, I have some updates.", to: folder.appendingPathComponent("mic.caf"))
        let metadata = RecordingSession.Metadata(
            startDate: Date(), durationSeconds: 5, includeMicrophone: true, files: ["system.caf", "mic.caf"],
            systemSampleRate: 48_000, micSampleRate: 48_000, micOffsetSeconds: 3)

        let url = try await Transcriber.transcribe(folder: folder, metadata: metadata, language: "en-US")

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("[00:00] Others: ") && lines[0].lowercased().contains("shall we start"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("[00:03] Me: ") && lines[1].lowercased().contains("updates"), lines[1])
    }

    func testAnEmptyAudioFileFinishesWithNoSpeech() async throws {
        guard #available(macOS 26, *), Transcriber.isSupported else { throw XCTSkip("Needs macOS 26") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeTestTrack(at: folder.appendingPathComponent("system.caf"), seconds: 0, level: 0)

        let url = try await Transcriber.transcribe(folder: folder, metadata: systemOnly, language: "en-US")

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "(No speech detected)\n")
    }

    func testMissingAudioIsReportedPlainly() async throws {
        guard #available(macOS 26, *), Transcriber.isSupported else { throw XCTSkip("Needs macOS 26") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            _ = try await Transcriber.transcribe(folder: folder, metadata: systemOnly, language: "en-US")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? Transcriber.TranscriberError, .missingAudio)
        }
    }

    private var systemOnly: RecordingSession.Metadata {
        .init(startDate: Date(), durationSeconds: 2, includeMicrophone: false, files: ["system.caf"],
              systemSampleRate: 48_000, micSampleRate: nil, micOffsetSeconds: nil)
    }

    private func speak(_ text: String, to url: URL) throws {
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEF32@48000", text]
        try say.run()
        say.waitUntilExit()
    }
}
