import SwiftUI

/// Which row is highlighted, shared between the view (hover) and the controller (keyboard).
@MainActor
final class ShortcutChooserModel: ObservableObject {
    @Published var selected = AppSettings.lastRecordingMode
}

/// The popup summoned by the global shortcut: a fast audio-source chooser while idle,
/// and a compact Stop control when the shortcut is pressed during a recording.
struct HotkeyPopupView: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var model: ShortcutChooserModel
    let onChoose: (RecordingMode) -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch session.state {
            case .idle: chooser
            case .starting: startingContent
            case .recording(let since): recordingContent(since: since)
            }
        }
        .padding(8)
        .frame(width: 290)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    @ViewBuilder
    private var chooser: some View {
        header("Start Recording")
        ForEach(RecordingMode.allCases) { mode in
            let micDenied = mode.includesMicrophone && PermissionsManager.microphoneDenied
            ChooserRow(
                symbol: mode.symbol,
                title: mode.title,
                subtitle: micDenied ? "Microphone access is denied" : mode.subtitle,
                hint: mode.keyHint,
                isSelected: model.selected == mode,
                onHover: { model.selected = mode },
                action: { onChoose(mode) }
            )
        }
        footer("Esc to cancel")
    }

    private var startingContent: some View {
        Text("Starting recording…")
            .font(.subheadline)
            .padding(8)
    }

    @ViewBuilder
    private func recordingContent(since: Date) -> some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(since))
            header(String(format: "Recording · %02d:%02d", seconds / 60, seconds % 60))
        }
        if session.systemSilenceWarning {
            SilenceWarningView().padding(.horizontal, 8).padding(.bottom, 4)
        }
        ChooserRow(
            symbol: "stop.circle.fill",
            title: "Stop Recording",
            subtitle: "Save the recording",
            hint: "↩",
            isSelected: true,
            iconTint: .red,
            onHover: {},
            action: onStop
        )
        footer("Esc to close")
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 2)
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 8)
            .padding(.top, 2)
    }
}

/// A full-width selectable row. Only the selected/hovered row gets a background,
/// so the unselected ones blend into the popup.
private struct ChooserRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let hint: String
    let isSelected: Bool
    var iconTint: Color?
    let onHover: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .frame(width: 24)
                    .foregroundStyle(iconTint ?? (isSelected ? Color.accentColor : Color.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
    }
}

/// Borderless panel that can take key focus and closes on click-away or Esc.
private final class FloatingPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func resignKey() {
        super.resignKey()
        close()
    }
    override func close() {
        super.close()
        onClose?()
    }
}

/// Owns the global hotkey and the floating popup it summons.
@MainActor
final class HotkeyPopupController: ObservableObject {
    @Published private(set) var hotkey = AppSettings.hotkey
    @Published private(set) var registrationError: String?

    private let session: RecordingSession
    private var manager: HotkeyManager?
    private var panel: FloatingPanel?
    private var keyMonitor: Any?
    private let chooserModel = ShortcutChooserModel()

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
        chooserModel.selected = AppSettings.lastRecordingMode
        let hosting = NSHostingView(rootView: HotkeyPopupView(
            session: session,
            model: chooserModel,
            onChoose: { [weak self] mode in self?.choose(mode) },
            onStop: { [weak self] in self?.stopRecording() }
        ))
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
        panel.onClose = { [weak self] in self?.removeKeyMonitor() }
        panel.setFrameOrigin(origin(for: size))

        self.panel = panel
        // A local monitor, not view key handlers: it works regardless of which SwiftUI view has focus.
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? event }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Below-right of the cursor with a gap so the pointer doesn't cover the first row;
    /// flips to the left / above near screen edges so it always stays fully visible.
    private func origin(for size: NSSize) -> NSPoint {
        let gap: CGFloat = 14
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x + gap, y: mouse.y - gap - size.height)
        guard let visible = screen?.visibleFrame else { return origin }
        if origin.x + size.width > visible.maxX { origin.x = mouse.x - gap - size.width }
        if origin.y < visible.minY { origin.y = mouse.y + gap }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
    }

    private func choose(_ mode: RecordingMode) {
        AppSettings.lastRecordingMode = mode
        panel?.close()
        session.start(includeMicrophone: mode.includesMicrophone)
    }

    private func stopRecording() {
        panel?.close()
        session.stop()
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 1 / 2 start a mode, arrows move, Return starts the selection, Esc cancels.
    /// Returns nil for keys it consumed.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel?.isVisible == true,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
        let isReturn = event.keyCode == 36 || event.keyCode == 76 // Return, keypad Enter
        if event.keyCode == 53 { // Esc
            panel?.close()
            return nil
        }
        switch session.state {
        case .idle:
            switch event.keyCode {
            case 18, 83: choose(.systemOnly) // 1
            case 19, 84: choose(.systemAndMicrophone) // 2
            case 126: chooserModel.selected = .systemOnly // up
            case 125: chooserModel.selected = .systemAndMicrophone // down
            case _ where isReturn: choose(chooserModel.selected)
            default: return event
            }
            return nil
        case .recording where isReturn:
            stopRecording()
            return nil
        default:
            return event
        }
    }
}
