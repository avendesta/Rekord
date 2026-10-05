import AppKit
import AVFoundation
import Foundation

/// Coordinates a recording: creates the timestamped session folder, starts the
/// system-audio recorder (always) and the mic recorder (optional), and writes
/// `session.json` on stop.
@MainActor
final class RecordingSession: ObservableObject {
    enum State: Equatable {
        case idle
        /// Waiting on the microphone permission prompt.
        case starting
        /// `since` is the moment the timer counts from: the start, moved later by any paused time.
        case recording(since: Date)
        /// Still the same recording; `recorded` is how much has been captured so far.
        case paused(recorded: TimeInterval)
    }

    struct Metadata: Codable {
        var startDate: Date
        var durationSeconds: Double
        var includeMicrophone: Bool
        var files: [String]
        var systemSampleRate: Double
        var micSampleRate: Double?
        /// Seconds the mic's first buffer arrived after the system tap's first
        /// buffer (negative = mic started earlier). Used by Combine to align tracks.
        var micOffsetSeconds: Double?
        /// A name the user gave the recording. Display only: files and folders keep their names.
        var name: String? = nil
        /// The one app the system track was recorded from; nil when it holds everything the Mac played.
        var sourceApp: String? = nil

        /// The recording's `session.json`.
        static func read(from folder: URL) throws -> Metadata {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Metadata.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
        }

        func write(to folder: URL) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        }
    }

    @Published private(set) var state: State = .idle

    /// True from start to stop, including while paused.
    var isRecording: Bool {
        switch state {
        case .recording, .paused: return true
        case .idle, .starting: return false
        }
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }
    @Published private(set) var lastError: String?
    /// Per-recording toggle; the persisted default arrives with AppSettings in a later phase.
    @Published var includeMicrophone = AppSettings.includeMicrophoneDefault
    /// Set when a failure needs the user to change a privacy setting; the UI offers a deep-link.
    @Published private(set) var permissionIssue: PermissionsManager.Issue?

    init() {
        // Quit paths other than the menu button (Cmd+Q, logout) must still finalize files.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// True when a recording has produced no system audio for a while: usually a missing permission.
    @Published private(set) var systemSilenceWarning = false

    private var silenceMonitor: Task<Void, Never>?
    private static let silenceGraceSeconds = 8

    private let systemRecorder = SystemAudioRecorder()
    private let micRecorder = MicRecorder()
    private var activeIncludesMic = false
    /// Name of the one app the current recording captures; nil when it captures everything.
    private(set) var activeSourceApp: String?
    private var startedAt = Date()
    private let pauseGate = PauseGate()
    private(set) var lastSessionFolder: URL?

    /// `includeMicrophone` overrides the menu toggle for this one recording (used by the hotkey popup).
    func start(includeMicrophone override: Bool? = nil) {
        guard state == .idle else { return }
        let wantsMic = override ?? includeMicrophone

        guard wantsMic else {
            beginRecording(includeMic: false)
            return
        }
        state = .starting
        lastError = nil
        permissionIssue = nil
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.state = .idle
                    self.permissionIssue = .microphone
                    self.lastError = "Microphone access denied. Grant it in System Settings > Privacy & Security > Microphone, or turn the microphone off."
                    return
                }
                self.beginRecording(includeMic: true)
            }
        }
    }

    private func beginRecording(includeMic: Bool) {
        guard state == .idle || state == .starting else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = AppSettings.outputFolder
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lastError = "Failed to create recording folder: \(error.localizedDescription)"
            state = .idle
            return
        }

        pauseGate.reset()
        systemRecorder.pauseGate = pauseGate
        micRecorder.pauseGate = pauseGate
        let source = AppSettings.audioSourceBundleID
        let sourceName = source.map(AudioSourceApps.name(forBundleID:))
        do {
            try systemRecorder.start(to: folder.appendingPathComponent("system.caf"), sourceBundleID: source)
            if includeMic {
                try micRecorder.start(to: folder.appendingPathComponent("mic.caf"))
            }
        } catch {
            // Never leave a partial session behind: stop whatever started and drop the folder.
            systemRecorder.stop()
            micRecorder.stop()
            try? FileManager.default.removeItem(at: folder)
            if case SystemAudioRecorder.RecorderError.tapCreationFailed = error { permissionIssue = .systemAudio }
            if case SystemAudioRecorder.RecorderError.sourceAppNotRunning = error, let sourceName {
                // Never fall back to recording everything: the user asked for this app only.
                lastError = "\(sourceName) isn't running. Open it, or set Source to All Audio."
            } else {
                lastError = "Failed to start recording: \(error.localizedDescription)"
            }
            state = .idle
            return
        }

        activeIncludesMic = includeMic
        activeSourceApp = sourceName
        lastSessionFolder = folder
        lastError = nil
        permissionIssue = nil
        startedAt = Date()
        state = .recording(since: startedAt)
        // Written now and again on stop, so a recording cut short by a crash or a force quit is
        // still listed; the store works out its length from the audio.
        try? metadata(duration: 0).write(to: folder)
        startSilenceMonitor()
        #if DEBUG
        print("[Rekord] Recording started in \(folder.path) (mic: \(includeMic))")
        #endif
    }

    /// Keeps the recording open but leaves out everything until `resume()`. Both tracks skip
    /// exactly the same stretch, so they stay in step and the result is still one recording.
    func pause() {
        guard case .recording(let since) = state else { return }
        pauseGate.pause()
        systemSilenceWarning = false
        state = .paused(recorded: Date().timeIntervalSince(since))
    }

    func resume() {
        guard case .paused(let recorded) = state else { return }
        pauseGate.resume()
        state = .recording(since: Date().addingTimeInterval(-recorded))
    }

    func stop() {
        let recorded: TimeInterval
        switch state {
        case .recording(let since): recorded = Date().timeIntervalSince(since)
        case .paused(let soFar): recorded = soFar
        case .idle, .starting: return
        }
        silenceMonitor?.cancel()
        systemSilenceWarning = false
        UserDefaults.standard.set(systemRecorder.sawAudio ? "yes" : "no", forKey: AppSettings.systemAudioSeenKey)
        systemRecorder.stop()
        micRecorder.stop()
        state = .idle

        guard let folder = lastSessionFolder else { return }
        let metadata = metadata(duration: recorded)  // paused time is not part of the recording
        do {
            try metadata.write(to: folder)
        } catch {
            lastError = "Recording saved, but session.json failed: \(error.localizedDescription)"
        }
        #if DEBUG
        print("[Rekord] Recording stopped, session at \(folder.path), mic offset: \(String(describing: metadata.micOffsetSeconds))")
        #endif
    }

    private func metadata(duration: TimeInterval) -> Metadata {
        Metadata(
            startDate: startedAt,
            durationSeconds: duration,
            includeMicrophone: activeIncludesMic,
            files: ["system.caf"] + (activeIncludesMic ? ["mic.caf"] : []),
            systemSampleRate: systemRecorder.sampleRate,
            micSampleRate: activeIncludesMic ? micRecorder.sampleRate : nil,
            micOffsetSeconds: micOffset(),
            sourceApp: activeSourceApp
        )
    }

    /// After a grace period, flags silence; clears the flag as soon as audio shows up,
    /// so starting a recording before a meeting begins isn't reported as a failure.
    private func startSilenceMonitor() {
        silenceMonitor?.cancel()
        silenceMonitor = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.silenceGraceSeconds))
            while !Task.isCancelled {
                guard let self else { return }
                self.systemSilenceWarning = !self.isPaused && !self.systemRecorder.sawAudio
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func micOffset() -> Double? {
        guard activeIncludesMic,
              let sys = systemRecorder.firstBufferHostTime,
              let mic = micRecorder.firstBufferHostTime else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(mic) - Double(sys)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}
