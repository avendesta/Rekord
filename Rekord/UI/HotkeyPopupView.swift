import SwiftUI

struct HotkeyPopupView: View {
    @ObservedObject var session: RecordingSession
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            switch session.state {
            case .idle:
                Text("Start recording")
                    .font(.headline)
                Button("System audio only") {
                    session.start(includeMicrophone: false)
                    dismiss()
                }
                Button("System audio + microphone") {
                    session.start(includeMicrophone: true)
                    dismiss()
                }
                if PermissionsManager.microphoneDenied {
                    Text("Microphone access is denied.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Open Privacy Settings…") { PermissionsManager.openSettings(for: .microphone) }
                }
            case .starting:
                Text("Starting recording…")
                    .font(.headline)
            case .recording(let since):
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(since))
                    Text(String(format: "Recording… %02d:%02d", seconds / 60, seconds % 60))
                        .font(.headline)
                        .foregroundStyle(.red)
                }
                if session.systemSilenceWarning {
                    SilenceWarningView()
                }
                Button("Stop") {
                    session.stop()
                    dismiss()
                }
            }
        }
        .padding(16)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        #if DEBUG
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange, lineWidth: 2)) // Phase 7 marker: hotkey fired
        #endif
    }
}

/// Borderless panel that can take key focus (for Esc) and closes on click-away.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func resignKey() {
        super.resignKey()
        close()
    }
}

/// Owns the global hotkey and the floating popup it summons.
@MainActor
final class HotkeyPopupController: ObservableObject {
    @Published private(set) var hotkey = AppSettings.hotkey
    @Published private(set) var registrationError: String?

    private let session: RecordingSession
    private var manager: HotkeyManager?
    private var panel: NSPanel?

    init(session: RecordingSession) {
        self.session = session
        manager = HotkeyManager { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
        if manager?.register(hotkey) == false { registrationError = unavailableMessage(for: hotkey) }
    }

    /// Switches to a new shortcut; if it can't be registered, the previous one is restored.
    func setHotkey(_ new: Hotkey) {
        let old = hotkey
        if manager?.register(new) == true {
            hotkey = new
            AppSettings.hotkey = new
            registrationError = nil
        } else {
            manager?.register(old)
            registrationError = unavailableMessage(for: new)
        }
    }

    /// Frees the shortcut while Settings is capturing a new one, so pressing the
    /// current combination isn't swallowed by the popup trigger.
    func suspend() { manager?.unregister() }
    func resume() { manager?.register(hotkey) }

    private func unavailableMessage(for hotkey: Hotkey) -> String {
        "Shortcut \(hotkey.display) is unavailable, another app is probably using it. Choose a different one in Settings."
    }

    private func toggle() {
        #if DEBUG
        print("[Rekord] Hotkey fired")
        #endif
        if let panel, panel.isVisible {
            panel.close()
        } else {
            show()
        }
    }

    private func show() {
        let hosting = NSHostingView(rootView: HotkeyPopupView(session: session) { [weak self] in
            self?.panel?.close()
        })
        let size = hosting.fittingSize

        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Just below the cursor, kept fully on the screen the cursor is on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrameOrigin(origin)

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }
}
