import AVFoundation
import XCTest
@testable import Rekord

final class AudioCompressorTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() }

    private func metadata(mic: Bool) -> RecordingSession.Metadata {
        .init(startDate: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 2, includeMicrophone: mic,
              files: mic ? ["system.caf", "mic.caf"] : ["system.caf"],
              systemSampleRate: 48_000, micSampleRate: mic ? 48_000 : nil, micOffsetSeconds: mic ? 0 : nil)
    }

    func testCompressingKeepsTheLengthAndRemovesTheOriginal() throws {
        let caf = folder.appendingPathComponent("system.caf")
        try writeTestTrack(at: caf, seconds: 2, level: 0.25)
        let frames = try AVAudioFile(forReading: caf).length
        let originalSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: caf.path)[.size] as? Int)

        let m4a = try AudioCompressor.compress(caf)

        XCTAssertEqual(try names(), ["system.m4a"])
        XCTAssertEqual(try AVAudioFile(forReading: m4a).length, frames)  // same length keeps the tracks in sync
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int)
        XCTAssertLessThan(size, originalSize / 4)
    }

    func testMicrophoneSampleRatesAreAccepted() throws {
        // Bluetooth headsets record at 16 or 24 kHz; built-in and USB mics at 44.1 or 48 kHz.
        for rate in [16_000.0, 24_000, 44_100, 48_000] {
            let caf = folder.appendingPathComponent("mic.caf")
            try writeTestTrack(at: caf, seconds: 1, level: 0.25, rate: rate)
            let frames = try AVAudioFile(forReading: caf).length
            let m4a = try AudioCompressor.compress(caf)
            XCTAssertEqual(try AVAudioFile(forReading: m4a).length, frames, "\(rate) Hz")
            try FileManager.default.removeItem(at: m4a)
        }
    }

    func testAFailedConversionKeepsTheOriginal() throws {
        let caf = folder.appendingPathComponent("system.caf")
        try Data(repeating: 7, count: 10_000).write(to: caf)  // not audio

        XCTAssertThrowsError(try AudioCompressor.compress(caf))
        XCTAssertEqual(try names(), ["system.caf"])
    }

    func testWholeRecordingIsCompressedAndSessionFileUpdated() throws {
        for name in ["system.caf", "mic.caf"] { try writeTestTrack(at: folder.appendingPathComponent(name), seconds: 1, level: 0.25) }
        _ = try CombineEngine.combine(folder: folder, metadata: metadata(mic: true))
        XCTAssertTrue(AudioCompressor.needsCompression(folder: folder))

        try AudioCompressor.compress(folder: folder, metadata: metadata(mic: true))

        XCTAssertEqual(try names(), ["combined.m4a", "mic.m4a", "session.json", "system.m4a"])
        XCTAssertFalse(AudioCompressor.needsCompression(folder: folder))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(RecordingSession.Metadata.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
        XCTAssertEqual(saved.files, ["system.m4a", "mic.m4a", "combined.m4a"])
        XCTAssertEqual(saved.startDate, metadata(mic: true).startDate)
    }

    func testAnEmptyTrackIsLeftAlone() throws {
        try writeTestTrack(at: folder.appendingPathComponent("system.caf"), seconds: 0, level: 0)
        XCTAssertFalse(AudioCompressor.needsCompression(folder: folder))
        try AudioCompressor.compress(folder: folder, metadata: metadata(mic: false))
        XCTAssertEqual(try names(), ["session.json", "system.caf"])
    }

    func testCompressedTracksCanStillBeMixedAndPlayed() throws {
        for name in ["system.caf", "mic.caf"] {
            try writeTestTrack(at: folder.appendingPathComponent(name), seconds: 1, level: 0.25)
            try AudioCompressor.compress(folder.appendingPathComponent(name))
        }
        XCTAssertEqual(Track.system.url(in: folder)?.lastPathComponent, "system.m4a")

        let mix = try CombineEngine.combine(folder: folder, metadata: metadata(mic: true))
        XCTAssertEqual(try AVAudioFile(forReading: mix).length, 48_000, accuracy: 4096)

        let recording = Recording(folder: folder, metadata: metadata(mic: true))
        XCTAssertTrue(recording.hasAudio && recording.isCombined)
        try AudioCompressor.compress(mix)
        XCTAssertEqual(recording.playableURL?.lastPathComponent, "combined.m4a")
    }

    func testTrackPrefersTheCompressedFile() throws {
        XCTAssertNil(Track.mic.url(in: folder))
        try Data().write(to: folder.appendingPathComponent("mic.caf"))
        XCTAssertEqual(Track.mic.url(in: folder)?.lastPathComponent, "mic.caf")
        try Data().write(to: folder.appendingPathComponent("mic.m4a"))
        XCTAssertEqual(Track.mic.url(in: folder)?.lastPathComponent, "mic.m4a")
    }
}
