import Foundation
import CryptoKit

@main struct CodexReadOnlyTests {
    static var count = 0
    static func expect(_ value: Bool, _ name: String) {
        guard value else { fatalError("FAIL: " + name) }; count += 1
    }
    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); fatalError("FAIL: " + name) } catch { count += 1 }
    }
    static func server(_ text: String, final: Bool = true, opcode: UInt8 = 1) -> Data {
        let payload = Data(text.utf8)
        var result = Data([(final ? 0x80 : 0) | opcode])
        if payload.count < 126 { result.append(UInt8(payload.count)) }
        else { result.append(126); result.append(UInt8(payload.count >> 8)); result.append(UInt8(payload.count & 255)) }
        result.append(payload); return result
    }
    static func main() async throws {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let header = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        try CodexInventoryProtocol.validateUpgrade(Data(header.utf8), key: key); count += 1
        rejects("mismatched websocket key") { try CodexInventoryProtocol.validateUpgrade(Data(header.utf8), key: "wrong") }
        rejects("non-upgrade rejected") { try CodexInventoryProtocol.validateUpgrade(Data("HTTP/1.1 200 OK\r\n".utf8), key: key) }
        rejects("duplicate header rejected") { try CodexInventoryProtocol.validateUpgrade(Data((header + "\r\nUpgrade: websocket").utf8), key: key) }
        expect(try CodexInventoryProtocol.serverFrame(Data([0x81])) == nil, "partial header waits")
        let frame = server("hello")
        let decoded = try CodexInventoryProtocol.serverFrame(frame)!
        expect(decoded.0.opcode == 1 && decoded.0.final && decoded.0.payload == Data("hello".utf8) && decoded.1 == frame.count, "complete text frame")
        expect(try CodexInventoryProtocol.serverFrame(frame.dropLast()) == nil, "partial body waits")
        let extended = server(String(repeating: "x", count: 300))
        expect(try CodexInventoryProtocol.serverFrame(extended)?.0.payload.count == 300, "extended payload length")
        let continuation = try CodexInventoryProtocol.serverFrame(server("piece", final: false, opcode: 0))!
        expect(!continuation.0.final && continuation.0.opcode == 0, "fragment boundary retained")
        expect(try CodexInventoryProtocol.serverFrame(server("ping", opcode: 9))?.0.opcode == 9, "ping control retained")
        rejects("masked server frame") { _ = try CodexInventoryProtocol.serverFrame(Data([0x81, 0x80, 1, 2, 3, 4])) }
        rejects("unknown extension bits") { _ = try CodexInventoryProtocol.serverFrame(Data([0xc1, 0])) }
        rejects("binary messages rejected") { _ = try CodexInventoryProtocol.serverFrame(Data([0x82, 0])) }
        rejects("oversized frame rejected before allocation") { _ = try CodexInventoryProtocol.serverFrame(Data([0x81, 127, 0, 0, 0, 0, 0, 0x40, 0, 0])) }
        rejects("fragmented ping rejected") { _ = try CodexInventoryProtocol.serverFrame(Data([9, 0])) }
        let mask: [UInt8] = [1, 2, 3, 4], payload = Data("request".utf8)
        let masked = Array(try CodexInventoryProtocol.clientFrame(payload, mask: mask))
        expect(masked[0] == 0x81 && masked[1] == 0x87 && Array(masked[2..<6]) == mask, "client masking header")
        expect(Data(masked.dropFirst(6).enumerated().map { $0.element ^ mask[$0.offset % 4] }) == payload, "client masking payload")
        rejects("oversized client request") { _ = try CodexInventoryProtocol.clientFrame(Data(repeating: 0, count: CodexInventoryProtocol.messageLimit + 1)) }

        let request = CodexInventoryProtocol.pageRequest(id: 4, cursor: "next-page", limit: 500)
        let params = request["params"] as! [String: Any]
        expect(request["method"] as? String == "thread/list", "only read metadata method")
        expect(params["currentAccountOnly"] as? Bool == true && params["useStateDbOnly"] as? Bool == true && params["archived"] as? Bool == false, "account/state/archive scope every request")
        expect(params["limit"] as? Int == 100 && params["cursor"] as? String == "next-page", "bounded page preserves cursor")
        expect(try CodexInventoryProtocol.result(["id": 2, "result": ["data": []]], id: 1) == nil, "unrelated response ignored")
        expect(try CodexInventoryProtocol.result(["id": true, "result": [:]], id: 1) == nil, "boolean id cannot match request")
        expect(try CodexInventoryProtocol.result(["id": 1.5, "result": [:]], id: 1) == nil, "fractional id cannot match request")
        rejects("RPC errors are not metadata") { _ = try CodexInventoryProtocol.result(["id": 1, "error": ["message": "private upstream detail"]], id: 1) }
        rejects("unexpected response structure") { _ = try CodexInventoryProtocol.result(["id": 1, "result": []], id: 1) }

        let firstID = "00000000-0000-4000-8000-000000000001", secondID = "00000000-0000-4000-8000-000000000002"
        let row: [String: Any] = ["id": firstID, "name": "Shared title", "preview": "must not escape", "turns": [["text": "must not escape"]], "canAcceptDirectInput": true]
        expect(CodexInventoryProtocol.chat(row) == CodexSavedChat(id: firstID, name: "Shared title"), "metadata projects only stable id and name")
        expect(CodexInventoryProtocol.chat(["id": firstID, "title": "wrong field"]) == nil, "name is authoritative")
        expect(CodexInventoryProtocol.chat(["id": "not-a-thread", "name": "bad"]) == nil, "invalid identity rejected")
        expect(CodexInventoryProtocol.chat(["id": firstID, "name": " "]) == nil, "empty labels omitted")
        expect(CodexInventoryProtocol.chat(["id": firstID, "name": "ephemeral", "ephemeral": true]) == nil, "ephemeral chat omitted")
        expect(CodexInventoryProtocol.chat(["id": firstID, "name": "internal", "canAcceptDirectInput": false]) == nil, "noninteractive chat omitted")
        expect(CodexInventoryProtocol.chat(["id": firstID, "name": "agent", "source": ["subAgent": [:]]]) == nil, "known subagent omitted")
        expect(CodexInventoryProtocol.chat(["id": firstID, "name": "fork", "forkedFromId": secondID]) != nil, "ordinary fork remains assignable")

        var pages = try CodexInventoryProtocol.Pages(maximum: 3)
        try pages.append(["data": [row], "nextCursor": "next"])
        expect(!pages.done && pages.cursor == "next" && pages.chats.count == 1, "first page continues")
        try pages.append(["data": [row, ["id": secondID, "name": "Shared title"]], "nextCursor": NSNull()])
        expect(pages.done && pages.chats.count == 2, "duplicate ids deduplicated across pages while same-title chats remain distinct")
        var bounded = try CodexInventoryProtocol.Pages(maximum: 1)
        try bounded.append(["data": [row], "nextCursor": "unused"])
        expect(bounded.done && bounded.cursor == nil, "configured maximum stops pagination")
        var repeated = try CodexInventoryProtocol.Pages(maximum: 500)
        try repeated.append(["data": [row], "nextCursor": "loop"])
        rejects("repeated cursor rejected") { try repeated.append(["data": [], "nextCursor": "loop"]) }
        rejects("invalid page shape") { var p = try CodexInventoryProtocol.Pages(maximum: 5); try p.append(["data": "private message"]) }
        rejects("invalid cursor rejected") { var p = try CodexInventoryProtocol.Pages(maximum: 5); try p.append(["data": [row], "nextCursor": 3]) }
        rejects("excessive per-page items") { var p = try CodexInventoryProtocol.Pages(maximum: 500); try p.append(["data": Array(repeating: row, count: 101)]) }
        rejects("unbounded maximum rejected") { _ = try CodexInventoryProtocol.Pages(maximum: 1001) }
        print("PASS \(count) Codex read-only inventory protocol checks")
        if CommandLine.arguments.contains("--live-read-only") {
            let started = ProcessInfo.processInfo.systemUptime
            let chats = try await CodexReadOnly.chats(maximum: 50)
            print("Live existing-daemon metadata only: \(chats.count) named chats in \(Int((ProcessInfo.processInfo.systemUptime-started)*1000))ms; no titles, previews or messages logged.")
            guard !chats.isEmpty else { throw CodexInventoryError.invalidResponse }
        }
        if CommandLine.arguments.contains("--live-pagination") {
            let started = ProcessInfo.processInfo.systemUptime
            let chats = try await CodexReadOnly.chats(maximum: 150)
            guard chats.count == 150, Set(chats.map(\.id)).count == 150 else { throw CodexInventoryError.invalidResponse }
            print("Live paginated existing-daemon metadata: 150 unique named chats in \(Int((ProcessInfo.processInfo.systemUptime-started)*1000))ms; no titles, previews or messages logged.")
        }
    }
}
