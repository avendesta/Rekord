import AppKit
import XCTest
@testable import Rekord

@MainActor
final class DockPresenceTests: XCTestCase {
    private func make() -> (DockPresence, () -> [NSApplication.ActivationPolicy]) {
        var calls: [NSApplication.ActivationPolicy] = []
        return (DockPresence { calls.append($0) }, { calls })
    }

    func testTheFirstWindowMakesRekordAnOrdinaryAppAndTheLastOneTakesItBack() {
        let (dock, calls) = make()
        dock.opened("recordings")
        XCTAssertEqual(calls(), [.regular])
        dock.opened("settings")      // a second window changes nothing
        dock.closed("recordings")    // one is still open
        XCTAssertEqual(calls(), [.regular])
        dock.closed("settings")
        XCTAssertEqual(calls(), [.regular, .accessory])
    }

    func testRepeatsAndStrangersAreIgnored() {
        let (dock, calls) = make()
        dock.closed("recordings")    // never opened
        dock.opened("recordings")
        dock.opened("recordings")    // already counted
        XCTAssertEqual(calls(), [.regular])
        dock.closed("recordings")
        dock.closed("recordings")
        XCTAssertEqual(calls(), [.regular, .accessory])
    }
}
