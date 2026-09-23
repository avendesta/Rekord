import AppKit
import AVFoundation

/// Permission status and deep-links into System Settings > Privacy & Security.
enum PermissionsManager {
    enum Issue {
        case microphone
        case systemAudio

        var settingsURL: URL {
            switch self {
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .systemAudio:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
            }
        }
    }

    static var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    static func openSettings(for issue: Issue) {
        NSWorkspace.shared.open(issue.settingsURL)
    }
}
