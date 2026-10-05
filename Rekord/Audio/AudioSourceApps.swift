import AppKit
import CoreAudio

/// Lists the apps that can be recorded on their own, and finds the Core Audio processes that
/// play an app's audio. Apps often play through helper processes whose bundle IDs don't follow
/// the app's (Zoom is `us.zoom.xos`, its audio host `us.zoom.aomhost`), so a helper is matched
/// by where its executable lives.
enum AudioSourceApps {
    struct App: Identifiable, Hashable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    // Safari plays through `com.apple.WebKit.GPU`, a system process outside its bundle that
    // can't be told apart from other apps' copies, so recording it alone would come out silent.
    private static let unsupported: Set<String> = ["com.apple.Safari"]

    /// Running apps that have an audio process right now, by name.
    static func all() -> [App] {
        let processes = audioProcesses()
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> App? in
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier, !unsupported.contains(bundleID),
                  processes.contains(where: { belongs($0, to: app) })
            else { return nil }
            return App(bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
        return Set(apps).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The app's own audio process and those of the helpers inside its bundle. Empty when the app isn't running.
    static func processObjects(forBundleID bundleID: String) -> [AudioObjectID] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else { return [] }
        return audioProcesses().filter { process in apps.contains { belongs(process, to: $0) } }.map(\.id)
    }

    /// The app's name, also when it isn't running.
    static func name(forBundleID bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent
            ?? bundleID
    }

    static func owns(bundlePath: String, executablePath: String) -> Bool {
        executablePath.hasPrefix(bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/")
    }

    private typealias AudioProcess = (id: AudioObjectID, pid: pid_t, path: String)

    private static func belongs(_ process: AudioProcess, to app: NSRunningApplication) -> Bool {
        if process.pid == app.processIdentifier { return true }
        guard let bundlePath = app.bundleURL?.path else { return false }
        return owns(bundlePath: bundlePath, executablePath: process.path)
    }

    /// Every process Core Audio knows about, with the path of its executable.
    private static func audioProcesses() -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { return nil }
            // Without a path the process can still be matched by PID, as the app itself.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let hasPath = proc_pidpath(pid, &path, UInt32(path.count)) > 0
            return (id, pid, hasPath ? String(cString: path) : "")
        }
    }
}
