import SwiftUI

@main
struct RekordApp: App {
    @StateObject private var session: RecordingSession
    @StateObject private var store = RecordingStore()
    @StateObject private var hotkeyPopup: HotkeyPopupController

    init() {
        let session = RecordingSession()
        _session = StateObject(wrappedValue: session)
        _hotkeyPopup = StateObject(wrappedValue: HotkeyPopupController(session: session))
        #if DEBUG
        print("[Rekord] MenuBarExtra loaded")
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(session: session, store: store, hotkeyError: hotkeyPopup.registrationError)
        } label: {
            Image(nsImage: Self.menuBarIcon(recording: session.isRecording))
        }
        .menuBarExtraStyle(.window)

        Window("Recordings", id: "recordings") {
            RecordingsWindowView(store: store)
        }
        .defaultSize(width: 440, height: 480)

        Window("Rekord Settings", id: "settings") {
            SettingsView(hotkey: hotkeyPopup)
        }
        .windowResizability(.contentSize)
    }

    /// Ring + dot drawn by hand: the ring follows the menu bar's text colour, and the
    /// dot turns red while recording. The drawing handler runs per appearance, so it
    /// stays correct on light and dark menu bars (a template image can't be part-red).
    private static func menuBarIcon(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ringWidth: CGFloat = 1.5
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1 + ringWidth / 2, dy: 1 + ringWidth / 2))
            ring.lineWidth = ringWidth
            NSColor.labelColor.setStroke()
            ring.stroke()

            (recording ? NSColor.systemRed : NSColor.labelColor).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Rekord"
        return image
    }
}
