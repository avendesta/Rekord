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

    // MARK: Echo removal

    private func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment { .init(start: start, text: text, end: end) }

    private func kept(mic: [TranscriptSegment], system: [TranscriptSegment], offset: Double = 0) -> [String] {
        Transcript.withoutEcho(mic: mic, system: system, micOffset: offset).map(\.text)
    }

    func testAMicLineThatRepeatsTheMeetingIsDropped() {
        let system = [seg(6.5, 9.5, "Now it's time to get the rooks into play.")]
        XCTAssertEqual(kept(mic: [seg(7.3, 9.4, "Now it's time to get the rooks into play.")], system: system), [])
    }

    func testSmallWordingDifferencesStillCountAsAnEcho() {
        let system = [seg(23.3, 26.3, "Uh, one is just to trade and simplify."),
                      seg(9.0, 14.9, "The evaluation API is the piece that you'll primarily be interacting with.")]
        XCTAssertEqual(kept(mic: [seg(23.2, 26.0, "One is just to trade and simplify."),
                                  seg(9.0, 14.8, "The evaluation API is the piece that you're primarily interacting with.")], system: system), [])
    }

    func testOneMeetingSentenceHeardAsSeveralMicSegmentsIsDropped() {
        let system = [seg(18.4, 23.1, "First, you need to include the SDK in your code, then set the provider you wish to use."),
                      seg(23.1, 24.5, "If you don't yet know about providers.")]
        let mic = [seg(18.3, 20.9, "First, you need to include the SDK in your code."),
                   seg(20.9, 24.4, "set the provider you wish to use if you don't yet know about providers.")]
        XCTAssertEqual(kept(mic: mic, system: system), [])
    }

    func testWhatTheUserSaidIsKeptEvenWhileOthersTalk() {
        let system = [seg(23.1, 24.5, "If you don't yet know about providers."), seg(25.9, 28.3, "We have another video on that topic.")]
        XCTAssertEqual(kept(mic: [seg(24.4, 26.1, "Are you okay?"), seg(26.1, 28.1, "We have another video on that topic.")], system: system),
                       ["Are you okay?"])
    }

    func testTheSameWordsAtAnotherTimeAreNotAnEcho() {
        let system = [seg(5, 8, "Let's move on to the budget.")]
        XCTAssertEqual(kept(mic: [seg(60, 63, "Let's move on to the budget.")], system: system), ["Let's move on to the budget."])
    }

    func testAShortReplyIsOnlyDroppedWhenItMatchesExactly() {
        let system = [seg(10, 14, "Yeah, I think that plan works for everyone."), seg(20, 21, "Okay.")]
        XCTAssertEqual(kept(mic: [seg(12, 12.5, "Yeah."), seg(20.1, 21, "Okay.")], system: system), ["Yeah."])
    }

    func testTheMicOffsetLinesTheTracksUpBeforeComparing() {
        // The mic started 30 s late, so its 5 s is the meeting's 35 s.
        let system = [seg(35, 38, "Shall we start with the roadmap today?")]
        let mic = [seg(5, 8, "Shall we start with the roadmap today?")]
        XCTAssertEqual(kept(mic: mic, system: system, offset: 30), [])
        XCTAssertEqual(kept(mic: mic, system: system, offset: 0), ["Shall we start with the roadmap today?"])
    }

    func testRenderLeavesEchoesOutButKeepsTheLabels() {
        let text = Transcript.render(system: [seg(3, 6, "Shall we start with the roadmap?")],
                                     mic: [seg(3.1, 6, "Shall we start with the roadmap?"), seg(7, 9, "Yes, I have two updates.")])
        XCTAssertEqual(text, "[00:03] Others: Shall we start with the roadmap?\n[00:07] Me: Yes, I have two updates.\n")
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

        // Leaving the microphone out transcribes the system track alone, without speaker labels.
        let systemOnly = try await Transcriber.transcribe(folder: folder, metadata: metadata, language: "en-US", includeMicrophone: false)
        let text = try String(contentsOf: systemOnly, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1)
        XCTAssertTrue(text.hasPrefix("[00:00] Shall we start"), text)
        XCTAssertFalse(text.contains("Me:") || text.contains("Others:"), text)
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
