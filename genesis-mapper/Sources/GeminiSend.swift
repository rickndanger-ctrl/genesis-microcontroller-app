import Foundation
import Darwin
import Security

/// Sending a prompt into an existing Gemini conversation, through the command-line tool inside the Gemini app
/// (`agy agentapi send-message`). The tool talks to the hub Gemini runs on this Mac; the hub's port and
/// token are in a file Gemini writes for its own use. The rules are pure so they are tested without Gemini.
/// The prompt and the token are never logged or recorded here: the prompt goes to the tool as one argument
/// (never through a shell), the token goes in the tool's environment.
enum GeminiSend {
    static let maximumPrompt = 64_000
    static let toolTimeout: TimeInterval = 4
    static let preflightTimeout: TimeInterval = 1.5
    static let signingTeam = "EQHXZ8M8AV"
    static let relativeTool = "Contents/Helpers/agy"
    static let hubWait: TimeInterval = 4
    static let sent = "Prompt sent; Gemini is responding."
    static let notOffered = "This Gemini chat is not in Gemini\u{2019}s chat list on this Mac. Refresh the chats; nothing was sent."
    static let selected = "Selected. Messages go to this Gemini chat."
    static let stopRefusal = "Gemini can\u{2019}t be stopped from the controller. Stop it in Gemini on the Mac."
    static let closed = "Gemini is still opening on this Mac. Nothing was sent; send again in a moment."
    static let toolMissing = "Gemini\u{2019}s send command was not found in the installed app. Nothing was sent."
    static let dashRefusal = "Gemini can\u{2019}t take a message that starts with a dash from the controller yet. Add a word before it. Nothing was sent."

    // MARK: The chat and the prompt

    enum ChatCheck: Equatable { case ok(String), invalid, notOffered }
    /// The exact lowercase UUID that the chat list offered; anything else is refused.
    static func checkChat(_ id: String?, offered: [String]) -> ChatCheck {
        guard let id, let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { return .invalid }
        return offered.contains(id) ? .ok(id) : .notOffered
    }

    /// Nil when the prompt may be sent, otherwise what to tell the phone.
    static func promptProblem(_ text: String?) -> String? {
        guard let text, !text.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }), !text.utf8.contains(0) else { return "The prompt is empty." }
        if text.utf8.count > maximumPrompt { return "The prompt is too long." }
        // The tool reads options from its arguments; whether "--" ends them there is not known, so no prompt is allowed to look like one.
        if text.hasPrefix("-") { return dashRefusal }
        return nil
    }

    static func arguments(chatID: String, text: String) -> [String]? {
        guard UUID(uuidString: chatID)?.uuidString.lowercased() == chatID, promptProblem(text) == nil else { return nil }
        return ["agentapi", "send-message", chatID, text]
    }

    /// Nothing is inherited: no proxy, no library variables, no credentials, no extra PATH entries.
    static func environment(home: String, port: Int, token: String) -> [String: String] {
        ["HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
         "TMPDIR": NSTemporaryDirectory(), "ANTIGRAVITY_LS_ADDRESS": "127.0.0.1:\(port)", "ANTIGRAVITY_CSRF_TOKEN": token]
    }

    // MARK: The hub

    struct Hub: Equatable { var file: String, pid: Int32, port: Int, token: String }
    struct Candidate: Equatable {
        var file: String, modified: Date, pid: Int32, port: Int, token: String
        var pidAlive: Bool, pidIsTool: Bool
    }

    /// The newest hub file whose process is alive and is Gemini's own tool. Old files from earlier launches are ignored.
    static func chooseHub(_ candidates: [Candidate]) -> Hub? {
        candidates.filter { $0.pidAlive && $0.pidIsTool && $0.pid > 0 && validPort($0.port) && validToken($0.token) }
            .sorted { $0.modified == $1.modified ? $0.file > $1.file : $0.modified > $1.modified }
            .first.map { Hub(file: $0.file, pid: $0.pid, port: $0.port, token: $0.token) }
    }
    static func validPort(_ port: Int) -> Bool { (1...65_535).contains(port) }
    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 256 && token.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value < 127 }
    }
    /// pid, httpPort and csrfToken from a hub file's JSON; nil when any is missing or of the wrong type.
    static func parseHubFile(_ data: Data) -> (pid: Int32, port: Int, token: String)? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, let port = (object["httpPort"] as? NSNumber)?.intValue,
              let token = object["csrfToken"] as? String else { return nil }
        return (pid, port, token)
    }

    /// Reads Gemini's daemon folder. Only regular files owned by this user and closed to others are believed.
    static func discoverHub(folder: String = NSHomeDirectory() + "/.gemini/antigravity/daemon", tool: URL) -> Hub? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder) else { return nil }
        let wanted = tool.resolvingSymlinksInPath().standardizedFileURL.path
        let candidates = names.filter { $0.hasPrefix("hub_") && $0.hasSuffix(".json") }.compactMap { name -> Candidate? in
            let path = folder + "/" + name
            guard let attributes = try? manager.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
                  let modified = attributes[.modificationDate] as? Date, (attributes[.size] as? NSNumber)?.intValue ?? 0 < 4096,
                  let data = manager.contents(atPath: path), let hub = parseHubFile(data) else { return nil }
            let alive = hub.pid > 0 && (kill(hub.pid, 0) == 0 || errno == EPERM)
            return Candidate(file: name, modified: modified, pid: hub.pid, port: hub.port, token: hub.token, pidAlive: alive, pidIsTool: alive && processPath(hub.pid) == wanted)
        }
        return chooseHub(candidates)
    }
    private static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: The tool

    /// Gemini's tool inside the installed app: the right bundle, a regular executable, not writable by others.
    static func tool(in application: URL) -> URL? {
        guard Bundle(url: application)?.bundleIdentifier == GeminiChatList.bundle else { return nil }
        let root = application.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(relativeTool).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"), FileManager.default.isExecutableFile(atPath: candidate.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0 else { return nil }
        return candidate
    }
    static func isSigned(_ executable: URL) -> Bool {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(signingTeam)\"" as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    enum ToolResult: Equatable { case sent, refused, unreadable }
    /// `{"response":{"sendMessage":{...}}}` is a send; a top-level "error" is a refusal; nothing else is believed.
    static func parseOutput(_ output: Data) -> ToolResult {
        guard !output.isEmpty, let object = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else { return .unreadable }
        if object["error"] != nil { return .refused }
        if let response = object["response"] as? [String: Any], response["sendMessage"] != nil { return .sent }
        return .unreadable
    }

    enum Completion: Equatable { case notLaunched, exited(Int32), interrupted, timedOut }
    struct Execution { var completion: Completion; var output: Data }
    struct Receipt: Equatable { var status: String, message: String }

    /// Only a clean exit with the tool's own success reply is "confirmed". A refusal printed by the tool is a
    /// failure. Anything where the message may or may not have gone is "uncertain", never a plain failure,
    /// so the phone does not offer to send it again as if nothing happened.
    static func receipt(_ execution: Execution) -> Receipt {
        let unsure = Receipt(status: "uncertain", message: "Gemini\u{2019}s send result is unknown. The command was not retried; check the chat before sending this prompt again.")
        switch execution.completion {
        case .notLaunched: return Receipt(status: "failed", message: "Gemini\u{2019}s send command could not start. Nothing was sent.")
        case .interrupted, .timedOut: return unsure
        case .exited(let code):
            switch parseOutput(execution.output) {
            case .sent: return code == 0 ? Receipt(status: "confirmed", message: sent) : unsure
            // The tool exits 0 when it has handed a message over, so an error printed with exit 0 may have come after delivery.
            case .refused: return code == 0 ? unsure : Receipt(status: "failed", message: "Gemini did not accept the message. Nothing was sent.")
            case .unreadable: return unsure
            }
        }
    }

    enum Preflight: Equatable { case ready, unknownChat, unreachable }
    /// Whether the hub answered and knows the conversation: 200 with a "metadata" object.
    static func preflight(status: Int?, body: Data) -> Preflight {
        guard let status else { return .unreachable }
        guard status == 200, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], object["metadata"] is [String: Any] else {
            return status == 200 || (400..<500).contains(status) ? .unknownChat : .unreachable
        }
        return .ready
    }
    static func preflightRequest(port: Int, token: String, chatID: String) -> URLRequest? {
        guard validPort(port), validToken(token), UUID(uuidString: chatID) != nil,
              let url = URL(string: "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetConversationMetadata") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: preflightTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-antigravity-csrf-token")
        request.httpBody = Data("{\"conversationId\":\"\(chatID)\"}".utf8)
        return request
    }

    // MARK: Running

    /// Asks the hub whether it is alive and knows the conversation. Sends nothing.
    static func checkHub(_ hub: Hub, chatID: String) async -> Preflight {
        guard let request = preflightRequest(port: hub.port, token: hub.token, chatID: chatID) else { return .unreachable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = preflightTimeout; configuration.timeoutIntervalForResource = preflightTimeout + 0.5
        configuration.connectionProxyDictionary = [:]; configuration.urlCache = nil
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return .unreachable }
        return preflight(status: http.statusCode, body: data.prefix(65_536))
    }

    /// Runs the tool once, off the main thread, from a folder that is not the user's project. Never retried.
    static func send(tool: URL, hub: Hub, chatID: String, text: String, home: String = NSHomeDirectory()) async -> Receipt {
        guard let arguments = arguments(chatID: chatID, text: text) else { return Receipt(status: "failed", message: "The prompt could not be sent. Nothing was sent.") }
        let task = Task.detached(priority: .userInitiated) { () -> Receipt in
            guard isSigned(tool) else { return Receipt(status: "failed", message: "The installed Gemini command could not be verified as signed by Google. Nothing was sent.") }
            return receipt(run(executable: tool, arguments: arguments, environment: environment(home: home, port: hub.port, token: hub.token), timeout: toolTimeout))
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    static func run(executable: URL, arguments: [String], environment: [String: String], directory: URL = FileManager.default.temporaryDirectory, timeout: TimeInterval) -> Execution {
        func unstarted() -> Execution { Execution(completion: .notLaunched, output: Data()) }
        guard !Task.isCancelled, timeout > 0, timeout.isFinite else { return unstarted() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let pipe = Pipe(), descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) >= 0 else { return unstarted() }
        process.standardOutput = pipe
        var output = Data()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        func drain() {
            var bytes = [UInt8](repeating: 0, count: 1024)
            // The tool's reply repeats the message, so the room kept must cover the longest prompt after JSON escaping.
            for _ in 0..<2048 {
                let count = read(descriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                output.append(contentsOf: bytes.prefix(min(count, max(0, 1_048_576 - output.count))))
            }
        }
        do { try process.run() } catch { return unstarted() }
        try? pipe.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled { drain(); Thread.sleep(forTimeInterval: 0.02) }
        drain()
        if !process.isRunning { return Execution(completion: process.terminationReason == .exit ? .exited(process.terminationStatus) : .interrupted, output: output) }
        let completion: Completion = Task.isCancelled ? .interrupted : .timedOut
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning, ProcessInfo.processInfo.systemUptime < grace { drain(); Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let reap = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning, ProcessInfo.processInfo.systemUptime < reap { drain(); Thread.sleep(forTimeInterval: 0.01) }
        drain()
        return Execution(completion: completion, output: output)
    }
}
