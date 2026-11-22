import Foundation
import SQLite3

@main struct GeminiChatListTests {
    static var count = 0
    static func expect(_ value: Bool, _ name: String) { guard value else { fatalError("FAIL: " + name) }; count += 1 }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }
    static let idle = GeminiChatList.idleStatus, running = "CASCADE_RUN_STATUS_RUNNING"
    static func id(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
    static func row(_ n: Int = 1, title: String = "A chat", status: String = idle, notFullyIdle: Int = 0, killed: Int = 0, depth: Int = 0, parent: String = "", modified: Date? = ago(1000)) -> GeminiChatList.Row {
        .init(id: id(n), title: title, status: status, notFullyIdle: notFullyIdle, killed: killed, nestingDepth: depth, parentID: parent, lastModified: modified)
    }
    static func state(_ r: GeminiChatList.Row) -> String { GeminiChatList.state(r, now: now) }

    static func main() throws {
        // State rule.
        expect(state(row()) == "Saved", "idle and fully idle is Saved")
        expect(state(row(modified: ago(1))) == "Saved", "idle is Saved however fresh")
        expect(state(row(status: running, modified: ago(5))) == "Working", "a running status with a fresh row is Working")
        expect(state(row(status: running, modified: ago(120))) == "Working", "exactly at the freshness limit is Working")
        expect(state(row(status: running, modified: ago(121))) == "Saved", "a stale running row is Saved")
        expect(state(row(status: running, modified: ago(3600))) == "Saved", "a crashed run does not stay lit")
        expect(state(row(status: running, modified: ago(-30))) == "Working", "a row a few seconds in the future is fresh")
        expect(state(row(status: running, modified: ago(-600))) == "Saved", "a row far in the future is not trusted")
        expect(state(row(status: running, modified: nil)) == "Saved", "no time is Saved")
        var quietRun = row(status: running, modified: ago(3600)); quietRun.touched = ago(3)
        expect(state(quietRun) == "Working", "a run in a chat that had been quiet lights from its file time")
        quietRun.touched = ago(500)
        expect(state(quietRun) == "Saved", "a stale file time does not light")
        var idleTouched = row(modified: ago(3600)); idleTouched.touched = ago(1)
        expect(state(idleTouched) == "Saved", "a fresh file time never lights an idle chat")
        let stampFolder = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-stamp-" + UUID().uuidString).path
        try? FileManager.default.createDirectory(atPath: stampFolder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: stampFolder + "/" + id(1).lowercased() + ".db", contents: Data())
        let stamped = GeminiChatList.stamped([row(1, status: running, modified: ago(3600)), row(2, modified: ago(3600))], folder: stampFolder)
        expect(stamped[0].touched != nil, "a working row is stamped from its conversation file")
        expect(stamped[1].touched == nil, "an idle row is not stamped")
        try? FileManager.default.removeItem(atPath: stampFolder)
        expect(state(row(notFullyIdle: 1, modified: ago(5))) == "Saved", "idle status is Saved even when not fully idle")
        expect(state(row(notFullyIdle: 1, modified: ago(500))) == "Saved", "not fully idle but stale is Saved")
        expect(state(row(status: running, notFullyIdle: 1, modified: ago(5))) == "Working", "running and not fully idle is Working")
        expect(state(row(status: "CASCADE_RUN_STATUS_SOMETHING_NEW", modified: ago(5))) == "Saved", "an unknown CASCADE_RUN_STATUS value never lights")
        expect(state(row(status: "CASCADE_RUN_STATUS_BUSY", modified: ago(5))) == "Working", "busy and fresh is Working")
        expect(state(row(status: "CASCADE_RUN_STATUS_CANCELING", modified: ago(5))) == "Working", "canceling and fresh is Working")
        expect(state(row(status: "CASCADE_RUN_STATUS_UNSPECIFIED", modified: ago(5))) == "Saved", "unspecified is Saved")
        expect(state(row(status: "CASCADE_RUN_STATUS_SOMETHING_NEW", modified: ago(500))) == "Saved", "an unknown status with a stale row is Saved")
        expect(state(row(status: "", modified: ago(5))) == "Saved", "an empty status is Saved")
        expect(state(row(status: "garbage", modified: ago(5))) == "Saved", "a status that is not a CASCADE_RUN_STATUS value is Saved")
        expect(state(row(status: running, killed: 1, modified: ago(5))) == "Saved", "a killed row is Saved")
        expect(state(row(notFullyIdle: 1, killed: 1, modified: ago(5))) == "Saved", "a killed row that is not fully idle is Saved")
        expect(["Working", "Saved"].contains(state(row(status: running, modified: ago(5)))), "states are the same strings Codex uses")

        // Which rows are offered, and in what order.
        expect(GeminiChatList.offered([row(1, depth: 1), row(2, parent: id(9)), row(3)], now: now).map(\.id) == [id(3)], "sub-conversations are not offered")
        expect(GeminiChatList.offered([row(1, title: ""), row(2, title: "  \n "), row(3, title: "Real")], now: now).map(\.title) == ["Real"], "empty and blank titles are not offered")
        expect(GeminiChatList.offered([row(1, modified: ago(300)), row(2, modified: ago(10)), row(3, modified: ago(100))], now: now).map(\.id) == [id(2), id(3), id(1)], "newest first")
        expect(GeminiChatList.offered([row(1, modified: nil), row(2, modified: ago(10))], now: now).map(\.id) == [id(2), id(1)], "a row with no time goes last")
        expect(GeminiChatList.offered([row(2, modified: ago(10)), row(1, modified: ago(10))], now: now).map(\.id) == [id(1), id(2)], "equal times keep a stable order")
        expect(GeminiChatList.offered([row(1), row(1)], now: now).count == 1, "a repeated conversation is offered once")
        expect(GeminiChatList.offered([], now: now).isEmpty, "no rows, no chats")
        let many = (1...600).map { row($0, modified: ago(Double($0))) }
        let capped = GeminiChatList.offered(many, now: now)
        expect(capped.count == 500 && GeminiChatList.maximumChats == 500 && capped.first?.id == id(1) && capped.last?.id == id(500), "capped at 500, newest kept")
        expect(GeminiChatList.offered(many, now: now, maximum: 3).count == 3 && GeminiChatList.offered(many, now: now, maximum: -1).isEmpty, "a custom cap is honoured and never negative")
        expect(GeminiChatList.offered([row(1, title: String(repeating: "x", count: 1000))], now: now)[0].title.count == 240, "long titles are cut to 240")
        let upper = GeminiChatList.offered([GeminiChatList.Row(id: "ABCDEF01-0000-4000-8000-000000000001", title: "T", status: idle, notFullyIdle: 0, killed: 0, nestingDepth: 0, parentID: "", lastModified: ago(1))], now: now)
        expect(upper.map(\.id) == ["abcdef01-0000-4000-8000-000000000001"], "the id is the exact UUID, lowercase")
        expect(GeminiChatList.offered([GeminiChatList.Row(id: "not-a-uuid", title: "T", status: idle, notFullyIdle: 0, killed: 0, nestingDepth: 0, parentID: "", lastModified: ago(1))], now: now).isEmpty, "a row without a UUID is dropped")
        let mixed = GeminiChatList.offered([row(1, status: running, modified: ago(5)), row(2, modified: ago(20))], now: now)
        expect(mixed.map(\.state) == ["Working", "Saved"], "states travel with the offered chats")

        // Times as Gemini writes them.
        func t(_ text: String) -> Double? { GeminiChatList.parseTime(text)?.timeIntervalSince1970 }
        expect(t("2026-11-22 19:01:43.15901+00:00") == 1_795_374_103.15901 || abs(t("2026-11-22 19:01:43.15901+00:00")! - 1_795_374_103.15901) < 0.001, "five fraction digits and +00:00")
        expect(abs(t("2026-11-22 19:01:43+00:00")! - 1_795_374_103) < 0.001, "no fraction")
        expect(abs(t("2026-11-22T19:01:43Z")! - 1_795_374_103) < 0.001, "T and Z")
        expect(abs(t("2026-11-22 20:01:43+01:00")! - 1_795_374_103) < 0.001, "a positive offset is subtracted")
        expect(abs(t("2026-11-22 14:01:43-05:00")! - 1_795_374_103) < 0.001, "a negative offset is added")
        expect(abs(t("2026-11-22 19:01:43.423054789+00:00")! - 1_795_374_103.423054789) < 0.001, "nine fraction digits")
        expect(abs(t("2026-11-22 19:01:43")! - 1_795_374_103) < 0.001, "no offset reads as UTC")
        for bad in ["", "yesterday", "2026-13-22 19:01:43+00:00", "2026-11-22 25:01:43+00:00", "2026-11-22", "2026-11-22 19:01+00:00", "2026-11-22 19:01:43.x1+00:00", "2026-11-22 19:01:43+0a:00"] {
            expect(t(bad) == nil, "unparseable time is nil: " + bad)
        }

        // Reading a database, against fixtures this test builds. Never Gemini's own.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func open(_ path: String) -> OpaquePointer { var db: OpaquePointer?; expect(sqlite3_open(path, &db) == SQLITE_OK, "fixture opens"); return db! }
        func run(_ db: OpaquePointer, _ sql: String) { expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "fixture sql: " + sql) }
        let full = "conversation_id TEXT, title TEXT, preview TEXT, step_count INTEGER, last_modified_time TEXT, status TEXT, not_fully_idle INTEGER, killed INTEGER, nesting_depth INTEGER, parent_conversation_id TEXT, raw_summary BLOB"
        func fill(_ db: OpaquePointer) {
            run(db, "INSERT INTO conversation_summaries (conversation_id,title,preview,last_modified_time,status,not_fully_idle,killed,nesting_depth,parent_conversation_id,raw_summary) VALUES ('\(id(1))','First','SECRET-PREVIEW','2026-11-22 19:01:43.15901+00:00','\(idle)',0,0,0,'',x'00')")
            run(db, "INSERT INTO conversation_summaries (conversation_id,title,preview,last_modified_time,status,not_fully_idle,killed,nesting_depth,parent_conversation_id,raw_summary) VALUES ('\(id(2))','Second','SECRET-PREVIEW','2026-11-22 19:05:00+00:00','\(running)',1,0,0,NULL,NULL)")
        }

        // A database with no -wal: read without creating any file next to it.
        let quiet = folder.appendingPathComponent("quiet").path
        do {
            let db = open(quiet); run(db, "PRAGMA journal_mode=WAL; CREATE TABLE conversation_summaries (\(full));"); fill(db)
            run(db, "PRAGMA wal_checkpoint(TRUNCATE)"); sqlite3_close(db)
            // SQLite may leave an empty -wal and a stale -shm behind; a database Gemini has closed has neither.
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: quiet + suffix) }
        }
        expect(!FileManager.default.fileExists(atPath: quiet + "-wal") && !FileManager.default.fileExists(atPath: quiet + "-shm"), "fixture: a closed WAL database leaves no side files")
        let before = try Data(contentsOf: URL(fileURLWithPath: quiet))
        if case .rows(let rows) = GeminiChatList.read(path: quiet, now: now) {
            expect(rows.count == 2, "both rows are read")
            let second = rows.first { $0.id == id(2) }!
            expect(second.title == "Second" && second.status == running && second.notFullyIdle == 1 && second.parentID == "" && second.killed == 0 && second.nestingDepth == 0, "columns map to fields, NULL parent is empty")
            expect(abs(rows.first { $0.id == id(1) }!.lastModified!.timeIntervalSince1970 - 1_795_374_103.15901) < 0.001, "the time is parsed")
        } else { expect(false, "a quiet database is readable") }
        expect(!FileManager.default.fileExists(atPath: quiet + "-wal") && !FileManager.default.fileExists(atPath: quiet + "-shm"), "reading creates no -wal or -shm")
        expect(try Data(contentsOf: URL(fileURLWithPath: quiet)) == before, "reading does not change the file")

        // A database a writer still holds open, with rows only in the -wal.
        let live = folder.appendingPathComponent("live").path
        let writer = open(live)
        run(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE conversation_summaries (\(full));")
        run(writer, "PRAGMA wal_checkpoint(TRUNCATE)"); fill(writer)
        expect((try? FileManager.default.attributesOfItem(atPath: live + "-wal")[.size] as? NSNumber)?.intValue ?? 0 > 0, "fixture: rows are waiting in the -wal")
        if case .rows(let rows) = GeminiChatList.read(path: live, now: now) { expect(rows.count == 2, "rows still in the WAL are seen") } else { expect(false, "a live WAL database is readable") }
        run(writer, "INSERT INTO conversation_summaries (conversation_id,title,last_modified_time,status,not_fully_idle,killed,nesting_depth,parent_conversation_id) VALUES ('\(id(3))','Third','2026-11-22 19:06:00+00:00','\(idle)',0,0,0,'')")
        if case .rows(let rows) = GeminiChatList.read(path: live, now: now) { expect(rows.count == 3, "a row written after the last read is seen") } else { expect(false, "a live WAL database stays readable") }
        // A writer holding an open write transaction does not block a reader, and a held lock is "busy", not a hang.
        run(writer, "BEGIN IMMEDIATE")
        if case .rows(let rows) = GeminiChatList.read(path: live, now: now) { expect(rows.count == 3, "an open write transaction does not block reading") } else { expect(false, "reading beside an open writer") }
        run(writer, "COMMIT"); sqlite3_close(writer)

        // A -wal with no -shm (Gemini crashed): not read, nothing copied, the original left alone.
        let crashed = folder.appendingPathComponent("crashed").path
        let holder = open(crashed)
        run(holder, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE conversation_summaries (\(full));"); run(holder, "PRAGMA wal_checkpoint(TRUNCATE)"); fill(holder)
        try FileManager.default.copyItem(atPath: crashed, toPath: folder.appendingPathComponent("crashed2").path)
        try FileManager.default.copyItem(atPath: crashed + "-wal", toPath: folder.appendingPathComponent("crashed2").path + "-wal")
        sqlite3_close(holder)
        try? FileManager.default.removeItem(atPath: folder.appendingPathComponent("crashed2").path + "-shm")
        let orphan = folder.appendingPathComponent("crashed2").path
        expect(GeminiChatList.read(path: orphan, now: now) == .failed, "a -wal with no -shm is not read")
        expect(!FileManager.default.fileExists(atPath: orphan + "-shm"), "refusing an orphan -wal leaves no -shm next to the original")

        // Schema drift, absence and damage.
        expect(GeminiChatList.read(path: folder.appendingPathComponent("nothing.db").path) == .missing, "no database is missing, not an error")
        let drift = folder.appendingPathComponent("drift").path
        do { let db = open(drift); run(db, "CREATE TABLE conversation_summaries (conversation_id TEXT, title TEXT, status TEXT); INSERT INTO conversation_summaries VALUES ('\(id(1))','x','\(idle)')"); sqlite3_close(db) }
        expect(GeminiChatList.read(path: drift) == .unsupported, "a missing column is unsupported")
        let renamed = folder.appendingPathComponent("renamed").path
        do { let db = open(renamed); run(db, "CREATE TABLE other (a TEXT)"); sqlite3_close(db) }
        expect(GeminiChatList.read(path: renamed) == .unsupported, "a missing table is unsupported")
        let junk = folder.appendingPathComponent("junk").path
        try Data("this is not a database at all".utf8).write(to: URL(fileURLWithPath: junk))
        expect(GeminiChatList.read(path: junk) == .failed, "a damaged file fails without crashing")
        let empty = folder.appendingPathComponent("empty").path
        FileManager.default.createFile(atPath: empty, contents: Data())
        if case .unsupported = GeminiChatList.read(path: empty) {} else { expect(false, "an empty file has no table") ; }
        expect(GeminiChatList.unreadableReason(.unsupported) != GeminiChatList.unreadableReason(.busy) && GeminiChatList.unreadableReason(nil).contains("Gemini"), "each reading has its own reason")

        // Only the listed columns are ever selected.
        let source = try String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/GeminiChatList.swift").path, encoding: .utf8)
        expect(!GeminiChatList.columns.contains("preview") && !GeminiChatList.columns.contains("raw_summary") && GeminiChatList.columns.count == 8, "preview and raw_summary are never selected")
        expect(!source.contains("SQLITE_OPEN_READWRITE") && !source.contains("SQLITE_OPEN_CREATE") && source.components(separatedBy: "sqlite3_exec").count == 1, "the reader only opens read-only and runs no statements besides its two reads")

        // The bridge: refusals and no fall-through to another provider.
        let bridge = try String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/RemoteBridge.swift").path, encoding: .utf8)
        let execute = bridge.components(separatedBy: "func execute(_ command:RemoteCommand) async -> RemoteReceipt {")[1]
        let gate = execute.range(of: "command.provider==\"gemini\"")!.lowerBound
        expect(gate < execute.range(of: "RemoteNavigationLease.commands.contains")!.lowerBound && gate < execute.range(of: "command.action==\"openArtifact\"")!.lowerBound && gate < execute.range(of: "command.action==\"launchApp\"")!.lowerBound, "every Gemini command is refused before any other path")
        expect(GeminiChatList.refusal(for: "stop") == GeminiSend.stopRefusal && GeminiChatList.refusal(for: "newChat").contains("new Gemini chat") && !GeminiChatList.refusal(for: "nativeVoice").isEmpty, "refusal wording")
        let thread = bridge.components(separatedBy: "private func readThread(")[1].components(separatedBy: "/// One Muse read per chat")[0]
        expect(thread.contains("provider==\"gemini\"") && thread.contains("GeminiThread.snapshot") && !thread.contains("default:\n            return await museThread"), "Gemini threads have their own reader and the default no longer reads Muse")
        expect(bridge.contains("provider==\"gemini\" ? GeminiChatList.bundle") && bridge.contains("parameter(\"provider\")==\"gemini\""), "status and chat list know Gemini")

        print("Gemini chat list: \(count) checks passed")
    }
}
