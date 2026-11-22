import Foundation

@main struct CodexActivityTests {
    static var count = 0
    static func expect(_ value: Bool, _ name: String) { guard value else { fatalError("FAIL: " + name) }; count += 1 }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }
        let open: [String: Any] = ["id": "t", "startedAt": 1, "completedAt": NSNull(), "status": "interrupted"]
        let done: [String: Any] = ["id": "t", "startedAt": 1, "completedAt": 5, "status": "completed"]

        // The decision.
        expect(CodexActivity.isWorking(newestTurn: open, modified: ago(5), now: now), "no completedAt and a fresh file is Working")
        expect(CodexActivity.isWorking(newestTurn: open, modified: ago(120), now: now), "exactly at the freshness limit is still Working")
        expect(!CodexActivity.isWorking(newestTurn: open, modified: ago(121), now: now), "no completedAt but a stale file is Saved")
        expect(!CodexActivity.isWorking(newestTurn: open, modified: ago(3600), now: now), "an hour-old unfinished turn is Saved")
        expect(!CodexActivity.isWorking(newestTurn: done, modified: ago(1), now: now), "a completed turn is Saved however fresh")
        expect(CodexActivity.isWorking(newestTurn: open, modified: ago(-30), now: now), "a file a few seconds in the future is fresh")
        expect(!CodexActivity.isWorking(newestTurn: open, modified: ago(-600), now: now), "a file far in the future is not trusted")
        expect(!CodexActivity.isWorking(newestTurn: nil, modified: ago(1), now: now), "no turn is Saved")
        expect(!CodexActivity.isWorking(newestTurn: open, modified: nil, now: now), "no file time is Saved")
        expect(!CodexActivity.isWorking(newestTurn: [:], modified: ago(1), now: now), "an empty turn is Saved")
        expect(!CodexActivity.isWorking(newestTurn: ["id": "t"], modified: ago(1), now: now), "a turn without completedAt is Saved")
        expect(!CodexActivity.isWorking(newestTurn: ["completedAt": "null"], modified: ago(1), now: now), "completedAt as text is Saved")
        expect(!CodexActivity.isWorking(newestTurn: ["completedAt": false], modified: ago(1), now: now), "completedAt as a boolean is Saved")
        expect(!CodexActivity.isWorking(newestTurn: ["completedAt": [Any]()], modified: ago(1), now: now), "completedAt as a list is Saved")
        // The status string says "interrupted" while a turn runs, and "completed" is not trusted over completedAt.
        expect(CodexActivity.isWorking(newestTurn: ["completedAt": NSNull(), "status": "completed"], modified: ago(1), now: now), "status text is ignored")
        expect(!CodexActivity.isWorking(newestTurn: ["completedAt": 7, "status": "interrupted"], modified: ago(1), now: now), "a finished interrupted turn is Saved")
        expect(!CodexActivity.isWorking(newestTurn: ["completedAt": 7, "status": "failed"], modified: ago(1), now: now), "a failed turn is Saved, not an error light")

        // Which chats are asked about.
        var files = [String: Date]()
        for number in 0..<20 { files[String(format: "chat-%02d", number)] = ago(Double(number)) }
        files["old"] = ago(500)
        let order = CodexActivity.probeOrder(files, now: now)
        expect(order.count == CodexActivity.probeLimit && CodexActivity.probeLimit == 8, "capped at eight")
        expect(order == (0..<8).map { String(format: "chat-%02d", $0) }, "newest file first")
        expect(!CodexActivity.probeOrder(files, now: now, limit: 100).contains("old"), "a stale file is never asked about")
        expect(CodexActivity.probeOrder(["a": ago(500), "b": ago(900)], now: now).isEmpty, "nothing fresh means no requests at all")
        expect(CodexActivity.probeOrder([:], now: now).isEmpty, "an empty list asks nothing")
        expect(CodexActivity.probeOrder(files, now: now, limit: 0).isEmpty, "a zero limit asks nothing")
        expect(CodexActivity.probeOrder(["b": ago(3), "a": ago(3)], now: now) == ["a", "b"], "ties break by id, so the order is stable")

        // The request asks for one newest turn, with no messages.
        let request = CodexActivity.turnRequest(threadID: "abc")
        expect(request["threadId"] as? String == "abc" && request["limit"] as? Int == 1
               && request["sortDirection"] as? String == "desc" && request["itemsView"] as? String == "notLoaded" && request.count == 4, "one newest turn, items not loaded")
        expect(CodexActivity.budget <= 1.5 && CodexActivity.freshness == 120, "short deadline and two-minute freshness")

        // Only files inside Codex's home are examined.
        let home = "/Users/x/.codex"
        expect(CodexActivity.trustedRolloutPath("/Users/x/.codex/sessions/2026/11/22/rollout-1.jsonl", home: home), "a rollout under the home is trusted")
        expect(CodexActivity.trustedRolloutPath("/Users/x/.codex/sessions/a.jsonl", home: home + "/"), "a trailing slash on the home is fine")
        expect(!CodexActivity.trustedRolloutPath("/Users/x/.codex-evil/a.jsonl", home: home), "a sibling folder with the same prefix is refused")
        expect(!CodexActivity.trustedRolloutPath("/etc/passwd.jsonl", home: home), "a path outside the home is refused")
        expect(!CodexActivity.trustedRolloutPath("/Users/x/.codex/sessions/../../secret.jsonl", home: home), "dot-dot is refused")
        expect(!CodexActivity.trustedRolloutPath("sessions/a.jsonl", home: home), "a relative path is refused")
        expect(!CodexActivity.trustedRolloutPath("/Users/x/.codex/sessions/a.txt", home: home), "only .jsonl files")
        expect(!CodexActivity.trustedRolloutPath("/Users/x/.codex/sessions/a\0.jsonl", home: home), "a NUL byte is refused")

        // Wiring, read from the sources the way the other tests do.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        func source(_ name: String) throws -> String { try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8) }
        let bridge = try source("RemoteBridge.swift"), protocolSource = try source("RemoteProtocol.swift"), reader = try source("CodexReadOnly.swift")
        expect(bridge.contains(#"state:$0.working ? "Working":"Saved""#), "only Working or Saved is reported for Codex")
        expect(protocolSource.contains(#"result.append("chatActivity")"#), "capability advertised with a working inventory")
        expect(reader.contains("markWorking(&chats") && reader.contains("tighten(to: CodexActivity.budget)"), "check runs on the inventory's own connection under the short deadline")
        expect(!reader.contains("turn/start") && !reader.contains("thread/resume") && !reader.contains("thread/start"), "the activity check sends nothing to a chat")
        print("CodexActivityTests passed: \(count)")
    }
}
