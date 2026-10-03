import AVFoundation

/// The moving part of playback, kept apart so only the scrubber redraws as time passes.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var time: TimeInterval = 0
}

/// One player for the whole Recordings window: starting a recording stops whichever was playing.
@MainActor
final class PlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// The recording whose playback controls are showing (playing or paused).
    @Published private(set) var activeID: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    let clock = PlaybackClock()

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Plays or pauses the recording; a different recording replaces the current one.
    func toggle(_ recording: Recording) {
        if activeID == recording.id, let player {
            player.isPlaying ? pause() : resume()
            return
        }
        stop()
        guard let url = recording.playableURL,
              let player = try? AVAudioPlayer(contentsOf: url), player.duration > 0 else { return }
        player.delegate = self
        self.player = player
        activeID = recording.id
        duration = player.duration
        resume()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), max(0, duration - 0.05))
        clock.time = player.currentTime
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        activeID = nil
        isPlaying = false
        duration = 0
        clock.time = 0
    }

    private func resume() {
        guard let player else { return }
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.clock.time = player.currentTime
            }
        }
    }

    private func pause() {
        player?.pause()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        clock.time = player?.currentTime ?? 0
    }

    // Reaching the end returns the row to Play, at the start, with its controls put away.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
