import Foundation
import Darwin

// Read-only. Nothing here writes to Claude's or Codex's files or sends to either app.
// Conversation text goes only into the returned value: never into a log or an error.

struct ThreadTurn: Encodable, Equatable {
    let role: String
    let text: String
}

struct ThreadSnapshot: Encodable {
    let provider: String
    let chatID: String
    let status: String
    let message: String?
    let turns: [ThreadTurn]
    let truncated: Bool

    static func ok(provider: String, chatID: String, turns: [ThreadTurn], truncated: Bool) -> ThreadSnapshot {
        ThreadSnapshot(provider: provider, chatID: chatID, status: "ok", message: nil, turns: turns, truncated: truncated)
    }
    static func unavailable(provider: String, chatID: String, _ message: String) -> ThreadSnapshot {
        ThreadSnapshot(provider: provider, chatID: chatID, status: "unavailable", message: message, turns: [], truncated: false)
    }
    private enum CodingKeys: String, CodingKey { case provider, chatID, status, message, turns, truncated }
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(provider, forKey: .provider); try box.encode(chatID, forKey: .chatID)
        try box.encode(status, forKey: .status)
        if let message { try box.encode(message, forKey: .message) } else { try box.encodeNil(forKey: .message) }
        try box.encode(turns, forKey: .turns); try box.encode(truncated, forKey: .truncated)
    }
}

enum ThreadFailure: Error {
    /// No Claude Code session with this exact title has a transcript here.
    case noSession
    case ambiguous
    case timeout
    /// Nothing visible within the largest window read.
    case tooFarBack
    /// The whole transcript holds no visible message yet.
    case empty
    /// The transcript carries no record tying it to the signed-in account.
    case unverified
    /// Anything else: an unexpected shape, an unsafe path, a changed identity.
    case unreadable
}

enum ThreadLimits {
    static let maxTurns = 12
    static let maxTurnCharacters = 8_000
    static let maxCharacters = 24_000
    static let tailBytes = 8 * 1_048_576
    /// Tail windows tried in turn; a long tool-heavy turn can bury the last visible messages.
    static let windows = [8, 32, 96].map { $0 * 1_048_576 }
    static let lineBytes = 4 * 1_048_576
    static let seconds = 2.5

    /// Newest first in, newest first out. The newest turns win when the budget runs out.
    static func bound(_ newestFirst: [ThreadTurn], limited: Bool) -> (turns: [ThreadTurn], truncated: Bool) {
        var kept = [ThreadTurn](), remaining = maxCharacters, truncated = limited
        for turn in newestFirst {
            guard kept.count < maxTurns, remaining > 0 else { truncated = true; break }
            let allowed = min(maxTurnCharacters, remaining)
            let text = turn.text.count > allowed ? String(turn.text.prefix(allowed)) : turn.text
            if text.count < turn.text.count { truncated = true }
            remaining -= text.count
            kept.append(ThreadTurn(role: turn.role, text: text))
        }
        return (kept.reversed(), truncated)
    }
    static func clean(_ raw: String, keepingLineBreaks: Bool = true) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || ($0 == "\n" || $0 == "\t" || ($0 == "\r" && keepingLineBreaks))
        })).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Claude

struct ClaudeBinding {
    let accountID: String
    let organizationID: String
    let cliSessionID: String
    let transcript: String
}

enum ClaudeThread {
    static let noSessionMessage = "Only Claude Code chats with a transcript on this Mac can be shown."

    private static func isUUID(_ value: Any?) -> Bool {
        guard let value = value as? String, value.utf8.count == 36 else { return false }
        return value.range(of: "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", options: .regularExpression) != nil
    }
    private static func isBool(_ value: Any?, _ expected: Bool) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue == expected
    }

    /// Every component under home must be a real directory or file owned by this user; no symlinks.
    private static func checked(home: String, path: String, directory: Bool) throws -> stat {
        guard path.hasPrefix(home + "/") else { throw ThreadFailure.unreadable }
        var cursor = home, info = stat()
        let parts = path.dropFirst(home.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw ThreadFailure.unreadable }
        for (index, part) in parts.enumerated() {
            cursor += "/" + part
            guard lstat(cursor, &info) == 0, info.st_mode & S_IFMT != S_IFLNK, info.st_uid == geteuid() else { throw ThreadFailure.unreadable }
            if index < parts.count - 1, info.st_mode & S_IFMT != S_IFDIR { throw ThreadFailure.unreadable }
        }
        let kind = info.st_mode & S_IFMT
        guard directory ? kind == S_IFDIR : kind == S_IFREG else { throw ThreadFailure.unreadable }
        return info
    }
    private static func descriptor(_ path: String, expecting before: stat) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ThreadFailure.unreadable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == before.st_dev, info.st_ino == before.st_ino else { close(fd); throw ThreadFailure.unreadable }
        return fd
    }
    private static func pread(_ fd: Int32, count: Int, at offset: Int) throws -> Data {
        var data = Data(count: count), done = 0
        while done < count {
            let got = data.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress!.advanced(by: done), count - done, off_t(offset + done)) }
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { throw ThreadFailure.unreadable }
            done += got
        }
        return data
    }
    private static func json(home: String, path: String, budget: inout Int) throws -> [String: Any] {
        let before = try checked(home: home, path: path, directory: false)
        guard before.st_size > 0, before.st_size <= 2 * 1_048_576 else { throw ThreadFailure.unreadable }
        budget -= Int(before.st_size)
        guard budget >= 0 else { throw ThreadFailure.unreadable }
        let fd = try descriptor(path, expecting: before)
        defer { close(fd) }
        let data = try pread(fd, count: Int(before.st_size), at: 0)
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ThreadFailure.unreadable }
        return value
    }

    /// Finds the one active Claude Code session whose title matches exactly.
    static func binding(title: String, home rawHome: String) throws -> ClaudeBinding {
        guard !title.isEmpty, title.count <= 2000, !title.contains("\0") else { throw ThreadFailure.unreadable }
        guard let resolved = realpath(rawHome, nil) else { throw ThreadFailure.unreadable }
        let home = String(cString: resolved); free(resolved)
        var homeInfo = stat()
        guard stat(home, &homeInfo) == 0, homeInfo.st_uid == geteuid() else { throw ThreadFailure.unreadable }
        let app = home + "/Library/Application Support/Claude"
        var budget = 16 * 1_048_576
        let desktop = try json(home: home, path: app + "/config.json", budget: &budget)
        let cli = try json(home: home, path: home + "/.claude.json", budget: &budget)
        guard let account = cli["oauthAccount"] as? [String: Any], isUUID(account["accountUuid"]), isUUID(account["organizationUuid"]),
              let accountID = account["accountUuid"] as? String, let organizationID = account["organizationUuid"] as? String,
              desktop["lastKnownAccountUuid"] as? String == accountID else { throw ThreadFailure.unreadable }
        let directory = "\(app)/claude-code-sessions/\(accountID)/\(organizationID)"
        _ = try checked(home: home, path: directory, directory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.range(of: "^local_[a-f0-9-]+\\.json$", options: .regularExpression) != nil }
        guard names.count <= 512 else { throw ThreadFailure.unreadable }
        var matches = [(record: [String: Any], name: String)]()
        for name in names.sorted() {
            let filenameID = String(name.dropFirst(6).dropLast(5))
            guard isUUID(filenameID) else { continue }
            let record = try json(home: home, path: directory + "/" + name, budget: &budget)
            if record["title"] as? String != title || isBool(record["isArchived"], true) { continue }
            // A missing archive flag cannot establish an active Desktop session.
            guard isBool(record["isArchived"], false), record["sessionId"] as? String == "local_" + filenameID else { throw ThreadFailure.noSession }
            guard isUUID(record["cliSessionId"]), let cwd = record["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0"),
                  cwd.count <= 4096, URL(fileURLWithPath: cwd).standardized.path == cwd else { throw ThreadFailure.noSession }
            matches.append((record, name))
        }
        guard matches.count == 1 else { throw matches.isEmpty ? ThreadFailure.noSession : ThreadFailure.ambiguous }
        try rejectSharedTitle(title, app: app, home: home, budget: &budget)
        let record = matches[0].record
        // Claude Code encodes the folder per UTF-16 unit, so one emoji becomes two dashes.
        let project = String(String.UnicodeScalarView((record["cwd"] as! String).utf16.map { unit -> Unicode.Scalar in
            let ascii = unit < 128 ? Unicode.Scalar(UInt8(unit)) : nil
            if let ascii, CharacterSet.alphanumerics.contains(ascii) { return ascii }
            return "-"
        }))
        let session = record["cliSessionId"] as! String
        let transcript = "\(home)/.claude/projects/\(project)/\(session).jsonl"
        // The exact indexed UUID path or nothing. Never search by title or take the newest file.
        guard (try? checked(home: home, path: transcript, directory: false)) != nil else { throw ThreadFailure.noSession }
        return ClaudeBinding(accountID: accountID, organizationID: organizationID, cliSessionID: session, transcript: transcript)
    }

    static let sharedTitleMessage = "Two chats on this Mac share this title, so its messages can\u{2019}t be shown. Rename one, then refresh."

    /// Another kind of session (local-agent-mode-sessions/<account>/<org>/local_*.json, with "title" and
    /// "isArchived") may carry the same title as the Code session; the sidebar cannot say which one a row is.
    /// A missing archive flag counts as unarchived here. An unreadable file in that store fails closed.
    /// Not covered: a chat that exists only in the cloud and shares a title with a Code session.
    private static func rejectSharedTitle(_ title: String, app: String, home: String, budget: inout Int) throws {
        let store = app + "/local-agent-mode-sessions"
        guard FileManager.default.fileExists(atPath: store) else { return }
        _ = try checked(home: home, path: store, directory: true)
        var files = [String]()
        for account in (try? FileManager.default.contentsOfDirectory(atPath: store)) ?? [] {
            let accountPath = store + "/" + account
            var info = stat()
            guard lstat(accountPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            for organization in (try? FileManager.default.contentsOfDirectory(atPath: accountPath)) ?? [] {
                let organizationPath = accountPath + "/" + organization
                guard lstat(organizationPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                files += ((try? FileManager.default.contentsOfDirectory(atPath: organizationPath)) ?? [])
                    .filter { $0.range(of: "^local_[a-f0-9-]+\\.json$", options: .regularExpression) != nil }
                    .map { organizationPath + "/" + $0 }
            }
        }
        guard files.count <= 512 else { throw ThreadFailure.unreadable }
        for file in files {
            let record = try json(home: home, path: file, budget: &budget)
            if record["title"] as? String == title, !isBool(record["isArchived"], true) { throw ThreadFailure.ambiguous }
        }
    }

    static func tail(_ binding: ClaudeBinding, home rawHome: String, maximum: Int) throws -> (data: Data, startsMidFile: Bool) {
        guard let resolved = realpath(rawHome, nil) else { throw ThreadFailure.unreadable }
        let home = String(cString: resolved); free(resolved)
        let before = try checked(home: home, path: binding.transcript, directory: false)
        let fd = try descriptor(binding.transcript, expecting: before)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ThreadFailure.unreadable }
        let size = Int(info.st_size), start = max(0, size - maximum)
        let data = try pread(fd, count: size - start, at: start)
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size >= info.st_size else { throw ThreadFailure.unreadable }
        return (data, start > 0)
    }

    private static func scaffolding(_ text: String) -> Bool {
        ["<system-reminder>", "<task-notification>", "<local-command-caveat>", "<local-command-stdout>", "<local-command-stderr>",
         "<command-message>", "<command-name>", "<ide_opened_file>", "<ide_selection>",
         "This session is being continued from a previous conversation that ran out of context.",
         "Caveat: The messages below were generated by the user while running local commands."].contains { text.hasPrefix($0) }
    }
    /// Visible user and assistant text only: no tool calls or results, thinking, sidechains, meta or wrappers.
    static func visible(_ record: [String: Any]) -> ThreadTurn? {
        guard let type = record["type"] as? String, type == "user" || type == "assistant",
              isBool(record["isSidechain"], false), !isBool(record["isMeta"], true), !isBool(record["isCompactSummary"], true),
              !isBool(record["isVisibleInTranscriptOnly"], true), !isBool(record["hidden"], true), record["visibility"] as? String != "hidden",
              record["toolUseResult"] == nil, record["sourceToolAssistantUUID"] == nil,
              let message = record["message"] as? [String: Any], message["role"] as? String == type else { return nil }
        var text: String
        if let string = message["content"] as? String, type == "user" { text = string }
        else if let blocks = message["content"] as? [Any] {
            let objects = blocks.compactMap { $0 as? [String: Any] }
            if type == "user", objects.contains(where: { ["tool_result", "tool_use"].contains($0["type"] as? String ?? "") }) { return nil }
            text = objects.filter { block in
                guard block["type"] as? String == "text", let value = block["text"] as? String, !isBool(block["hidden"], true), block["visibility"] as? String != "hidden" else { return false }
                return type != "user" || !scaffolding(ThreadLimits.clean(value))
            }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else { return nil }
        text = ThreadLimits.clean(text)
        if text.isEmpty || (type == "user" && scaffolding(text)) { return nil }
        return ThreadTurn(role: type, text: text)
    }

    /// A message the person sent while Claude was still working. Claude Code stores it as a
    /// "queued_command" attachment, not as a user record, so without this it never shows in the thread.
    /// Only ones a person typed count: background task notices use the same record and are left out.
    static func queued(_ record: [String: Any]) -> ThreadTurn? {
        guard record["type"] as? String == "attachment", isBool(record["isSidechain"], false), !isBool(record["isMeta"], true),
              let attachment = record["attachment"] as? [String: Any], attachment["type"] as? String == "queued_command",
              attachment["commandMode"] as? String == "prompt" else { return nil }
        let human = isBool(attachment["humanTurn"], true) || (attachment["origin"] as? [String: Any])?["kind"] as? String == "human"
        guard human else { return nil }
        var text: String
        if let string = attachment["prompt"] as? String { text = string }
        else if let blocks = attachment["prompt"] as? [Any] {
            text = blocks.compactMap { $0 as? [String: Any] }.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.filter { !scaffolding(ThreadLimits.clean($0)) }.joined(separator: "\n")
        } else { return nil }
        text = ThreadLimits.clean(text)
        if text.isEmpty || scaffolding(text) { return nil }
        return ThreadTurn(role: "user", text: text)
    }

    /// What a transcript line says at its top level, found without decoding the message inside it.
    struct LineFields {
        var type: String?, uuid: String?, sessionId: String?
        var parent: String?, parentIsNull = false, parentPresent = false
        var sidechain: Bool?, hasToolUseResult = false
    }

    /// Reads the few short top-level fields of one JSON object and skips every other value, so a
    /// multi-megabyte tool result or screenshot costs a scan, not a decode. Nil when the line is not
    /// shaped as expected; the caller then decodes it fully and fails closed if that fails too.
    static func scan(_ base: UnsafePointer<UInt8>, _ count: Int) -> LineFields? {
        var i = 0
        func space() { while i < count, base[i] == 0x20 || base[i] == 0x0A || base[i] == 0x0D || base[i] == 0x09 { i += 1 } }
        /// Index just past the closing quote of the string whose opening quote is at i.
        func endOfString() -> Int? {
            var j = i + 1
            while j < count {
                guard let hit = memchr(base + j, 0x22, count - j) else { return nil }
                let quote = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                var slashes = 0, k = quote - 1
                while k > j - 1, base[k] == 0x5C { slashes += 1; k -= 1 }
                if slashes % 2 == 0 { return quote + 1 }
                j = quote + 1
            }
            return nil
        }
        func skipValue() -> Bool {
            guard i < count else { return false }
            switch base[i] {
            case 0x22: guard let end = endOfString() else { return false }; i = end; return true
            case 0x7B, 0x5B:
                var depth = 0
                while i < count {
                    switch base[i] {
                    case 0x22: guard let end = endOfString() else { return false }; i = end; continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D: depth -= 1; if depth == 0 { i += 1; return true }
                    default: break
                    }
                    i += 1
                }
                return false
            default:
                while i < count, base[i] != 0x2C, base[i] != 0x7D, base[i] != 0x20, base[i] != 0x0A, base[i] != 0x0D { i += 1 }
                return true
            }
        }
        var fields = LineFields()
        space()
        guard i < count, base[i] == 0x7B else { return nil }
        i += 1
        while true {
            space()
            guard i < count else { return nil }
            if base[i] == 0x7D { return fields }
            guard base[i] == 0x22, let keyEnd = endOfString() else { return nil }
            let key = UnsafeBufferPointer(start: base + i + 1, count: keyEnd - i - 2)
            i = keyEnd; space()
            guard i < count, base[i] == 0x3A else { return nil }
            i += 1; space()
            guard i < count else { return nil }
            let name = String(decoding: key, as: UTF8.self)
            let isString = base[i] == 0x22
            switch name {
            case "type", "uuid", "sessionId", "parentUuid", "isSidechain", "toolUseResult":
                if name == "toolUseResult" { fields.hasToolUseResult = true; guard skipValue() else { return nil } }
                else if isString {
                    let start = i
                    guard let end = endOfString() else { return nil }
                    let raw = UnsafeBufferPointer(start: base + start + 1, count: end - start - 2)
                    // An escaped identifier is not one we can trust without a real decode.
                    if raw.contains(0x5C) { return nil }
                    let text = String(decoding: raw, as: UTF8.self)
                    i = end
                    switch name {
                    case "type": fields.type = text
                    case "uuid": fields.uuid = text
                    case "sessionId": fields.sessionId = text
                    case "parentUuid": fields.parent = text; fields.parentPresent = true
                    default: return nil
                    }
                } else {
                    let start = i
                    guard skipValue() else { return nil }
                    let literal = String(decoding: UnsafeBufferPointer(start: base + start, count: i - start), as: UTF8.self)
                    switch name {
                    case "isSidechain": fields.sidechain = literal == "false" ? false : literal == "true" ? true : nil
                    case "parentUuid": fields.parentPresent = true; fields.parentIsNull = literal == "null"
                    default: break
                    }
                }
            default:
                guard skipValue() else { return nil }
            }
            space()
            guard i < count else { return nil }
            if base[i] == 0x2C { i += 1; continue }
            if base[i] == 0x7D { return fields }
            return nil
        }
    }

    /// Walks the parent chain back from the newest record. Returns visible messages, newest first.
    /// `reachedEdge` means a parent was missing from the buffer, so older messages exist beyond it.
    static func parse(_ buffer: Data, binding: ClaudeBinding, startsMidFile: Bool, deadline: Double = .infinity) throws -> (turns: [ThreadTurn], limited: Bool, reachedEdge: Bool) {
        try buffer.withUnsafeBytes { raw -> (turns: [ThreadTurn], limited: Bool, reachedEdge: Bool) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return ([], startsMidFile, false) }
            var begin = 0, end = raw.count, limited = false
            if startsMidFile {
                guard let newline = memchr(base, 10, end) else { throw ThreadFailure.unreadable }
                begin = base.distance(to: newline.assumingMemoryBound(to: UInt8.self)) + 1
            }
            if end > 0, base[end - 1] != 10 {
                var last = end - 1
                while last >= 0, base[last] != 10 { last -= 1 }
                end = last + 1; limited = true
            }
            var nodes = [String: (parent: String?, turn: ThreadTurn?)](), leaf: String?, bridge: [String: Any]?, lines = 0
            var cursor = begin
            while cursor < end {
                let stop = memchr(base + cursor, 10, end - cursor).map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? end
                let length = stop - cursor, start = cursor
                cursor = stop + 1
                if length == 0 { continue }
                lines += 1
                if lines % 64 == 0, ProcessInfo.processInfo.systemUptime > deadline { throw ThreadFailure.timeout }
                // Decode a line fully only when it could be a visible message or the ownership record.
                func decode() throws -> [String: Any] {
                    guard length <= ThreadLimits.lineBytes,
                          let object = try? JSONSerialization.jsonObject(with: Data(bytes: base + start, count: length)) as? [String: Any] else { throw ThreadFailure.unreadable }
                    return object
                }
                var fields = scan(base + start, length)
                var record: [String: Any]?
                if fields == nil {
                    record = try decode()
                    fields = LineFields(type: record?["type"] as? String, uuid: record?["uuid"] as? String, sessionId: record?["sessionId"] as? String,
                                        parent: record?["parentUuid"] as? String, parentIsNull: record?["parentUuid"] is NSNull,
                                        parentPresent: record?["parentUuid"] != nil, sidechain: (record?["isSidechain"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil },
                                        hasToolUseResult: record?["toolUseResult"] != nil)
                }
                guard let fields, fields.sessionId == binding.cliSessionID else { continue }
                if fields.type == "bridge-session" { if let record { bridge = record } else { bridge = try decode() }; continue }
                guard let type = fields.type, ["user", "assistant", "system", "attachment"].contains(type), fields.sidechain == false,
                      isUUID(fields.uuid), let uuid = fields.uuid else { continue }
                if !fields.parentIsNull, !isUUID(fields.parent) { throw ThreadFailure.unreadable }
                guard nodes[uuid] == nil else { throw ThreadFailure.unreadable }
                var turn: ThreadTurn?
                // A tool result is never a visible message, so its payload is never decoded.
                if (type == "user" || type == "assistant"), !fields.hasToolUseResult {
                    if length > ThreadLimits.lineBytes { limited = true }
                    else { let full = try record ?? decode(); turn = visible(full) }
                } else if type == "attachment", length <= ThreadLimits.lineBytes,
                          memmem(base + start, length, "\"queued_command\"", 16) != nil {
                    // Attachments are decoded only when they could be a message sent while Claude was working.
                    if let full = try? (record ?? decode()) { turn = queued(full) }
                }
                nodes[uuid] = (fields.parentIsNull ? nil : fields.parent, turn); leaf = uuid
            }
            guard let bridge, bridge["ownerAccountUuid"] as? String == binding.accountID,
                  bridge["ownerOrganizationUuid"] as? String == binding.organizationID else { throw ThreadFailure.unverified }
            var turns = [ThreadTurn](), seen = Set<String>(), next = leaf, reachedEdge = false
            while let id = next {
                guard seen.insert(id).inserted else { throw ThreadFailure.unreadable }
                guard let node = nodes[id] else { limited = true; reachedEdge = true; break }
                if let turn = node.turn { turns.append(turn) }
                next = node.parent
            }
            return (turns, limited, reachedEdge)
        }
    }

    /// Reads a window at the end of the transcript, widening it while the newest visible messages are not in it.
    static func read(title: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path, deadline: Double,
                     windows: [Int] = ThreadLimits.windows, now: () -> Double = { ProcessInfo.processInfo.systemUptime }) throws -> (turns: [ThreadTurn], limited: Bool) {
        let found = try binding(title: title, home: home)
        var best: (turns: [ThreadTurn], limited: Bool)?
        var wholeFile = false
        for (index, size) in windows.enumerated() {
            let started = now()
            let tail = try tail(found, home: home, maximum: size)
            wholeFile = !tail.startsMidFile
            let last = index + 1 >= windows.count
            var widen = false
            do {
                let parsed = try parse(tail.data, binding: found, startsMidFile: tail.startsMidFile, deadline: deadline)
                best = (parsed.turns, parsed.limited)
                widen = tail.startsMidFile && (parsed.turns.count < 6 || (parsed.reachedEdge && parsed.turns.count < ThreadLimits.maxTurns))
            } catch ThreadFailure.unverified where tail.startsMidFile && !last {
                widen = true     // the ownership record may sit before this window
            } catch ThreadFailure.timeout where best != nil {
                best?.limited = true; break
            }
            guard widen, !last else { break }
            // Reading and parsing cost about the same per byte as the last window did.
            let predicted = (now() - started) / Double(size) * Double(windows[index + 1])
            guard now() + predicted < deadline else { break }
        }
        guard var result = best else { throw ThreadFailure.unverified }
        // The title must still name the same single session once the file has been read.
        guard try binding(title: title, home: home).transcript == found.transcript else { throw ThreadFailure.unreadable }
        if result.turns.isEmpty { throw wholeFile ? ThreadFailure.empty : ThreadFailure.tooFarBack }
        return result
    }
}

// MARK: Codex

enum CodexThread {
    typealias Call = (String, [String: Any]) throws -> [String: Any]
    static let turnPage = 5, itemPage = 100, requestLimit = 24
    /// One page of a chat's items can carry tool output and images, far more than a chat list does.
    static let responseLimit = 64 * 1_048_576

    private static func identifier(_ raw: Any?) throws -> String {
        guard let id = raw as? String, !id.isEmpty, id.utf8.count <= 256,
              !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ThreadFailure.unreadable }
        return id
    }
    private static func rows(_ result: [String: Any], maximum: Int) throws -> [[String: Any]] {
        guard let rows = result["data"] as? [[String: Any]], rows.count <= maximum else { throw ThreadFailure.unreadable }
        return rows
    }
    private static func cursor(_ result: [String: Any], seen: inout Set<String>) throws -> String? {
        guard let value = result["nextCursor"], !(value is NSNull) else { return nil }
        guard let cursor = value as? String, !cursor.isEmpty, cursor.utf8.count <= 4096, seen.insert(cursor).inserted else { throw ThreadFailure.unreadable }
        return cursor
    }
    /// Codex wraps some user input in transport text that the person never typed.
    static func userText(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("# AGENTS.md instructions") || text.hasPrefix("<environment_context>") || text.hasPrefix("<permissions instructions>") { return nil }
        if text.hasPrefix("<realtime_delegation>") {
            guard !text.contains("<source>transcript_tail_flush</source>"), let start = text.range(of: "<input>"),
                  let end = text.range(of: "</input>", range: start.upperBound..<text.endIndex) else { return nil }
            text = String(text[start.upperBound..<end.lowerBound])
        } else if text.hasPrefix("<send_user_message_question_reply>") {
            guard let start = text.range(of: ">"), let end = text.range(of: "</send_user_message_question_reply>"),
                  let data = String(text[start.upperBound..<end.lowerBound]).data(using: .utf8),
                  let replies = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            text = replies.compactMap { $0["answer"] as? String }.joined(separator: "\n")
        } else if text.hasPrefix("# Files mentioned by the user:") {
            guard let request = text.range(of: "## My request:") else { return nil }
            text = String(text[request.upperBound...])
            text = text.replacingOccurrences(of: "(?s)<image\\b[^>]*>.*?</image>", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "<image\\b[^>]*>", with: "", options: .regularExpression)
        }
        text = ThreadLimits.clean(text, keepingLineBreaks: false)
        return text.isEmpty ? nil : text
    }
    static func message(_ entry: [String: Any], turnID: String) throws -> (id: String, turn: ThreadTurn)? {
        guard try identifier(entry["turnId"]) == turnID else { throw ThreadFailure.unreadable }
        guard let item = entry["item"] as? [String: Any], let type = item["type"] as? String else { throw ThreadFailure.unreadable }
        guard type == "userMessage" || type == "agentMessage" else { return nil }
        let role = type == "userMessage" ? "user" : "assistant"
        if let claimed = item["role"], !(claimed is NSNull), claimed as? String != role { return nil }
        if item["hidden"] as? Bool == true || item["visibility"] as? String == "hidden" { return nil }
        if let moderation = item["moderation"] as? [String: Any], moderation["moderated"] as? Bool == true { return nil }
        let id = try identifier(item["id"])
        if type == "agentMessage" {
            if ["analysis", "reasoning", "hidden"].contains(item["phase"] as? String ?? "") { return nil }
            guard let raw = item["text"] as? String else { throw ThreadFailure.unreadable }
            let text = ThreadLimits.clean(raw, keepingLineBreaks: false)
            return text.isEmpty ? nil : (id, ThreadTurn(role: role, text: text))
        }
        // Current Codex uses content; some versions use input. Never fall back to other fields.
        guard let parts = (item["content"] ?? item["input"]) as? [[String: Any]] else { return nil }
        let text = parts.compactMap { part -> String? in
            guard part["type"] as? String == "text", let value = part["text"] as? String else { return nil }
            if let owner = part["role"] as? String, owner != "user" { return nil }
            return userText(value)
        }.joined(separator: "\n")
        return text.isEmpty ? nil : (id, ThreadTurn(role: role, text: text))
    }

    /// Messages newest first. Reads by exact thread UUID only; the caller has already matched it to the chat list.
    static func read(threadID: String, call: Call) throws -> (turns: [ThreadTurn], limited: Bool) {
        guard threadID.utf8.count == 36, let uuid = UUID(uuidString: threadID), uuid.uuidString.lowercased() == threadID else { throw ThreadFailure.unreadable }
        var requests = 1
        let metadata = try call("thread/read", ["threadId": threadID, "includeTurns": false])
        guard let thread = metadata["thread"] as? [String: Any], (thread["id"] as? String)?.lowercased() == threadID else { throw ThreadFailure.unreadable }
        var messages = [ThreadTurn](), itemIDs = Set<String>(), turnIDs = Set<String>(), turnCursors = Set<String>(), turnCursor: String?
        var limited = false
        pages: while true {
            var params: [String: Any] = ["threadId": threadID, "limit": turnPage, "sortDirection": "desc", "itemsView": "notLoaded"]
            if let turnCursor { params["cursor"] = turnCursor }
            requests += 1
            let response = try call("thread/turns/list", params)
            let turns = try rows(response, maximum: turnPage)
            let moreTurnsAfterPage = response["nextCursor"] != nil && !(response["nextCursor"] is NSNull)
            for (index, turn) in turns.enumerated() {
                let turnID = try identifier(turn["id"])
                guard turnIDs.insert(turnID).inserted else { continue }
                var itemCursor: String?, itemCursors = Set<String>()
                repeat {
                    guard requests < requestLimit else { limited = true; break pages }
                    var itemParams: [String: Any] = ["threadId": threadID, "turnId": turnID, "limit": itemPage, "sortDirection": "desc"]
                    if let itemCursor { itemParams["cursor"] = itemCursor }
                    requests += 1
                    let result = try call("thread/items/list", itemParams)
                    for entry in try rows(result, maximum: itemPage) {
                        if let value = try message(entry, turnID: turnID), itemIDs.insert(turnID + ":" + value.id).inserted { messages.append(value.turn) }
                    }
                    itemCursor = try cursor(result, seen: &itemCursors)
                    if messages.count >= ThreadLimits.maxTurns {
                        limited = itemCursor != nil || index < turns.count - 1 || moreTurnsAfterPage
                        break pages
                    }
                } while itemCursor != nil
            }
            turnCursor = try cursor(response, seen: &turnCursors)
            if turnCursor == nil { break }
        }
        return (messages, limited)
    }
}

// MARK: Entry points

extension Array where Element == String {
    /// The thread route reads files and needs neither the app running nor Accessibility;
    /// it answers for every provider, so the phone must not mistake a gap for an old companion.
    func withReadThread(installed: Bool, unlocked: Bool) -> [String] {
        installed && unlocked && !contains("readThread") ? self + ["readThread"] : self
    }
}

/// A piece of static text inside a history entry, and where it sat.
struct MuseText: Equatable {
    var text: String
    /// Inside a button, pop-up or other control: a label, never message text.
    var insideControl = false
    /// A direct child of the entry's root.
    var directChild = false
}

/// One entry of Muse's message history: its text, the labels found inside it, and where its root sat
/// in the history container (x and width, in points from the container's left edge).
struct MuseEntry: Equatable {
    var pieces: [MuseText]
    var labels: [String]
    var x: Double?
    var width: Double?
    init(pieces: [MuseText], labels: [String] = [], x: Double? = nil, width: Double? = nil) {
        self.pieces = pieces; self.labels = labels; self.x = x; self.width = width
    }
    init(texts: [String], labels: [String] = [], x: Double? = nil, width: Double? = nil) {
        self.init(pieces: texts.map { MuseText(text: $0) }, labels: labels, x: x, width: width)
    }
}

/// What one read of Muse's screen found.
struct MuseThreadRead {
    let openTitle: String
    /// Another chat in the open panel carries the same title, so the open one cannot be told apart.
    let ambiguous: Bool
    let entries: [MuseEntry]
    /// The history held more entries than were read.
    let olderEntries: Bool
    /// Width of the history container, the reference for each entry's position.
    var historyWidth: Double = 0
}

/// What the history-shape diagnostic may say about an attribute: never its text.
enum MuseShape {
    /// Attributes whose short fixed values describe the UI, not the user's words.
    static let fixedValueAttributes: Set<String> = ["AXRole", "AXSubrole", "AXRoleDescription", "AXIdentifier", "AXDOMIdentifier", "AXARIACurrent",
                                                    "AXARIALive", "AXARIARelevant", "AXARIABusy", "AXDOMClassList"]
    /// A fixed UI identifier is letters and separators only, so it cannot be a sentence, a date or an id.
    static func isFixedIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 40 && text.range(of: "^[A-Za-z][A-Za-z_.:-]*$", options: .regularExpression) != nil
    }
    /// The first words that end with a colon, when they are at most two: a UI label such as "User message:".
    static func labelPrefix(_ text: String) -> String? {
        let words = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).prefix(2).map(String.init)
        for count in 1...max(1, words.count) where count <= words.count {
            let candidate = words.prefix(count).joined(separator: " ")
            if candidate.hasSuffix(":"), candidate.count <= 24 { return candidate }
        }
        return nil
    }
    static func string(name: String, text: String) -> [String: Any] {
        var info: [String: Any] = ["name": name, "length": text.count, "startsWithUserMessage": text.hasPrefix("User message"),
                                   "timestampLike": MuseThread.isTimestamp(text), "controlWord": MuseThread.chrome.contains(text)]
        if let prefix = labelPrefix(text) { info["labelPrefix"] = prefix }
        // A very short string is shaped, not shown: letters become a, digits 9, the rest stays.
        if text.count <= 8 { info["pattern"] = String(text.map { $0.isLetter ? "a" : $0.isWholeNumber ? "9" : $0 }) }
        if fixedValueAttributes.contains(name), isFixedIdentifier(text) { info["value"] = text }
        return info
    }
    static func strings(name: String, values: [String]) -> [String: Any] {
        ["name": name, "count": values.count, "values": values.map { isFixedIdentifier($0) && fixedValueAttributes.contains(name) ? $0 : "(\($0.count) characters)" }]
    }
}

enum MuseThread {
    static let openMessage = "Open this chat in Muse on your Mac to see its messages."
    static let closedMessage = "Muse is not showing a chat right now. Open Muse on this Mac."
    static let accessibilityMessage = "Enable Accessibility for Agent Micro Controller."
    /// Muse labels what a person sent with this prefix; an entry drawn bare carries no marker.
    static let userMarker = "User message: "
    /// Controls and notes that sit among the entries and are not messages.
    static let chrome: Set<String> = ["Copy", "Copied", "Retry", "Share", "Like", "Dislike", "Thinking", "Thinking\u{2026}", "Show more", "Show less", "Today", "Yesterday"]

    static func isTimestamp(_ text: String) -> Bool {
        text.range(of: "^\\d{1,2}:\\d{2}(\\s?[AaPp][Mm])?$", options: .regularExpression) != nil
    }
    static let layoutMessage = "Muse\u{2019}s layout isn\u{2019}t one this version can read. Update Agent Micro Controller on your Mac."
    /// Muse lays an assistant reply against the left edge and a person's message against the right.
    static func role(of entry: MuseEntry, marked: Bool, historyWidth: Double) -> String? {
        if marked { return "user" }
        guard let x = entry.x, let width = entry.width, historyWidth > 0 else { return nil }
        if x < historyWidth * 0.15 { return "assistant" }
        if x > historyWidth * 0.30, abs(historyWidth - (x + width)) <= historyWidth * 0.06 { return "user" }
        return nil
    }
    /// Oldest first. Entries with no message text are dropped; text inside controls is never message text.
    /// An entry that sits on neither side is skipped, and when more than a third of the entries that hold
    /// text are like that the layout is not one this reader knows, so nothing is returned.
    static func read(entries: [MuseEntry], historyWidth: Double) -> (turns: [ThreadTurn], unsupported: Bool) {
        var turns: [ThreadTurn] = [], withText = 0, unplaced = 0
        func usable(_ raw: String) -> String? {
            let text = ThreadLimits.clean(raw.hasPrefix(userMarker) ? String(raw.dropFirst(userMarker.count)) : raw)
            return text.isEmpty || text == "User message" || chrome.contains(text) || isTimestamp(text) ? nil : text
        }
        for entry in entries {
            let pieces = entry.pieces.filter { !$0.insideControl }
            let marked = (pieces.map(\.text) + entry.labels).contains { $0.hasPrefix(userMarker) || $0 == "User message" }
            let role = role(of: entry, marked: marked, historyWidth: historyWidth)
            // Short text directly under a person's entry root sits before the message and is metadata (a time or label).
            let kept = pieces.compactMap { piece -> String? in
                guard let text = usable(piece.text) else { return nil }
                return role == "user" && piece.directChild && text.count <= 8 ? nil : text
            }
            guard !kept.isEmpty else { continue }
            withText += 1
            guard let role else { unplaced += 1; continue }
            turns.append(ThreadTurn(role: role, text: kept.joined(separator: "\n")))
        }
        return (turns, withText > 0 && unplaced * 3 > withText)
    }
    /// True only when the chat Muse shows is the one asked for, and no other chat shares its title.
    static func isRequestedChat(read: MuseThreadRead, chatID: String, idFor: (String) -> String) -> Bool {
        !read.ambiguous && idFor(read.openTitle) == chatID
    }
}

enum ThreadReader {
    static let emptyMessage = "This chat has no messages to show yet."

    /// The one place a snapshot with turns is made: a thread with nothing visible is unavailable, never "ok".
    static func make(provider: String, chatID: String, turnsNewestFirst: [ThreadTurn], limited: Bool) -> ThreadSnapshot {
        let bounded = ThreadLimits.bound(turnsNewestFirst, limited: limited)
        guard !bounded.turns.isEmpty else { return .unavailable(provider: provider, chatID: chatID, emptyMessage) }
        return .ok(provider: provider, chatID: chatID, turns: bounded.turns, truncated: bounded.truncated)
    }

    /// Muse's text comes from the screen, so only the chat that is open can be read.
    static func muse(chatID: String, read: (Double) -> MuseThreadRead?, idFor: (String) -> String) -> ThreadSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + ThreadLimits.seconds
        guard let seen = read(deadline) else { return .unavailable(provider: "muse", chatID: chatID, MuseThread.closedMessage) }
        guard MuseThread.isRequestedChat(read: seen, chatID: chatID, idFor: idFor) else { return .unavailable(provider: "muse", chatID: chatID, MuseThread.openMessage) }
        let built = MuseThread.read(entries: seen.entries, historyWidth: seen.historyWidth)
        if built.unsupported { return .unavailable(provider: "muse", chatID: chatID, MuseThread.layoutMessage) }
        return make(provider: "muse", chatID: chatID, turnsNewestFirst: built.turns.reversed(), limited: seen.olderEntries)
    }
    static let tooFarBackMessage = "This chat\u{2019}s recent messages are too far back to read right now. Try again after its next reply."
    static let tooLargeMessage = "This chat\u{2019}s latest messages are too large to show here."
    static let refreshMessage = "Refresh the chats on your phone, then try again."
    static let codexUnavailable = "Codex could not provide this chat\u{2019}s messages right now. Open Codex on this Mac and try again."
    static let claudeUnavailable = "This Claude chat could not be read safely from its transcript right now."

    private static func finish(provider: String, chatID: String, _ read: () throws -> (turns: [ThreadTurn], limited: Bool), failure: (ThreadFailure) -> String) -> ThreadSnapshot {
        do {
            let result = try read()
            return make(provider: provider, chatID: chatID, turnsNewestFirst: result.turns, limited: result.limited)
        } catch let error as ThreadFailure {
            return .unavailable(provider: provider, chatID: chatID, failure(error))
        } catch CodexInventoryError.timeout {
            return .unavailable(provider: provider, chatID: chatID, failure(.timeout))
        } catch CodexInventoryError.tooLarge {
            return .unavailable(provider: provider, chatID: chatID, tooLargeMessage)
        } catch {
            // Other errors can carry paths or text; only a fixed sentence leaves here.
            return .unavailable(provider: provider, chatID: chatID, failure(.unreadable))
        }
    }

    static func claude(title: String, chatID: String) async -> ThreadSnapshot {
        await Task.detached(priority: .userInitiated) {
            let deadline = ProcessInfo.processInfo.systemUptime + ThreadLimits.seconds
            return finish(provider: "claude", chatID: chatID, { try ClaudeThread.read(title: title, deadline: deadline) }, failure: {
                switch $0 {
                case .noSession: return ClaudeThread.noSessionMessage
                case .ambiguous: return ClaudeThread.sharedTitleMessage
                case .timeout: return "Reading this Claude chat took too long. Try again."
                case .tooFarBack: return tooFarBackMessage
                case .empty: return emptyMessage
                case .unverified: return "This Claude chat\u{2019}s transcript has no record tying it to your account, so it is not shown."
                case .unreadable: return claudeUnavailable
                }
            })
        }.value
    }

    static func codex(threadID: String, chatID: String) async -> ThreadSnapshot {
        let task = Task.detached(priority: .userInitiated) { () -> ThreadSnapshot in
            finish(provider: "codex", chatID: chatID, {
                let socket = try CodexMetadataSocket(path: try CodexReadOnly.socketPath(), timeout: ThreadLimits.seconds,
                                                     frameLimit: CodexThread.responseLimit, messageLimit: CodexThread.responseLimit)
                try socket.initializeSession()
                return try CodexThread.read(threadID: threadID, call: socket.call)
            }, failure: { $0 == .timeout ? "Codex took too long to answer. Try again." : codexUnavailable })
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
}

extension ThreadFailure: Equatable {}
