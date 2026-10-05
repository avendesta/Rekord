import SwiftUI

@main
struct RekordApp: App {
    @StateObject private var session: RecordingSession
    @StateObject private var store: RecordingStore
    @StateObject private var hotkeyPopup: HotkeyPopupController

    init() {
        let session = RecordingSession()
        _session = StateObject(wrappedValue: session)
        let store = RecordingStore()
        store.follow(session)
        _store = StateObject(wrappedValue: store)
        _hotkeyPopup = StateObject(wrappedValue: HotkeyPopupController(session: session))
        #if DEBUG
        print("[Rekord] MenuBarExtra loaded")
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(session: session, store: store, hotkeyError: hotkeyPopup.registrationError)
                .background(TooltipsWhenInactive())
        } label: {
            Image(nsImage: Self.menuBarIcon(recording: session.isRecording, warning: session.systemSilenceWarning, paused: session.isPaused))
        }
        .menuBarExtraStyle(.window)

        Window("Recordings", id: "recordings") {
            RecordingsWindowView(store: store, session: session)
                .background(TooltipsWhenInactive())
        }
        .defaultSize(width: 480, height: 340)

        Window("Rekord Settings", id: "settings") {
            SettingsView(hotkey: hotkeyPopup, store: store, session: session)
                .background(TooltipsWhenInactive())
        }
        .windowResizability(.contentSize)
    }

    /// Ring + dot drawn by hand: the ring follows the menu bar's text colour, and the
    /// dot turns red while recording, or orange while recording with no system audio arriving
    /// (usually a missing permission). The drawing handler runs per appearance, so it
    /// stays correct on light and dark menu bars (a template image can't be part-red).
    private static func menuBarIcon(recording: Bool, warning: Bool, paused: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ringWidth: CGFloat = 1.5
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1 + ringWidth / 2, dy: 1 + ringWidth / 2))
            ring.lineWidth = ringWidth
            NSColor.labelColor.setStroke()
            ring.stroke()

            (recording ? (warning ? NSColor.systemOrange : NSColor.systemRed) : NSColor.labelColor).setFill()
            if paused {
                // Two bars in place of the dot: paused is told by shape, not only by colour.
                for x in [6.25, 9.75] { NSBezierPath(rect: NSRect(x: x, y: 5.5, width: 2, height: 7)).fill() }
            } else {
                NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5)).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = paused ? "Rekord, paused" : recording ? (warning ? "Rekord, recording, no system audio" : "Rekord, recording") : "Rekord"
        return image
    }
}

/// A menu bar app's windows often show while another app is still the active one, and macOS
/// shows no tooltips in an inactive app unless the window asks for them.
private struct TooltipsWhenInactive: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowFinder() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowFinder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.allowsToolTipsWhenApplicationIsInactive = true
        }
    }
}
