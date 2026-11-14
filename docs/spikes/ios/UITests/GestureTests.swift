// Spike I(a): real touches on the board. The app runs in `touch` mode (frame recorder armed at the first section at
// reading zoom); this test sends one-finger pans and pinch pairs (in, then out) through XCTest's event synthesis,
// which reaches the app as real touches. The pans start on a point of the board's ground that the app finds and
// shows in a tiny label ("groundPoint"), because a drag that starts on a card does not pan; four more pans start on
// the card under the centre to record that. Board from TEST_RUNNER_LINEN_BOARD (big-500 by default).
import XCTest

final class GestureTests: XCTestCase {
    func testPansAndPinches() throws {
        let env = ProcessInfo.processInfo.environment
        let board = env["LINEN_BOARD"] ?? "big-500"
        let pans = Int(env["LINEN_PANS"] ?? "20") ?? 20
        let pinches = Int(env["LINEN_PINCHES"] ?? "10") ?? 10
        let app = XCUIApplication()
        if env["LINEN_ATTACH"] == "1" {
            // The app was started in touch mode outside the test (so xctrace can attach to it first): do not relaunch.
            app.activate()
        } else {
            app.launchArguments = ["-LinenMode", "touch", "-LinenBoard", board]
            app.launch()
        }
        let label = app.staticTexts["groundPoint"]
        XCTAssertTrue(label.waitForExistence(timeout: 40))
        sleep(2)
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let parts = label.label.split(separator: ",").compactMap { Double($0) }
        let ground = parts.count == 2 ? origin.withOffset(CGVector(dx: parts[0], dy: parts[1])) : web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let moves: [CGVector] = [CGVector(dx: -150, dy: 0), CGVector(dx: 150, dy: 0), CGVector(dx: 0, dy: -180), CGVector(dx: 0, dy: 180)]
        // In pairs: out from the ground point, then back from where the finger lifted, which is the same board point
        // (a pan moves the board 1:1 with the finger), so every pan starts on the ground and each pair ends where it began.
        for i in 0..<pans {
            let m = moves[(i / 2) % moves.count]
            if i % 2 == 0 { ground.press(forDuration: 0.05, thenDragTo: ground.withOffset(m), withVelocity: 400, thenHoldForDuration: 0) }
            else { ground.withOffset(m).press(forDuration: 0.05, thenDragTo: ground, withVelocity: 400, thenHoldForDuration: 0) }
            usleep(900_000)
        }
        let centre = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for i in 0..<4 {
            centre.press(forDuration: 0.05, thenDragTo: centre.withOffset(moves[i % moves.count]), withVelocity: 400, thenHoldForDuration: 0)
            usleep(900_000)
        }
        for _ in 0..<pinches {
            web.pinch(withScale: 1.8, velocity: 1.2)
            usleep(900_000)
            web.pinch(withScale: 1 / 1.8, velocity: -1.2)
            usleep(900_000)
        }
        sleep(3) // the recorder's last write (every 2 s)
    }
}
