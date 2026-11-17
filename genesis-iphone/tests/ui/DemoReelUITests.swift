import XCTest

/// A slow, choreographed run through the demo controller, for screen recording.
/// It checks nothing new and is skipped unless asked for:
///   TEST_RUNNER_GENESIS_DEMO_REEL=1 GENESIS_UI_TEST=testDemoReel scripts/test-ui.sh <simulator>
/// scripts/record-demo.sh runs it and records the simulator's screen.
extension ControllerUITests {
    @MainActor
    func testDemoReel() throws {
        guard ProcessInfo.processInfo.environment["GENESIS_DEMO_REEL"] == "1" else {
            throw XCTSkip("Recorded on request only; see scripts/record-demo.sh.")
        }
        continueAfterFailure = true
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = pad ? .landscapeLeft : .portrait
        app.launch()
        func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
        func key(_ slot: Int) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "C\(slot), ")).firstMatch
        }
        /// A press held long enough to see the cap sink and the light flare.
        func press(_ element: XCUIElement, hold: TimeInterval = 0.22, then wait: TimeInterval = 0.75) {
            guard element.exists, element.isHittable else { return }
            element.press(forDuration: hold); pause(wait)
        }
        let chat = app.descendants(matching: .any).matching(identifier: "Chat dial").firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        pause(1.6)

        // Each chat key recolors the whole deck.
        for slot in [2, 3, 4, 5, 6, 1] { press(key(slot)) }
        pause(0.4)

        // Turn the chat knob around its edge, then press it to open the chat it points at.
        func rim(_ angle: Double) -> XCUICoordinate {
            chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + 0.40 * cos(angle), dy: 0.42 + 0.34 * sin(angle)))
        }
        let quarter = Double.pi / 2
        for step in 0..<3 {
            let from = Double.pi + Double(step) * quarter
            rim(from).press(forDuration: 0.12, thenDragTo: rim(from + quarter), withVelocity: .slow, thenHoldForDuration: 0.15)
            pause(0.35)
        }
        chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        pause(1.0)

        // The same deck drives each agent app.
        for provider in ["Codex", "Muse", "Claude"] {
            let tab = app.buttons[provider]
            if tab.exists, tab.isHittable { tab.tap(); pause(1.1) }
        }
        press(key(3)); press(key(5))

        // Full screen.
        let fullscreen = app.buttons["controller.fullscreen"]
        if fullscreen.exists, fullscreen.isHittable {
            fullscreen.tap(); pause(1.4)
            for slot in [1, 2, 4, 6] { press(key(slot), then: 0.65) }
            let fullChat = app.descendants(matching: .any).matching(identifier: "Chat dial").firstMatch
            if fullChat.exists {
                let a = fullChat.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.50))
                let b = fullChat.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.08))
                a.press(forDuration: 0.12, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.15); pause(0.5)
                b.press(forDuration: 0.12, thenDragTo: a, withVelocity: .slow, thenHoldForDuration: 0.15); pause(0.5)
            }
            pause(0.6)
            let exit = app.buttons["controller.exitFullscreen"]
            if exit.exists, exit.isHittable { exit.tap(); pause(1.2) }
        }
        press(key(1)); pause(1.2)
    }
}
