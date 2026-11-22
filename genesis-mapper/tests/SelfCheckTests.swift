import Foundation

@main struct SelfCheckTests {
    static var passed = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("FAIL: " + message) }
        passed += 1
    }

    static let good = SelfCheck.Mac(unlocked: true, accessibility: true)

    static func claude(installed: Bool = true, running: Bool = true, sessions: Int = 3, prompts: Int = 1,
                       sends: Int = 1, models: Int = 1, permissions: Bool = true) -> SelfCheck.Claude {
        .init(installed: installed, running: running, sessionRows: sessions, promptFields: prompts,
              sendOrStopButtons: sends, modelChoosers: models, permissionChooserFound: permissions)
    }

    static func muse(installed: Bool = true, running: Bool = true, navigable: Bool = true, boxes: Int = 1,
                     answering: Bool = false, chats: Int = 4, shared: Int = 0, calls: Int = 1) -> SelfCheck.Muse {
        .init(installed: installed, running: running, navigable: navigable, messageBoxes: boxes,
              answering: answering, chats: chats, sharedTitles: shared, callControls: calls)
    }

    static func codex(installed: Bool = true, running: Bool = true, inventory: Bool = true, chats: Int = 12,
                      menu: Bool = true, queue: Bool = true) -> SelfCheck.Codex {
        .init(installed: installed, running: running, inventoryReachable: inventory, savedChats: chats,
              menuBarReadable: menu, queueAvailable: queue)
    }

    static func item(_ items: [SelfCheckItem], _ name: String) -> SelfCheckItem? { items.first { $0.name == name } }

    static func main() {
        macChecks()
        claudeRootCauses()
        claudeDetails()
        museRootCauses()
        museDetails()
        codexChecks()
        geminiChecks()
        summaries()
        // A Muse window too narrow to control is one cause, reported once.
        let covered = SelfCheck.muse(.init(installed: true, running: true, navigable: false, messageBoxes: 0, answering: false, chats: 0, sharedTitles: 0, callControls: 0, windowTooNarrow: true), mac: .init(unlocked: true, accessibility: true))
        expect(covered.count == 1 && covered[0].ok == false && covered[0].name == "Window", "A narrow window is one Muse problem, not four")
        expect(covered[0].detail.contains("too narrow") && covered[0].detail.contains("Open Muse"), "It says what is wrong and what to press")
        print("Self-check: \(passed) checks passed")
    }

    static func macChecks() {
        let fine = SelfCheck.mac(good)
        expect(fine.count == 2 && fine.allSatisfy { $0.provider == "mac" }, "The Mac check returns two items, both for the Mac")
        expect(fine.map(\.name) == ["Unlocked", "Accessibility"], "The Mac items are Unlocked then Accessibility")
        expect(fine.allSatisfy { $0.ok && !$0.detail.isEmpty }, "An unlocked Mac with Accessibility passes both, with a sentence each")

        let locked = SelfCheck.mac(.init(unlocked: false, accessibility: true))
        expect(item(locked, "Unlocked")?.ok == false && item(locked, "Accessibility")?.ok == true, "A locked Mac fails only the Unlocked item")
        expect(item(locked, "Unlocked")?.detail == "This Mac is locked. Unlock it to use any controls.", "A locked Mac says to unlock it")

        let blocked = SelfCheck.mac(.init(unlocked: true, accessibility: false))
        expect(item(blocked, "Accessibility")?.ok == false && item(blocked, "Unlocked")?.ok == true, "Missing Accessibility fails only the Accessibility item")
        expect(item(blocked, "Accessibility")?.detail == "Allow Accessibility for Agent Micro Controller in System Settings, under Privacy & Security.", "Missing Accessibility says where to allow it")
    }

    static func claudeRootCauses() {
        let all = SelfCheck.claude(claude(), mac: good)
        expect(all.count == 5 && all.allSatisfy { $0.ok && $0.provider == "claude" }, "A healthy Claude returns five passing items")
        expect(all.map(\.name) == ["Session list", "Message box", "Send control", "Model chooser", "Permissions chooser"], "Claude's detailed checks come in the agreed order")

        let missing = SelfCheck.claude(claude(installed: false, running: false), mac: .init(unlocked: false, accessibility: false))
        expect(missing.count == 1 && missing[0].name == "Installed" && !missing[0].ok, "Not installed wins over every other cause and returns one item")
        expect(missing[0].detail.contains("install") || missing[0].detail.contains("Install"), "The not-installed detail says to install Claude")

        let locked = SelfCheck.claude(claude(running: false), mac: .init(unlocked: false, accessibility: false))
        expect(locked.count == 1 && locked[0].name == "Reachable" && locked[0].detail.contains("locked"), "A locked Mac wins over missing Accessibility and a closed app")

        let noAX = SelfCheck.claude(claude(running: false), mac: .init(unlocked: true, accessibility: false))
        expect(noAX.count == 1 && noAX[0].name == "Reachable" && noAX[0].detail.contains("Accessibility"), "Missing Accessibility wins over a closed app")

        let closed = SelfCheck.claude(claude(running: false), mac: good)
        expect(closed == [SelfCheckItem(provider: "claude", name: "Open", ok: false, detail: "Open Claude on this Mac.")], "A closed Claude says to open it, as the only item")
        expect(closed[0].ok == false, "Every root cause is a failure")
    }

    static func claudeDetails() {
        func run(_ c: SelfCheck.Claude) -> [SelfCheckItem] { SelfCheck.claude(c, mac: good) }

        let sessions = run(claude(sessions: 1))
        expect(item(sessions, "Session list")?.ok == true && item(sessions, "Session list")?.detail == "1 session found.", "One session reads in the singular")
        expect(item(run(claude(sessions: 7)), "Session list")?.detail == "7 sessions found.", "Several sessions read in the plural with the count")
        let none = item(run(claude(sessions: 0)), "Session list")
        expect(none?.ok == false && none?.detail == "No chats found. Open Claude, sign in if asked, and show its sidebar.", "No sessions says to open Claude, sign in and show the sidebar")

        let noBox = item(run(claude(prompts: 0)), "Message box")
        expect(noBox?.ok == false && noBox?.detail == "No message box is showing. Open a session in Claude.", "No message box says to open a session")
        let twoBoxes = item(run(claude(prompts: 2)), "Message box")
        expect(twoBoxes?.ok == false && twoBoxes?.detail == "More than one message box is showing, so the target is ambiguous.", "Two message boxes are ambiguous")

        expect(item(run(claude(sends: 1)), "Send control")?.ok == true, "Exactly one send control passes")
        let resting = item(run(claude(sends: 0)), "Send control")
        expect(resting?.ok == true && resting?.detail == "Not showing yet. Claude adds it once a draft is in the message box.", "No send control beside one empty message box is Claude's normal resting state")
        let noSend = item(run(claude(prompts: 0, sends: 0)), "Send control")
        expect(noSend?.ok == false && noSend?.detail.contains("not found") == true && noSend?.detail.contains("layout may have changed") == true, "No send control and no message box says it was not found and the layout may have changed")
        let noSendTwoBoxes = item(run(claude(prompts: 2, sends: 0)), "Send control")
        expect(noSendTwoBoxes?.ok == false, "No send control with two message boxes is not excused")
        let manySend = item(run(claude(sends: 3)), "Send control")
        expect(manySend?.ok == false && manySend?.detail.contains("ambiguous") == true && manySend?.detail.contains("layout may have changed") == true, "Several send controls are ambiguous and may mean a layout change")

        expect(item(run(claude(models: 1)), "Model chooser")?.ok == true, "Exactly one model chooser passes")
        let noModel = item(run(claude(models: 0)), "Model chooser")
        expect(noModel?.ok == false && noModel?.detail.contains("not found") == true && noModel?.detail.contains("layout may have changed") == true, "No model chooser says it was not found and the layout may have changed")
        let manyModel = item(run(claude(models: 2)), "Model chooser")
        expect(manyModel?.ok == false && manyModel?.detail.contains("ambiguous") == true, "Two model choosers are ambiguous")

        expect(item(run(claude(permissions: true)), "Permissions chooser")?.ok == true, "A found permissions chooser passes")
        let noPerm = item(run(claude(permissions: false)), "Permissions chooser")
        expect(noPerm?.ok == false && noPerm?.detail == "Not found beside the model chooser. Claude\u{2019}s layout may have changed.", "A missing permissions chooser says to suspect the layout")

        let broken = run(claude(sessions: 0, prompts: 0, sends: 0, models: 0, permissions: false))
        expect(broken.count == 5 && broken.allSatisfy { !$0.ok }, "Every detailed check can fail independently while all five items still appear")
    }

    static func museRootCauses() {
        let healthy = SelfCheck.muse(muse(), mac: good)
        expect(healthy.count == 4 && healthy.allSatisfy { $0.ok && $0.provider == "muse" }, "A healthy Muse returns four passing items")
        expect(healthy.map(\.name) == ["Chat list", "Chats", "Message box", "Call control"], "Muse's detailed checks come in the agreed order")

        let missing = SelfCheck.muse(muse(installed: false, running: false), mac: .init(unlocked: false, accessibility: false))
        expect(missing.count == 1 && missing[0].name == "Installed" && !missing[0].ok && missing[0].detail.contains("Muse"), "Muse not installed wins and names Muse")

        let locked = SelfCheck.muse(muse(running: false), mac: .init(unlocked: false, accessibility: false))
        expect(locked.count == 1 && locked[0].name == "Reachable" && locked[0].detail.contains("locked"), "A locked Mac wins over missing Accessibility for Muse")

        let noAX = SelfCheck.muse(muse(running: false), mac: .init(unlocked: true, accessibility: false))
        expect(noAX.count == 1 && noAX[0].name == "Reachable" && noAX[0].detail.contains("Accessibility"), "Missing Accessibility wins over a closed Muse")

        let closed = SelfCheck.muse(muse(running: false), mac: good)
        expect(closed == [SelfCheckItem(provider: "muse", name: "Open", ok: false, detail: "Open Muse on this Mac.")], "A closed Muse says to open it, as the only item")
    }

    static func museDetails() {
        func run(_ m: SelfCheck.Muse) -> [SelfCheckItem] { SelfCheck.muse(m, mac: good) }

        let lost = item(run(muse(navigable: false)), "Chat list")
        expect(lost?.ok == false && lost?.detail == "Muse is showing a screen without its chat list.", "A screen without the chat list is reported")

        expect(item(run(muse(chats: 1)), "Chats")?.detail == "1 chat offered.", "One chat reads in the singular")
        expect(item(run(muse(chats: 5)), "Chats")?.detail == "5 chats offered.", "Several chats read in the plural")
        let noChats = item(run(muse(chats: 0)), "Chats")
        expect(noChats?.ok == false && noChats?.detail == "No chats found.", "Zero chats fails with No chats found")
        let oneShared = item(run(muse(chats: 3, shared: 1)), "Chats")
        expect(oneShared?.ok == true && oneShared?.detail == "3 chats offered. 1 title is shared by several chats and is left out; rename it in Muse to use it.", "One shared title uses the singular wording and still passes")
        let twoShared = item(run(muse(chats: 3, shared: 2)), "Chats")
        expect(twoShared?.detail == "3 chats offered. 2 titles are shared by several chats and are left out; rename them in Muse to use them.", "Several shared titles use the plural wording")
        expect(item(run(muse(chats: 0, shared: 2)), "Chats")?.detail == "No chats found.", "Zero chats says only that none were found")

        expect(item(run(muse(boxes: 1)), "Message box")?.ok == true, "Exactly one message box passes")
        let noBox = item(run(muse(boxes: 0)), "Message box")
        expect(noBox?.ok == false && noBox?.detail == "No message box is showing. Open a chat in Muse.", "No message box fails when Muse is idle")
        let manyBoxes = item(run(muse(boxes: 2)), "Message box")
        expect(manyBoxes?.ok == false && manyBoxes?.detail.contains("ambiguous") == true, "Two message boxes are ambiguous when Muse is idle")
        for boxes in [0, 1, 2] {
            let answering = item(run(muse(boxes: boxes, answering: true)), "Message box")
            expect(answering?.ok == true && answering?.detail == "Muse is answering. Sending waits until it finishes.", "While Muse answers the message box passes whatever the count is (\(boxes))")
        }

        expect(item(run(muse(calls: 1)), "Call control")?.ok == true, "Exactly one call control passes")
        for calls in [0, 2] {
            let call = item(run(muse(calls: calls)), "Call control")
            expect(call?.ok == false && call?.detail == "Not showing. A call may already be in progress.", "\(calls) call controls fails with the call-in-progress hint")
        }
    }

    static func geminiChecks() {
        func gem(installed: Bool = true, readable: Bool = true, chats: Int = 2, problem: String = "") -> SelfCheck.Gemini {
            .init(installed: installed, running: false, databaseReadable: readable, chats: chats, problem: problem, threadsReadable: readable)
        }
        let healthy = SelfCheck.gemini(gem(), mac: good)
        expect(healthy.map(\.name) == ["Chat list", "Chats", "Threads", "Send"] && healthy.filter { $0.name != "Send" }.allSatisfy { $0.ok && $0.provider == "gemini" }, "A healthy Gemini returns its items, and needs neither Accessibility nor an open app")
        expect(item(healthy, "Chats")?.detail == "2 chats offered.", "Gemini chats gives the count")
        let missing = SelfCheck.gemini(gem(installed: false), mac: .init(unlocked: false, accessibility: false))
        expect(missing.count == 1 && missing[0].name == "Installed" && !missing[0].ok, "Gemini not installed returns one item")
        expect(SelfCheck.gemini(gem(), mac: .init(unlocked: false, accessibility: true)).first?.name == "Reachable", "A locked Mac returns one Reachable item for Gemini")
        let broken = SelfCheck.gemini(gem(readable: false, chats: 0, problem: "Layout changed."), mac: good)
        expect(broken.count == 4 && !broken[0].ok && broken[0].detail == "Layout changed." && !broken[1].ok, "An unreadable list fails both items and says why")
        expect(!SelfCheck.gemini(gem(chats: 0), mac: good)[1].ok, "No chats is flagged")
        expect(item(healthy, "Threads")?.ok == true && !broken[2].ok && broken[2].provider == "gemini", "Gemini Threads is ok when conversations read, failed when not")
        var drifted = gem(); drifted.threadsReadable = false; drifted.threadsProblem = "Layout moved."
        expect(item(SelfCheck.gemini(drifted, mac: good), "Threads")?.detail == "Layout moved." && !SelfCheck.gemini(gem(readable: true), mac: good)[1].detail.isEmpty, "Gemini Threads says why it cannot read")
        var withTool = gem(); withTool.sendCommandFound = true
        let closedSend = item(SelfCheck.gemini(withTool, mac: good), "Send")
        expect(closedSend?.ok == true && closedSend?.detail.contains("opened when you send") == true, "A closed Gemini with the tool is ready to send")
        withTool.hubLive = true
        expect(item(SelfCheck.gemini(withTool, mac: good), "Send")?.detail.contains("Gemini is open") == true, "An open Gemini says so")
        expect(item(SelfCheck.gemini(gem(), mac: good), "Send")?.ok == false, "No tool, no Send")
    }

    static func codexChecks() {
        let healthy = SelfCheck.codex(codex(), mac: good)
        expect(healthy.map(\.name) == ["Saved chats", "Send", "Menu controls"] && healthy.allSatisfy { $0.ok && $0.provider == "codex" }, "A healthy Codex returns three passing items")
        expect(item(healthy, "Saved chats")?.detail == "12 saved chats found.", "Saved chats gives the count")
        expect(item(SelfCheck.codex(codex(chats: 1), mac: good), "Saved chats")?.detail == "1 saved chat found.", "One saved chat reads in the singular")

        let missing = SelfCheck.codex(codex(installed: false, running: false), mac: .init(unlocked: false, accessibility: false))
        expect(missing.count == 1 && missing[0].name == "Installed" && !missing[0].ok, "Codex not installed returns one item and wins over a locked Mac")

        let locked = SelfCheck.codex(codex(), mac: .init(unlocked: false, accessibility: true))
        expect(locked.count == 1 && locked[0].name == "Reachable" && !locked[0].ok && locked[0].detail.contains("locked"), "A locked Mac returns one Reachable item for Codex")

        let closed = SelfCheck.codex(codex(running: false), mac: good)
        expect(closed.count == 3, "A closed Codex window still returns three items")
        expect(item(closed, "Saved chats")?.ok == true && item(closed, "Send")?.ok == true, "Saved chats and sending do not depend on the window being open")
        expect(item(closed, "Menu controls")?.ok == false && item(closed, "Menu controls")?.detail == "Open Codex to use its menu controls.", "A closed window only affects the menu controls")

        let noAXClosed = SelfCheck.codex(codex(running: false), mac: .init(unlocked: true, accessibility: false))
        expect(item(noAXClosed, "Menu controls")?.detail == "Open Codex to use its menu controls.", "Not running is reported before missing Accessibility")
        let noAX = SelfCheck.codex(codex(), mac: .init(unlocked: true, accessibility: false))
        expect(item(noAX, "Menu controls")?.ok == false && item(noAX, "Menu controls")?.detail.contains("Accessibility") == true, "Missing Accessibility is named for the menu controls")
        expect(item(noAX, "Saved chats")?.ok == true, "Missing Accessibility does not affect saved chats")
        let unreadable = SelfCheck.codex(codex(menu: false), mac: good)
        expect(item(unreadable, "Menu controls")?.ok == false && item(unreadable, "Menu controls")?.detail == "Codex\u{2019}s menus could not be read.", "A running Codex with unreadable menus says so")

        let down = SelfCheck.codex(codex(inventory: false), mac: good)
        expect(item(down, "Saved chats")?.ok == false && item(down, "Saved chats")?.detail == "Codex\u{2019}s background service is not answering. Use Restart Codex service on the phone\u{2019}s Codex tab, or run on this Mac: codex app-server daemon restart", "An unreachable service gives the restart command")
        let noQueue = SelfCheck.codex(codex(queue: false), mac: good)
        expect(item(noQueue, "Send")?.ok == false && item(noQueue, "Send")?.detail == "The command used to send prompts was not found in the installed Codex app.", "A missing send command is reported")
    }

    static func summaries() {
        expect(SelfCheck.summary([]) == "Nothing was checked.", "No items reads Nothing was checked")

        let one = [SelfCheckItem(provider: "mac", name: "Unlocked", ok: true, detail: "x")]
        expect(SelfCheck.summary(one) == "All 1 check passed.", "A single passing check uses the singular")
        expect(SelfCheck.summary(SelfCheck.mac(good)) == "All 2 checks passed.", "Several passing checks use the plural")

        let oneBad = [SelfCheckItem(provider: "claude", name: "Message box", ok: false, detail: "x"),
                      SelfCheckItem(provider: "mac", name: "Unlocked", ok: true, detail: "x")]
        expect(SelfCheck.summary(oneBad) == "1 of 2 checks needs attention: Claude \u{2013} Message box.", "One failure says needs attention and names it")

        let twoBad = [SelfCheckItem(provider: "claude", name: "Message box", ok: false, detail: "x"),
                      SelfCheckItem(provider: "mac", name: "Unlocked", ok: true, detail: "x"),
                      SelfCheckItem(provider: "codex", name: "Saved chats", ok: false, detail: "x")]
        expect(SelfCheck.summary(twoBad) == "2 of 3 checks need attention: Claude \u{2013} Message box; Codex \u{2013} Saved chats.", "Several failures are listed in order, separated by semicolons")

        let single = [SelfCheckItem(provider: "muse", name: "Open", ok: false, detail: "x")]
        expect(SelfCheck.summary(single) == "1 of 1 check needs attention: Muse \u{2013} Open.", "A single failing check uses the singular for both words")

        let mac = SelfCheck.summary([SelfCheckItem(provider: "mac", name: "Accessibility", ok: false, detail: "x")])
        expect(mac.contains("Mac \u{2013} Accessibility"), "Provider names are capitalised")

        let everything = SelfCheck.mac(good) + SelfCheck.claude(claude(), mac: good) + SelfCheck.muse(muse(), mac: good) + SelfCheck.codex(codex(), mac: good)
        expect(SelfCheck.summary(everything) == "All 14 checks passed.", "A fully healthy Mac passes all fourteen checks")

        let encoded = try? JSONEncoder().encode(one)
        expect(encoded.flatMap { try? JSONDecoder().decode([SelfCheckItem].self, from: $0) } == one, "A check item survives being sent as JSON")

        let texts = everything.map(\.detail) + SelfCheck.claude(claude(installed: false), mac: good).map(\.detail)
        expect(texts.allSatisfy { $0 == $0.trimmingCharacters(in: .whitespaces) && !$0.isEmpty }, "No detail is empty or has stray spaces at its ends")
    }
}
