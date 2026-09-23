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
        case recording(since: Date)
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
    }

    @Published private(set) var state: State = .idle

    var isRecording: Bool {
        if case .recording = state { return true }
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

        do {
            try systemRecorder.start(to: folder.appendingPathComponent("system.caf"))
            if includeMic {
                try micRecorder.start(to: folder.appendingPathComponent("mic.caf"))
            }
        } catch {
            // Never leave a partial session behind: stop whatever started and drop the folder.
            systemRecorder.stop()
            micRecorder.stop()
            try? FileManager.default.removeItem(at: folder)
            if case SystemAudioRecorder.RecorderError.tapCreationFailed = error { permissionIssue = .systemAudio }
            lastError = "Failed to start recording: \(error.localizedDescription)"
            state = .idle
            return
        }

        activeIncludesMic = includeMic
        lastSessionFolder = folder
        lastError = nil
        permissionIssue = nil
        state = .recording(since: Date())
        startSilenceMonitor()
        #if DEBUG
        print("[Rekord] Recording started in \(folder.path) (mic: \(includeMic))")
        #endif
    }

    func stop() {
        guard case .recording(let since) = state else { return }
        silenceMonitor?.cancel()
        systemSilenceWarning = false
        systemRecorder.stop()
        micRecorder.stop()
        state = .idle

        guard let folder = lastSessionFolder else { return }
        let files = ["system.caf"] + (activeIncludesMic ? ["mic.caf"] : [])
        let metadata = Metadata(
            startDate: since,
            durationSeconds: Date().timeIntervalSince(since),
            includeMicrophone: activeIncludesMic,
            files: files,
            systemSampleRate: systemRecorder.sampleRate,
            micSampleRate: activeIncludesMic ? micRecorder.sampleRate : nil,
            micOffsetSeconds: micOffset()
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metadata).write(to: folder.appendingPathComponent("session.json"))
        } catch {
            lastError = "Recording saved, but session.json failed: \(error.localizedDescription)"
        }
        #if DEBUG
        print("[Rekord] Recording stopped, session at \(folder.path), mic offset: \(String(describing: metadata.micOffsetSeconds))")
        #endif
    }

    /// After a grace period, flags silence; clears the flag as soon as audio shows up,
    /// so starting a recording before a meeting begins isn't reported as a failure.
    private func startSilenceMonitor() {
        silenceMonitor?.cancel()
        silenceMonitor = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.silenceGraceSeconds))
            while !Task.isCancelled {
                guard let self else { return }
                self.systemSilenceWarning = !self.systemRecorder.sawAudio
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
