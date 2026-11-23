import Foundation
import Darwin

@main struct GeminiSendTests {
    static var count = 0
    static func expect(_ value: Bool, _ name: String) { guard value else { fatalError("FAIL: " + name) }; count += 1 }

    static let chat = "abcdef01-0000-4000-8000-000000000001"
    static let token = "tok-abc_123"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func cand(_ file: String, age: Double = 0, pid: Int32 = 100, port: Int = 5000, token: String = token, alive: Bool = true, isTool: Bool = true) -> GeminiSend.Candidate {
        .init(file: file, modified: now.addingTimeInterval(-age), pid: pid, port: port, token: token, pidAlive: alive, pidIsTool: isTool)
    }
    static func data(_ text: String) -> Data { Data(text.utf8) }
    static func exec(_ completion: GeminiSend.Completion, _ out: String = "") -> GeminiSend.Execution { .init(completion: completion, output: data(out)) }
    static let success = "{\"response\":{\"sendMessage\":{\"x\":1}}}"

    /// A one-shot HTTP server on loopback. Returns its port; the request text lands in `captured`.
    final class Box: @unchecked Sendable { var request = "" }
    static func serve(status: Int, body: String, box: Box) -> Int {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var one: Int32 = 1; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(listener, 1)
        var bound = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(listener, $0, &length) } }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        Thread.detachNewThread {
            let connection = accept(listener, nil, nil)
            var buffer = [UInt8](repeating: 0, count: 8192), text = ""
            while !(text.contains("\r\n\r\n") && text.hasSuffix("}")) {
                let n = read(connection, &buffer, buffer.count); if n <= 0 { break }
                text += String(decoding: buffer.prefix(n), as: UTF8.self)
            }
            box.request = text
            let reply = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            _ = reply.withCString { write(connection, $0, strlen($0)) }
            close(connection); close(listener)
        }
        return port
    }

    static func main() async throws {
        // The chat: an exact lowercase UUID from the offered list.
        expect(GeminiSend.checkChat(chat, offered: [chat]) == .ok(chat), "an offered chat is accepted")
        expect(GeminiSend.checkChat(chat.uppercased(), offered: [chat]) == .invalid, "uppercase is not the exact id")
        expect(GeminiSend.checkChat(chat, offered: []) == .notOffered, "a chat that is not offered is refused")
        expect(GeminiSend.checkChat("00000000-0000-4000-8000-000000000002", offered: [chat]) == .notOffered, "another UUID is refused")
        expect(GeminiSend.checkChat("gemini-123", offered: ["gemini-123"]) == .invalid, "a non-UUID is invalid even if listed")
        expect(GeminiSend.checkChat(nil, offered: [chat]) == .invalid && GeminiSend.checkChat("", offered: [chat]) == .invalid, "no chat is invalid")

        // The prompt.
        expect(GeminiSend.promptProblem("hello") == nil && GeminiSend.promptProblem("line one\nline two \u{1F600}") == nil, "ordinary prompts pass")
        expect(GeminiSend.promptProblem(nil) == "The prompt is empty." && GeminiSend.promptProblem("  \n\t ") == "The prompt is empty.", "blank prompts are refused")
        expect(GeminiSend.promptProblem("a\u{0}b") != nil, "a NUL byte is refused")
        expect(GeminiSend.promptProblem(String(repeating: "a", count: 64_000)) == nil, "64,000 bytes is the limit")
        expect(GeminiSend.promptProblem(String(repeating: "a", count: 64_001)) == "The prompt is too long.", "one byte over is refused")
        expect(GeminiSend.promptProblem(String(repeating: "\u{1F600}", count: 16_001)) == "The prompt is too long.", "the limit counts bytes, not characters")
        expect(GeminiSend.promptProblem("--help") == GeminiSend.dashRefusal && GeminiSend.promptProblem("-x") != nil && GeminiSend.promptProblem("a -b") == nil, "only a leading dash is refused")

        // Arguments and environment.
        expect(GeminiSend.arguments(chatID: chat, text: "hi there; rm -rf $HOME `x`") == ["agentapi", "send-message", chat, "hi there; rm -rf $HOME `x`"], "the prompt is one untouched argument")
        expect(GeminiSend.arguments(chatID: chat.uppercased(), text: "hi") == nil && GeminiSend.arguments(chatID: chat, text: " ") == nil && GeminiSend.arguments(chatID: "x", text: "hi") == nil, "bad input builds no arguments")
        let env = GeminiSend.environment(home: "/Users/someone", port: 5123, token: token)
        expect(env["ANTIGRAVITY_LS_ADDRESS"] == "127.0.0.1:5123" && env["ANTIGRAVITY_CSRF_TOKEN"] == token && env["HOME"] == "/Users/someone", "the hub address and token go in the environment")
        expect(Set(env.keys) == ["HOME", "USER", "LOGNAME", "PATH", "LANG", "TMPDIR", "ANTIGRAVITY_LS_ADDRESS", "ANTIGRAVITY_CSRF_TOKEN"] && env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin", "nothing else is inherited")
        expect(!GeminiSend.arguments(chatID: chat, text: "x")!.joined().contains(token), "the token is never an argument")

        // Choosing the hub.
        expect(GeminiSend.chooseHub([]) == nil, "no files, no hub")
        expect(GeminiSend.chooseHub([cand("hub_1.json", age: 500, pid: 1, port: 1111), cand("hub_2.json", age: 5, pid: 2, port: 2222), cand("hub_3.json", age: 50, pid: 3, port: 3333)])?.port == 2222, "the newest live hub wins")
        expect(GeminiSend.chooseHub([cand("hub_new.json", age: 1, alive: false), cand("hub_old.json", age: 900, port: 4444)])?.port == 4444, "a newer file with a dead pid is skipped")
        expect(GeminiSend.chooseHub([cand("hub_new.json", age: 1, isTool: false), cand("hub_old.json", age: 900, port: 4444)])?.port == 4444, "a live pid that is not Gemini's tool is skipped")
        expect(GeminiSend.chooseHub([cand("a.json", alive: false), cand("b.json", isTool: false)]) == nil, "only stale files means no hub")
        expect(GeminiSend.chooseHub([cand("a.json", port: 0)]) == nil && GeminiSend.chooseHub([cand("a.json", port: 70_000)]) == nil, "an impossible port is no hub")
        expect(GeminiSend.chooseHub([cand("a.json", token: "")]) == nil && GeminiSend.chooseHub([cand("a.json", token: "has space")]) == nil && GeminiSend.chooseHub([cand("a.json", token: "line\nbreak")]) == nil && GeminiSend.chooseHub([cand("a.json", token: String(repeating: "t", count: 257))]) == nil, "an odd token is no hub")
        expect(GeminiSend.chooseHub([cand("hub_a.json", port: 1), cand("hub_b.json", port: 2)])?.file == "hub_b.json", "equal times pick a stable file")
        let parsed = GeminiSend.parseHubFile(data("{\"pid\":42,\"httpPort\":5555,\"httpsPort\":5556,\"lsVersion\":\"1\",\"csrfToken\":\"abc\"}"))
        expect(parsed?.pid == 42 && parsed?.port == 5555 && parsed?.token == "abc", "a hub file parses")
        expect(GeminiSend.parseHubFile(data("{\"pid\":42,\"httpPort\":5555}")) == nil && GeminiSend.parseHubFile(data("nope")) == nil && GeminiSend.parseHubFile(data("{\"pid\":\"x\",\"httpPort\":1,\"csrfToken\":\"a\"}")) == nil && GeminiSend.parseHubFile(Data()) == nil, "an incomplete or damaged hub file is nothing")

        // The tool's output and the receipt.
        expect(GeminiSend.parseOutput(data(success)) == .sent, "the tool's success reply is a send")
        expect(GeminiSend.parseOutput(data("{\"error\":\"conversation not found\"}")) == .refused, "a top-level error is a refusal")
        expect(GeminiSend.parseOutput(data("{\"error\":\"x\",\"response\":{\"sendMessage\":{}}}")) == .refused, "an error wins over a response")
        for odd in ["", "garbage", "[]", "{}", "{\"response\":{}}", "{\"response\":{\"other\":{}}}", "{\"response\":\"sendMessage\"}", "null", "{\"ok\":true}"] { expect(GeminiSend.parseOutput(data(odd)) == .unreadable, "unreadable output: " + odd) }
        let ok = GeminiSend.receipt(exec(.exited(0), success))
        expect(ok.status == "confirmed" && ok.message == "Prompt sent; Gemini is responding.", "a clean success is confirmed")
        let refused = GeminiSend.receipt(exec(.exited(1), "{\"error\":\"nope\"}"))
        expect(refused.status == "failed" && refused.message.contains("Nothing was sent"), "a refusal is failed")
        expect(GeminiSend.receipt(exec(.exited(0), "{\"error\":\"nope\"}")).status == "uncertain", "an error printed with a clean exit may follow delivery, so it is uncertain")
        for unsure in [exec(.exited(0), ""), exec(.exited(0), "garbage"), exec(.exited(2), ""), exec(.exited(1), success), exec(.timedOut, success), exec(.timedOut), exec(.interrupted)] {
            expect(GeminiSend.receipt(unsure).status == "uncertain" && GeminiSend.receipt(unsure).message.contains("not retried"), "when delivery cannot be told the receipt is uncertain")
        }
        expect(GeminiSend.receipt(exec(.notLaunched)).status == "failed", "a tool that never started is failed")
        expect(!ok.message.contains(token) && !GeminiSend.receipt(exec(.timedOut)).message.contains(chat), "receipts carry no token or chat id")

        // Pre-flight.
        expect(GeminiSend.preflight(status: 200, body: data("{\"metadata\":{\"a\":1}}")) == .ready, "200 with metadata is ready")
        expect(GeminiSend.preflight(status: 200, body: data("{}")) == .unknownChat && GeminiSend.preflight(status: 200, body: data("garbage")) == .unknownChat, "200 without metadata is not a known chat")
        expect(GeminiSend.preflight(status: 404, body: Data()) == .unknownChat && GeminiSend.preflight(status: 403, body: Data()) == .unknownChat, "a 4xx is not a known chat")
        expect(GeminiSend.preflight(status: 502, body: Data()) == .unreachable && GeminiSend.preflight(status: nil, body: Data()) == .unreachable, "no answer is unreachable")
        let request = GeminiSend.preflightRequest(port: 5000, token: token, chatID: chat)!
        expect(request.url?.absoluteString == "http://127.0.0.1:5000/exa.language_server_pb.LanguageServerService/GetConversationMetadata" && request.httpMethod == "POST", "pre-flight goes to the loopback hub")
        expect(request.value(forHTTPHeaderField: "x-antigravity-csrf-token") == token && request.value(forHTTPHeaderField: "Content-Type") == "application/json" && request.timeoutInterval == GeminiSend.preflightTimeout, "pre-flight headers and time limit")
        expect(String(decoding: request.httpBody!, as: UTF8.self) == "{\"conversationId\":\"\(chat)\"}", "pre-flight body")
        expect(GeminiSend.preflightRequest(port: 0, token: token, chatID: chat) == nil && GeminiSend.preflightRequest(port: 5000, token: "a b", chatID: chat) == nil && GeminiSend.preflightRequest(port: 5000, token: token, chatID: "\"}") == nil, "a bad port, token or chat builds no request")

        // Pre-flight against a real local listener.
        let box = Box()
        let live = serve(status: 200, body: "{\"metadata\":{}}", box: box)
        expect(await GeminiSend.checkHub(.init(file: "h", pid: 1, port: live, token: token), chatID: chat) == .ready, "a hub that knows the chat is ready")
        expect(box.request.hasPrefix("POST /exa.language_server_pb.LanguageServerService/GetConversationMetadata HTTP/1.1") && box.request.lowercased().contains("x-antigravity-csrf-token: " + token) && box.request.contains("{\"conversationId\":\"\(chat)\"}"), "the request reaches the hub as built")
        let unknown = serve(status: 404, body: "{\"code\":\"not_found\"}", box: Box())
        expect(await GeminiSend.checkHub(.init(file: "h", pid: 1, port: unknown, token: token), chatID: chat) == .unknownChat, "a hub that does not know the chat says so")
        let closedSocket = socket(AF_INET, SOCK_STREAM, 0); var probe = sockaddr_in(); probe.sin_family = sa_family_t(AF_INET); probe.sin_addr.s_addr = inet_addr("127.0.0.1"); probe.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        withUnsafePointer(to: &probe) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(closedSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var named = sockaddr_in(), namedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &named) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(closedSocket, $0, &namedLength) } }
        let deadPort = Int(UInt16(bigEndian: named.sin_port)); close(closedSocket)
        expect(await GeminiSend.checkHub(.init(file: "h", pid: 1, port: deadPort, token: token), chatID: chat) == .unreachable, "nothing listening is unreachable")

        // Finding the hub on disk, with real processes.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-send-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func launch() throws -> Process { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["30"]; try p.run(); return p }
        let older = try launch(), newer = try launch()
        defer { older.terminate(); newer.terminate() }
        func hubFile(_ name: String, pid: Int32, port: Int, age: Double, mode: Int = 0o600) throws {
            let path = folder.appendingPathComponent(name).path
            try data("{\"pid\":\(pid),\"httpPort\":\(port),\"httpsPort\":1,\"lsVersion\":\"v\",\"csrfToken\":\"\(token)\"}").write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: mode, .modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
        }
        let sleepTool = URL(fileURLWithPath: "/bin/sleep")
        try hubFile("hub_old.json", pid: older.processIdentifier, port: 6001, age: 300)
        try hubFile("hub_dead.json", pid: 2_000_000, port: 6002, age: 1)
        try hubFile("hub_self.json", pid: getpid(), port: 6003, age: 2)
        try hubFile("hub_open.json", pid: newer.processIdentifier, port: 6004, age: 3, mode: 0o644)
        try hubFile("notes.json", pid: newer.processIdentifier, port: 6005, age: 0)
        expect(GeminiSend.discoverHub(folder: folder.path, tool: sleepTool)?.port == 6001, "stale, dead, foreign, world-readable and misnamed files are all passed over")
        try hubFile("hub_new.json", pid: newer.processIdentifier, port: 6006, age: 10)
        expect(GeminiSend.discoverHub(folder: folder.path, tool: sleepTool)?.port == 6006 && GeminiSend.discoverHub(folder: folder.path, tool: sleepTool)?.token == token, "the newest live tool wins")
        expect(GeminiSend.discoverHub(folder: folder.path, tool: URL(fileURLWithPath: "/bin/cat")) == nil, "no process is the tool when the tool is somewhere else")
        expect(GeminiSend.discoverHub(folder: folder.path + "/missing", tool: sleepTool) == nil, "no daemon folder, no hub")

        // Running the tool: cwd, environment, arguments, timeout. Stand-ins only; the real tool is never run.
        let echo = GeminiSend.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["a b", "$HOME;x"], environment: [:], timeout: 5)
        expect(echo.completion == .exited(0) && String(decoding: echo.output, as: UTF8.self) == "a b $HOME;x\n", "arguments pass through with no shell")
        let pwd = GeminiSend.run(executable: URL(fileURLWithPath: "/bin/pwd"), arguments: [], environment: [:], directory: folder, timeout: 5)
        expect(String(decoding: pwd.output, as: UTF8.self).contains(folder.lastPathComponent), "the tool runs in the folder it is given")
        let printed = GeminiSend.run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], environment: ["ONLY": "this"], timeout: 5)
        expect(String(decoding: printed.output, as: UTF8.self).contains("ONLY=this") && !String(decoding: printed.output, as: UTF8.self).contains("HOME="), "the tool sees only the given environment")
        let started = Date()
        let slow = GeminiSend.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:], timeout: 0.4)
        expect(slow.completion == .timedOut && Date().timeIntervalSince(started) < 3, "a tool that hangs is stopped at the time limit")
        expect(GeminiSend.receipt(slow).status == "uncertain", "and that is reported as uncertain")
        expect(GeminiSend.run(executable: URL(fileURLWithPath: "/nonexistent/agy"), arguments: [], environment: [:], timeout: 1).completion == .notLaunched, "a missing tool does not launch")
        let loud = GeminiSend.run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], environment: [:], timeout: 0.3)
        expect(loud.output.count <= 1_048_576 && loud.completion == .timedOut, "output is capped")
        expect(GeminiSend.tool(in: folder) == nil, "a folder that is not the Gemini app has no tool")

        // The source never logs or stores what it is given.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOfFile: root.appendingPathComponent("Sources/GeminiSend.swift").path, encoding: .utf8)
        expect(!source.contains("print(") && !source.contains("NSLog") && !source.contains("os_log") && !source.contains("/bin/sh") && !source.contains("/bin/zsh"), "no logging and no shell in the sender")
        let bridge = try String(contentsOfFile: root.appendingPathComponent("Sources/RemoteBridge.swift").path, encoding: .utf8)
        let run = bridge.components(separatedBy: "private func executeGemini(")[1].components(separatedBy: "private func launchApp(")[0]
        expect(!run.contains("print(") && !run.contains("NSLog") && run.contains("GeminiSend.checkChat") && run.contains("GeminiSend.checkHub") && run.contains("configuration.activates=false"), "the bridge checks the chat and hub first and opens Gemini without activating it")
        expect(run.range(of: "checkChat")!.lowerBound < run.range(of: "GeminiSend.send(")!.lowerBound && run.range(of: "checkHub")!.lowerBound < run.range(of: "GeminiSend.send(")!.lowerBound, "the chat and hub are checked before anything is sent")
        expect(bridge.contains("[GeminiChatList.capability,\"chatActivity\",\"openChat\",GeminiThread.capability]+(geminiTool() != nil ? [\"sendPrompt\"]:[])"), "sendPrompt is advertised only with the tool present")

        print("Gemini send: \(count) checks passed")
    }
}
