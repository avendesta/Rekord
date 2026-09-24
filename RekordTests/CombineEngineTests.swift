import AVFoundation
import XCTest
@testable import Rekord

final class CombineEngineTests: XCTestCase {
    private var folder: URL!
    private let rate = 48_000.0

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Writes a mono CAF holding a constant value, so the mix can be checked by sample level.
    private func writeTrack(_ name: String, seconds: Double, level: Float) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent(name), settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = level }
        try file.write(from: buffer)
    }

    private func metadata(micOffset: Double?, includeMic: Bool = true) -> RecordingSession.Metadata {
        .init(startDate: Date(), durationSeconds: 1, includeMicrophone: includeMic,
              files: ["system.caf", "mic.caf"], systemSampleRate: rate, micSampleRate: rate,
              micOffsetSeconds: micOffset)
    }

    /// Level of the left channel `seconds` into the file.
    private func level(of url: URL, at seconds: Double) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        file.framePosition = AVAudioFramePosition(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 64)!
        try file.read(into: buffer, frameCount: 64)
        return buffer.floatChannelData![0][0]
    }

    func testMixesBothTracksWhenAligned() throws {
        try writeTrack("system.caf", seconds: 1, level: 0.25)
        try writeTrack("mic.caf", seconds: 1, level: 0.25)

        let output = try CombineEngine.combine(folder: folder, metadata: metadata(micOffset: 0))

        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.length, AVAudioFramePosition(rate), accuracy: 4096)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(try level(of: output, at: 0.5), 0.5, accuracy: 0.01)
    }

    func testLateMicIsPaddedByTheOffset() throws {
        try writeTrack("system.caf", seconds: 1, level: 0.25)
        try writeTrack("mic.caf", seconds: 1, level: 0.5)

        let output = try CombineEngine.combine(folder: folder, metadata: metadata(micOffset: 0.5))

        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.length, AVAudioFramePosition(1.5 * rate), accuracy: 4096)
        XCTAssertEqual(try level(of: output, at: 0.25), 0.25, accuracy: 0.01)  // system only
        XCTAssertEqual(try level(of: output, at: 0.75), 0.75, accuracy: 0.01)  // both
        XCTAssertEqual(try level(of: output, at: 1.25), 0.5, accuracy: 0.01)   // mic only
    }

    func testEarlyMicPadsTheSystemTrack() throws {
        try writeTrack("system.caf", seconds: 1, level: 0.25)
        try writeTrack("mic.caf", seconds: 1, level: 0.5)

        let output = try CombineEngine.combine(folder: folder, metadata: metadata(micOffset: -0.5))

        XCTAssertEqual(try level(of: output, at: 0.25), 0.5, accuracy: 0.01)   // mic only
        XCTAssertEqual(try level(of: output, at: 1.25), 0.25, accuracy: 0.01)  // system only
    }

    func testRefusesARecordingWithoutMic() {
        XCTAssertThrowsError(try CombineEngine.combine(folder: folder, metadata: metadata(micOffset: nil, includeMic: false))) {
            XCTAssertEqual($0 as? CombineEngine.CombineError, .missingTrack)
        }
    }
}
