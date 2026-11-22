import Foundation
import SQLite3

@main struct GeminiThreadTests {
    static var count = 0
    static func expect(_ value: Bool, _ name: String) { guard value else { fatalError("FAIL: " + name) }; count += 1 }

    // MARK: Hand-encoded protobuf
    static func varint(_ value: UInt64) -> [UInt8] {
        var out = [UInt8](), rest = value
        repeat { var byte = UInt8(rest & 0x7f); rest >>= 7; if rest != 0 { byte |= 0x80 }; out.append(byte) } while rest != 0
        return out
    }
    static func message(_ field: Int, _ body: [UInt8]) -> [UInt8] { varint(UInt64(field << 3 | 2)) + varint(UInt64(body.count)) + body }
    static func string(_ field: Int, _ text: String) -> [UInt8] { message(field, Array(text.utf8)) }
    static func number(_ field: Int, _ value: UInt64) -> [UInt8] { varint(UInt64(field << 3)) + varint(value) }
    static func user(_ text: String) -> [UInt8] { number(1, 14) + message(19, number(1, 7) + string(2, text)) }
    static func reply(_ text: String?, hidden: String = "HIDDEN-REASONING") -> [UInt8] {
        number(1, 15) + message(20, (text.map { string(1, $0) } ?? []) + string(3, hidden))
    }
    static func injected(sender: String?, body: String?) -> [UInt8] {
        var inner = [UInt8]()
        if let sender { inner += string(3, sender) }
        if let body { inner += string(4, body) }
        return message(114, message(4, inner))
    }

    static let id = "7effad46-9779-4a8d-b2db-d5a0643f73a0"
    static let otherID = "00000000-0000-4000-8000-000000000002"
    static let schema = "CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL DEFAULT 0, status integer NOT NULL DEFAULT 0, has_subtrajectory numeric, metadata blob, error_details blob, permissions blob, task_details blob, render_info blob, step_payload blob, step_format integer NOT NULL DEFAULT 0)"

    static func open(_ path: String) -> OpaquePointer { var db: OpaquePointer?; expect(sqlite3_open(path, &db) == SQLITE_OK, "fixture opens"); return db! }
    static func run(_ db: OpaquePointer, _ sql: String) { expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "fixture sql: " + sql) }
    static func insert(_ db: OpaquePointer, _ idx: Int, type: Int, status: Int = 3, format: Int = 0, payload: [UInt8]?) {
        var statement: OpaquePointer?
        expect(sqlite3_prepare_v2(db, "INSERT INTO steps (idx, step_type, status, step_format, step_payload) VALUES (?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK, "fixture insert prepares")
        sqlite3_bind_int64(statement, 1, Int64(idx)); sqlite3_bind_int64(statement, 2, Int64(type)); sqlite3_bind_int64(statement, 3, Int64(status)); sqlite3_bind_int64(statement, 4, Int64(format))
        if let payload { _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32(payload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } } else { sqlite3_bind_null(statement, 5) }
        expect(sqlite3_step(statement) == SQLITE_DONE, "fixture insert runs"); sqlite3_finalize(statement)
    }
    static func texts(_ reading: GeminiThread.Reading) -> [String] { if case .turns(let t, _) = reading { return t.map { $0.role + ":" + $0.text } }; return ["<not turns>"] }

    static func main() throws {
        // The wire-format reader.
        func slice(_ bytes: [UInt8]) -> ArraySlice<UInt8> { bytes[...] }
        expect(GeminiThread.Proto.varint(slice([0xAC, 0x02]), 0)?.value == 300, "a two-byte varint")
        expect(GeminiThread.Proto.varint(slice([0x80]), 0) == nil, "a truncated varint is unreadable")
        expect(GeminiThread.Proto.varint(slice([UInt8](repeating: 0xff, count: 10) + [0x01]), 0) == nil, "an over-long varint is unreadable")
        expect(GeminiThread.Proto.string(slice(string(2, "héllo")), field: 2) == "héllo", "a string field")
        expect(GeminiThread.Proto.bytes(slice(string(2, "a") + string(2, "b")), field: 2).map { String(decoding: $0, as: UTF8.self) } == "a", "the first occurrence wins")
        expect(GeminiThread.Proto.string(slice(number(2, 5) + string(2, "x")), field: 2) == "x", "a varint with the same number is not the string")
        expect(GeminiThread.Proto.string(slice([0x0D, 1, 2, 3, 4] + [0x11, 1, 2, 3, 4, 5, 6, 7, 8] + string(2, "after")), field: 2) == "after", "fixed32 and fixed64 are stepped over")
        expect(GeminiThread.Proto.string(slice([0x0D, 1, 2, 3] + string(2, "x")), field: 2) == nil, "a truncated fixed32 is unreadable")
        expect(GeminiThread.Proto.string(slice([0x11, 1, 2, 3]), field: 2) == nil, "a truncated fixed64 is unreadable")
        expect(GeminiThread.Proto.string(slice(string(2, "x") + [0x12, 0x09, 0x41]), field: 2) == nil, "a length past the end poisons the message, even after the field was found")
        expect(GeminiThread.Proto.string(slice([0x12, 0x05, 0x41, 0x42]), field: 2) == nil, "a truncated string is unreadable")
        expect(GeminiThread.Proto.string(slice([0x0B, 0x0C] + string(2, "x")), field: 2) == nil, "a group is unreadable")
        expect(GeminiThread.Proto.string(slice([0x00, 0x01] + string(2, "x")), field: 2) == nil, "field number 0 is unreadable")
        expect(GeminiThread.Proto.string(slice([0x07, 0x00]), field: 2) == nil, "a reserved wire type is unreadable")
        expect(GeminiThread.Proto.string(slice([0x12, 0x02, 0xff, 0xfe]), field: 2) == nil, "invalid UTF-8 is unreadable")
        expect(GeminiThread.Proto.string(slice([]), field: 2) == nil, "an empty message has no field")

        // Each step-type rule.
        func turn(_ type: Int, _ payload: [UInt8], status: Int = 3, format: Int = 0) -> ThreadTurn? { GeminiThread.turn(type: type, status: status, format: format, payload: payload[...]) }
        expect(turn(14, user("Hello there")) == ThreadTurn(role: "user", text: "Hello there"), "14 is the user's text from field 19.2")
        expect(turn(14, user("Hello"), status: 2) == nil, "a user step that is not done is skipped")
        expect(turn(14, number(1, 14) + message(19, number(1, 7))) == nil, "a user step without text is skipped")
        expect(turn(14, number(1, 14) + string(2, "wrong place")) == nil, "text outside field 19 is not a user message")
        expect(turn(14, user(" \n\t ")) == nil, "a whitespace-only message is skipped")
        expect(turn(14, user("a\u{0}b\u{7}c\nd")) == ThreadTurn(role: "user", text: "abc\nd"), "control characters are cleaned, line breaks kept")
        expect(turn(15, reply("The answer")) == ThreadTurn(role: "assistant", text: "The answer"), "15 is Gemini's reply from field 20.1")
        expect(turn(15, reply("The answer"))?.text.contains("HIDDEN") == false, "hidden reasoning (field 20.3) never leaks")
        expect(turn(15, reply(nil, hidden: "HIDDEN-ONLY")) == nil, "a reply with only hidden reasoning is skipped")
        expect(turn(15, reply("")) == nil, "an empty reply is skipped")
        expect(turn(15, reply("  ")) == nil, "a blank reply is skipped")
        expect(turn(15, number(1, 15)) == nil, "a reply step with no message is skipped")
        expect(turn(15, reply("Still typing"), status: 2) == ThreadTurn(role: "assistant", text: "Still typing"), "a streaming reply with text is shown")
        expect(turn(15, reply("From field 3 only?", hidden: "HIDDEN") ) != nil && turn(15, number(1, 15) + message(20, string(3, "HIDDEN"))) == nil, "field 3 alone is never a reply")
        expect(turn(101, injected(sender: "system", body: "Sent from the phone")) == ThreadTurn(role: "user", text: "Sent from the phone"), "101 from system is a controller message")
        expect(turn(101, injected(sender: "System", body: "x")) == nil && turn(101, injected(sender: "system ", body: "x")) == nil && turn(101, injected(sender: "", body: "x")) == nil, "the sender must be exactly system")
        expect(turn(101, injected(sender: id + "/task-37", body: "sub-task result")) == nil, "a sub-task sender is skipped")
        expect(turn(101, injected(sender: "system", body: nil)) == nil, "no body is skipped")
        expect(turn(101, injected(sender: nil, body: "x")) == nil, "no sender is skipped")
        expect(turn(101, message(114, string(1, "x"))) == nil, "no field 4 is skipped")
        expect(turn(101, injected(sender: "system", body: "x"), status: 2) == nil, "an injected step that is not done is skipped")
        for other in [132, 17, 0, 13, 16, 100, 102, -1] { expect(turn(other, user("tool") + reply("tool")) == nil, "step type \(other) is skipped") }
        expect(turn(14, user("x"), format: 1) == nil && turn(15, reply("x"), format: 2) == nil && turn(101, injected(sender: "system", body: "x"), format: 7) == nil, "an unknown step_format is skipped")
        expect(turn(14, Array(user("Hello").dropLast(3))) == nil && turn(15, Array(reply("Hello").dropLast(2))) == nil, "truncated payloads are skipped")
        expect(turn(14, [0xff, 0xff, 0xff]) == nil && turn(15, [0x00]) == nil && turn(101, []) == nil, "garbage payloads are skipped")

        // Fixtures. Never Gemini's own files.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-thread-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String) -> String { folder.appendingPathComponent(name + ".db").path }
        func quiet(_ name: String, _ fill: (OpaquePointer) -> Void) -> String {
            let path = file(name), db = open(path)
            run(db, "PRAGMA journal_mode=WAL; " + schema); fill(db)
            run(db, "PRAGMA wal_checkpoint(TRUNCATE)"); sqlite3_close(db)
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            return path
        }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

        // Order, the rules together, and nothing created or changed beside the file.
        let mixed = quiet("mixed") { db in
            insert(db, 5, type: 15, payload: reply("Answer two"))
            insert(db, 1, type: 14, payload: user("Question one"))
            insert(db, 3, type: 132, payload: user("tool step"))
            insert(db, 2, type: 15, payload: reply("Answer one"))
            insert(db, 4, type: 101, payload: injected(sender: "system", body: "Phone message"))
            insert(db, 6, type: 101, payload: injected(sender: id + "/task-1", body: "hidden sub-task"))
            insert(db, 7, type: 15, payload: reply(nil))
            insert(db, 8, type: 14, status: 1, payload: user("not done"))
            insert(db, 9, type: 14, format: 3, payload: user("future format"))
            insert(db, 10, type: 15, payload: Array(reply("Cut off").dropLast(4)))
            insert(db, 11, type: 14, payload: nil)
            insert(db, 12, type: 14, payload: [])
        }
        expect(!exists(mixed + "-wal") && !exists(mixed + "-shm"), "fixture: no side files")
        let mixedBefore = try Data(contentsOf: URL(fileURLWithPath: mixed))
        expect(texts(GeminiThread.read(path: mixed)) == ["assistant:Answer two", "user:Phone message", "assistant:Answer one", "user:Question one"], "newest first by idx, the rules applied, nothing merged")
        expect(!exists(mixed + "-wal") && !exists(mixed + "-shm"), "reading creates no -wal or -shm")
        expect(try Data(contentsOf: URL(fileURLWithPath: mixed)) == mixedBefore, "reading does not change the file")
        let snap = GeminiThread.snapshot(chatID: id, offered: [id], folder: "/nonexistent")
        expect(snap.status == "unavailable" && snap.message == GeminiThread.missing, "a missing folder or file is unavailable, not a crash")

        // The snapshot, in the exact shape the phone reads.
        try FileManager.default.copyItem(atPath: mixed, toPath: file(id))
        let ok = GeminiThread.snapshot(chatID: id, offered: [id, otherID], folder: folder.path)
        expect(ok.status == "ok" && ok.provider == "gemini" && ok.chatID == id && !ok.truncated && ok.message == nil, "an offered chat reads ok")
        expect(ok.turns.map { $0.role + ":" + $0.text } == ["user:Question one", "assistant:Answer one", "user:Phone message", "assistant:Answer two"], "turns run oldest to newest")
        let json = String(decoding: try JSONEncoder().encode(ok), as: UTF8.self)
        expect(json.contains("\"status\":\"ok\"") && json.contains("\"provider\":\"gemini\"") && json.contains("\"message\":null") && json.contains("\"truncated\":false") && json.contains("\"turns\":[{") && json.contains("\"role\":\"user\"") && json.contains("\"text\":\"Question one\""), "the JSON shape matches the other providers")
        expect(!json.contains("HIDDEN") && !json.contains("tool step") && !json.contains("sub-task") && !json.contains("not done") && !json.contains("future format"), "nothing hidden or skipped reaches the phone")

        // Offered and exact-UUID rules.
        let notOffered = GeminiThread.snapshot(chatID: id, offered: [otherID], folder: folder.path)
        expect(notOffered.status == "unavailable" && notOffered.message == GeminiThread.notOffered && notOffered.turns.isEmpty, "a chat the list does not offer is unavailable")
        let upper = GeminiThread.snapshot(chatID: id.uppercased(), offered: [id], folder: folder.path)
        expect(upper.status == "unavailable" && upper.message == GeminiThread.notOffered, "an uppercase UUID is refused")
        for bad in ["", "../" + id, id + "/../x", "not-a-uuid", " " + id, id + "\n"] {
            expect(GeminiThread.snapshot(chatID: bad, offered: [id, bad], folder: folder.path).status == "unavailable", "an id that is not a lowercase UUID is refused: \(bad.debugDescription)")
        }
        expect(GeminiThread.snapshot(chatID: otherID, offered: [otherID], folder: folder.path).message == GeminiThread.missing, "an offered chat with no file is unavailable with a plain reason")

        // Unsafe files: a link, a folder, or a file that is not ours is never opened.
        let linkID = "00000000-0000-4000-8000-000000000003"
        try FileManager.default.createSymbolicLink(atPath: file(linkID), withDestinationPath: file(id))
        expect(GeminiThread.snapshot(chatID: linkID, offered: [linkID], folder: folder.path).message == GeminiThread.unsafe, "a symlinked conversation file is not followed")
        let dirID = "00000000-0000-4000-8000-000000000004"
        try FileManager.default.createDirectory(atPath: file(dirID), withIntermediateDirectories: false)
        expect(GeminiThread.snapshot(chatID: dirID, offered: [dirID], folder: folder.path).message == GeminiThread.unsafe, "a folder is not a conversation file")
        expect(GeminiThread.checkFile(file(id)) == .ok && GeminiThread.checkFile(file("nothing")) == .missing, "a plain file of ours is fine, an absent one is missing")
        let wallinkID = "00000000-0000-4000-8000-000000000005"
        try FileManager.default.copyItem(atPath: mixed, toPath: file(wallinkID))
        try FileManager.default.createSymbolicLink(atPath: file(wallinkID) + "-wal", withDestinationPath: "/etc/hosts")
        expect(GeminiThread.snapshot(chatID: wallinkID, offered: [wallinkID], folder: folder.path).message == GeminiThread.unsafe, "a symlinked -wal is not followed")

        // Truncation and the row guard.
        let long = quiet("long") { db in for n in 1...30 { insert(db, n, type: n % 2 == 1 ? 14 : 15, payload: n % 2 == 1 ? user("Q\(n)") : reply("A\(n)")) } }
        if case .turns(let newest, let limited) = GeminiThread.read(path: long) { expect(newest.count == ThreadLimits.maxTurns + 1 && limited && newest.first?.text == "A30", "reading stops once ThreadLimits has enough, and says more exists") } else { expect(false, "a long conversation reads") }
        let longID = "00000000-0000-4000-8000-000000000006"
        try FileManager.default.copyItem(atPath: long, toPath: file(longID))
        let bounded = GeminiThread.snapshot(chatID: longID, offered: [longID], folder: folder.path)
        expect(bounded.status == "ok" && bounded.truncated && bounded.turns.count == ThreadLimits.maxTurns && bounded.turns.first?.text == "Q19" && bounded.turns.last?.text == "A30", "the newest turns are kept, oldest to newest, and truncated is set")
        if case .turns(let t, let limited) = GeminiThread.read(path: long, newestRows: 3) { expect(t.count == 3 && limited, "the row guard stops the read and says so") } else { expect(false, "row guard") }
        if case .turns(let t, let limited) = GeminiThread.read(path: long, newestRows: 30) { expect(t.count == ThreadLimits.maxTurns + 1 && limited, "a row guard larger than the data still stops at enough turns") } else { expect(false, "row guard 2") }
        let short = quiet("short") { db in for n in 1...4 { insert(db, n, type: 14, payload: user("m\(n)")) } }
        if case .turns(let t, let limited) = GeminiThread.read(path: short, newestRows: 4) { expect(t.count == 4 && !limited, "exactly the row guard is not limited") } else { expect(false, "exact guard") }
        let gaps = quiet("gaps") { db in
            for n in 1...600 { insert(db, n, type: 132, payload: user("tool")) }
            insert(db, 601, type: 14, payload: user("Only message"))
        }
        expect(texts(GeminiThread.read(path: gaps)) == ["user:Only message"], "tool steps do not use up the row guard")
        let heavy = quiet("heavy") { db in
            insert(db, 1, type: 14, payload: user("Before"))
            for n in 2...450 { insert(db, n, type: 14, payload: Array(user("x").dropLast(1))) }   // 449 malformed newer steps
        }
        if case .turns(let t, let limited) = GeminiThread.read(path: heavy) { expect(t.isEmpty && limited, "malformed steps past the row guard are not read and the read is marked limited") } else { expect(false, "heavy") }
        let manyChars = quiet("chars") { db in for n in 1...3 { insert(db, n, type: 14, payload: user(String(repeating: "é", count: 9000))) } }
        let charsID = "00000000-0000-4000-8000-000000000007"
        try FileManager.default.copyItem(atPath: manyChars, toPath: file(charsID))
        let cut = GeminiThread.snapshot(chatID: charsID, offered: [charsID], folder: folder.path)
        expect(cut.status == "ok" && cut.truncated && cut.turns.allSatisfy { $0.text.count <= ThreadLimits.maxTurnCharacters }, "one long message is cut and marked truncated")
        let empty = quiet("empty") { db in insert(db, 1, type: 132, payload: user("tool")) }
        let emptyID = "00000000-0000-4000-8000-000000000008"
        try FileManager.default.copyItem(atPath: empty, toPath: file(emptyID))
        expect(GeminiThread.snapshot(chatID: emptyID, offered: [emptyID], folder: folder.path).message == ThreadReader.emptyMessage, "a conversation with no visible message is unavailable, never ok")

        // A huge blob is skipped without being loaded; the rest still read.
        let huge = quiet("huge") { db in
            insert(db, 1, type: 14, payload: user("Small before"))
            insert(db, 2, type: 15, payload: reply(String(repeating: "H", count: GeminiThread.maximumPayload + 10)))
            insert(db, 3, type: 14, payload: user("Small after"))
        }
        expect(texts(GeminiThread.read(path: huge)) == ["user:Small after", "user:Small before"], "a payload over 8 MB is skipped, its neighbours are read")

        // Missing file, missing table or column, damage.
        expect(GeminiThread.read(path: file("absent")) == .missing, "a missing file is missing")
        let noTable = file("notable"); do { let db = open(noTable); run(db, "CREATE TABLE other (a TEXT)"); sqlite3_close(db) }
        expect(GeminiThread.read(path: noTable) == .unsupported, "a missing table is unsupported")
        let noColumn = file("nocolumn"); do { let db = open(noColumn); run(db, "CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer, status integer, step_format integer)"); sqlite3_close(db) }
        expect(GeminiThread.read(path: noColumn) == .unsupported, "a missing column is unsupported")
        let junk = file("junk"); try Data("this is not a database at all".utf8).write(to: URL(fileURLWithPath: junk))
        expect(GeminiThread.read(path: junk) == .failed, "a damaged file fails without crashing")
        let nothing = file("zero"); FileManager.default.createFile(atPath: nothing, contents: Data())
        expect(GeminiThread.read(path: nothing) == .unsupported, "an empty file has no table")
        for (name, reading) in [("missing", GeminiThread.Reading.missing), ("unsupported", .unsupported), ("busy", .busy), ("failed", .failed)] {
            expect(GeminiThread.message(reading).hasSuffix(".") && !GeminiThread.message(reading).isEmpty, "a plain-English reason for \(name)")
        }
        expect(Set([GeminiThread.missing, GeminiThread.unsupported, GeminiThread.busy, GeminiThread.failed, GeminiThread.unsafe, GeminiThread.notOffered]).count == 6, "each reason is its own")
        let junkID = "00000000-0000-4000-8000-000000000009"
        try FileManager.default.copyItem(atPath: junk, toPath: file(junkID))
        expect(GeminiThread.snapshot(chatID: junkID, offered: [junkID], folder: folder.path).message == GeminiThread.failed, "a corrupt file is unavailable with the failed reason")
        expect(GeminiThread.layoutProblem(chatID: id, folder: folder.path) == nil && GeminiThread.layoutProblem(chatID: junkID, folder: folder.path) == GeminiThread.failed && GeminiThread.layoutProblem(chatID: "00000000-0000-4000-8000-0000000000ff", folder: folder.path) == GeminiThread.missing, "the layout check reads no message and names the problem")

        // A writer still holds the file: rows only in the -wal are seen, and a held write lock does not hang the read.
        let live = file("live"), writer = open(live)
        run(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; " + schema); run(writer, "PRAGMA wal_checkpoint(TRUNCATE)")
        insert(writer, 1, type: 14, payload: user("In the WAL"))
        insert(writer, 2, type: 15, payload: reply("Also in the WAL"))
        expect((try? FileManager.default.attributesOfItem(atPath: live + "-wal")[.size] as? NSNumber)?.intValue ?? 0 > 0, "fixture: rows are waiting in the -wal")
        expect(texts(GeminiThread.read(path: live)) == ["assistant:Also in the WAL", "user:In the WAL"], "rows only in the WAL are seen")
        insert(writer, 3, type: 14, payload: user("Newer"))
        expect(texts(GeminiThread.read(path: live)).first == "user:Newer", "a row written after the last read is seen")
        run(writer, "BEGIN IMMEDIATE"); insert(writer, 4, type: 14, payload: user("Uncommitted"))
        expect(texts(GeminiThread.read(path: live)).first == "user:Newer", "an open write transaction does not block reading and is not seen")
        run(writer, "COMMIT"); sqlite3_close(writer)

        // A -wal with no -shm (Gemini crashed) is not read and nothing is created.
        let crashed = file("crashed"), holder = open(crashed)
        run(holder, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; " + schema); run(holder, "PRAGMA wal_checkpoint(TRUNCATE)"); insert(holder, 1, type: 14, payload: user("Orphan"))
        let orphan = file("orphan")
        try FileManager.default.copyItem(atPath: crashed, toPath: orphan); try FileManager.default.copyItem(atPath: crashed + "-wal", toPath: orphan + "-wal")
        sqlite3_close(holder); try? FileManager.default.removeItem(atPath: orphan + "-shm")
        expect(GeminiThread.read(path: orphan) == .failed && !exists(orphan + "-shm"), "a -wal with no -shm is not read and no -shm appears")

        // Source scans: the reader is read-only and never speaks of message text.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOfFile: root.appendingPathComponent("Sources/GeminiThread.swift").path, encoding: .utf8)
        let code = source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        expect(!code.contains("SQLITE_OPEN_READWRITE") && !code.contains("SQLITE_OPEN_CREATE") && !code.contains("sqlite3_exec") && !code.contains("sqlite3_open(") && code.contains("SQLITE_OPEN_URI") == false && code.contains("sqlite3_open_v2"), "the reader never opens the file writable and takes its flags from the guarded read-only path")
        expect(!code.contains("INSERT") && !code.contains("UPDATE ") && !code.contains("DELETE") && !code.contains("PRAGMA journal_mode") && !code.contains("wal_checkpoint") && !code.contains("writeToFile") && !code.contains("createFile") && !code.contains("copyItem") && !code.contains("FileHandle(forWriting"), "the reader never writes, copies or checkpoints")
        expect(!code.contains("print(") && !code.contains("NSLog") && !code.contains("os_log") && !code.contains("Logger") && !code.contains("ActivityLog"), "the reader never logs")
        expect(code.components(separatedBy: "field: 3").count == 2 && code.contains("Proto.string(note, field: 3) == \"system\""), "field 3 is read only as the injected sender, never as reply text")
        let chatList = try String(contentsOfFile: root.appendingPathComponent("Sources/GeminiChatList.swift").path, encoding: .utf8)
        expect(chatList.contains("SQLITE_OPEN_READONLY | SQLITE_OPEN_URI") && !chatList.contains("SQLITE_OPEN_READWRITE"), "the shared guarded read only ever opens read-only")

        // The bridge.
        let bridge = try String(contentsOfFile: root.appendingPathComponent("Sources/RemoteBridge.swift").path, encoding: .utf8)
        let thread = bridge.components(separatedBy: "private func readThread(")[1].components(separatedBy: "/// One Muse read per chat")[0]
        let lockedAt = thread.range(of: "guard !isLocked")!.lowerBound, geminiAt = thread.range(of: "provider==\"gemini\"")!.lowerBound
        expect(lockedAt < geminiAt, "a locked Mac is refused before Gemini is read")
        expect(thread.contains("Task.detached") && thread.contains("GeminiThread.snapshot(chatID:chatID,offered:ids)") && thread.contains("await loadGeminiChats()"), "Gemini threads are read off the main actor, against the offered list")
        expect(bridge.contains("GeminiChatList.capability,\"chatActivity\",\"openChat\",GeminiThread.capability") && GeminiThread.capability == "readThread", "readThread is advertised for Gemini with the ready capabilities")
        expect(!bridge.contains("GeminiChatList.threadMessage") && !chatList.contains("threadMessage"), "the old not-yet message is gone")

        print("Gemini threads: \(count) checks passed")
    }
}
