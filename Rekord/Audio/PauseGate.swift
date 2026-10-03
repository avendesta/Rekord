import AVFoundation
import os

/// The paused stretches of a recording, shared by both recorders so they leave out exactly the
/// same moments and the two tracks stay in step. Times are host (mach) ticks, as audio buffers carry.
final class PauseGate {
    typealias Interval = (start: UInt64, end: UInt64?)

    private let intervals = OSAllocatedUnfairLock(initialState: [Interval]())
    private static let ticksPerSecond: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
    }()

    func reset() { intervals.withLock { $0 = [] } }

    func pause(at host: UInt64 = mach_absolute_time()) {
        intervals.withLock { if $0.last?.end != nil || $0.isEmpty { $0.append((host, nil)) } }
    }

    func resume(at host: UInt64 = mach_absolute_time()) {
        intervals.withLock { if let last = $0.indices.last, $0[last].end == nil { $0[last].end = host } }
    }

    /// The parts of a buffer that fall outside every pause, each written as its own piece.
    func pieces(of buffer: AVAudioPCMBuffer, startingAt host: UInt64) -> [AVAudioPCMBuffer] {
        let paused = intervals.withLock { $0 }
        guard !paused.isEmpty else { return [buffer] }
        let frames = Int(buffer.frameLength)
        return Self.keptFrames(start: host, frameCount: frames, sampleRate: buffer.format.sampleRate,
                               paused: paused, ticksPerSecond: Self.ticksPerSecond)
            .compactMap { $0 == 0..<frames ? buffer : buffer.copy(of: $0) }
    }

    /// Frame ranges of a buffer starting at `start` that lie outside the paused intervals.
    static func keptFrames(start: UInt64, frameCount: Int, sampleRate: Double,
                           paused: [Interval], ticksPerSecond: Double) -> [Range<Int>] {
        func frame(at host: UInt64) -> Int {
            let seconds = (Double(host) - Double(start)) / ticksPerSecond
            return min(max(Int((seconds * sampleRate).rounded()), 0), frameCount)
        }
        var kept: [Range<Int>] = []
        var cursor = 0
        for interval in paused {
            let from = frame(at: interval.start)
            let to = interval.end.map(frame(at:)) ?? frameCount
            if from > cursor { kept.append(cursor..<from) }
            cursor = max(cursor, to)
        }
        if cursor < frameCount { kept.append(cursor..<frameCount) }
        return kept
    }
}

extension AVAudioPCMBuffer {
    /// A new buffer holding only the given frames; works for interleaved and planar data alike.
    func copy(of range: Range<Int>) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)) else { return nil }
        copy.frameLength = AVAudioFrameCount(range.count)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData + range.lowerBound * bytesPerFrame, range.count * bytesPerFrame)
        }
        return copy
    }
}
