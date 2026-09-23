import Foundation

/// The two ways to start a recording from the shortcut popup.
enum RecordingMode: String, CaseIterable, Identifiable {
    case systemOnly
    case systemAndMicrophone

    var id: String { rawValue }
    var includesMicrophone: Bool { self == .systemAndMicrophone }

    var title: String {
        switch self {
        case .systemOnly: return "System Audio"
        case .systemAndMicrophone: return "System Audio + Microphone"
        }
    }

    var subtitle: String {
        switch self {
        case .systemOnly: return "Record audio from your Mac"
        case .systemAndMicrophone: return "Include your microphone"
        }
    }

    var symbol: String {
        switch self {
        case .systemOnly: return "speaker.wave.2.fill"
        case .systemAndMicrophone: return "mic.fill"
        }
    }

    /// Number key that starts this mode from the popup.
    var keyHint: String { self == .systemOnly ? "1" : "2" }
}
