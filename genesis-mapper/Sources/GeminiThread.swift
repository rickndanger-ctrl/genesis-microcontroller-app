import Foundation
import Darwin
import SQLite3

/// Gemini's conversation threads, read-only (stage 3).
/// Each Gemini conversation is its own SQLite file; its steps hold protobuf payloads. Only the visible
/// text of user messages, Gemini's replies and messages sent from this controller is taken. Hidden reasoning,
/// tool steps and sub-task results are never read. Nothing here writes to Gemini's files, and no message
/// text is ever logged: the text goes into the returned snapshot only.
enum GeminiThread {
    static let capability = "readThread"
    static let provider = "gemini"
    static let table = "steps"
    /// The only columns that are ever selected (step_payload only through the size guard below).
    static let columns = ["idx", "step_type", "status", "step_format", "step_payload"]
    static let maximumRows = 400
    static let maximumPayload = 8 * 1_048_576
    static let doneStatus = 3
    static let userStep = 14, replyStep = 15, injectedStep = 101
    static let budget: TimeInterval = ThreadLimits.seconds

    static let notInstalled = "Install Gemini on this Mac to read its chats."
    static let locked = "Unlock this Mac to read this chat."
    static let notOffered = "This chat is not in Gemini\u{2019}s chat list on this Mac. Refresh the chats and try again."
    static let missing = "This Gemini chat\u{2019}s file was not found on this Mac. Refresh the chats and try again."
    static let unsupported = "This version of Gemini keeps its conversations in a layout this controller does not know yet."
    static let busy = "Gemini is writing to this chat. Try again in a moment."
    static let failed = "This Gemini chat could not be read on this Mac. Open Gemini and try again."
    static let noChatToCheck = "There is no Gemini chat yet to check."
    static let unsafe = "This Gemini chat\u{2019}s file is not a plain file in your own Gemini folder, so it was not read."

    // MARK: Protobuf

    /// Just enough of the wire format to pick fields out of a message: varint, 64-bit, length-delimited, 32-bit.
    /// Anything malformed (truncated, a group, field 0, a length past the end) makes the message unreadable.
    enum Proto {
        static func varint(_ bytes: ArraySlice<UInt8>, _ at: Int) -> (value: UInt64, next: Int)? {
            var result: UInt64 = 0, shift: UInt64 = 0, i = at
            while i < bytes.endIndex, shift <= 63 {
                let byte = bytes[i]; i += 1
                if shift == 63 && byte > 1 { return nil }
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return (result, i) }
                shift += 7
            }
            return nil
        }

        /// The first length-delimited value of `field` at the top level of `message`.
        /// Nil when it is absent, or when the message is malformed anywhere.
        static func bytes(_ message: ArraySlice<UInt8>, field: Int) -> ArraySlice<UInt8>? {
            var i = message.startIndex, found: ArraySlice<UInt8>?
            while i < message.endIndex {
                guard let key = varint(message, i) else { return nil }
                i = key.next
                let number = key.value >> 3
                guard number >= 1, number <= 0x1FFF_FFFF else { return nil }
                switch key.value & 7 {
                case 0:
                    guard let value = varint(message, i) else { return nil }
                    i = value.next
                case 1:
                    guard message.endIndex - i >= 8 else { return nil }
                    i += 8
                case 5:
                    guard message.endIndex - i >= 4 else { return nil }
                    i += 4
                case 2:
                    guard let length = varint(message, i), length.value <= UInt64(message.endIndex - length.next) else { return nil }
                    let start = length.next, end = start + Int(length.value)
                    if found == nil, Int(number) == field { found = message[start..<end] }
                    i = end
                default:
                    return nil   // groups and reserved wire types
                }
            }
            return found
        }

        /// A string field. Invalid UTF-8 makes the field unreadable rather than guessed at.
        static func string(_ message: ArraySlice<UInt8>, field: Int) -> String? {
            bytes(message, field: field).flatMap { String(bytes: $0, encoding: .utf8) }
        }
    }

    // MARK: Steps

    /// The turn a step carries, or nil when it carries none. Pure: no file, no log.
    /// - 14: the user's own message. 15: Gemini's visible reply (field 1; field 3 is hidden reasoning and is never read).
    /// - 101: only a message whose sender is exactly "system" came from this controller; any other sender is Gemini's own plumbing.
    static func turn(type: Int, status: Int, format: Int, payload: ArraySlice<UInt8>) -> ThreadTurn? {
        guard format == 0 else { return nil }
        let role: String, raw: String?
        switch type {
        case userStep:
            guard status == doneStatus else { return nil }
            role = "user"
            raw = Proto.bytes(payload, field: 19).flatMap { Proto.string($0, field: 2) }
        case replyStep:
            // A reply still streaming is shown; a step that only made tool calls has no visible text and is skipped.
            role = "assistant"
            raw = Proto.bytes(payload, field: 20).flatMap { Proto.string($0, field: 1) }
        case injectedStep:
            guard status == doneStatus else { return nil }
            role = "user"
            guard let note = Proto.bytes(payload, field: 114).flatMap({ Proto.bytes($0, field: 4) }),
                  Proto.string(note, field: 3) == "system" else { return nil }
            raw = Proto.string(note, field: 4)
        default:
            return nil
        }
        guard let raw else { return nil }
        let text = ThreadLimits.clean(raw)
        return text.isEmpty ? nil : ThreadTurn(role: role, text: text)
    }

    // MARK: Reading

    enum Reading: Equatable {
        /// Newest first. `limited` when older steps were left unread.
        case turns([ThreadTurn], limited: Bool)
        case missing, unsupported, busy, failed
    }

    static func path(for chatID: String, folder: String = GeminiChatList.conversationsFolder()) -> String {
        folder + "/" + chatID + ".db"
    }

    enum FileCheck: Equatable { case ok, missing, unsafe }
    /// The file must be a regular file owned by this user, not a link; so must any -wal or -shm beside it.
    static func checkFile(_ path: String) -> FileCheck {
        func check(_ file: String, required: Bool) -> FileCheck {
            var info = stat()
            guard lstat(file, &info) == 0 else { return required ? .missing : .ok }
            return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() ? .ok : .unsafe
        }
        let main = check(path, required: true)
        guard main == .ok else { return main }
        for side in ["-wal", "-shm"] where check(path + side, required: false) != .ok { return .unsafe }
        return .ok
    }

    /// Reads the newest turns of one conversation file. Callers run this off the main thread.
    /// `newestRows` of 0 only checks the layout. The file is opened read-only through the same guarded
    /// path as the chat list (immutable with a before/after check when there is no -wal, a locked read-only
    /// reader when there is one); it is never opened writable and nothing is created beside it.
    static func read(path: String, newestRows: Int = maximumRows, budget: TimeInterval = budget) -> Reading {
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        return GeminiChatList.guardedRead(path: path, missing: Reading.missing, failed: .failed, busy: .busy) { target, flags in
            query(target, flags: flags, newestRows: newestRows, deadline: deadline)
        }
    }

    private static func query(_ target: String, flags: Int32, newestRows: Int, deadline: TimeInterval) -> Reading {
        var db: OpaquePointer?
        guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK, let db else { sqlite3_close(db); return .failed }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, Int32(GeminiChatList.budget * 1000))
        // The time budget also applies inside a single step, so an unexpectedly slow scan is cut short instead of running on.
        let limit = UnsafeMutablePointer<TimeInterval>.allocate(capacity: 1)
        limit.initialize(to: deadline)
        sqlite3_progress_handler(db, 2000, { context in
            guard let context else { return 0 }
            return ProcessInfo.processInfo.systemUptime > context.assumingMemoryBound(to: TimeInterval.self).pointee ? 1 : 0
        }, limit)
        defer { sqlite3_progress_handler(db, 0, nil, nil); limit.deallocate() }
        func code(_ result: Int32) -> Reading { result == SQLITE_BUSY || result == SQLITE_LOCKED || result == SQLITE_INTERRUPT ? .busy : .failed }
        var info: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &info, nil)
        guard prepared == SQLITE_OK else { sqlite3_finalize(info); return code(prepared) }
        var names = Set<String>(), step = sqlite3_step(info)
        while step == SQLITE_ROW { if let text = sqlite3_column_text(info, 1) { names.insert(String(cString: text)) }; step = sqlite3_step(info) }
        sqlite3_finalize(info)
        guard step == SQLITE_DONE else { return code(step) }
        guard Set(columns).isSubset(of: names) else { return .unsupported }
        guard newestRows > 0 else { return .turns([], limited: false) }

        // Only the three step types that can carry a message, newest first. A payload over the cap comes back NULL
        // (SQLite measures it without loading it) and that step is skipped. One row more than asked tells us there is more.
        var statement: OpaquePointer?
        let sql = "SELECT idx, step_type, status, step_format, CASE WHEN length(step_payload) <= \(maximumPayload) THEN step_payload END FROM \(table) WHERE step_type IN (\(userStep), \(replyStep), \(injectedStep)) ORDER BY idx DESC LIMIT \(newestRows + 1)"
        let compiled = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard compiled == SQLITE_OK else { sqlite3_finalize(statement); return code(compiled) }
        defer { sqlite3_finalize(statement) }
        var turns = [ThreadTurn](), rows = 0, limited = false
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            rows += 1
            // Enough for ThreadLimits (it keeps maxTurns and notes when there were more), or the row guard.
            if rows > newestRows || turns.count > ThreadLimits.maxTurns { limited = true; break }
            if ProcessInfo.processInfo.systemUptime > deadline { if turns.isEmpty { return .busy }; limited = true; break }
            if sqlite3_column_type(statement, 4) == SQLITE_BLOB, let blob = sqlite3_column_blob(statement, 4) {
                let count = Int(sqlite3_column_bytes(statement, 4))
                if count > 0, count <= maximumPayload {
                    let payload = Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: UInt8.self), count: count))
                    if let found = turn(type: Int(sqlite3_column_int64(statement, 1)), status: Int(sqlite3_column_int64(statement, 2)),
                                        format: Int(sqlite3_column_int64(statement, 3)), payload: payload[...]) { turns.append(found) }
                }
            }
            result = sqlite3_step(statement)
        }
        guard limited || result == SQLITE_DONE else { return code(result) }
        return .turns(turns, limited: limited)
    }

    /// Why a chat's thread is unavailable, in words for the phone.
    static func message(_ reading: Reading) -> String {
        switch reading {
        case .missing: return missing
        case .unsupported: return unsupported
        case .busy: return busy
        case .failed, .turns: return failed
        }
    }

    /// The whole route after the Mac is known to be unlocked and Gemini installed: the chat must be an exact
    /// lowercase UUID that the chat list offers, and its file a plain file of this user.
    static func snapshot(chatID: String, offered: [String], folder: String = GeminiChatList.conversationsFolder(), budget: TimeInterval = budget) -> ThreadSnapshot {
        func unavailable(_ message: String) -> ThreadSnapshot { .unavailable(provider: provider, chatID: chatID, message) }
        guard case .ok(let id) = GeminiSend.checkChat(chatID, offered: offered) else { return unavailable(notOffered) }
        let file = path(for: id, folder: folder)
        switch checkFile(file) {
        case .missing: return unavailable(missing)
        case .unsafe: return unavailable(unsafe)
        case .ok: break
        }
        let reading = read(path: file, budget: budget)
        guard case .turns(let newestFirst, let limited) = reading else { return unavailable(message(reading)) }
        return ThreadReader.make(provider: provider, chatID: chatID, turnsNewestFirst: newestFirst, limited: limited)
    }

    /// Layout check only, for the self-check: no step is read.
    static func layoutProblem(chatID: String, folder: String = GeminiChatList.conversationsFolder()) -> String? {
        let file = path(for: chatID, folder: folder)
        switch checkFile(file) {
        case .missing: return missing
        case .unsafe: return unsafe
        case .ok: break
        }
        let reading = read(path: file, newestRows: 0)
        if case .turns = reading { return nil }
        return message(reading)
    }
}
