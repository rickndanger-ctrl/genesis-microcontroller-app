import Foundation

@main struct ActivityLogTests {
    static var passed = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("FAIL: " + message) }
        passed += 1
    }

    /// A clock the tests can set, so entries get known times.
    final class Clock {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        func tick() -> Date { defer { time += 1 }; return time }
    }

    static func main() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-log-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // The parent folder does not exist yet: the log must create it.
        let url = root.appendingPathComponent("logs/activity.jsonl")

        let clock = Clock()
        let log = ActivityLog(url: url, now: clock.tick)
        expect(log.recent(10).isEmpty, "A log with no file starts empty")

        let start = clock.time
        log.record(provider: "claude", action: "openChat", status: "confirmed", message: "Opened Trip planning", durationMs: 420)
        let first = log.recent(1)
        expect(first == [ActivityEntry(time: start, provider: "claude", action: "openChat", status: "confirmed", message: "Opened Trip planning", durationMs: 420)],
               "A recorded entry reads back with every field and the injected clock's time")

        var permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        expect(permissions == 0o600, "The log file is readable by its owner only")
        permissions = (try? FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path))?[.posixPermissions] as? Int
        expect(permissions == 0o700, "The folder made for the log is private to its owner")

        log.record(provider: "muse", action: "sendPrompt", status: "failed", message: "No message box found", durationMs: 90)
        let again = ActivityLog(url: url)
        expect(again.recent(10).map(\.action) == ["openChat", "sendPrompt"], "Entries survive into a second log on the same file, oldest first")
        expect(again.recent(10)[1].time == start + 1, "Each entry takes the clock's time at the moment it was recorded")
        again.record(provider: "codex", action: "pressControl", status: "queued", message: "Queued", durationMs: 5)
        expect(ActivityLog(url: url).recent(10).count == 3, "An entry recorded by the second log is saved too")
        permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        expect(permissions == 0o600, "The log file stays private after it is rewritten")

        // Recent bounds.
        expect(again.recent(0).isEmpty && again.recent(-3).isEmpty, "Asking for zero or a negative count returns nothing")
        expect(again.recent(2).map(\.action) == ["sendPrompt", "pressControl"], "Asking for fewer than exist returns the newest, oldest first")
        expect(again.recent(500).count == 3, "Asking for more than exist returns what there is")

        // The limit keeps the newest.
        let limitedURL = root.appendingPathComponent("limited.jsonl")
        let limited = ActivityLog(url: limitedURL, limit: 3)
        for index in 1...5 {
            limited.record(provider: "claude", action: "step\(index)", status: "confirmed", message: "", durationMs: index)
        }
        expect(limited.recent(10).map(\.action) == ["step3", "step4", "step5"], "Past the limit the oldest entries are dropped")
        expect(ActivityLog(url: limitedURL, limit: 3).recent(10).map(\.action) == ["step3", "step4", "step5"], "The file holds only the newest entries too")
        expect(ActivityLog(url: limitedURL, limit: 2).recent(10).map(\.action) == ["step4", "step5"], "A smaller limit on load keeps only the newest entries")
        let lineCount = ((try? String(contentsOf: limitedURL, encoding: .utf8)) ?? "").split(separator: "\n").count
        expect(lineCount == 3, "The file has one line per kept entry")

        // A damaged line costs only itself.
        let corruptURL = root.appendingPathComponent("corrupt.jsonl")
        let good = ActivityLog(url: corruptURL)
        good.record(provider: "claude", action: "before", status: "confirmed", message: "ok", durationMs: 1)
        good.record(provider: "claude", action: "after", status: "confirmed", message: "ok", durationMs: 2)
        var text = (try? String(contentsOf: corruptURL, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map(String.init)
        text = [lines[0], "{not json", "", "{\"time\":\"yesterday\"}", lines[1]].joined(separator: "\n") + "\n"
        try? text.write(to: corruptURL, atomically: true, encoding: .utf8)
        let survivors = ActivityLog(url: corruptURL)
        expect(survivors.recent(10).map(\.action) == ["before", "after"], "Lines that do not decode are skipped and the good lines survive")
        survivors.record(provider: "claude", action: "next", status: "confirmed", message: "ok", durationMs: 3)
        expect(ActivityLog(url: corruptURL).recent(10).map(\.action) == ["before", "after", "next"], "Recording after a corrupt file rewrites it cleanly")
        try? Data([0xFF, 0xFE, 0x00, 0x7B]).write(to: corruptURL)
        expect(ActivityLog(url: corruptURL).recent(10).isEmpty, "A file of binary garbage loads as an empty log")

        // Sanitising.
        let cleanURL = root.appendingPathComponent("clean.jsonl")
        let clean = ActivityLog(url: cleanURL)
        clean.record(provider: "claude", action: "openChat", status: "failed", message: "line one\nline two\r\nline\tthree", durationMs: 1)
        expect(clean.recent(1)[0].message == "line one line two  line three", "Newlines and tabs in a message become spaces")
        expect((try? String(contentsOf: cleanURL, encoding: .utf8))?.split(separator: "\n").count == 1, "An entry is always exactly one line in the file")
        clean.record(provider: "claude", action: "openChat", status: "failed", message: String(repeating: "x", count: 500), durationMs: 1)
        expect(clean.recent(1)[0].message.count == 200, "A long message is cut to 200 characters")
        clean.record(provider: "claude", action: "openChat", status: "failed", message: String(repeating: "y", count: 200), durationMs: 1)
        expect(clean.recent(1)[0].message.count == 200, "A message of exactly 200 characters is kept whole")
        let long = String(repeating: "z", count: 100)
        clean.record(provider: long, action: long, status: long, message: "m", durationMs: 1)
        let cut = clean.recent(1)[0]
        expect(cut.provider.count == 40 && cut.action.count == 40 && cut.status.count == 40, "Provider, action and status are each cut to 40 characters")
        clean.record(provider: "p", action: "a", status: "s", message: "m", durationMs: -50)
        expect(clean.recent(1)[0].durationMs == 0, "A negative duration is stored as zero")
        clean.record(provider: "p", action: "a", status: "s", message: String(repeating: "é", count: 300), durationMs: 7)
        expect(ActivityLog(url: cleanURL).recent(1)[0].message.count == 200, "Cutting counts characters, so accented text is not split mid-character")

        // An unwritable location must not hurt the caller.
        let blocked = ActivityLog(url: URL(fileURLWithPath: "/dev/null/activity.jsonl"))
        blocked.record(provider: "claude", action: "openChat", status: "confirmed", message: "ok", durationMs: 1)
        expect(blocked.recent(1).count == 1, "A log that cannot reach its file still records in memory without failing")

        print("Activity log: \(passed) checks passed")
    }
}
