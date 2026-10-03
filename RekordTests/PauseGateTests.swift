import AVFoundation
import XCTest
@testable import Rekord

final class PauseGateTests: XCTestCase {
    /// 1000 ticks a second and 1000 frames a second, so ticks, frames and milliseconds line up.
    private func kept(start: UInt64, frames: Int, paused: [PauseGate.Interval]) -> [Range<Int>] {
        PauseGate.keptFrames(start: start, frameCount: frames, sampleRate: 1000, paused: paused, ticksPerSecond: 1000)
    }

    func testNothingIsDroppedBeforeAPause() {
        XCTAssertEqual(kept(start: 0, frames: 100, paused: [(500, nil)]), [0..<100])
    }

    func testABufferIsCutWhereThePauseBegins() {
        XCTAssertEqual(kept(start: 450, frames: 100, paused: [(500, nil)]), [0..<50])
    }

    func testEverythingDuringAPauseIsDropped() {
        XCTAssertEqual(kept(start: 600, frames: 100, paused: [(500, nil)]), [])
        XCTAssertEqual(kept(start: 600, frames: 100, paused: [(500, 900)]), [])
    }

    func testABufferIsPickedUpWhereTheRecordingResumes() {
        XCTAssertEqual(kept(start: 850, frames: 100, paused: [(500, 900)]), [50..<100])
        XCTAssertEqual(kept(start: 900, frames: 100, paused: [(500, 900)]), [0..<100])
    }

    func testAShortPauseInsideOneBufferLeavesBothEnds() {
        XCTAssertEqual(kept(start: 0, frames: 100, paused: [(20, 30), (60, 70)]), [0..<20, 30..<60, 70..<100])
    }

    func testBothTracksDropTheSameAmountWhateverTheirBufferSizes() {
        // System audio arrives in small buffers and the microphone in large ones, at different rates.
        let paused: [PauseGate.Interval] = [(1_234, 5_678), (7_000, 7_500)]
        func total(bufferFrames: Int, sampleRate: Double) -> Double {
            var frames = 0
            let ticksPerBuffer = UInt64(Double(bufferFrames) / sampleRate * 1000)
            for start in stride(from: UInt64(0), to: 10_000, by: Int(ticksPerBuffer)) {
                frames += PauseGate.keptFrames(start: start, frameCount: bufferFrames, sampleRate: sampleRate,
                                               paused: paused, ticksPerSecond: 1000).reduce(0) { $0 + $1.count }
            }
            return Double(frames) / sampleRate
        }
        let expected = 10 - 4.444 - 0.5
        XCTAssertEqual(total(bufferFrames: 480, sampleRate: 48_000), expected, accuracy: 0.001)   // 10 ms buffers
        XCTAssertEqual(total(bufferFrames: 4_800, sampleRate: 48_000), expected, accuracy: 0.001) // 100 ms buffers
        XCTAssertEqual(total(bufferFrames: 1_600, sampleRate: 16_000), expected, accuracy: 0.001) // a Bluetooth mic
    }

    func testPausingTwiceOrResumingWhenNotPausedChangesNothing() {
        let gate = PauseGate()
        gate.resume(at: 10)
        gate.pause(at: 100)
        gate.pause(at: 200)
        gate.resume(at: 300)
        gate.resume(at: 400)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        XCTAssertEqual(gate.pieces(of: buffer, startingAt: 0).count, 1)  // before the pause: the buffer itself
        gate.reset()
        XCTAssertTrue(gate.pieces(of: buffer, startingAt: 150).first === buffer)
    }

    func testCopyingPartOfABufferKeepsTheRightSamples() throws {
        for interleaved in [false, true] {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10)!
            buffer.frameLength = 10
            for frame in 0..<10 {
                for channel in 0..<2 {
                    let value = Int16(frame * 10 + channel)
                    if interleaved { buffer.int16ChannelData![0][frame * 2 + channel] = value }
                    else { buffer.int16ChannelData![channel][frame] = value }
                }
            }
            let piece = try XCTUnwrap(buffer.copy(of: 3..<6))
            XCTAssertEqual(piece.frameLength, 3)
            let first = interleaved ? [piece.int16ChannelData![0][0], piece.int16ChannelData![0][1]]
                                    : [piece.int16ChannelData![0][0], piece.int16ChannelData![1][0]]
            XCTAssertEqual(first, [30, 31], "interleaved: \(interleaved)")
            let last = interleaved ? piece.int16ChannelData![0][5] : piece.int16ChannelData![1][2]
            XCTAssertEqual(last, 51)
        }
    }
}
