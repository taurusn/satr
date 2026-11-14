import XCTest

/// A one-finger drag that starts on a card pans the board on the phone (spike I(a) finding 1; the renderer change in
/// Renderer/board.js). The app, launched with `-LinenProbe`, reports the board's view and the centre of a card that
/// is really under that point (`document.elementFromPoint`) in a tiny label the test reads.
final class BoardPanTests: XCTestCase {
    private struct Probe: Decodable {
        var tx: Double
        var ty: Double
        var s: Double
        var mode: String
        var level: String
        var card: [Double]?
    }

    private func probe(_ app: XCUIApplication) throws -> Probe {
        let label = app.staticTexts["probe"]
        XCTAssertTrue(label.waitForExistence(timeout: 20))
        return try JSONDecoder().decode(Probe.self, from: Data(label.label.utf8))
    }

    /// Waits until the probe shows a board in Canvas with a card in reach.
    private func settled(_ app: XCUIApplication, _ ok: (Probe) -> Bool) throws -> Probe {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let p = try? probe(app), ok(p) { return p }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return try probe(app)
    }

    func testDragStartingOnACardPansTheBoard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-LinenOpen", "fixtures-boards/big-500.canvas", "-LinenProbe", "-appearance", "paper"]
        app.launch()

        let canvas = app.segmentedControls["mode"].buttons["Canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        canvas.tap()
        let before = try settled(app) { $0.mode == "canvas" && $0.card != nil }
        let card = try XCTUnwrap(before.card, "no card under a point in view")
        XCTAssertEqual(before.mode, "canvas")

        let web = app.webViews["renderer"]
        XCTAssertTrue(web.exists)
        let origin = web.frame.origin
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: origin.x + card[0], dy: origin.y + card[1]))
        let end = start.withOffset(CGVector(dx: -150, dy: -60))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 400, thenHoldForDuration: 0.1)

        let after = try settled(app) { abs($0.tx - before.tx) > 20 }
        XCTAssertEqual(after.tx - before.tx, -150, accuracy: 30, "the board did not follow a drag that started on a card")
        XCTAssertEqual(after.ty - before.ty, -60, accuracy: 30)
        XCTAssertEqual(after.s, before.s, accuracy: 0.001, "a pan must not zoom")
    }
}
