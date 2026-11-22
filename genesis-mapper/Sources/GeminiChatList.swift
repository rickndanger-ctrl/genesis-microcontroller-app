import Foundation
import SQLite3

/// Gemini's chat list, read from the summary database Gemini keeps for itself.
/// Stage 1 is read-only: titles and run status only. Nothing here opens a
/// conversation, a preview or a summary blob, and nothing writes to Gemini's files.
/// The rules are pure, so they are tested without Gemini.
enum GeminiChatList {
    static let bundle = "com.google.GeminiMacOS"
    static let capability = "gemini"
    static let idleStatus = "CASCADE_RUN_STATUS_IDLE"
    /// Same staleness guard as Codex: an unfinished run only counts while the
    /// row was touched this recently, so a crashed run does not stay lit forever.
    static let freshness: TimeInterval = 120
    static let clockSlack: TimeInterval = 60
    static let maximumChats = 500
    static let maximumTitle = 240
    static let readOnlyRefusal = "The controller can\u{2019}t do that in Gemini yet. Nothing was changed."
    static let table = "conversation_summaries"
    /// The only columns that are ever selected. No preview, no raw summary.
    static let columns = ["conversation_id", "title", "status", "not_fully_idle", "killed", "nesting_depth", "parent_conversation_id", "last_modified_time"]

    struct Row: Equatable {
        var id: String, title: String, status: String
        var notFullyIdle: Int, killed: Int, nestingDepth: Int
        var parentID: String
        var lastModified: Date?
        /// When Gemini last wrote this conversation's own file. Gemini only moves `last_modified_time`
        /// when an answer finishes, so a run in a chat that had been quiet would otherwise look stale.
        var touched: Date? = nil
    }
    struct Chat: Equatable { var id: String, title: String, state: String }

    static func defaultPath(home: String = NSHomeDirectory()) -> String { home + "/.gemini/antigravity/conversation_summaries.db" }

    /// What a command for Gemini is told when it is not one of the two Gemini supports (openChat, sendPrompt).
    static func refusal(for action: String) -> String {
        action == "stop" ? GeminiSend.stopRefusal : action == "newChat" ? "The controller can\u{2019}t start a new Gemini chat yet. Nothing was changed." : readOnlyRefusal
    }

    /// Why the list is not available, in words for the phone. Nil reading means no check has finished.
    static func unreadableReason(_ reading: Reading?) -> String {
        switch reading {
        case .missing?: return "Gemini has no chats on this Mac yet. Open Gemini and start one."
        case .unsupported?: return "This version of Gemini keeps its chat list in a layout this controller does not know yet."
        case .busy?: return "Gemini\u{2019}s chat list is busy. Refresh in a moment."
        default: return "Gemini\u{2019}s chat list could not be read on this Mac. Open Gemini and refresh."
        }
    }

    static func isFresh(_ modified: Date?, now: Date) -> Bool {
        guard let modified else { return false }
        let age = now.timeIntervalSince(modified)
        return age >= -clockSlack && age <= freshness
    }

    /// The statuses Gemini uses while a conversation is doing something. Anything else,
    /// including a status this controller has never seen, is Saved: a light must not come on by guesswork.
    static let workingStatuses: Set<String> = ["CASCADE_RUN_STATUS_RUNNING", "CASCADE_RUN_STATUS_BUSY", "CASCADE_RUN_STATUS_CANCELING"]

    /// "Working" only for a known working status on a fresh row. Killed rows are always Saved.
    static func state(_ row: Row, now: Date) -> String {
        if row.killed != 0 { return "Saved" }
        guard workingStatuses.contains(row.status) else { return "Saved" }
        return isFresh(row.lastModified, now: now) || isFresh(row.touched, now: now) ? "Working" : "Saved"
    }

    /// Top-level chats with a title, newest first, capped. The id is the
    /// conversation's UUID in lowercase; a row without a valid UUID is dropped.
    static func offered(_ rows: [Row], now: Date, maximum: Int = maximumChats) -> [Chat] {
        var seen = Set<String>()
        let usable = rows.compactMap { row -> (Row, String)? in
            guard row.nestingDepth == 0, row.parentID.isEmpty,
                  !row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let uuid = UUID(uuidString: row.id), seen.insert(uuid.uuidString.lowercased()).inserted else { return nil }
            return (row, uuid.uuidString.lowercased())
        }
        return usable.sorted { a, b in
            switch (a.0.lastModified, b.0.lastModified) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.1 < b.1
            }
        }.prefix(max(0, maximum)).map { Chat(id: $0.1, title: String($0.0.title.prefix(maximumTitle)), state: state($0.0, now: now)) }
    }

    /// Gemini writes "2026-11-22 19:01:43.15901+00:00": any number of fraction digits, an offset or Z.
    static func parseTime(_ text: String) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "T" }).map(String.init)
        guard parts.count == 2 else { return nil }
        let day = parts[0].split(separator: "-").map { Int($0) }
        guard day.count == 3, !day.contains(where: { $0 == nil }) else { return nil }
        let ymd = day.compactMap { $0 }
        var clock = parts[1], offset = 0
        if clock.hasSuffix("Z") { clock.removeLast() }
        else if let sign = clock.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let zone = clock[clock.index(after: sign)...].split(separator: ":").compactMap { Int($0) }
            guard (1...2).contains(zone.count), zone.count == clock[clock.index(after: sign)...].split(separator: ":").count else { return nil }
            offset = (zone[0] * 3600 + (zone.count == 2 ? zone[1] * 60 : 0)) * (clock[sign] == "-" ? -1 : 1)
            clock = String(clock[..<sign])
        }
        let fields = clock.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard fields.count <= 2 else { return nil }
        let time = fields[0].split(separator: ":").compactMap { Int($0) }
        guard time.count == 3, fields[0].split(separator: ":").count == 3, (1...12).contains(ymd[1]), (1...31).contains(ymd[2]), (0...23).contains(time[0]), (0...59).contains(time[1]), (0...60).contains(time[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let base = calendar.date(from: DateComponents(year: ymd[0], month: ymd[1], day: ymd[2], hour: time[0], minute: time[1], second: time[2])) else { return nil }
        var fraction = 0.0
        if fields.count == 2, !fields[1].isEmpty { guard fields[1].allSatisfy(\.isNumber), let value = Double("0." + fields[1]) else { return nil }; fraction = value }
        return base.addingTimeInterval(fraction - Double(offset))
    }

    // MARK: Reading

    enum Reading: Equatable {
        case rows([Row])
        case missing        // no database: Gemini has not been used on this Mac
        case unsupported    // the table or a needed column is not there: Gemini changed its layout
        case busy           // locked longer than the time limit
        case failed
    }

    /// Time a read may take. SQLite waits at most this long for a lock.
    static let budget: TimeInterval = 0.5
    static let rowGuard = 5000

    /// Reads without changing Gemini's data. Callers run this off the main thread.
    /// Gemini keeps this database in WAL mode but usually leaves no -wal or -shm on disk between writes.
    /// - No -wal: opened `immutable`, which takes no lock and creates no file. Because that read is
    ///   unlocked, the file's size and time are compared before and after; if Gemini wrote meanwhile the
    ///   read is thrown away and tried once more, then reported busy.
    /// - A -wal and its -shm: a normal locked read-only reader, which sees the rows still in the -wal.
    /// - A -wal with no -shm (Gemini crashed): not read. Opening Gemini repairs it.
    static func read(path: String = defaultPath(), now: Date = Date()) -> Reading {
        withFileTimes(guardedRead(path: path, missing: .missing, failed: .failed, busy: .busy) { target, flags in query(target, flags: flags) }, path)
    }

    /// The one safe way into any of Gemini's SQLite files (the summary database and each conversation's own file).
    /// The caller's `run` receives a URI and open flags and must open read-only; its result is returned as is,
    /// except when the file changed during an unlocked read, which is thrown away and retried once.
    static func guardedRead<R>(path: String, missing: R, failed: R, busy: R, run: (String, Int32) -> R) -> R {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return missing }
        func size(_ file: String) -> Int { ((try? manager.attributesOfItem(atPath: file))?[.size] as? NSNumber)?.intValue ?? 0 }
        func stamp() -> String {
            let main = try? manager.attributesOfItem(atPath: path)
            return "\((main?[.size] as? NSNumber)?.intValue ?? -1)|\((main?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)|\(size(path + "-wal"))"
        }
        let uri = "file:" + escape(path)
        for _ in 0..<2 {
            let before = stamp()
            if size(path + "-wal") > 0 {
                guard manager.fileExists(atPath: path + "-shm") else { return failed }
                return run(uri + "?mode=ro", SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
            }
            let reading = run(uri + "?immutable=1", SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
            if stamp() == before { return reading }
        }
        return busy
    }

    /// Adds file times for working rows. The conversations folder sits next to the summary database.
    private static func withFileTimes(_ reading: Reading, _ path: String) -> Reading {
        guard case .rows(let rows) = reading else { return reading }
        return .rows(stamped(rows, folder: (path as NSString).deletingLastPathComponent + "/conversations"))
    }

    private static func escape(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")) ?? path
    }

    private static func query(_ target: String, flags: Int32) -> Reading {
        var db: OpaquePointer?
        guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK, let db else { sqlite3_close(db); return .failed }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, Int32(budget * 1000))
        func code(_ result: Int32) -> Reading { result == SQLITE_BUSY || result == SQLITE_LOCKED ? .busy : .failed }
        // Layout check first: a missing table or column is "unsupported", never a crash.
        var info: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &info, nil)
        guard prepared == SQLITE_OK else { sqlite3_finalize(info); return code(prepared) }
        var names = Set<String>(), step = sqlite3_step(info)
        while step == SQLITE_ROW { if let text = sqlite3_column_text(info, 1) { names.insert(String(cString: text)) }; step = sqlite3_step(info) }
        sqlite3_finalize(info)
        guard step == SQLITE_DONE else { return code(step) }
        guard Set(columns).isSubset(of: names) else { return .unsupported }
        var statement: OpaquePointer?
        let sql = "SELECT " + columns.joined(separator: ", ") + " FROM \(table) LIMIT \(rowGuard)"
        let compiled = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard compiled == SQLITE_OK else { sqlite3_finalize(statement); return code(compiled) }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        var rows = [Row]()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            rows.append(Row(id: text(0), title: text(1), status: text(2), notFullyIdle: Int(sqlite3_column_int64(statement, 3)),
                            killed: Int(sqlite3_column_int64(statement, 4)), nestingDepth: Int(sqlite3_column_int64(statement, 5)),
                            parentID: text(6), lastModified: parseTime(text(7))))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { return code(result) }
        return .rows(rows)
    }

    /// For rows in a working status only: when the conversation's own file (or its -wal) was last written.
    /// File times only; the conversation is never opened.
    static func stamped(_ rows: [Row], folder: String) -> [Row] {
        let manager = FileManager.default
        return rows.map { row in
            guard workingStatuses.contains(row.status), let uuid = UUID(uuidString: row.id) else { return row }
            let base = folder + "/" + uuid.uuidString.lowercased() + ".db"
            let times = [base, base + "-wal"].compactMap { (try? manager.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
            var copy = row; copy.touched = times.max(); return copy
        }
    }
    static func conversationsFolder(home: String = NSHomeDirectory()) -> String { home + "/.gemini/antigravity/conversations" }
}
