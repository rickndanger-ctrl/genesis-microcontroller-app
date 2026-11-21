import Foundation

@main struct ThreadReaderTests {
    static var count = 0
    static func expect(_ value: Bool, _ name: String) { guard value else { fatalError("FAIL: " + name) }; count += 1 }
    static func fails(_ name: String, _ expected: ThreadFailure? = nil, _ body: () throws -> Void) {
        do { try body(); fatalError("FAIL: " + name) }
        catch { if let expected, (error as? ThreadFailure) != expected { fatalError("FAIL (wrong error): " + name) }; count += 1 }
    }

    static let account = "11111111-1111-1111-1111-111111111111"
    static let organization = "22222222-2222-2222-2222-222222222222"
    static let session = "33333333-3333-3333-3333-333333333333"
    static let desktopID = "44444444-4444-4444-4444-444444444444"
    static func uuid(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }
    static func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)! + "\n"
    }
    static func record(_ n: Int, parent: Int?, type: String, content: Any, extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["type": type, "uuid": uuid(n), "parentUuid": parent.map(uuid) ?? NSNull(), "sessionId": session,
                                     "isSidechain": false, "message": ["role": type, "content": content]]
        for (key, value) in extra { object[key] = value }
        return line(object)
    }
    static let bridge = line(["type": "bridge-session", "sessionId": session, "ownerAccountUuid": account, "ownerOrganizationUuid": organization])
    static let binding = ClaudeBinding(accountID: account, organizationID: organization, cliSessionID: session, transcript: "")
    static func text(_ value: String) -> [[String: Any]] { [["type": "text", "text": value]] }

    static func main() throws {
        // Limits: newest turns kept, oldest first on return, per-turn and total caps.
        let many = (0..<20).map { ThreadTurn(role: $0 % 2 == 0 ? "assistant" : "user", text: "m\(19 - $0)") }
        let bounded = ThreadLimits.bound(many, limited: false)
        expect(bounded.turns.count == 12 && bounded.truncated, "twelve turns at most")
        expect(bounded.turns.first?.text == "m8" && bounded.turns.last?.text == "m19", "newest kept, oldest first")
        let long = ThreadLimits.bound([ThreadTurn(role: "assistant", text: String(repeating: "a", count: 9_000))], limited: false)
        expect(long.turns[0].text.count == 8_000 && long.truncated, "per-turn cap")
        let big = (0..<5).map { _ in ThreadTurn(role: "user", text: String(repeating: "b", count: 7_000)) }
        let total = ThreadLimits.bound(big, limited: false)
        expect(total.turns.reduce(0) { $0 + $1.text.count } == 24_000 && total.turns.count == 4 && total.truncated, "total cap")
        let small = ThreadLimits.bound([ThreadTurn(role: "user", text: "hi")], limited: false)
        expect(small.turns.count == 1 && !small.truncated, "small stays whole")
        expect(ThreadLimits.bound([], limited: true).truncated, "caller limit carries through")

        // Claude message filtering.
        func visible(_ type: String, _ content: Any, _ extra: [String: Any] = [:]) -> ThreadTurn? {
            let data = record(1, parent: nil, type: type, content: content, extra: extra).data(using: .utf8)!
            return ClaudeThread.visible(try! JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        expect(visible("user", "hello") == ThreadTurn(role: "user", text: "hello"), "plain user string")
        expect(visible("assistant", "string content") == nil, "assistant string content ignored")
        expect(visible("assistant", [["type": "thinking", "thinking": "secret"], ["type": "text", "text": "answer"], ["type": "tool_use", "id": "x"]])
               == ThreadTurn(role: "assistant", text: "answer"), "only text blocks of an assistant")
        expect(visible("assistant", [["type": "tool_use", "id": "x"]]) == nil, "tool call alone is not a message")
        expect(visible("user", [["type": "tool_result", "content": "out"], ["type": "text", "text": "x"]]) == nil, "tool result turn dropped")
        expect(visible("user", text("<system-reminder>do not show</system-reminder>")) == nil, "wrapper block dropped")
        expect(visible("user", "<command-name>/clear</command-name>") == nil, "command wrapper dropped")
        expect(visible("user", "hi", ["isMeta": true]) == nil, "meta dropped")
        expect(visible("user", "hi", ["isCompactSummary": true]) == nil, "compact summary dropped")
        expect(visible("user", "hi", ["isSidechain": true]) == nil, "sidechain dropped")
        expect(visible("user", "hi", ["toolUseResult": ["a": 1]]) == nil, "tool use result dropped")
        expect(visible("assistant", text("x"), ["sourceToolAssistantUUID": uuid(9)]) == nil, "tool-sourced dropped")
        expect(visible("assistant", [["type": "text", "text": "x", "hidden": true]]) == nil, "hidden block dropped")
        expect(visible("system", "x") == nil, "system record is not a message")
        expect(visible("user", "a\u{0001}b\u{0000}c\n d ")?.text == "abc\n d", "control characters removed and trimmed")
        expect(visible("user", "  \n ") == nil, "blank dropped")

        // Parent chain from the newest leaf; a side branch is not part of it.
        var file = bridge
        file += record(1, parent: nil, type: "user", content: "first question")
        file += record(2, parent: 1, type: "assistant", content: [["type": "tool_use", "id": "t"]])
        file += record(3, parent: 2, type: "user", content: [["type": "tool_result", "content": "r"]], extra: ["toolUseResult": ["ok": true]])
        file += record(4, parent: 3, type: "assistant", content: text("first answer"))
        file += record(5, parent: 1, type: "assistant", content: text("abandoned branch"))
        file += record(6, parent: 4, type: "user", content: "second question")
        file += record(7, parent: 6, type: "assistant", content: [["type": "thinking", "thinking": "t"], ["type": "text", "text": "second answer"]])
        file += line(["type": "summary", "sessionId": session, "summary": "ignored"])
        var parsed = try ClaudeThread.parse(Data(file.utf8), binding: binding, startsMidFile: false)
        expect(parsed.turns.map(\.text) == ["second answer", "second question", "first answer", "first question"] && !parsed.limited, "chain, newest first")
        let other = binding
        file += String(record(8, parent: 7, type: "user", content: "other session").replacingOccurrences(of: session, with: "99999999-9999-9999-9999-999999999999"))
        parsed = try ClaudeThread.parse(Data(file.utf8), binding: other, startsMidFile: false)
        expect(parsed.turns.count == 4, "records of another session are ignored")

        // Mid-file tail drops the first partial line; a half-written last line is dropped and flagged.
        let partialTail = "ial line that was cut\n" + file + "{\"type\":\"user\",\"uu"
        parsed = try ClaudeThread.parse(Data(partialTail.utf8), binding: binding, startsMidFile: true)
        expect(parsed.limited && parsed.turns.count == 4, "tail starts mid-file and ends mid-line")
        fails("mid-file tail with no newline", .unreadable) { _ = try ClaudeThread.parse(Data("no newline".utf8), binding: binding, startsMidFile: true) }
        // A parent outside the tail ends the walk and is reported as limited.
        let orphan = bridge + record(2, parent: 1, type: "user", content: "only child")
        parsed = try ClaudeThread.parse(Data(orphan.utf8), binding: binding, startsMidFile: false)
        expect(parsed.turns.count == 1 && parsed.limited, "missing ancestor is limited")

        // Fail closed on unexpected shapes.
        fails("no bridge record", .unverified) { _ = try ClaudeThread.parse(Data(record(1, parent: nil, type: "user", content: "x").utf8), binding: binding, startsMidFile: false) }
        let wrongOwner = line(["type": "bridge-session", "sessionId": session, "ownerAccountUuid": uuid(5), "ownerOrganizationUuid": organization])
        fails("bridge owned by another account", .unverified) { _ = try ClaudeThread.parse(Data((wrongOwner + record(1, parent: nil, type: "user", content: "x")).utf8), binding: binding, startsMidFile: false) }
        fails("invalid JSON line", .unreadable) { _ = try ClaudeThread.parse(Data((bridge + "{not json}\n").utf8), binding: binding, startsMidFile: false) }
        fails("duplicate uuid", .unreadable) { _ = try ClaudeThread.parse(Data((bridge + record(1, parent: nil, type: "user", content: "a") + record(1, parent: nil, type: "user", content: "b")).utf8), binding: binding, startsMidFile: false) }
        fails("bad parent uuid", .unreadable) {
            var bad = record(1, parent: nil, type: "user", content: "a")
            bad = bad.replacingOccurrences(of: "\"parentUuid\":null", with: "\"parentUuid\":\"nope\"")
            _ = try ClaudeThread.parse(Data((bridge + bad).utf8), binding: binding, startsMidFile: false)
        }
        fails("timeout is reported", .timeout) {
            _ = try ClaudeThread.parse(Data((bridge + (1...600).map { record($0, parent: nil, type: "user", content: "x") }.joined()).utf8), binding: binding, startsMidFile: false, deadline: 0)
        }

        // Session lookup against a fake home folder.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("thread-reader-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        func write(_ relative: String, _ contents: String) {
            let url = home.appendingPathComponent(relative)
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! contents.write(to: url, atomically: true, encoding: .utf8)
        }
        write("Library/Application Support/Claude/config.json", line(["lastKnownAccountUuid": account]))
        write(".claude.json", line(["oauthAccount": ["accountUuid": account, "organizationUuid": organization]]))
        let sessions = "Library/Application Support/Claude/claude-code-sessions/\(account)/\(organization)"
        let cwd = "/Users/test/My Project"
        func desktop(_ id: String, title: String, archived: Bool? = false, cli: String = session) {
            var object: [String: Any] = ["sessionId": "local_" + id, "title": title, "cliSessionId": cli, "cwd": cwd]
            if let archived { object["isArchived"] = archived }
            write("\(sessions)/local_\(id).json", line(object))
        }
        desktop(desktopID, title: "Plan the trip")
        desktop("55555555-5555-5555-5555-555555555555", title: "Old one", archived: true)
        let transcriptPath = ".claude/projects/-Users-test-My-Project/\(session).jsonl"
        write(transcriptPath, file)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let found = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: deadline)
        expect(found.turns.count == 4 && found.turns[0].text == "second answer", "end-to-end read from a fake home")
        fails("title with no session", .noSession) { _ = try ClaudeThread.read(title: "A chat that is not Code", home: home.path, deadline: deadline) }
        fails("archived session is not matched", .noSession) { _ = try ClaudeThread.read(title: "Old one", home: home.path, deadline: deadline) }
        desktop("66666666-6666-6666-6666-666666666666", title: "Plan the trip", cli: "77777777-7777-7777-7777-777777777777")
        fails("two sessions with one title", .ambiguous) { _ = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: deadline) }
        try fm.removeItem(at: home.appendingPathComponent("\(sessions)/local_66666666-6666-6666-6666-666666666666.json"))
        desktop("88888888-8888-8888-8888-888888888888", title: "No archive flag", archived: nil)
        fails("missing archive flag fails closed", .noSession) { _ = try ClaudeThread.read(title: "No archive flag", home: home.path, deadline: deadline) }
        try fm.removeItem(at: home.appendingPathComponent("\(sessions)/local_88888888-8888-8888-8888-888888888888.json"))
        // Another kind of session with the same title makes the chat ambiguous.
        let agents = "Library/Application Support/Claude/local-agent-mode-sessions/\(account)/\(organization)"
        func agent(_ id: String, title: String, archived: Bool?) {
            var object: [String: Any] = ["sessionId": "local_" + id, "title": title, "sessionType": "dispatch_child"]
            if let archived { object["isArchived"] = archived }
            write("\(agents)/local_\(id).json", line(object))
        }
        let agentFile = home.appendingPathComponent("\(agents)/local_99999999-9999-9999-9999-999999999999.json")
        agent("99999999-9999-9999-9999-999999999999", title: "Different title", archived: false)
        expect((try? ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: deadline)) != nil, "other-kind session with another title is fine")
        agent("99999999-9999-9999-9999-999999999999", title: "Plan the trip", archived: true)
        expect((try? ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: deadline)) != nil, "archived other-kind session is ignored")
        agent("99999999-9999-9999-9999-999999999999", title: "Plan the trip", archived: false)
        fails("same title in another store", .ambiguous) { _ = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: deadline) }
        agent("99999999-9999-9999-9999-999999999999", title: "Plan the trip", archived: nil)
        fails("unflagged other-kind session counts", .ambiguous) { _ = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: deadline) }
        write("\(agents)/local_99999999-9999-9999-9999-999999999999.json", "{broken")
        fails("unreadable other store fails closed", .unreadable) { _ = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: deadline) }
        try fm.removeItem(at: agentFile)
        expect((try? ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: deadline)) != nil, "readable again once the twin is gone")
        expect(ClaudeThread.sharedTitleMessage.hasPrefix("Two chats on this Mac share this title"), "ambiguity wording")

        // A different signed-in account must not match.
        write("Library/Application Support/Claude/config.json", line(["lastKnownAccountUuid": uuid(42)]))
        fails("account mismatch", .unreadable) { _ = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: deadline) }
        write("Library/Application Support/Claude/config.json", line(["lastKnownAccountUuid": account]))
        // The transcript must be the exact indexed file, not a symlink to something else.
        try fm.removeItem(at: home.appendingPathComponent(transcriptPath))
        try fm.createSymbolicLink(at: home.appendingPathComponent(transcriptPath), withDestinationURL: home.appendingPathComponent(".claude.json"))
        fails("symlinked transcript", .noSession) { _ = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: deadline) }
        try fm.removeItem(at: home.appendingPathComponent(transcriptPath))
        fails("missing transcript", .noSession) { _ = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: deadline) }
        // The tail read only takes the last bytes.
        write(transcriptPath, file)
        let binding = try ClaudeThread.binding(title: "Plan the trip", home: home.path)
        let tail = try ClaudeThread.tail(binding, home: home.path, maximum: 300)
        expect(tail.data.count == 300 && tail.startsMidFile, "tail is limited to the requested bytes")

        // Long tool-heavy turns bury the last visible messages: the window widens, in time, and never answers empty.
        let mebi = 1_048_576
        func toolLine(_ n: Int, parent: Int, bytes: Int) -> String {
            "{\"parentUuid\":\"\(uuid(parent))\",\"isSidechain\":false,\"sessionId\":\"\(session)\",\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\""
                + String(repeating: "A", count: bytes) + "\\\" } ] ,\\\\\"}]},\"uuid\":\"\(uuid(n))\",\"toolUseResult\":{\"stdout\":\"x\"}}\n"
        }
        /// Two visible messages, then `mebis` MiB of tool results chained from them, then a small ownership record.
        func buried(mebis: Int, toolBytes: Int = mebi) {
            let url = home.appendingPathComponent(transcriptPath)
            fm.createFile(atPath: url.path, contents: Data((bridge + record(1, parent: nil, type: "user", content: "buried question")
                + record(2, parent: 1, type: "assistant", content: text("buried answer"))).utf8))
            let handle = try! FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            var parent = 2
            for n in 0..<max(1, mebis * mebi / toolBytes) { handle.write(Data(toolLine(100 + n, parent: parent, bytes: toolBytes).utf8)); parent = 100 + n }
            handle.write(Data(bridge.utf8)); handle.closeFile()
        }
        let roomy = ProcessInfo.processInfo.systemUptime + 600
        buried(mebis: 10)
        var wide = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: roomy)
        expect(wide.turns.map(\.text) == ["buried answer", "buried question"] && !wide.limited, "messages 10 MiB back are found, and nothing older exists")
        buried(mebis: 40)
        wide = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: roomy)
        expect(wide.turns.count == 2, "messages 40 MiB back are found")
        buried(mebis: 6, toolBytes: 5 * mebi)
        wide = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: roomy)
        expect(wide.turns.count == 2, "a tool result over the line limit does not break the chain")
        buried(mebis: 100)
        fails("nothing visible within 96 MiB", .tooFarBack) { _ = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: roomy) }
        expect(ThreadReader.tooFarBackMessage == "This chat\u{2019}s recent messages are too far back to read right now. Try again after its next reply.", "too-far-back wording")
        // Time: a wider read is not started when it would not fit.
        buried(mebis: 10)
        var clock = 0.0
        fails("no time to widen", .tooFarBack) { _ = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: 1, now: { clock += 0.4; return clock }) }
        // Smaller windows widen in steps, and the whole-file answer is not marked as cut.
        buried(mebis: 3)
        wide = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: roomy, windows: [1 * mebi, 2 * mebi, 8 * mebi])
        expect(wide.turns.count == 2, "custom windows widen in steps")
        write(transcriptPath, bridge + line(["type": "summary", "sessionId": session]))
        fails("a transcript with no messages", .empty) { _ = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: roomy) }
        write(transcriptPath, file)
        let smallRead = try ClaudeThread.read(title: "Plan the trip", home: home.path, deadline: roomy)
        expect(smallRead.turns.count == 4 && !smallRead.limited, "a small transcript reads whole, as before")
        // Strings holding quotes, braces and backslashes do not confuse the field scan.
        let tricky = bridge + record(1, parent: nil, type: "user", content: "say \"hi\" } ] , \\ done") + record(2, parent: 1, type: "assistant", content: text("ok {\"a\":[1]}"))
        parsed = try ClaudeThread.parse(Data(tricky.utf8), binding: binding, startsMidFile: false)
        expect(parsed.turns.map(\.text) == ["ok {\"a\":[1]}", "say \"hi\" } ] , \\ done"] && !parsed.reachedEdge, "scan survives quotes, braces and backslashes")
        expect(ClaudeThread.scan(Array("{\"type\":".utf8), 9) == nil, "a cut-off line is not scanned")

        // Codex.
        func entry(_ turn: String, _ item: [String: Any]) -> [String: Any] { ["turnId": turn, "item": item] }
        func agent(_ id: String, _ value: String, phase: String? = nil) -> [String: Any] {
            var item: [String: Any] = ["type": "agentMessage", "id": id, "text": value]; if let phase { item["phase"] = phase }; return item
        }
        func user(_ id: String, _ value: String) -> [String: Any] { ["type": "userMessage", "id": id, "content": [["type": "text", "text": value]]] }
        expect(try CodexThread.message(entry("t", agent("a", " Done. ", phase: "final_answer")), turnID: "t")?.turn == ThreadTurn(role: "assistant", text: "Done."), "codex agent message")
        expect(try CodexThread.message(entry("t", agent("a", "thinking", phase: "reasoning")), turnID: "t") == nil, "codex reasoning hidden")
        expect(try CodexThread.message(entry("t", ["type": "commandExecution", "id": "c", "text": "ls"]), turnID: "t") == nil, "codex tool item dropped")
        expect(try CodexThread.message(entry("t", user("u", "question")), turnID: "t")?.turn == ThreadTurn(role: "user", text: "question"), "codex user message")
        expect(try CodexThread.message(entry("t", user("u", "# AGENTS.md instructions for x")), turnID: "t") == nil, "codex AGENTS wrapper dropped")
        expect(try CodexThread.message(entry("t", user("u", "<environment_context>x</environment_context>")), turnID: "t") == nil, "codex environment dropped")
        expect(try CodexThread.message(entry("t", user("u", "# Files mentioned by the user:\n- a\n\n## My request:\nwhat is this <image name=[Image #1]>")), turnID: "t")?.turn.text == "what is this", "codex file wrapper unwrapped")
        fails("entry for another turn", .unreadable) { _ = try CodexThread.message(entry("other", agent("a", "x")), turnID: "t") }

        let thread = uuid(7)
        var calls = [String]()
        func fake(turnsPerPage: Int, totalTurns: Int, itemsPerTurn: Int) -> CodexThread.Call {
            return { method, params in
                calls.append(method)
                switch method {
                case "thread/read": return ["thread": ["id": thread.uppercased()]]
                case "thread/turns/list":
                    let start = Int(params["cursor"] as? String ?? "0")!, end = min(totalTurns, start + turnsPerPage)
                    return ["data": (start..<end).map { ["id": "turn\(totalTurns - 1 - $0)", "status": "completed"] },
                            "nextCursor": end < totalTurns ? String(end) : NSNull()]
                default:
                    let turn = params["turnId"] as! String
                    return ["data": (0..<itemsPerTurn).map { entry(turn, $0 % 2 == 0 ? agent("\(turn)-\($0)", "reply \(turn) \($0)") : user("\(turn)-\($0)", "ask \(turn) \($0)")) },
                            "nextCursor": NSNull()]
                }
            }
        }
        calls = []
        var codex = try CodexThread.read(threadID: thread, call: fake(turnsPerPage: 5, totalTurns: 3, itemsPerTurn: 2))
        expect(codex.turns.count == 6 && !codex.limited && codex.turns[0].text == "reply turn2 0", "codex reads everything small, newest first")
        expect(Set(calls) == ["thread/read", "thread/turns/list", "thread/items/list"], "codex uses only read methods")
        codex = try CodexThread.read(threadID: thread, call: fake(turnsPerPage: 5, totalTurns: 30, itemsPerTurn: 4))
        expect(codex.turns.count == 12 && codex.limited, "codex stops after enough messages and says more exist")
        expect(codex.turns[0].text == "reply turn29 0", "codex starts from the newest turn")
        calls = []
        codex = try CodexThread.read(threadID: thread, call: fake(turnsPerPage: 1, totalTurns: 100, itemsPerTurn: 0))
        expect(codex.turns.isEmpty && codex.limited && calls.count <= CodexThread.requestLimit + 1, "codex request budget holds")
        fails("codex wrong thread id", .unreadable) { _ = try CodexThread.read(threadID: thread, call: { _, _ in ["thread": ["id": uuid(8)]] }) }
        fails("codex non-uuid id", .unreadable) { _ = try CodexThread.read(threadID: "../x", call: { _, _ in [:] }) }
        fails("codex malformed rows", .unreadable) { _ = try CodexThread.read(threadID: thread, call: { method, _ in method == "thread/read" ? ["thread": ["id": thread]] : ["data": "no"] }) }

        // Capabilities follow the route's own gate: installed and unlocked, nothing else.
        expect(["artifacts"].withReadThread(installed: true, unlocked: true) == ["artifacts", "readThread"], "advertised when installed and unlocked, even if the app is closed")
        expect(["artifacts"].withReadThread(installed: true, unlocked: false) == ["artifacts"], "not advertised while locked")
        expect(["artifacts"].withReadThread(installed: false, unlocked: true) == ["artifacts"], "not advertised when not installed")
        expect(["readThread"].withReadThread(installed: true, unlocked: true) == ["readThread"], "never listed twice")
        // The route does no Accessibility work and offers a refresh when a title is not cached.
        let bridgeSource = try String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/RemoteBridge.swift").path, encoding: .utf8)
        let body = bridgeSource.components(separatedBy: "private func readThread(")[1].components(separatedBy: "private func clearDisplaySession")[0]
        expect(!body.contains("loadChats(") && !body.contains("AXIsProcessTrusted") && !body.contains("access."), "readThread does no Accessibility work")
        expect(body.contains("ThreadReader.refreshMessage") && ThreadReader.refreshMessage == "Refresh the chats on your phone, then try again.", "uncached title asks for a refresh")
        let providers = bridgeSource.components(separatedBy: "withReadThread(installed:installed,unlocked:!isLocked)").count - 1
        expect(providers == 2 && bridgeSource.contains("RemoteCodexAvailability.capabilities"), "Claude and Muse advertise readThread through the shared gate")

        // The response shape.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let ok = String(data: try encoder.encode(ThreadSnapshot.ok(provider: "claude", chatID: "claude-1", turns: [ThreadTurn(role: "user", text: "hi")], truncated: false)), encoding: .utf8)!
        expect(ok.contains("\"message\":null") && ok.contains("\"status\":\"ok\"") && ok.contains("\"truncated\":false") && ok.contains("{\"role\":\"user\",\"text\":\"hi\"}"), "ok JSON shape")
        let gone = String(data: try encoder.encode(ThreadSnapshot.unavailable(provider: "muse", chatID: "m", "Nope.")), encoding: .utf8)!
        expect(gone.contains("\"status\":\"unavailable\"") && gone.contains("\"message\":\"Nope.\"") && gone.contains("\"turns\":[]"), "unavailable JSON shape")
        print("Thread reader tests passed: \(count)")
    }
}
