import Foundation
import CryptoKit
import Darwin

struct CodexSavedChat: Equatable, Sendable {
    let id: String
    let name: String
}

enum CodexInventoryError: LocalizedError {
    case unavailable, timeout, invalidResponse, rejected, tooLarge
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex’s existing local chat service is unavailable. Open Codex on this Mac, then refresh."
        case .timeout: return "Codex’s chat list took too long to respond. Try refreshing again."
        case .invalidResponse: return "Codex returned an unsupported chat-list response. No chat was changed."
        case .rejected: return "Codex could not provide this account’s saved chats. No chat was changed."
        case .tooLarge: return "Codex’s chat-list response exceeded the controller’s limit. No chat was changed."
        }
    }
}

// The existing daemon is a metadata reader, not the desktop conversation owner.
// No method in this client starts a daemon, resumes a thread, or sends a turn.
enum CodexReadOnly {
    static func chats(maximum: Int = 500) async throws -> [CodexSavedChat] {
        let task = Task.detached(priority: .userInitiated) {
            let connection = try CodexMetadataSocket(path: try socketPath())
            return try connection.list(maximum: maximum)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    static func socketPath() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let home: URL
        if let path = environment["CODEX_HOME"], !path.isEmpty {
            guard path.hasPrefix("/") else { throw CodexInventoryError.unavailable }
            home = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        return home.appendingPathComponent("app-server-control/app-server-control.sock").path
    }
}

// Pure protocol helpers are tested separately from the real local service.
enum CodexInventoryProtocol {
    static let frameLimit = 2_097_152
    static let messageLimit = 4_194_304
    static let pageLimit = 100

    static func initialize(id: Int) -> [String: Any] {
        ["id": id, "method": "initialize", "params": [
            "clientInfo": ["name": "genesis_controller_inventory", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true]
        ]]
    }
    static func pageRequest(id: Int, cursor: String?, limit: Int) -> [String: Any] {
        var params: [String: Any] = ["limit": min(pageLimit, max(1, limit)), "archived": false,
                                     "currentAccountOnly": true, "useStateDbOnly": true]
        if let cursor { params["cursor"] = cursor }
        return ["id": id, "method": "thread/list", "params": params]
    }
    static func chat(_ row: [String: Any]) -> CodexSavedChat? {
        guard let rawID = row["id"] as? String, let id = UUID(uuidString: rawID),
              let name = row["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              row["ephemeral"] as? Bool != true,
              row["canAcceptDirectInput"] as? Bool != false else { return nil }
        if let source = row["source"] as? [String: Any], source.keys.contains(where: { $0.lowercased() == "subagent" }) { return nil }
        if let source = row["source"] as? String, source.lowercased() == "subagent" { return nil }
        // Profile labels have a 240-character limit. Identity always uses UUID.
        return CodexSavedChat(id: id.uuidString.lowercased(), name: String(name.prefix(240)))
    }
    static func result(_ message: [String: Any], id: Int) throws -> [String: Any]? {
        guard let number = message["id"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(id) else { return nil }
        if message["error"] != nil { throw CodexInventoryError.rejected }
        guard let value = message["result"] as? [String: Any] else { throw CodexInventoryError.invalidResponse }
        return value
    }
    static func validateUpgrade(_ bytes: Data, key: String) throws {
        guard let header = String(data: bytes, encoding: .utf8) else { throw CodexInventoryError.invalidResponse }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first?.split(separator: " ").dropFirst().first == "101" else { throw CodexInventoryError.unavailable }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw CodexInventoryError.invalidResponse }
            let name = line[..<colon].lowercased()
            guard fields[name] == nil else { throw CodexInventoryError.invalidResponse }
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard fields["sec-websocket-accept"] == expected,
              fields["upgrade"]?.lowercased() == "websocket",
              fields["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true else { throw CodexInventoryError.invalidResponse }
    }
    struct Frame {
        let opcode: UInt8
        let final: Bool
        let payload: Data
    }
    /// Only the header is copied out; a large payload is sliced once, when the whole frame has arrived.
    static func serverFrame(_ bytes: Data, frameLimit: Int = CodexInventoryProtocol.frameLimit) throws -> (Frame, Int)? {
        let data = Array(bytes.prefix(14))
        guard data.count >= 2 else { return nil }
        let opcode = data[0] & 0x0f, final = data[0] & 0x80 != 0
        guard data[0] & 0x70 == 0, data[1] & 0x80 == 0, [0, 1, 8, 9, 10].contains(opcode) else { throw CodexInventoryError.invalidResponse }
        var length = UInt64(data[1] & 0x7f), offset = 2
        if length == 126 {
            guard data.count >= 4 else { return nil }
            length = UInt64(data[2]) << 8 | UInt64(data[3]); offset = 4
        } else if length == 127 {
            guard data.count >= 10 else { return nil }
            length = data[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; offset = 10
        }
        guard length <= frameLimit else { throw CodexInventoryError.tooLarge }
        guard opcode < 8 || (final && length <= 125) else { throw CodexInventoryError.invalidResponse }
        guard bytes.count >= offset + Int(length) else { return nil }
        let from = bytes.startIndex + offset
        return (Frame(opcode: opcode, final: final, payload: Data(bytes[from..<(from + Int(length))])), offset + Int(length))
    }
    static func clientFrame(_ payload: Data, opcode: UInt8 = 1, mask: [UInt8]? = nil) throws -> Data {
        guard payload.count <= messageLimit, [1, 10].contains(opcode) else { throw CodexInventoryError.tooLarge }
        let key = mask ?? (0..<4).map { _ in UInt8.random(in: 0...255) }
        guard key.count == 4 else { throw CodexInventoryError.invalidResponse }
        var data = Data([0x80 | opcode])
        if payload.count < 126 { data.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65535 {
            data.append(0xfe); data.append(UInt8(payload.count >> 8)); data.append(UInt8(payload.count & 255))
        } else {
            data.append(0xff)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((UInt64(payload.count) >> shift) & 255)) }
        }
        data.append(contentsOf: key)
        data.append(contentsOf: payload.enumerated().map { $0.element ^ key[$0.offset % 4] })
        return data
    }
    struct Pages {
        let maximum: Int
        private(set) var chats: [CodexSavedChat] = []
        private(set) var cursor: String?
        private(set) var done = false
        private var ids = Set<String>()
        private var cursors = Set<String>()
        private var pages = 0
        init(maximum: Int) throws {
            guard (1...1000).contains(maximum) else { throw CodexInventoryError.invalidResponse }
            self.maximum = maximum
        }
        mutating func append(_ result: [String: Any]) throws {
            guard !done, let rows = result["data"] as? [[String: Any]], rows.count <= pageLimit else { throw CodexInventoryError.invalidResponse }
            pages += 1
            for row in rows {
                guard chats.count < maximum, let chat = CodexInventoryProtocol.chat(row), ids.insert(chat.id).inserted else { continue }
                chats.append(chat)
            }
            if let raw = result["nextCursor"], !(raw is NSNull), !(raw is String) { throw CodexInventoryError.invalidResponse }
            let next = result["nextCursor"] as? String
            if chats.count >= maximum || next == nil { done = true; cursor = nil; return }
            guard let next, !next.isEmpty, next.utf8.count <= 4096, cursors.insert(next).inserted,
                  pages < 20 else { throw CodexInventoryError.invalidResponse }
            cursor = next
        }
    }
}

final class CodexMetadataSocket {
    private var descriptor: Int32 = -1
    private let deadline: Double
    private var buffered = Data()
    private var nextID = 1
    /// The chat list keeps the small default. Reading one chat's messages passes a larger limit,
    /// because a single page can carry tool output and images.
    private let frameLimit: Int, messageLimit: Int
    init(path: String, timeout: Double = 8, frameLimit: Int = CodexInventoryProtocol.frameLimit,
         messageLimit: Int = CodexInventoryProtocol.messageLimit) throws {
        self.frameLimit = frameLimit; self.messageLimit = messageLimit
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var info = stat()
        guard stat(resolved, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & S_IWOTH == 0 else { throw CodexInventoryError.unavailable }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let encoded = Array(resolved.utf8) + [0]
        guard encoded.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CodexInventoryError.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: encoded) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexInventoryError.unavailable }
        descriptor = fd
        do {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw CodexInventoryError.unavailable }
            var noSignal: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw CodexInventoryError.unavailable }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw CodexInventoryError.unavailable }
                try wait(POLLOUT)
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw CodexInventoryError.unavailable }
            }
            try handshake()
        } catch { close(fd); descriptor = -1; throw error }
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
    private func wait(_ requested: Int32) throws {
        let events = Int16(requested)
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CodexInventoryError.timeout }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(100, max(1, remaining * 1000))))
            if result < 0 { if errno == EINTR { continue }; throw CodexInventoryError.unavailable }
            if result == 0 { continue }
            if item.revents & events != 0 { return }
            if item.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw CodexInventoryError.unavailable }
        }
    }
    private func write(_ bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            try wait(POLLOUT)
            let sent = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if sent < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw CodexInventoryError.unavailable }
            guard sent > 0 else { throw CodexInventoryError.unavailable }; offset += sent
        }
    }
    private func receive() throws {
        try wait(POLLIN)
        var bytes = [UInt8](repeating: 0, count: 262_144)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count < 0 { if errno == EINTR || errno == EAGAIN { return }; throw CodexInventoryError.unavailable }
        guard count > 0 else { throw CodexInventoryError.unavailable }
        buffered.append(contentsOf: bytes.prefix(count))
        guard buffered.count <= messageLimit + 262_144 else { throw CodexInventoryError.tooLarge }
    }
    private func handshake() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        try write(Data("GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        let separator = Data("\r\n\r\n".utf8)
        while buffered.range(of: separator) == nil {
            guard buffered.count < 16_384 else { throw CodexInventoryError.tooLarge }
            try receive()
        }
        guard let range = buffered.range(of: separator), range.upperBound <= 16_384 else { throw CodexInventoryError.invalidResponse }
        try CodexInventoryProtocol.validateUpgrade(Data(buffered[..<range.lowerBound]), key: key)
        buffered.removeSubrange(..<range.upperBound)
    }
    private func send(_ object: [String: Any]) throws {
        try write(CodexInventoryProtocol.clientFrame(JSONSerialization.data(withJSONObject: object)))
    }
    private func message() throws -> [String: Any] {
        var fragments: Data?, frameCount = 0
        while frameCount < 128 {
            if let (frame, count) = try CodexInventoryProtocol.serverFrame(buffered, frameLimit: frameLimit) {
                buffered.removeFirst(count); frameCount += 1
                if frame.opcode == 8 { throw CodexInventoryError.unavailable }
                if frame.opcode == 9 { try write(CodexInventoryProtocol.clientFrame(frame.payload, opcode: 10)); continue }
                if frame.opcode == 10 { continue }
                if frame.opcode == 1 {
                    guard fragments == nil else { throw CodexInventoryError.invalidResponse }
                    fragments = frame.payload
                } else {
                    guard fragments != nil else { throw CodexInventoryError.invalidResponse }
                    fragments!.append(frame.payload)
                }
                guard let payload = fragments, payload.count <= messageLimit else { throw CodexInventoryError.tooLarge }
                if frame.final {
                    guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw CodexInventoryError.invalidResponse }
                    return object
                }
            } else { try receive() }
        }
        throw CodexInventoryError.tooLarge
    }
    private func response(_ request: [String: Any], id: Int) throws -> [String: Any] {
        try send(request)
        for _ in 0..<64 {
            if let result = try CodexInventoryProtocol.result(message(), id: id) { return result }
        }
        throw CodexInventoryError.invalidResponse
    }
    /// One request on a session that has been initialized. Callers pass read-only methods only.
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        try Task.checkCancellation()
        defer { nextID += 1 }
        return try response(["id": nextID, "method": method, "params": params], id: nextID)
    }
    func initializeSession() throws {
        _ = try response(CodexInventoryProtocol.initialize(id: nextID), id: nextID); nextID += 1
        try send(["method": "initialized"])
    }
    func list(maximum: Int) throws -> [CodexSavedChat] {
        var pages = try CodexInventoryProtocol.Pages(maximum: maximum)
        _ = try response(CodexInventoryProtocol.initialize(id: nextID), id: nextID); nextID += 1
        try send(["method": "initialized"])
        while !pages.done {
            try Task.checkCancellation()
            let result = try response(CodexInventoryProtocol.pageRequest(id: nextID, cursor: pages.cursor, limit: min(maximum, CodexInventoryProtocol.pageLimit)), id: nextID)
            nextID += 1; try pages.append(result)
        }
        return pages.chats
    }
}
