import Foundation
import os

/// Breadcrumbs for finding out where the app got stuck. Each step goes to the unified log, and a
/// watchdog reports when the main thread stops answering, naming the step it was in. Read with:
///   log show --last 1h --predicate 'subsystem == "com.avendesta.rekord"'
enum Diagnostics {
    static let log = Logger(subsystem: "com.avendesta.rekord", category: "diagnostics")

    private static let state = OSAllocatedUnfairLock(
        initialState: (step: "launch", since: Date(), beat: Date(), reported: false))
    private static var watchdog: DispatchSourceTimer?

    /// Marks what the app is about to do. Names say what, never whose audio: no paths or content.
    static func step(_ name: String) {
        let previous = state.withLock { state -> (String, TimeInterval) in
            let previous = (state.step, Date().timeIntervalSince(state.since))
            state.step = name
            state.since = Date()
            return previous
        }
        log.notice("step: \(name, privacy: .public) (after \(previous.0, privacy: .public), \(previous.1, format: .fixed(precision: 3)) s)")
    }

    /// Checks once a second that the main thread still answers; says so when it hasn't for 3 seconds.
    static func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.avendesta.rekord.watchdog", qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            DispatchQueue.main.async {
                let stuckFor = state.withLock { state -> TimeInterval? in
                    defer { state.beat = Date(); state.reported = false }
                    return state.reported ? Date().timeIntervalSince(state.beat) : nil
                }
                if let stuckFor { log.fault("main thread answering again after \(stuckFor, format: .fixed(precision: 1)) s") }
            }
            let stuck = state.withLock { state -> (String, TimeInterval)? in
                let silent = Date().timeIntervalSince(state.beat)
                guard silent > 3, !state.reported else { return nil }
                state.reported = true
                return (state.step, silent)
            }
            if let stuck {
                log.fault("main thread stuck for \(stuck.1, format: .fixed(precision: 1)) s, last step: \(stuck.0, privacy: .public)")
            }
        }
        timer.resume()
        watchdog = timer
    }
}
