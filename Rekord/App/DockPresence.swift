import AppKit

/// Rekord is a menu bar app, with no Dock icon and no place in Cmd+Tab. While one of its windows is
/// open it becomes an ordinary app, so the window can be found again from the Dock or with Cmd+Tab,
/// and it goes back to the menu bar once the last window closes.
@MainActor
final class DockPresence {
    static let shared = DockPresence { policy in
        NSApp.setActivationPolicy(policy)
        // Changing the policy can leave the window behind the app that was in front.
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    private var open: Set<String> = []
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void

    init(setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void) {
        self.setPolicy = setPolicy
    }

    /// A window is showing. Safe to call again for one that is already counted.
    func opened(_ window: String) {
        let wasEmpty = open.isEmpty
        guard open.insert(window).inserted, wasEmpty else { return }
        setPolicy(.regular)
    }

    func closed(_ window: String) {
        guard open.remove(window) != nil, open.isEmpty else { return }
        setPolicy(.accessory)
    }
}
