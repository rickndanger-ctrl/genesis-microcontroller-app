import XCTest

final class ControllerUITests: XCTestCase {
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
        XCTAssertEqual(first, "C1, Genesis iPhone")
        let top = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.17))
        let right = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.45))
        top.press(forDuration: 0.10, thenDragTo: right)
        let browsed = chat.value as? String
        XCTAssertNotEqual(browsed, first, "Clockwise drag changes the selected slot")
        let key = app.buttons[browsed ?? "missing"]
        XCTAssertTrue(key.exists)
        XCTAssertEqual(key.value as? String, "Dial selection", "Drag browses without activating")
        right.press(forDuration: 0.10, thenDragTo: top)
        XCTAssertEqual(chat.value as? String, first, "Reverse drag returns to the original slot")
        top.press(forDuration: 0.10, thenDragTo: right)
        chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        let current = NSPredicate(format: "value CONTAINS %@", "Current chat")
        expectation(for: current, evaluatedWith: key)
        waitForExpectations(timeout: 5)

        let initialArtifact = artifact.value as? String
        let aTop = artifact.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.17))
        let aEnd = artifact.coordinate(withNormalizedOffset: CGVector(dx: 0.77, dy: 0.28))
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
        let keys = ["Genesis iPhone", "OMAC workspace", "Design studio", "Weekly review", "Build notes", "Ideas & experiments"]
        for (index,title) in keys.enumerated() {
            let key = app.buttons["C\(index+1), \(title)"]
            XCTAssertTrue(key.exists)
            key.tap()
            let active = NSPredicate(format:"value CONTAINS %@", "Current chat")
            expectation(for: active, evaluatedWith: key)
            waitForExpectations(timeout: 3)
        }
        app.buttons["C1, Genesis iPhone"].tap()
        let talk = app.buttons["Start dictation"]
        XCTAssertTrue(talk.waitForExistence(timeout: 3))
        talk.press(forDuration: 1)
        let field = app.textFields["Draft for selected chat"]
        let retained = field.value as? String
        app.buttons["C2, OMAC workspace"].tap()
        XCTAssertNotEqual(field.value as? String, retained)
        app.buttons["C1, Genesis iPhone"].tap()
        XCTAssertEqual(field.value as? String, retained)
        for host in ["Mini 2", "Neo", "Mini 1"] {
            app.buttons[host].tap()
            XCTAssertTrue(app.buttons[host].isSelected)
        }
        XCTAssertEqual(field.value as? String, retained)
        app.buttons["Codex"].tap()
        XCTAssertTrue(app.buttons["A1, Genesis iPhone"].exists)
        XCTAssertNotEqual(field.value as? String, retained)
        app.buttons["Claude"].tap()
        XCTAssertEqual(field.value as? String, retained)
        app.buttons["Muse"].tap()
        XCTAssertTrue(app.buttons["M1, Genesis iPhone"].exists)
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
        let titles = ["Genesis iPhone", "OMAC workspace", "Design studio", "Weekly review", "Build notes", "Ideas & experiments"]
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
        XCTAssertTrue(app.staticTexts["Two-way voice mode is not connected in Genesis yet. Use Hold to talk to dictate a draft, then Send."].exists)
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
        app.buttons["A1, Genesis iPhone"].press(forDuration: 0.8)
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
