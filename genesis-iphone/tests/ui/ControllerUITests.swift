import XCTest

final class ControllerUITests: XCTestCase {
    @MainActor
    func testFullscreenPreservesDraftRouteAndFollow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-follow"]
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        app.launch()
        let enter = app.buttons["controller.fullscreen"]
        XCTAssertTrue(enter.waitForExistence(timeout: 8))
        // Changing the host intentionally stops Follow. Keep its current route
        // here; the separate menu test exercises actual route changes.
        let selectedComputer = ["Mini 1", "Mini 2", "Neo"].first { app.buttons[$0].isSelected } ?? "missing"
        XCTAssertNotEqual(selectedComputer, "missing")
        XCTAssertTrue(app.buttons["Claude"].isSelected)
        app.buttons["Start dictation"].press(forDuration: 1.0)
        let draft = app.textFields["controller.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 3))
        let retainedDraft = draft.value as? String
        XCTAssertEqual(retainedDraft, "Show me the latest changes and what still needs attention.")

        let chat = app.descendants(matching: .any).matching(identifier: "Chat dial").firstMatch
        let beforeBrowse = chat.value as? String
        let top = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.17))
        let right = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.45))
        top.press(forDuration: 0.10, thenDragTo: right)
        let browsed = chat.value as? String
        XCTAssertNotEqual(browsed, beforeBrowse)
        XCTAssertEqual((app.buttons[browsed ?? "missing"].value as? String)?.hasSuffix("Dial selection"), true)
        saveFullscreenScreenshot("Before full screen, browsed dial")

        enter.tap()
        let exit = app.buttons["controller.exitFullscreen"]
        XCTAssertTrue(exit.waitForExistence(timeout: 3))
        assertFullscreenGeometry(app)
        XCTAssertEqual(app.buttons["controller.chooseComputer"].value as? String, selectedComputer)
        XCTAssertEqual(app.buttons["controller.chooseProvider"].value as? String, "Claude")
        XCTAssertEqual(chat.value as? String, browsed, "Entering full screen preserves an unopened dial selection")
        XCTAssertEqual((app.buttons[browsed ?? "missing"].value as? String)?.hasSuffix("Dial selection"), true)
        XCTAssertTrue(app.buttons["controller.sendDraft"].isEnabled, "The reviewed Claude draft remains ready without sending it")
        saveFullscreenScreenshot("Full screen, retained dial and draft")

        app.buttons["controller.reviewDraft"].tap()
        XCTAssertTrue(app.navigationBars["Review draft"].waitForExistence(timeout: 3))
        XCTAssertEqual(draft.value as? String, retainedDraft)
        app.navigationBars["Review draft"].buttons["Done"].tap()
        XCTAssertTrue(exit.waitForExistence(timeout: 3))
        XCTAssertTrue(exit.isHittable, "Done closes the draft drawer without leaving full screen")

        app.buttons["controller.glasses"].tap()
        XCTAssertTrue(app.navigationBars["Glasses"].waitForExistence(timeout: 3))
        let follow = app.switches["glasses.enabled"]
        XCTAssertTrue(follow.exists)
        XCTAssertEqual(follow.value as? String, "1", "Opening a drawer does not stop existing Follow")
        app.navigationBars["Glasses"].buttons["Done"].tap()
        XCTAssertTrue(exit.waitForExistence(timeout: 3))
        XCTAssertTrue(exit.isHittable, "Done closes the glasses drawer")
        XCTAssertEqual(chat.value as? String, browsed)

        exit.tap()
        XCTAssertTrue(enter.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons[selectedComputer].isSelected)
        XCTAssertTrue(app.buttons["Claude"].isSelected)
        XCTAssertEqual(draft.value as? String, retainedDraft, "Exiting never clears or sends the draft")
        XCTAssertEqual(chat.value as? String, browsed)
        XCTAssertEqual((app.buttons[browsed ?? "missing"].value as? String)?.hasSuffix("Dial selection"), true)
        saveFullscreenScreenshot("After full screen, same dial angle and draft")

        // Reentering exercises both branches a second time; Follow is the same
        // observed controller, not a newly created presentation-only session.
        enter.tap()
        XCTAssertTrue(exit.waitForExistence(timeout: 3))
        app.buttons["controller.glasses"].tap()
        XCTAssertTrue(app.navigationBars["Glasses"].waitForExistence(timeout: 3))
        XCTAssertEqual(follow.value as? String, "1")
        app.navigationBars["Glasses"].buttons["Done"].tap()
        app.buttons["controller.reviewDraft"].tap()
        XCTAssertTrue(app.navigationBars["Review draft"].waitForExistence(timeout: 3))
        XCTAssertEqual(draft.value as? String, retainedDraft)
        app.navigationBars["Review draft"].buttons["Done"].tap()
        exit.tap()
    }

    @MainActor
    func testFullscreenRouteMenusKeepDraftsSeparate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        app.launch()
        XCTAssertTrue(app.buttons["controller.fullscreen"].waitForExistence(timeout: 8))
        app.buttons["controller.fullscreen"].tap()
        XCTAssertTrue(app.buttons["controller.chooseComputer"].waitForExistence(timeout: 3))
        chooseFullscreenRoute(app, menu: "controller.chooseComputer", option: "Mini 1")
        XCTAssertEqual(app.buttons["controller.chooseProvider"].value as? String, "Claude")
        app.buttons["Start dictation"].press(forDuration: 1.0)
        let retained = "Show me the latest changes and what still needs attention."
        assertFullscreenDraft(app, expected: retained)

        for computer in ["Mini 2", "Neo"] {
            chooseFullscreenRoute(app, menu: "controller.chooseComputer", option: computer)
            XCTAssertEqual(app.buttons["controller.chooseProvider"].value as? String, "Claude")
            assertFullscreenDraft(app, expected: nil)
            XCTAssertFalse(app.buttons["controller.sendDraft"].isEnabled, "A different Mac cannot inherit a ready draft")
        }
        chooseFullscreenRoute(app, menu: "controller.chooseComputer", option: "Mini 1")
        assertFullscreenDraft(app, expected: retained)
        XCTAssertTrue(app.buttons["controller.sendDraft"].isEnabled)

        chooseFullscreenRoute(app, menu: "controller.chooseProvider", option: "Codex")
        XCTAssertEqual(app.buttons["controller.chooseComputer"].value as? String, "Mini 1")
        assertFullscreenDraft(app, expected: nil)
        XCTAssertFalse(app.buttons["controller.sendDraft"].isEnabled, "Demo Codex remains draft-only")
        chooseFullscreenRoute(app, menu: "controller.chooseProvider", option: "Claude")
        assertFullscreenDraft(app, expected: retained)
        XCTAssertTrue(app.buttons["controller.sendDraft"].isEnabled)
        XCTAssertFalse(app.alerts["Controller update"].exists)
        app.buttons["controller.exitFullscreen"].tap()
        XCTAssertTrue(app.buttons["controller.fullscreen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Mini 1"].isSelected)
        XCTAssertTrue(app.buttons["Claude"].isSelected)
        XCTAssertEqual(app.textFields["controller.draft"].value as? String, retained)
    }

    @MainActor
    private func chooseFullscreenRoute(_ app: XCUIApplication, menu: String, option: String) {
        let control = app.buttons[menu]
        control.tap()
        let item = app.buttons.matching(identifier: option).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), "\(option) is a selectable menu item")
        item.tap()
        let selected = NSPredicate { _, _ in (control.value as? String) == option }
        expectation(for: selected, evaluatedWith: control)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.buttons["controller.exitFullscreen"].isHittable, "Routing keeps the controller in full screen")
    }

    @MainActor
    private func assertFullscreenDraft(_ app: XCUIApplication, expected: String?) {
        app.buttons["controller.reviewDraft"].tap()
        XCTAssertTrue(app.navigationBars["Review draft"].waitForExistence(timeout: 3))
        let field = app.textFields["controller.draft"]
        XCTAssertTrue(field.exists)
        if let expected {
            XCTAssertEqual(field.value as? String, expected, "Returning to the exact route restores its unsent draft")
        } else {
            let value = field.value as? String ?? ""
            XCTAssertTrue(value.isEmpty || value == field.placeholderValue, "An untouched route has an empty draft, not text from another Mac or provider")
        }
        app.navigationBars["Review draft"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["controller.exitFullscreen"].isHittable)
    }

    @MainActor
    func testFullscreenIPadRotationPreservesDraft() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Fullscreen rotation coverage requires the iPad layout")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(app.buttons["controller.fullscreen"].waitForExistence(timeout: 8))
        waitForObservedOrientation(app, landscape: true)
        app.buttons["controller.fullscreen"].tap()
        XCTAssertTrue(app.buttons["controller.exitFullscreen"].waitForExistence(timeout: 3))
        let computer = app.buttons["controller.chooseComputer"].value as? String
        let provider = app.buttons["controller.chooseProvider"].value as? String
        app.buttons["Start dictation"].press(forDuration: 1.0)
        let retained = "Show me the latest changes and what still needs attention."
        assertFullscreenDraft(app, expected: retained)
        assertFullscreenGeometry(app)
        saveFullscreenScreenshot("Full screen before rotation")

        XCUIDevice.shared.orientation = .portrait
        waitForObservedOrientation(app, landscape: false)
        XCTAssertTrue(app.buttons["controller.exitFullscreen"].exists, "Rotation keeps full screen active")
        XCTAssertEqual(app.buttons["controller.chooseComputer"].value as? String, computer)
        XCTAssertEqual(app.buttons["controller.chooseProvider"].value as? String, provider)
        assertFullscreenGeometry(app)
        assertFullscreenDraft(app, expected: retained)
        saveFullscreenScreenshot("Full screen after portrait rotation")

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForObservedOrientation(app, landscape: true)
        XCTAssertEqual(app.buttons["controller.chooseComputer"].value as? String, computer)
        XCTAssertEqual(app.buttons["controller.chooseProvider"].value as? String, provider)
        assertFullscreenGeometry(app)
        assertFullscreenDraft(app, expected: retained)
        saveFullscreenScreenshot("Full screen after return to landscape")
        let exit = app.buttons["controller.exitFullscreen"]
        XCTAssertTrue(exit.isEnabled, "Rotation cannot leave layout transitions locked")
        exit.tap()
        XCTAssertTrue(app.buttons["controller.fullscreen"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["controller.draft"].value as? String, retained)
    }

    @MainActor
    private func waitForObservedOrientation(_ app: XCUIApplication, landscape: Bool) {
        // Check actual app bounds, not only the orientation requested from the
        // simulator: a rejected rotation must not count as portrait coverage.
        let observed = NSPredicate { _, _ in
            landscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width
        }
        expectation(for: observed, evaluatedWith: app)
        waitForExpectations(timeout: 8)
    }

    @MainActor
    func testFullscreenRecordingAndSendGuards() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        app.launch()
        let enter = app.buttons["controller.fullscreen"]
        XCTAssertTrue(enter.waitForExistence(timeout: 8))
        // Remapping the physical-style Send key must not remove the separate,
        // guarded draft Send button from full screen.
        mapDemoQuickKey(app, key: "Send", index: 1, action: "Model & effort")
        mapDemoQuickKey(app, key: "Voice", index: 3, action: "Hold to talk")
        XCTAssertTrue(app.buttons["Model"].exists)
        let dictate = app.buttons["Hold to talk"]
        XCTAssertTrue(dictate.exists)

        enter.tap()
        let exit = app.buttons["controller.exitFullscreen"]
        let send = app.buttons["controller.sendDraft"]
        XCTAssertTrue(exit.waitForExistence(timeout: 3))
        XCTAssertFalse(send.isEnabled, "An empty draft cannot be sent")
        assertFullscreenGeometry(app)
        exit.tap()
        XCTAssertTrue(enter.waitForExistence(timeout: 3))

        // A mapped Dictate toggle lets the test inspect the live capture gate
        // without using a real microphone or holding two simulator touches.
        dictate.tap()
        XCTAssertTrue(app.buttons["Stop dictation"].waitForExistence(timeout: 3))
        XCTAssertFalse(enter.isEnabled, "Layout changes are blocked while recording")
        dictate.tap()
        XCTAssertTrue(app.buttons["Start dictation"].waitForExistence(timeout: 3))
        XCTAssertTrue(enter.isEnabled)
        enter.tap()
        XCTAssertTrue(exit.waitForExistence(timeout: 3))
        XCTAssertTrue(send.isEnabled, "Dedicated Send survives remapping the quick key")

        dictate.tap()
        XCTAssertTrue(app.buttons["Stop dictation"].waitForExistence(timeout: 3))
        XCTAssertFalse(exit.isEnabled, "Leaving full screen cannot interrupt a capture")
        XCTAssertFalse(send.isEnabled, "A changing speech draft cannot be sent")
        XCTAssertFalse(app.buttons["controller.reviewDraft"].isEnabled)
        dictate.tap()
        XCTAssertTrue(app.buttons["Start dictation"].waitForExistence(timeout: 3))
        XCTAssertTrue(exit.isEnabled)
        XCTAssertTrue(send.isEnabled)
        app.buttons["controller.reviewDraft"].tap()
        XCTAssertTrue(app.navigationBars["Review draft"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["controller.draft"].value as? String,
                       "Show me the latest changes and what still needs attention.")
        app.navigationBars["Review draft"].buttons["Done"].tap()
        send.tap() // --demo never sends a host command.
        let disabled = NSPredicate { _, _ in send.exists && !send.isEnabled }
        expectation(for: disabled, evaluatedWith: send)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.staticTexts["Demo only — no prompt sent."].exists)
        XCTAssertTrue(app.buttons["Model"].exists)
        saveFullscreenScreenshot("Full screen, guarded Send after demo receipt")
    }

    @MainActor
    private func mapDemoQuickKey(_ app: XCUIApplication, key: String, index: Int, action: String) {
        app.buttons[key].press(forDuration: 0.8)
        XCTAssertTrue(app.navigationBars["Map quick key \(index)"].waitForExistence(timeout: 3))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText(action)
        let option = app.staticTexts[action]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
        XCTAssertTrue(app.buttons["controller.fullscreen"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func assertFullscreenGeometry(_ app: XCUIApplication) {
        let ids = ["controller.exitFullscreen", "controller.chooseComputer", "controller.chooseProvider",
                   "controller.reviewDraft", "controller.sendDraft", "controller.glasses"]
        for id in ids {
            let control = app.buttons[id]
            XCTAssertTrue(control.exists, "\(id) is present")
            XCTAssertTrue(control.isHittable, "\(id) is reachable without scrolling on this layout")
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX - 1, "\(id) stays inside the left edge")
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX + 1, "\(id) stays inside the right edge")
            XCTAssertGreaterThanOrEqual(control.frame.minY, app.frame.minY - 1, "\(id) stays inside the top edge")
            XCTAssertLessThanOrEqual(control.frame.maxY, app.frame.maxY + 1, "\(id) stays inside the bottom edge")
        }
        for id in ["Chat dial", "Artifact dial"] {
            let dial = app.descendants(matching: .any).matching(identifier: id).firstMatch
            XCTAssertTrue(dial.isHittable, "\(id) remains directly usable")
            XCTAssertGreaterThanOrEqual(dial.frame.width, 44)
            XCTAssertGreaterThanOrEqual(dial.frame.height, 44)
            XCTAssertGreaterThanOrEqual(dial.frame.minX, app.frame.minX - 1)
            XCTAssertLessThanOrEqual(dial.frame.maxX, app.frame.maxX + 1)
            XCTAssertGreaterThanOrEqual(dial.frame.minY, app.frame.minY - 1)
            XCTAssertLessThanOrEqual(dial.frame.maxY, app.frame.maxY + 1)
        }
    }

    @MainActor
    private func saveFullscreenScreenshot(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let orientation = XCUIDevice.shared.orientation.isLandscape ? "landscape" : "portrait"
        image.name = "\(device) \(orientation) · \(name)"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor
    func testFreshInstallOffersDemoAndCanLeaveIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // A brand-new install: nothing paired, nothing saved.
        app.launchArguments = ["--fresh-install"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let tryDemo = app.buttons["controller.tryDemo"]
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 8), "An unpaired install offers the demo")
        XCTAssertTrue(app.buttons["Pair a Mac"].firstMatch.exists, "Pairing stays the first choice")
        XCTAssertFalse(app.buttons["controller.exitDemo"].exists)
        saveFullscreenScreenshot("Fresh install, before pairing")

        tryDemo.tap()
        let exitDemo = app.buttons["controller.exitDemo"]
        XCTAssertTrue(exitDemo.waitForExistence(timeout: 5), "The demo always shows its way out")
        let chat = app.descendants(matching: .any).matching(identifier: "Chat dial").firstMatch
        XCTAssertEqual(chat.value as? String, "C1, Controller app", "The demo opens on sample chats")
        XCTAssertFalse(tryDemo.exists, "The demo does not offer itself again")
        app.buttons["C2, OMAC workspace"].tap()
        let opened = NSPredicate(format: "value CONTAINS %@", "Current chat")
        expectation(for: opened, evaluatedWith: app.buttons["C2, OMAC workspace"])
        waitForExpectations(timeout: 5)
        // Full screen keeps the way out in reach too.
        app.buttons["controller.fullscreen"].tap()
        XCTAssertTrue(app.buttons["controller.exitFullscreen"].waitForExistence(timeout: 3))
        XCTAssertTrue(exitDemo.isHittable, "Exit demo is reachable in full screen")
        saveFullscreenScreenshot("In-app demo, full screen")

        exitDemo.tap()
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 5), "Leaving the demo returns to the unpaired controller")
        XCTAssertFalse(exitDemo.exists)
        // The Settings route out works as well.
        tryDemo.tap()
        XCTAssertTrue(exitDemo.waitForExistence(timeout: 5))
        app.buttons["Settings and Mac pairing"].tap()
        let settingsExit = app.buttons["settings.exitDemo"]
        XCTAssertTrue(settingsExit.waitForExistence(timeout: 5))
        settingsExit.tap()
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 5), "Exit demo in Settings also returns to the unpaired controller")
    }

    @MainActor
    func testCheckThisMacShowsSelfCheckAndActivity() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["Settings and Mac pairing"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["controller.companionNotice"].exists, "The demo has no Mac to be out of date")
        XCTAssertFalse(app.buttons["controller.openApp"].exists, "Nothing to open while the sample apps are ready")
        app.buttons["Settings and Mac pairing"].tap()
        XCTAssertTrue(app.navigationBars["Your controller"].waitForExistence(timeout: 5))
        let link = app.buttons["settings.diagnostics"]
        for _ in 0..<6 where !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.isHittable, "Check this Mac can be reached in Settings")
        link.tap()
        let run = app.buttons["diagnostics.run"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Opened Design studio."].waitForExistence(timeout: 5), "Recent activity loads with the screen")
        XCTAssertFalse(app.staticTexts["diagnostics.summary"].exists, "No result is shown before a check is run")
        run.tap()
        let summary = app.staticTexts["diagnostics.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "1 of 8 checks needs attention: Codex – Menu controls.")
        XCTAssertTrue(app.staticTexts["This Mac"].exists && app.staticTexts["Claude"].exists, "Results are grouped by app")
        saveFullscreenScreenshot("Check this Mac, results")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Your controller"].waitForExistence(timeout: 5), "Back returns to Settings")
    }

    @MainActor
    func testGlassesSwitchHidesGlassesControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        app.launch()
        let settings = app.buttons["Settings and Mac pairing"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        let follow = app.switches["glasses.enabled"]
        XCTAssertTrue(follow.exists, "The demo starts with the glasses controls shown")
        func setGlasses(_ on: Bool) {
            settings.tap()
            let toggle = app.switches["settings.glasses"]
            XCTAssertTrue(app.navigationBars["Your controller"].waitForExistence(timeout: 5))
            // The switch sits below pairing, so it may start off-screen. On an iPad the
            // sheet is short: a switch that is only just showing at the sheet's bottom edge
            // counts as hittable, but a tap on it lands outside the sheet and closes it.
            let list = app.collectionViews.firstMatch
            func inReach() -> Bool {
                guard toggle.exists, toggle.isHittable else { return false }
                return !list.exists || toggle.frame.maxY <= list.frame.maxY - 28
            }
            for _ in 0..<10 where !inReach() {
                guard list.exists else { app.swipeUp(); continue }
                list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
                    .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38)))
            }
            XCTAssertTrue(inReach(), "The glasses switch can be reached in Settings")
            if (toggle.value as? String == "1") != on {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.50)).tap()
                let changed = NSPredicate { _, _ in (toggle.value as? String == "1") == on }
                expectation(for: changed, evaluatedWith: toggle)
                waitForExpectations(timeout: 3)
            }
            app.buttons["Done"].firstMatch.tap()
            XCTAssertTrue(app.buttons["controller.fullscreen"].waitForExistence(timeout: 3))
        }
        setGlasses(false)
        XCTAssertFalse(follow.exists, "Turning the switch off removes the Follow panel")
        app.buttons["controller.fullscreen"].tap()
        XCTAssertTrue(app.buttons["controller.exitFullscreen"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["controller.glasses"].exists, "Full screen has no Glasses button either")
        XCTAssertTrue(app.buttons["Actions"].isHittable, "The other tools stay usable without it")
        app.buttons["controller.exitFullscreen"].tap()
        XCTAssertTrue(app.buttons["controller.fullscreen"].waitForExistence(timeout: 3))
        setGlasses(true)
        XCTAssertTrue(follow.exists, "Turning it back on restores the Follow panel")
    }

    /// The deck theme is chosen in Settings and never touches what a chat key says about its chat.
    @MainActor
    func testDeckThemeCanBeChosen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let settings = app.buttons["Settings and Mac pairing"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["C5, Build notes"].value as? String, "Error")
        func choose(_ theme: String) {
            settings.tap()
            XCTAssertTrue(app.navigationBars["Your controller"].waitForExistence(timeout: 5))
            let row = app.buttons["settings.theme.\(theme)"]
            let list = app.collectionViews.firstMatch
            // Scroll until the row is well inside the sheet: a tap at its edge can land outside it.
            func inReach() -> Bool { row.exists && row.isHittable && (!list.exists || row.frame.maxY <= list.frame.maxY - 28) }
            for _ in 0..<14 where !inReach() {
                guard list.exists else { app.swipeUp(); continue }
                list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
                    .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38)))
            }
            XCTAssertTrue(inReach(), "The \(theme) theme can be reached in Settings")
            row.tap()
            let chosen = NSPredicate { _, _ in row.isSelected }
            expectation(for: chosen, evaluatedWith: row)
            waitForExpectations(timeout: 3)
            app.buttons["Done"].firstMatch.tap()
            XCTAssertTrue(app.buttons["controller.fullscreen"].waitForExistence(timeout: 3))
        }
        choose("sunset")
        XCTAssertEqual(app.buttons["C5, Build notes"].value as? String, "Error", "A theme does not change what a chat key reports")
        XCTAssertEqual(app.buttons["C2, OMAC workspace"].value as? String, "Done")
        choose("mono")
        XCTAssertEqual(app.buttons["C3, Design studio"].value as? String, "Needs input")
        // Leave the default behind for the tests and recordings that follow.
        choose("aurora")
    }

    @MainActor
    func testGlassesFollowPanel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-follow"]
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts["Agent Micro Controller"].waitForExistence(timeout: 8))
        let draft = app.buttons["glasses.draft"]
        for _ in 0..<8 {
            if draft.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(draft.isHittable, "Follow controls are reachable on the native controller screen")
        XCTAssertEqual(app.buttons["glasses.reply"].label, "Conversation", "The visible label describes the conversation while preserving the reply control identifier")
        let pageHelp = app.staticTexts["glasses.pageHelp"]
        XCTAssertTrue(pageHelp.exists)
        XCTAssertTrue(pageHelp.label.contains("right arrow shows older conversation text"))
        XCTAssertTrue(pageHelp.label.contains("Draft to page through your current draft"))
        XCTAssertGreaterThanOrEqual(pageHelp.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(pageHelp.frame.maxX, app.frame.maxX)
        let controls = ["glasses.reply", "glasses.draft", "glasses.home", "glasses.previous", "glasses.next", "glasses.refresh", "glasses.send"]
        for identifier in controls {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.exists, "\(identifier) is present")
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX, "\(identifier) stays inside the left edge")
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX, "\(identifier) stays inside the right edge")
            XCTAssertGreaterThanOrEqual(button.frame.height, 28, "\(identifier) has a usable touch target")
        }
        draft.tap()
        let next = app.buttons["glasses.next"]
        next.tap()
        XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 3))
        app.buttons["glasses.previous"].tap()
        XCTAssertTrue(app.staticTexts["Page 1 of 3"].exists)
        app.buttons["glasses.home"].tap()
        XCTAssertFalse(next.isEnabled, "Home view has no reply page controls")
        app.buttons["glasses.reply"].tap()
        XCTAssertTrue(next.isEnabled)
        app.buttons["glasses.refresh"].tap()
        XCTAssertTrue(app.staticTexts["Design preview · simulated glasses display"].exists)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = UIDevice.current.userInterfaceIdiom == .pad ? "G2 follow iPad landscape" : "G2 follow iPhone portrait"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor
    func testDialsAndRotation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let chat = app.descendants(matching: .any).matching(identifier: "Chat dial").firstMatch
        let artifact = app.descendants(matching: .any).matching(identifier: "Artifact dial").firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8))
        XCTAssertTrue(artifact.exists)

        let first = chat.value as? String
        XCTAssertEqual(first, "C1, Controller app")
        // A stroke up the knob's left side turns it clockwise by one slot.
        let top = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.50))
        let right = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.08))
        top.press(forDuration: 0.10, thenDragTo: right)
        let browsed = chat.value as? String
        XCTAssertEqual(browsed?.hasPrefix("C2, "), true, "A clockwise turn moves to the next slot, not past it")
        let key = app.buttons[browsed ?? "missing"]
        XCTAssertTrue(key.exists)
        XCTAssertEqual(key.value as? String, "Done, Dial selection", "Drag browses without activating, and the key still says what its chat is doing")
        // Each key's light says what its chat is doing; the value carries it for VoiceOver.
        XCTAssertEqual(app.buttons["C1, Controller app"].value as? String, "Thinking, Current chat")
        XCTAssertEqual(app.buttons["C3, Design studio"].value as? String, "Needs input")
        XCTAssertEqual(app.buttons["C4, Weekly review"].value as? String, "Idle")
        XCTAssertEqual(app.buttons["C5, Build notes"].value as? String, "Error")
        XCTAssertEqual(app.staticTexts["controller.activity"].label, "Thinking", "The open chat's state is named beside its title")
        right.press(forDuration: 0.10, thenDragTo: top)
        XCTAssertEqual(chat.value as? String, first, "Reverse drag returns to the original slot")
        // A swipe straight across the face goes the way the finger went,
        // wherever it passes relative to the center.
        for height in [0.22, 0.40] {
            let west = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: height))
            let east = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: height))
            west.press(forDuration: 0.10, thenDragTo: east)
            let swiped = chat.value as? String
            XCTAssertEqual(swiped?.hasPrefix("C2, "), true, "A swipe right moves one slot forward at height \(height), got \(swiped ?? "nothing")")
            east.press(forDuration: 0.10, thenDragTo: west)
            XCTAssertEqual(chat.value as? String, first, "The same swipe back returns at height \(height)")
        }
        top.press(forDuration: 0.10, thenDragTo: right)
        chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        let current = NSPredicate(format: "value CONTAINS %@", "Current chat")
        expectation(for: current, evaluatedWith: key)
        waitForExpectations(timeout: 5)

        let initialArtifact = artifact.value as? String
        let aTop = artifact.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.42))
        let aEnd = artifact.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.20))
        aTop.press(forDuration: 0.10, thenDragTo: aEnd)
        let chosenArtifact = artifact.value as? String
        XCTAssertNotEqual(chosenArtifact, initialArtifact, "Artifact dial browses to a different file")
        artifact.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        XCTAssertTrue(app.navigationBars[chosenArtifact ?? "missing"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()

        let quickKey = app.buttons["Voice"]
        quickKey.press(forDuration: 0.8)
        XCTAssertTrue(app.navigationBars["Map quick key 3"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Previous controller chat")
        let longAction = app.staticTexts["Previous controller chat"]
        XCTAssertTrue(longAction.waitForExistence(timeout: 5))
        longAction.tap()
        XCTAssertTrue(app.buttons["Previous controller chat"].waitForExistence(timeout: 5))
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portrait.name = "Genesis portrait long label"
        portrait.lifetime = .keepAlways
        add(portrait)

        app.buttons["Settings and Mac pairing"].tap()
        let sounds = app.switches["Controller sounds"]
        XCTAssertTrue(sounds.waitForExistence(timeout: 5))
        let wasEnabled = sounds.value as? String
        sounds.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.50)).tap()
        let changed = NSPredicate { _, _ in (sounds.value as? String) != wasEnabled }
        expectation(for: changed, evaluatedWith: sounds)
        waitForExpectations(timeout: 3)
        sounds.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.50)).tap()
        let restored = NSPredicate { _, _ in (sounds.value as? String) == wasEnabled }
        expectation(for: restored, evaluatedWith: sounds)
        waitForExpectations(timeout: 3)
        app.buttons["Done"].tap()

        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(chat.waitForExistence(timeout: 5))
            // App screenshots retain stale portrait bounds during rotation on
            // newer simulators. Capture the settled screen, not that crop.
            let settled = expectation(description: "Landscape compositor settled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
            waitForExpectations(timeout: 3)
            XCTAssertTrue(chat.exists)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Genesis iPad landscape"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

    }
    @MainActor
    func testCodexModelMapping() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["Codex"].waitForExistence(timeout: 8))
        app.buttons["Codex"].tap()
        let actions = app.buttons["Actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        XCTAssertTrue(app.navigationBars["Codex actions"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Change model")
        XCTAssertTrue(app.staticTexts["Change model"].waitForExistence(timeout: 5))
        if !app.buttons["Done"].exists { app.buttons["Close"].tap() }
        app.buttons["Done"].tap()
        let key = app.buttons["Keyboard shortcuts"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.press(forDuration: 0.8)
        XCTAssertTrue(app.navigationBars["Map quick key 3"].waitForExistence(timeout: 5))
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Change model")
        let changeModel = app.staticTexts["Change model"]
        XCTAssertTrue(changeModel.waitForExistence(timeout: 5))
        changeModel.tap()
        let model = app.buttons["Model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        let snapshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        snapshot.name = "Codex mapped Model key"
        snapshot.lifetime = .keepAlways
        add(snapshot)
        model.tap()
        XCTAssertTrue(app.navigationBars["Navigate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Select"].exists)
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Demo · Next menu item"].waitForExistence(timeout: 3))
        let previous = app.buttons.matching(identifier: "Previous").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(previous)
        previous?.tap()
        XCTAssertTrue(app.staticTexts["Demo · Previous menu item"].waitForExistence(timeout: 3))
        app.buttons["Select"].tap()
        XCTAssertTrue(app.staticTexts["Demo · Selection preview"].waitForExistence(timeout: 3))
        app.buttons["Back"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Model"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHoldToTalkAndSendClaude() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["Claude"].waitForExistence(timeout: 8))
        let talk = app.buttons["Start dictation"]
        XCTAssertTrue(talk.waitForExistence(timeout: 5))
        talk.press(forDuration: 2.0)
        XCTAssertTrue(talk.waitForExistence(timeout: 5), "Release restores talk control")
        let field = app.textFields["Draft for selected chat"]
        XCTAssertTrue(field.exists)
        let draft = field.value as? String
        XCTAssertEqual(draft, "Show me the latest changes and what still needs attention.")
        app.buttons["Send"].tap()
        let cleared = NSPredicate { _, _ in
            (field.value as? String) == "Hold the microphone, or type a draft…" || (field.value as? String) == ""
        }
        expectation(for: cleared, evaluatedWith: field)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts["Demo only — no prompt sent."].exists)
    }

    @MainActor
    func testProviderHostAndDraftIsolation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["Claude"].waitForExistence(timeout: 8))
        let keys = ["Controller app", "OMAC workspace", "Design studio", "Weekly review", "Build notes", "Ideas & experiments"]
        for (index,title) in keys.enumerated() {
            let key = app.buttons["C\(index+1), \(title)"]
            XCTAssertTrue(key.exists)
            key.tap()
            let active = NSPredicate(format:"value CONTAINS %@", "Current chat")
            expectation(for: active, evaluatedWith: key)
            waitForExpectations(timeout: 3)
        }
        app.buttons["C1, Controller app"].tap()
        let talk = app.buttons["Start dictation"]
        XCTAssertTrue(talk.waitForExistence(timeout: 3))
        talk.press(forDuration: 1)
        let field = app.textFields["Draft for selected chat"]
        let retained = field.value as? String
        app.buttons["C2, OMAC workspace"].tap()
        XCTAssertNotEqual(field.value as? String, retained)
        app.buttons["C1, Controller app"].tap()
        XCTAssertEqual(field.value as? String, retained)
        for host in ["Mini 2", "Neo", "Mini 1"] {
            app.buttons[host].tap()
            XCTAssertTrue(app.buttons[host].isSelected)
        }
        XCTAssertEqual(field.value as? String, retained)
        app.buttons["Codex"].tap()
        XCTAssertTrue(app.buttons["A1, Controller app"].exists)
        XCTAssertNotEqual(field.value as? String, retained)
        app.buttons["Claude"].tap()
        XCTAssertEqual(field.value as? String, retained)
        app.buttons["Muse"].tap()
        XCTAssertTrue(app.buttons["M1, Controller app"].exists)
        app.buttons["Claude"].tap()
        XCTAssertEqual(field.value as? String, retained)
        app.buttons["Refresh connection and chats"].tap()
        XCTAssertEqual(field.value as? String, retained)
    }

    @MainActor
    func testSlotEditorsAndMapButton() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let titles = ["Controller app", "OMAC workspace", "Design studio", "Weekly review", "Build notes", "Ideas & experiments"]
        XCTAssertTrue(app.buttons["Claude"].waitForExistence(timeout: 8))
        for (index,title) in titles.enumerated() {
            app.buttons["C\(index+1), \(title)"].press(forDuration: 0.8)
            XCTAssertTrue(app.navigationBars["Map C\(index+1)"].waitForExistence(timeout: 3))
            app.buttons["Cancel"].tap()
        }
        app.buttons["Map"].tap()
        XCTAssertTrue(app.navigationBars["Map C1"].waitForExistence(timeout: 3))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3), "Slot assignment search is visible")
        search.tap()
        search.typeText("Model")
        XCTAssertTrue(app.staticTexts["Model & effort"].waitForExistence(timeout: 3))
        app.staticTexts["Model & effort"].tap()
        XCTAssertTrue(app.buttons["C1, Model & effort"].waitForExistence(timeout: 3))
        app.buttons["C1, Model & effort"].tap()
        XCTAssertTrue(app.navigationBars["Navigate"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        app.buttons["Return to chat selection"].tap()
        XCTAssertTrue(app.buttons["C1, Model & effort"].exists)
    }

    @MainActor
    func testUnavailableQuickActionAndAllQuickEditors() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["Voice"].waitForExistence(timeout: 8))
        app.buttons["Voice"].tap()
        XCTAssertTrue(app.alerts["Controller update"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Two-way voice mode is not connected here yet. Use Hold to talk to dictate a draft, then Send."].exists)
        app.alerts.buttons["OK"].tap()
        for (index,title) in ["Send", "Stop", "Voice", "Artifacts"].enumerated() {
            app.buttons[title].press(forDuration: 0.8)
            XCTAssertTrue(app.navigationBars["Map quick key \(index + 1)"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.searchFields.firstMatch.exists)
            app.buttons["Done"].tap()
        }
    }

    @MainActor
    func testHoldReleaseOutsideAndMappedDictationToggle() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let talk = app.buttons["Start dictation"]
        XCTAssertTrue(talk.waitForExistence(timeout: 8))
        let start = talk.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let outside = start.withOffset(CGVector(dx: 0, dy: -120))
        start.press(forDuration: 1, thenDragTo: outside)
        XCTAssertTrue(talk.waitForExistence(timeout: 3), "Dragging off and releasing stops recording")
        let field = app.textFields["Draft for selected chat"]
        XCTAssertEqual(field.value as? String, "Show me the latest changes and what still needs attention.")
        app.buttons["Voice"].press(forDuration: 0.8)
        XCTAssertTrue(app.navigationBars["Map quick key 3"].waitForExistence(timeout: 3))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Hold to talk")
        app.staticTexts["Hold to talk"].tap()
        XCTAssertTrue(app.buttons["Hold to talk"].waitForExistence(timeout: 3))
        app.buttons["Hold to talk"].tap()
        XCTAssertTrue(app.buttons["Stop dictation"].waitForExistence(timeout: 3), "Mapped shortcut starts recording")
        XCTAssertFalse(field.isEnabled, "Speech-owned draft cannot be manually overwritten mid-capture")
        app.buttons["Hold to talk"].tap()
        XCTAssertTrue(talk.waitForExistence(timeout: 3), "Mapped shortcut stops recording")
        XCTAssertTrue(field.isEnabled)
        XCTAssertEqual(field.value as? String, "Show me the latest changes and what still needs attention.")
        app.buttons["Hold to talk"].tap()
        XCTAssertTrue(app.buttons["Stop dictation"].waitForExistence(timeout: 3))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(talk.waitForExistence(timeout: 5), "Backgrounding ends capture")
        XCTAssertEqual(field.value as? String, "Show me the latest changes and what still needs attention.", "Backgrounding preserves the last reviewed draft")
    }

    @MainActor
    func testArtifactShelfSearchAndPreview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["Artifacts"].waitForExistence(timeout: 8))
        app.buttons["Artifacts"].tap()
        XCTAssertTrue(app.navigationBars["Artifacts"].waitForExistence(timeout: 3))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Design")
        XCTAssertTrue(app.staticTexts["Design review"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Build notes"].firstMatch.isHittable, "Filtered item cannot be tapped in the shelf")
        app.staticTexts["Design review"].tap()
        XCTAssertTrue(app.navigationBars["Design review"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Artifact preview"].exists)
        XCTAssertTrue(app.buttons["Open on Mac"].exists)
        app.navigationBars["Design review"].buttons["Done"].tap()
        if !app.navigationBars["Artifacts"].buttons["Done"].exists { app.buttons["Close"].tap() }
        app.navigationBars["Artifacts"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Artifacts"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testPairingScannerCanCancelAndCodexDraftExplanation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            for label in ["Don’t Allow", "Don't Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        XCTAssertTrue(app.buttons["Settings and Mac pairing"].waitForExistence(timeout: 8))
        app.buttons["Settings and Mac pairing"].tap()
        app.buttons["Scan pairing code"].tap()
        XCTAssertTrue(app.navigationBars["Scan pairing code"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        XCTAssertTrue(app.navigationBars["Your controller"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        app.buttons["Codex"].tap()
        app.buttons["A1, Controller app"].press(forDuration: 0.8)
        XCTAssertTrue(app.navigationBars["Map A1"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Chat switching, phone dictation drafts, and artifacts are available. Send is not connected for this provider yet."].exists)
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testRepeatedHoldReleaseAfterReview() {
        // Demo proves the gesture resets between captures. Real speech restart,
        // audio buffers, and appended recognition require service/device tests.
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        let talk = app.buttons["Start dictation"]
        let field = app.textFields["Draft for selected chat"]
        XCTAssertTrue(talk.waitForExistence(timeout: 8))
        for capture in 1...3 {
            talk.press(forDuration: 1.1)
            XCTAssertTrue(talk.waitForExistence(timeout: 5), "Release resets capture \(capture)")
            XCTAssertTrue(field.isEnabled)
            XCTAssertEqual(field.value as? String, "Show me the latest changes and what still needs attention.")
            XCTAssertFalse(app.alerts["Controller update"].exists)
            app.buttons["Send"].tap() // --demo never sends a host command.
            let cleared = NSPredicate { _, _ in
                (field.value as? String) == "Hold the microphone, or type a draft…" || (field.value as? String) == ""
            }
            expectation(for: cleared, evaluatedWith: field); waitForExpectations(timeout: 3)
            if capture < 3 {
                let review = expectation(description: "Review interval between holds")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { review.fulfill() }
                waitForExpectations(timeout: 6)
            }
        }
    }

}
