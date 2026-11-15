import Foundation
import Network

/// Local fixture: real HTTP sockets and URLSession, no live desktop or provider calls.
final class HTTPFixture: @unchecked Sendable {
    let hostID: String
    let name: String
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "genesis.integration.fixture")
    private var listener: NWListener?
    private var requests: [(String, [String: String], Data)] = []
    private var receiptState = "pending"
    private var receiptMissing = false
    private var receiptWrongID = false
    private var simulateUncertain = false
    private var rejectSend = false
    private var dropSendResponse = false
    private var sendAcceptedState = "confirmed"
    private var statusDelay: TimeInterval = 0
    private var statusUnavailable = false
    private var heldPaths = Set<String>()
    private var heldResponses: [String: [() -> Void]] = [:]
    private var savedProfiles: [String: [String: Any]] = [:]
    private var profileProviderOverride: String?
    private var providers: [ProviderInfo] = [.init(id:"claude",name:"Claude",installed:true,readiness:"ready",capabilities:["openChat","sendPrompt","stop","artifacts"],reason:nil)]
    private var actionResults: [String: [String: Any]] = [:]
    private var droppedActions = Set<String>()
    private var navigationActive = false
    private var navigationSession = UUID().uuidString
    private var navigationGeneration: Int?
    private var navigationChatID: String?
    private var acceptedNavigation = 0
    private var dispatched = Set<String>()
    private var startCompleted = false
    private(set) var port: UInt16 = 0
    let token = String(repeating: "test-only-token-", count: 4)
    let codexChatID = UUID().uuidString

    init(name: String) { self.name = name; hostID = UUID().uuidString }
    var baseURL: String { "http://127.0.0.1:\(port)" }
    var host: RemoteHost { .init(id: name, name: name, baseURL: baseURL, hostID: hostID) }
    var sendCount: Int { lock.lock(); defer { lock.unlock() }; return dispatched.count }
    var received: [(String, [String: String], Data)] { lock.lock(); defer { lock.unlock() }; return requests }
    func setUncertain(_ value: Bool) { lock.lock(); simulateUncertain = value; lock.unlock() }
    func rejectSend(_ value: Bool) { lock.lock(); rejectSend = value; lock.unlock() }
    func dropSendResponse(_ value: Bool) { lock.lock(); dropSendResponse = value; lock.unlock() }
    func setSendAcceptance(_ value: String) { lock.lock(); sendAcceptedState = value; lock.unlock() }
    func confirmReceipt() { lock.lock(); receiptState = "confirmed"; lock.unlock() }
    func setReceiptState(_ state: String) { lock.lock(); receiptState = state; lock.unlock() }
    func setReceiptMissing(_ value: Bool) { lock.lock(); receiptMissing = value; lock.unlock() }
    func setReceiptWrongID(_ value: Bool) { lock.lock(); receiptWrongID = value; lock.unlock() }
    func setProviders(_ value: [ProviderInfo]) { lock.lock(); providers = value; lock.unlock() }
    func overrideProfileProvider(_ value: String?) { lock.lock(); profileProviderOverride = value; lock.unlock() }
    func setActionResult(_ action: String, status: String = "confirmed", chat: ChatRecord? = nil) {
        var result: [String: Any] = ["status":status,"message":"Fixture action result"]
        if let chat { result["activeChat"] = try? JSONSerialization.jsonObject(with:JSONEncoder().encode(chat)) }
        lock.lock(); actionResults[action] = result; lock.unlock()
    }
    func dropAction(_ action: String, value: Bool) { lock.lock(); if value { droppedActions.insert(action) } else { droppedActions.remove(action) }; lock.unlock() }
    func setNavigation(_ active: Bool, rotate: Bool = false) { lock.lock(); navigationActive = active; if rotate { navigationSession = UUID().uuidString }; lock.unlock() }
    var navigationCount: Int { lock.lock(); defer { lock.unlock() }; return acceptedNavigation }
    func delayStatus(_ delay: TimeInterval) { lock.lock(); statusDelay = delay; lock.unlock() }
    func setStatusUnavailable(_ value: Bool) { lock.lock(); statusUnavailable = value; lock.unlock() }
    func hold(_ path: String) { lock.lock(); heldPaths.insert(path); lock.unlock() }
    func heldCount(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return heldResponses[path]?.count ?? 0 }
    func requestCount(_ path: String) -> Int { received.filter { $0.0.hasPrefix("GET \(path)?") || $0.0.hasPrefix("GET \(path) ") }.count }
    func release(_ path: String) {
        lock.lock(); heldPaths.remove(path); let replies = heldResponses.removeValue(forKey: path) ?? []; lock.unlock()
        queue.async { replies.forEach { $0() } }
    }
    func stop() { listener?.cancel() }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue); self.receive(connection, accumulated: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.lock(); let completed = self.startCompleted; self.startCompleted = true; self.lock.unlock()
                    guard !completed else { return }
                    self.port = listener.port!.rawValue; continuation.resume()
                case let .failed(error):
                    self.lock.lock(); let completed = self.startCompleted; self.startCompleted = true; self.lock.unlock()
                    if !completed { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] part, _, done, error in
            guard let self else { return }
            var data = accumulated; if let part { data.append(part) }
            if let boundary = data.range(of: Data("\r\n\r\n".utf8)), let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
                    if pieces.count == 2 { headers[pieces[0].lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if data.count >= boundary.upperBound + length {
                    let body = Data(data[boundary.upperBound..<(boundary.upperBound + length)])
                    self.reply(connection, firstLine: lines.first ?? "", headers: headers, body: body)
                    return
                }
            }
            if done || error != nil || data.count > 140_000 { connection.cancel() }
            else { self.receive(connection, accumulated: data) }
        }
    }
    private func reply(_ connection: NWConnection, firstLine: String, headers: [String: String], body: Data) {
        lock.lock(); requests.append((firstLine, headers, body)); let delay = statusDelay; let unavailable = statusUnavailable; let uncertain = simulateUncertain; let rejected = rejectSend; let dropped = dropSendResponse; let receiptState = self.receiptState; lock.unlock()
        guard headers["authorization"] == "Bearer \(token)" else { respond(connection, code: 401, json: ["error": "Unauthorized"]); return }
        let target = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let path = target.components(separatedBy: "?")[0]
        let queryProvider = URLComponents(string:"http://localhost" + target)?.queryItems?.first(where:{$0.name == "provider"})?.value ?? "claude"
        if path == "/v1/redirect" {
            respond(connection, code: 302, json: [:], extra: "Location: http://127.0.0.1:\(port)/v1/leaked\r\n"); return
        }
        if path == "/v1/conflict" { respond(connection, code: 409, json: ["error": "Profile changed"]); return }
        if path == "/v1/status" {
            if unavailable { respond(connection, code:503, json:["error":"Fixture temporarily unavailable"]); return }
            lock.lock(); let providerList = providers; lock.unlock()
            let value: [String: Any] = ["protocolVersion":1,"hostID":hostID,"hostName":name,
                "providers":(try? JSONSerialization.jsonObject(with:JSONEncoder().encode(providerList))) ?? []]
            queue.asyncAfter(deadline: .now() + delay) { self.respond(connection, code: 200, json: value) }; return
        }
        if path == "/v1/profile" {
            let edited = (try? JSONSerialization.jsonObject(with: body)) as? [String:Any]
            let provider = firstLine.hasPrefix("PUT ") ? edited?["provider"] as? String ?? queryProvider : queryProvider
            let chatID = provider == "codex" ? codexChatID : "chat-\(name)"
            let slots = (0..<6).map { ["index":$0,"kind":$0 == 0 ? "chat":"empty","title":$0 == 0 ? "Fixture chat":"Assign","targetID":$0 == 0 ? chatID:""] as [String: Any] }
            lock.lock()
            var profile = savedProfiles[provider] ?? ["provider":provider,"revision":1,"slots":slots]
            if firstLine.hasPrefix("PUT "), var edited {
                edited["revision"] = (profile["revision"] as? Int ?? 1) + 1; profile = edited; savedProfiles[provider] = edited
            }
            if firstLine.hasPrefix("GET "), let profileProviderOverride { profile["provider"] = profileProviderOverride; profile["revision"] = 999 }
            lock.unlock()
            respond(connection, code: 200, json: profile, holdPath: firstLine.hasPrefix("GET ") ? path : nil); return
        }
        if path == "/v1/chats" {
            let id = queryProvider == "codex" ? codexChatID : "chat-\(name)"
            respond(connection, code: 200, json: ["chats":[["id":id,"title":queryProvider == "codex" ? "Existing Codex thread":"Fixture chat","state":"Idle"]]], holdPath: path); return
        }
        if path == "/v1/artifacts" { respond(connection, code: 200, json: ["artifacts":[]], holdPath: path); return }
        if path == "/v1/navigation" {
            let query = URLComponents(string:"http://localhost" + target)?.queryItems ?? []
            lock.lock()
            navigationGeneration = Int(query.first(where:{$0.name == "generation"})?.value ?? "")
            navigationChatID = query.first(where:{$0.name == "chatID"})?.value
            let nav: [String:Any] = ["active":navigationActive,"session":navigationActive ? navigationSession : NSNull(),"label":"Fixture menu","selection":"First item"]
            lock.unlock(); respond(connection,code:200,json:nav,holdPath:path); return
        }
        if path == "/v1/commands", let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let id = object["id"] as? String {
            if object["hostID"] as? String != hostID { respond(connection, code: 422, json: ["error":"Wrong host"]); return }
            let action = object["action"] as? String ?? ""
            lock.lock(); let droppedAction = droppedActions.contains(action); var custom = actionResults[action]; lock.unlock()
            if droppedAction { connection.cancel(); return }
            if action.hasPrefix("menu") {
                lock.lock()
                let matches = navigationActive && object["navigationSession"] as? String == navigationSession &&
                    object["generation"] as? Int == navigationGeneration && object["chatID"] as? String == navigationChatID
                if matches { acceptedNavigation += 1 }
                if action == "menuHome", matches { navigationActive = false }
                let nav: [String:Any] = ["active":navigationActive,"session":navigationActive ? navigationSession : NSNull(),"label":"Fixture menu","selection":"Next item"]
                lock.unlock()
                guard matches else { respond(connection,code:409,json:["error":"Navigation context changed."]); return }
                if custom == nil { custom = ["status":"confirmed","message":"Navigation fixture"] }
                custom?["navigation"] = nav
            }
            if var custom { custom["id"] = id; respond(connection,code:200,json:custom,holdPath:"/v1/commands/"+action); return }
            if object["action"] as? String == "sendPrompt" {
                if rejected {
                    respond(connection, code: 200, json: ["id":id,"status":"failed","message":"The Mac composer already contains a draft or is unavailable. Nothing was replaced."]); return
                }
                lock.lock(); dispatched.insert(id); let accepted = sendAcceptedState; lock.unlock()
                if dropped { connection.cancel(); return }
                if uncertain { respond(connection, code: 200, json: ["id":id,"status":"uncertain","message":"Test delivery pending"]); return }
                respond(connection,code:200,json:["id":id,"status":accepted,"message":accepted == "queued" ? "Queued for Codex":"Fixture confirmed"],holdPath:"/v1/commands/"+action);return
            }
            respond(connection, code: 200, json: ["id":id,"status":"confirmed","message":"Fixture confirmed"],
                holdPath:"/v1/commands/"+action); return
        }
        if path.hasPrefix("/v1/commands/") {
            let id = String(path.dropFirst("/v1/commands/".count))
            lock.lock(); let known = dispatched.contains(id) && !receiptMissing; let wrongID = receiptWrongID; lock.unlock()
            if known { respond(connection, code: 200, json: ["id":wrongID ? UUID().uuidString : id,"status":receiptState,"message":"Fixture receipt"], holdPath: "/v1/commands/receipt") }
            else { respond(connection, code: 404, json: ["error":"No receipt"]) }
            return
        }
        respond(connection, code: 404, json: ["error":"Not found"])
    }
    private func respond(_ connection: NWConnection, code: Int, json: [String: Any], extra: String = "", holdPath: String? = nil) {
        if let holdPath {
            lock.lock()
            if heldPaths.contains(holdPath) {
                heldResponses[holdPath, default: []].append { self.respond(connection, code: code, json: json, extra: extra) }
                lock.unlock(); return
            }
            lock.unlock()
        }
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        var response = Data("HTTP/1.1 \(code) Test\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(extra)\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

final class FixtureCredentials: ControllerCredentialVault {
    private var values: [String: String] = [:]
    func token(for hostID: String) -> String? { values[hostID] }
    func save(_ token: String, for hostID: String) throws { values[hostID] = token }
    func remove(for hostID: String) { values.removeValue(forKey: hostID) }
}

/// Exercises the real store capture path without requesting microphone access.
@MainActor final class FixtureDictation: PhoneDictationService {
    var onText: ((String) -> Void)?
    var onState: ((PhoneDictation.State) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var state: PhoneDictation.State = .idle { didSet { onState?(state) } }
    private(set) var starts = 0
    private(set) var recordings = 0
    private var epoch = 0
    private var authorization: CheckedContinuation<Void, Never>?
    var delayAuthorization = false
    var denyPermission = false
    var finalText: String?
    func start() async throws {
        starts += 1; epoch += 1; let current = epoch
        state = .authorizing
        if delayAuthorization {
            delayAuthorization = false
            await withCheckedContinuation { authorization = $0 }
        }
        guard current == epoch else { return }
        if denyPermission { state = .idle; throw PhoneDictation.DictationError.permissions }
        recordings += 1; state = .recording
    }
    func completeAuthorization() { let pending = authorization; authorization = nil; pending?.resume() }
    func emit(_ text: String) { onText?(text) }
    func stop() async {
        guard state == .recording else { cancel(); return }
        state = .finalizing
        if let finalText { onText?(finalText); self.finalText = nil }
        state = .idle
    }
    func cancel() { epoch += 1; state = .idle }
    func interrupt() {
        cancel(); onError?("Recording was interrupted. Your partial draft is saved; nothing was sent.")
    }
}

@main struct RemoteHTTPIntegration {
    @MainActor static var count = 0
    @MainActor static func expect(_ value: Bool, _ label: String) {
        count += 1
        if !value { fatalError("FAIL: \(label)") }
    }
    @MainActor static func main() async throws {
        let first = HTTPFixture(name: "fixture-a"), second = HTTPFixture(name: "fixture-b")
        try await first.start(); try await second.start(); defer { first.stop(); second.stop() }
        let client = RemoteClient()
        let status = try await client.fetch(HostStatus.self, host: first.host, token: first.token, path: "/v1/status")
        expect(status.hostID == first.hostID, "Real HTTP status round trip")
        expect(first.received.last?.1["authorization"] == "Bearer \(first.token)", "Bearer only in request header")
        do {
            let _: HostStatus = try await client.fetch(HostStatus.self, host: first.host, token: "invalid", path: "/v1/status")
            fatalError("401 unexpectedly accepted")
        } catch RemoteError.server(let code, _) { expect(code == 401, "401 surfaced without fabricated success") }
        do {
            let _: HostStatus = try await client.fetch(HostStatus.self, host: first.host, token: first.token, path: "/v1/conflict")
            fatalError("409 unexpectedly accepted")
        } catch RemoteError.server(let code, _) { expect(code == 409, "Conflict not treated as saved") }
        do {
            let _: HostStatus = try await client.fetch(HostStatus.self, host: first.host, token: first.token, path: "/v1/redirect")
            fatalError("Redirect unexpectedly followed")
        } catch RemoteError.server(let code, _) { expect(code == 302, "Redirect refused") }
        expect(!first.received.contains { $0.0.contains("/v1/leaked") }, "Redirect cannot forward credentials")
        let _: ChatsResponse = try await client.fetch(ChatsResponse.self, host: first.host, token: first.token, path: "/v1/chats", query: [.init(name:"provider",value:"claude & muse")])
        expect(first.received.last?.0.contains("provider=claude%20%26%20muse") == true, "Query values safely encoded")
        let beforeOversize = first.received.count
        do {
            let _: CommandReceipt = try await client.fetch(CommandReceipt.self, host: first.host, token: first.token, path: "/v1/commands", method:"POST", body:Data(repeating:0,count:131_073))
            fatalError("Oversized prompt unexpectedly posted")
        } catch RemoteError.server(let code, _) { expect(code == 413, "Oversized prompt rejected locally") }
        expect(first.received.count == beforeOversize, "Oversized body never reaches HTTP service")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("genesis-http-test-\(UUID().uuidString)")
        let freshStore = ControllerStore(client: client, credentials: FixtureCredentials(),
            persistence: ControllerPersistence(directory: temporary.appendingPathComponent("fresh")))
        expect(freshStore.hosts.isEmpty && freshStore.selectedHost == nil && !freshStore.isPaired,
               "Fresh install starts without owner-specific Mac entries")
        let firstPairing = PairingPayload(v:1,name:first.name,hostID:first.hostID,baseURL:first.baseURL,token:first.token)
        let firstPairingData = try JSONEncoder().encode(firstPairing).base64EncodedString()
            .replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        try await freshStore.pair(URL(string:"genesiscontroller://pair?data=\(firstPairingData)")!)
        expect(freshStore.hosts.count == 1 && freshStore.selectedHost?.hostID == first.hostID && freshStore.isPaired,
               "First QR pairing adds and selects the verified Mac")
        let persistence = ControllerPersistence(directory: temporary)
        let credentials = FixtureCredentials()
        try credentials.save(first.token, for: first.name); try credentials.save(second.token, for: second.name)
        defer { credentials.remove(for: first.name); credentials.remove(for: second.name); try? FileManager.default.removeItem(at: temporary) }
        var saved = LocalControllerSettings()
        saved.hosts = [first.host,second.host]; saved.selectedHostID = first.name; saved.selectedProvider = .claude
        saved.selectedChats["\(first.hostID).claude"] = .init(id:"chat-\(first.name)",title:"Fixture chat",state:"Idle")
        saved.selectedChats["\(second.hostID).claude"] = .init(id:"chat-\(second.name)",title:"Other chat",state:"Idle")
        try persistence.save(saved)
        let store = ControllerStore(client: client, credentials: credentials, persistence: persistence)
        await store.refresh()
        expect(store.isPaired && store.status?.hostID == first.hostID, "Store authenticates paired host")
        expect(store.profile.slots.count == 6 && store.chats.count == 1, "Mapping and chat snapshots populated through HTTP")
        let beforeVoice = first.received.count
        await store.startNativeVoice()
        expect(first.received.count == beforeVoice, "Unavailable native voice cannot issue a network command")
        let wrongIdentity = PairingPayload(v:1,name:"Wrong Mac",hostID:UUID().uuidString,baseURL:first.baseURL,token:first.token)
        let b64 = try JSONEncoder().encode(wrongIdentity).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        do {
            try await store.pair(URL(string:"genesiscontroller://pair?data=\(b64)")!)
            fatalError("Wrong host pairing accepted")
        } catch RemoteError.wrongHost { expect(true, "Pairing verifies identity through live status") }
        expect(credentials.token(for:wrongIdentity.hostID) == nil && store.selectedHostID == first.name, "Failed pairing neither saves token nor switches target")
        store.draft = "An explicit test prompt\nwith punctuation & Unicode café."
        expect(first.sendCount == 0, "Editing a draft never sends")
        first.setUncertain(true)
        await store.sendDraft()
        expect(first.sendCount == 1, "Explicit Send dispatches once")
        expect(store.hasUnresolvedSend && !store.canSend, "Uncertain delivery disables duplicate Send")
        await store.sendDraft()
        expect(first.sendCount == 1, "Second tap cannot dispatch while result is unresolved")
        let posted = first.received.last { $0.0.hasPrefix("POST /v1/commands ") }!
        let command = try JSONDecoder().decode(RemoteCommand.self, from: posted.2)
        expect(command.chatID == "chat-\(first.name)" && command.hostID == first.hostID, "Send pinned to exact host/chat")
        expect(command.text == store.draft, "Reviewed text preserved through HTTP JSON encoding")
        let restored = ControllerStore(client: client, credentials: credentials, persistence: persistence)
        expect(restored.hasUnresolvedSend && restored.draft == store.draft, "Restart retains both draft and original request ID")
        first.confirmReceipt()
        await restored.refresh()
        expect(!restored.hasUnresolvedSend && restored.draft.isEmpty, "GET receipt confirms delivery and clears matching draft")
        expect(first.sendCount == 1, "Receipt recovery never posts again")

        store.acknowledgeUncertainSend(wasSent: true)
        store.draft = "Draft for first Mac"
        first.delayStatus(0.4)
        let oldRefresh = Task { await store.refresh() }
        try? await Task.sleep(nanoseconds:50_000_000)
        store.selectHost(second.name)
        store.draft = "Draft for second Mac"
        await oldRefresh.value
        try? await Task.sleep(nanoseconds:200_000_000)
        expect(store.status?.hostID == second.hostID, "Delayed first-host status cannot replace second-host state")
        expect(store.draft == "Draft for second Mac", "Delayed response cannot change current draft")
        store.selectHost(first.name)
        expect(store.draft == "Draft for first Mac", "Returning to first Mac restores only its own draft")
        expect(first.sendCount == 1 && second.sendCount == 0, "Switching never sends saved drafts")
        first.delayStatus(0)
        await store.refresh()
        try? await Task.sleep(nanoseconds:450_000_000)
        await store.refresh()
        first.dropSendResponse(true)
        store.draft = "Lost response fixture"
        await store.sendDraft()
        expect(!store.hasUnresolvedSend && store.lastReceipt?.status == "confirmed" && store.lastError == nil,
               "Lost POST response checks the exact receipt before showing a false warning")
        expect(first.sendCount == 2, "Transport loss retains one distinct command identity")
        first.confirmReceipt(); first.dropSendResponse(false)
        await store.recoverPendingSend()
        expect(!store.hasUnresolvedSend && store.draft.isEmpty && first.sendCount == 2, "Receipt lookup recovers after network loss without another command")
        store.setForeground(false)

        // Latency regression: hold each read reply at the server. All independent
        // requests must arrive before any is released, without blocking actions.
        let fast = HTTPFixture(name: "fixture-responsive"); try await fast.start(); defer { fast.stop() }
        try credentials.save(fast.token, for: fast.name)
        var responsiveSettings = LocalControllerSettings()
        responsiveSettings.hosts = [fast.host, second.host]; responsiveSettings.selectedHostID = fast.name
        responsiveSettings.selectedChats["\(fast.hostID).claude"] = .init(id: "chat-\(fast.name)", title: "Fixture chat", state: "Idle")
        responsiveSettings.selectedChats["\(second.hostID).claude"] = .init(id: "chat-\(second.name)", title: "Second fixture chat", state: "Idle")
        let responsivePersistence = ControllerPersistence(directory: temporary.appendingPathComponent("responsive"))
        try responsivePersistence.save(responsiveSettings)
        let responsive = ControllerStore(client: client, credentials: credentials, persistence: responsivePersistence)
        await responsive.refresh()
        fast.rejectSend(true)
        responsive.draft = "Keep this reviewed draft after a rejected Send"
        await responsive.sendDraft()
        expect(responsive.lastError?.contains("composer") == true && responsive.draft == "Keep this reviewed draft after a rejected Send",
               "Rejected Send reports the composer problem without deleting the phone draft")
        fast.hold("/v1/commands/openChat")
        let openAfterFailure = Task { await responsive.openSlot(0) }
        for _ in 0..<100 {
            if fast.heldCount("/v1/commands/openChat") == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(responsive.isBusy && responsive.lastError == nil && responsive.lastReceipt == nil,
               "A new navigation command clears the old error and receipt while awaiting confirmation")
        fast.release("/v1/commands/openChat")
        await openAfterFailure.value
        let attemptedActions = fast.received.compactMap { try? JSONDecoder().decode(RemoteCommand.self, from: $0.2) }.map(\.action)
        expect(attemptedActions == ["sendPrompt", "openChat"] && responsive.lastError == nil && fast.sendCount == 0,
               "A thread tap clears the earlier Send warning and issues only openChat")
        expect(responsive.draft == "Keep this reviewed draft after a rejected Send",
               "Returning to the same thread keeps its unsent draft intact")
        fast.rejectSend(false)
        // Let changeChat's independent shelf fetch finish before holding the next cycle.
        await responsive.refresh()
        let readPaths = ["/v1/profile", "/v1/chats", "/v1/artifacts"]
        readPaths.forEach { fast.hold($0) }
        let artifactsBefore = fast.requestCount("/v1/artifacts")
        let overlappingReads = Task { await responsive.refresh() }
        for _ in 0..<100 {
            if readPaths.allSatisfy({ fast.heldCount($0) == 1 }) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(readPaths.allSatisfy { fast.heldCount($0) == 1 }, "Profile, chats and artifacts overlap after verified status")
        async let duplicateShelf: Void = responsive.refreshArtifacts()
        async let repeatedShelf: Void = responsive.refreshArtifacts()
        _ = await (duplicateShelf, repeatedShelf)
        expect(fast.requestCount("/v1/artifacts") == artifactsBefore + 1, "Overlapping artifact refreshes share one request per selection")
        let mapping = SlotMapping(index: 0, kind: "chat", title: "New mapping", targetID: "chat-updated")
        let savedMapping = await responsive.saveSlot(mapping)
        expect(savedMapping && responsive.profile.revision == 2, "Mapping save completes while older read replies are pending")
        readPaths.forEach { fast.release($0) }
        await overlappingReads.value
        expect(responsive.profile.revision == 2 && responsive.profile.slots[0] == mapping,
               "A delayed profile snapshot cannot overwrite the mapping just saved")
        expect(responsivePersistence.load().profiles["\(fast.hostID).claude"]?.slots[0] == mapping,
               "The newer mapping survives reopening persisted state")

        fast.hold("/v1/chats"); fast.hold("/v1/artifacts")
        let slowBackground = Task { await responsive.refresh() }
        for _ in 0..<100 {
            if fast.heldCount("/v1/chats") == 1 && fast.heldCount("/v1/artifacts") == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let another = ChatRecord(id: "chat-another", title: "Another fixture chat", state: "Idle")
        await responsive.selectChat(another)
        expect(responsive.selectedChat?.id == another.id && !responsive.isBusy && responsive.canDictate,
               "Confirmed chat opens and unlocks talk before background scans finish")
        let navigation = fast.received.compactMap { try? JSONDecoder().decode(RemoteCommand.self, from: $0.2) }.last
        expect(navigation?.action == "openChat" && navigation?.chatID == another.id && fast.sendCount == 0,
               "Responsive navigation remains a confirmed explicit command without sending a draft")
        responsive.selectHost(second.name)
        responsive.draft = "Second Mac draft during delayed first-Mac reads"
        fast.release("/v1/chats"); fast.release("/v1/artifacts")
        await slowBackground.value
        for _ in 0..<100 {
            if responsive.status?.hostID == second.hostID && responsive.chats.first?.id == "chat-\(second.name)" { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(responsive.status?.hostID == second.hostID && responsive.chats.first?.id == "chat-\(second.name)",
               "Delayed parallel snapshots cannot replace the newly selected Mac")
        expect(responsive.draft == "Second Mac draft during delayed first-Mac reads" && fast.sendCount == 0 && second.sendCount == 0,
               "Switching during parallel refresh preserves the new target draft without sending")

        // Receipt presentation belongs to its command. Recovery may finish while
        // another action or target is active; the journal still reconciles safely.
        let receiptFixture = HTTPFixture(name: "fixture-receipts"); try await receiptFixture.start(); defer { receiptFixture.stop() }
        try credentials.save(receiptFixture.token, for: receiptFixture.name)
        var receiptSettings = LocalControllerSettings()
        receiptSettings.hosts = [receiptFixture.host, second.host]; receiptSettings.selectedHostID = receiptFixture.name
        receiptSettings.selectedChats["\(receiptFixture.hostID).claude"] = .init(id:"chat-\(receiptFixture.name)",title:"Receipt fixture",state:"Idle")
        receiptSettings.selectedChats["\(second.hostID).claude"] = .init(id:"chat-\(second.name)",title:"Second fixture",state:"Idle")
        let receiptPersistence = ControllerPersistence(directory:temporary.appendingPathComponent("receipts"))
        try receiptPersistence.save(receiptSettings)
        let receiptStore = ControllerStore(client:client,credentials:credentials,persistence:receiptPersistence)
        await receiptStore.refresh()
        receiptFixture.dropSendResponse(true)
        receiptStore.draft = "Pending receipt stays protected"
        await receiptStore.sendDraft()
        expect(receiptStore.hasUnresolvedSend && receiptStore.lastReceipt?.status == "pending" && !receiptStore.canSend,
               "A readback still pending preserves the journal and blocks another Send")
        await receiptStore.runAction("sendPrompt")
        expect(receiptFixture.sendCount == 1, "Repeated tap while receipt is pending never posts again")
        receiptFixture.confirmReceipt(); await receiptStore.recoverPendingSend()
        expect(!receiptStore.hasUnresolvedSend && receiptStore.lastError == nil && receiptStore.draft.isEmpty,
               "Confirmed recovery clears only its own unresolved-Send alert")

        receiptFixture.dropSendResponse(false); receiptFixture.setUncertain(true)
        receiptStore.draft = "Recover without clearing a newer warning"
        await receiptStore.sendDraft()
        receiptFixture.hold("/v1/commands/receipt")
        let recoveryWithNewError = Task { await receiptStore.recoverPendingSend() }
        for _ in 0..<100 {
            if receiptFixture.heldCount("/v1/commands/receipt") == 1 { break }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        receiptStore.lastError = "Microphone permission unavailable."
        receiptFixture.release("/v1/commands/receipt"); await recoveryWithNewError.value
        expect(!receiptStore.hasUnresolvedSend && receiptStore.lastError == "Microphone permission unavailable.",
               "Late confirmed recovery preserves an unrelated newer error")

        receiptStore.draft = "Recover without replacing a newer command receipt"
        await receiptStore.sendDraft()
        receiptFixture.hold("/v1/commands/receipt")
        let recoveryWithNewCommand = Task { await receiptStore.recoverPendingSend() }
        for _ in 0..<100 {
            if receiptFixture.heldCount("/v1/commands/receipt") == 1 { break }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        await receiptStore.stopResponse()
        let newerReceipt = receiptStore.lastReceipt
        receiptFixture.release("/v1/commands/receipt"); await recoveryWithNewCommand.value
        expect(!receiptStore.hasUnresolvedSend && receiptStore.lastReceipt == newerReceipt && newerReceipt?.isConfirmed == true,
               "An older Send readback reconciles its journal without replacing the newer Stop receipt")

        receiptFixture.dropSendResponse(true); receiptFixture.setReceiptMissing(true)
        receiptStore.draft = "Unknown receipt must not be sent twice"
        let beforeUnknown = receiptFixture.sendCount
        await receiptStore.sendDraft(); await receiptStore.sendDraft()
        expect(receiptStore.hasUnresolvedSend && receiptStore.lastReceipt?.status == "uncertain" && receiptFixture.sendCount == beforeUnknown + 1,
               "Unknown receipt stays protected with exactly one POST")
        receiptStore.acknowledgeUncertainSend(wasSent:false)
        receiptFixture.setReceiptMissing(false); receiptFixture.setReceiptWrongID(true)
        receiptStore.draft = "Mismatched receipt must not confirm"
        await receiptStore.sendDraft(); await receiptStore.recoverPendingSend()
        expect(receiptStore.hasUnresolvedSend && !receiptStore.draft.isEmpty && receiptStore.lastReceipt?.status == "uncertain",
               "Receipt ID mismatch never confirms or clears the draft")
        receiptStore.acknowledgeUncertainSend(wasSent:false); receiptFixture.setReceiptWrongID(false)

        receiptFixture.hold("/v1/commands/receipt")
        receiptStore.draft = "Deadline preserves this draft"
        let deadlineStart = ProcessInfo.processInfo.systemUptime
        await receiptStore.sendDraft()
        let readbackDuration = ProcessInfo.processInfo.systemUptime - deadlineStart
        expect(readbackDuration < 3.5 && !receiptStore.isBusy && receiptStore.hasUnresolvedSend,
               "Immediate receipt readback has a bounded wall-clock deadline and releases busy state")
        let timedOutID = receiptStore.lastReceipt?.id
        receiptFixture.release("/v1/commands/receipt")
        try? await Task.sleep(nanoseconds:80_000_000)
        expect(receiptStore.hasUnresolvedSend && receiptStore.lastReceipt?.id == timedOutID && !receiptStore.draft.isEmpty,
               "A cancelled readback cannot later confirm silently when its delayed response arrives")
        await receiptStore.recoverPendingSend()
        expect(!receiptStore.hasUnresolvedSend && receiptStore.lastError == nil && receiptStore.draft.isEmpty,
               "A fresh background receipt check confirms after the short readback deadline")

        receiptFixture.dropSendResponse(false)
        receiptStore.draft = "Original Mac draft awaiting receipt"
        await receiptStore.sendDraft()
        receiptFixture.hold("/v1/commands/receipt")
        let switchedRecovery = Task { await receiptStore.recoverPendingSend() }
        for _ in 0..<100 {
            if receiptFixture.heldCount("/v1/commands/receipt") == 1 { break }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        receiptStore.selectHost(second.name)
        receiptStore.draft = "New Mac draft must stay untouched"
        receiptStore.lastError = "New Mac warning"
        receiptFixture.release("/v1/commands/receipt"); await switchedRecovery.value
        expect(receiptStore.selectedHostID == second.name && receiptStore.draft == "New Mac draft must stay untouched" &&
               receiptStore.lastReceipt == nil && receiptStore.lastError == "New Mac warning",
               "Recovery for a previous Mac cannot change the new target's draft, receipt, or alert")
        let originalRoute = DraftRoute(hostID:receiptFixture.hostID,provider:"claude",chatID:"chat-\(receiptFixture.name)")
        expect(receiptPersistence.load().ledger.pendingSends[originalRoute.storageKey] == nil,
               "Original Send is still reconciled in persistence after switching Macs")
        let sendPosts = receiptFixture.received.compactMap { try? JSONDecoder().decode(RemoteCommand.self, from: $0.2) }.filter { $0.action == "sendPrompt" }
        expect(receiptFixture.sendCount == 7 && sendPosts.count == 7, "All receipt scenarios use one POST per explicit Send and no retries")
        print(String(format:"Receipt readback deadline observed: %.2f seconds", readbackDuration))

        // Codex can expose existing chats independently of prompt delivery.
        let codexFixture = HTTPFixture(name:"fixture-codex"); try await codexFixture.start(); defer { codexFixture.stop() }
        let claudeInfo = ProviderInfo(id:"claude",name:"Claude",installed:true,readiness:"ready",capabilities:["openChat","sendPrompt","stop","artifacts"],reason:nil)
        let codexInfo = ProviderInfo(id:"codex",name:"Codex",installed:true,readiness:"ready",capabilities:["openChat","artifacts"],reason:"Chat switching is available. Sending is not verified.")
        codexFixture.setProviders([claudeInfo,codexInfo])
        try credentials.save(codexFixture.token, for:codexFixture.name)
        var codexSettings = LocalControllerSettings()
        codexSettings.hosts = [codexFixture.host]; codexSettings.selectedHostID = codexFixture.name; codexSettings.selectedProvider = .codex
        codexSettings.selectedChats["\(codexFixture.hostID).claude"] = .init(id:"chat-\(codexFixture.name)",title:"Claude fixture",state:"Idle")
        let codexPersistence = ControllerPersistence(directory:temporary.appendingPathComponent("codex"))
        try codexPersistence.save(codexSettings)
        let codexSpeech = FixtureDictation()
        let codexStore = ControllerStore(client:client,credentials:credentials,persistence:codexPersistence,speech:codexSpeech)
        await codexStore.refresh()
        expect(codexStore.canMapChats && codexStore.navigationOnly && codexStore.chats.first?.id == codexFixture.codexChatID,
               "Navigation-only Codex lists existing UUID-addressed chats without Send capability")
        let codexMapping = SlotMapping(index:0,kind:"chat",title:"Existing Codex thread",targetID:codexFixture.codexChatID)
        let codexSaved = await codexStore.saveSlot(codexMapping)
        await codexStore.openSlot(0)
        let codexOpen = codexFixture.received.compactMap { try? JSONDecoder().decode(RemoteCommand.self,from:$0.2) }.last
        expect(codexSaved && codexStore.profile.provider == "codex" && codexStore.selectedChat?.id == codexFixture.codexChatID &&
               codexOpen?.provider == "codex" && codexOpen?.action == "openChat" && codexOpen?.chatID == codexFixture.codexChatID,
               "Codex A-slot save and open target the exact existing thread and provider")
        codexStore.draft = "Existing local Codex draft"
        expect(!codexStore.canSend && codexStore.canDictate && codexStore.availableShortcuts == [.dictate,.artifacts],
               "Codex can capture a local draft without enabling remote Send")
        expect(codexStore.dictationControl.label == "HOLD TO TALK" && codexStore.dictationControl.summary?.contains("iPhone draft") == true,
               "Codex mic offers local capture and clearly distinguishes the destination")
        let commandCount = codexFixture.received.filter { $0.0.hasPrefix("POST /v1/commands ") }.count
        await codexStore.sendDraft(); await codexStore.stopResponse(); await codexStore.startNativeVoice()
        expect(codexFixture.received.filter { $0.0.hasPrefix("POST /v1/commands ") }.count == commandCount && !codexStore.isRecording &&
               !codexStore.hasUnresolvedSend && codexStore.draft == "Existing local Codex draft",
               "Unsupported Codex delivery controls cannot create a Send journal or remove the draft")
        let localTalkMapped = await codexStore.saveSlot(.init(index:2,kind:"action",title:"Hold to talk",targetID:"dictate"))
        let localQuickMapped = await codexStore.saveQuickAction(1,actionID:"dictate")
        await codexStore.openSlot(2)
        expect(localTalkMapped && localQuickMapped && codexStore.requestedPanel == "talk" && codexSpeech.starts == 0,
               "Codex slot and quick key accept local Talk and only ready the microphone, without recording automatically")
        await codexStore.startDictation()
        expect(codexSpeech.recordings == 1 && codexStore.isRecording && !codexStore.canSend,
               "Codex Hold to talk starts the phone capture service while Send remains unavailable")
        codexSpeech.emit("Partial words")
        codexSpeech.finalText = "Final words from local dictation."
        await codexStore.stopDictation()
        let codexRoute = DraftRoute(hostID:codexFixture.hostID,provider:"codex",chatID:codexFixture.codexChatID)
        expect(!codexStore.isRecording && codexStore.draft == "Existing local Codex draft\nFinal words from local dictation." &&
               codexPersistence.load().ledger.text(for:codexRoute) == codexStore.draft,
               "Release finalizes and persists dictated text for the exact Codex chat without sending")
        await codexStore.sendDraft()
        expect(codexFixture.received.filter { $0.0.hasPrefix("POST /v1/commands ") }.count == commandCount &&
               !codexStore.canSend && !codexStore.hasUnresolvedSend,
               "Recording, release, and a disabled Send never post commands or create a delivery journal")
        codexStore.draft = "Existing local Codex draft"
        codexSpeech.delayAuthorization = true
        let pendingCapture = Task { await codexStore.startDictation() }
        for _ in 0..<100 { if codexSpeech.state == .authorizing { break }; await Task.yield() }
        await codexStore.stopDictation(); codexSpeech.completeAuthorization(); await pendingCapture.value
        expect(codexSpeech.recordings == 1 && !codexStore.isRecording && codexStore.draft == "Existing local Codex draft",
               "Releasing Codex Talk during permission startup prevents a later microphone start")
        codexSpeech.denyPermission = true; await codexStore.startDictation(); codexSpeech.denyPermission = false
        expect(!codexStore.isRecording && codexStore.lastError?.contains("Settings") == true && codexStore.draft == "Existing local Codex draft",
               "Denied microphone permission preserves the local Codex draft and offers typed input")
        _ = await codexStore.saveSlot(.init(index:1,kind:"action",title:"Legacy Send shortcut",targetID:"sendPrompt"))
        await codexStore.openSlot(1)
        expect(codexStore.lastError?.contains("not available") == true && codexStore.draft == "Existing local Codex draft" &&
               codexFixture.received.filter { $0.0.hasPrefix("POST /v1/commands ") }.count == commandCount,
               "An older unsupported Send mapping explains its limitation without dispatching or discarding text")
        let capturePersistence = ControllerPersistence(directory:temporary.appendingPathComponent("codex-capture"))
        var captureSettings = codexPersistence.load()
        captureSettings.hosts.append(second.host)
        let otherCodexChat = ChatRecord(id:UUID().uuidString,title:"Other Mac Codex chat",state:"Idle")
        captureSettings.selectedChats["\(second.hostID).codex"] = otherCodexChat
        let otherCodexRoute = DraftRoute(hostID:second.hostID,provider:"codex",chatID:otherCodexChat.id)
        captureSettings.ledger.set("Other Mac draft",for:otherCodexRoute)
        try capturePersistence.save(captureSettings)
        let captureSpeech = FixtureDictation()
        let captureStore = ControllerStore(client:client,credentials:credentials,persistence:capturePersistence,speech:captureSpeech)
        await captureStore.refresh()
        await captureStore.startDictation(); captureSpeech.emit("Preserved before switching.")
        let oldTranscript = captureSpeech.onText
        let capturedText = captureStore.draft
        captureStore.selectProvider(.claude); captureStore.draft = "Separate Claude draft"
        oldTranscript?("Late Codex words")
        expect(!captureStore.isRecording && captureStore.draft == "Separate Claude draft" &&
               capturePersistence.load().ledger.text(for:codexRoute) == capturedText,
               "Changing provider stops local Codex capture and ignores its late transcript without losing either draft")
        captureStore.selectProvider(.codex); captureStore.selectHost(second.name)
        oldTranscript?("Late words for another Mac")
        expect(captureStore.draft == "Other Mac draft" && captureStore.selectedHostID == second.name,
               "Changing Macs restores its own Codex draft and rejects old microphone output")
        captureStore.selectHost(codexFixture.name)
        for _ in 0..<100 {
            if captureStore.canDictate { break }
            try? await Task.sleep(nanoseconds:10_000_000); await captureStore.refresh()
        }
        await captureStore.startDictation(); captureSpeech.emit("Before selecting another chat.")
        let oldChatTranscript = captureSpeech.onText
        let originalChatDraft = captureStore.draft
        let nextCodexChat = ChatRecord(id:UUID().uuidString,title:"Second Codex chat",state:"Idle")
        await captureStore.selectChat(nextCodexChat)
        oldChatTranscript?("Late first-chat words")
        expect(captureStore.selectedChat?.id == nextCodexChat.id && captureStore.draft.isEmpty && !captureStore.isRecording &&
               capturePersistence.load().ledger.text(for:codexRoute) == originalChatDraft,
               "Selecting another Codex chat cancels capture and preserves text only under its original UUID")
        await captureStore.startDictation(); captureSpeech.emit("Interrupted draft")
        captureSpeech.interrupt()
        expect(!captureStore.isRecording && captureStore.draft == "Interrupted draft" && captureStore.lastError?.contains("interrupted") == true,
               "Audio interruption leaves the captured Codex draft available for editing")
        captureStore.setForeground(true)
        captureSpeech.delayAuthorization = true
        let backgroundCapture = Task { await captureStore.startDictation() }
        for _ in 0..<100 { if captureSpeech.state == .authorizing { break }; await Task.yield() }
        let recordingsBeforeBackground = captureSpeech.recordings
        captureStore.setForeground(false); captureSpeech.completeAuthorization(); await backgroundCapture.value
        expect(!captureStore.isRecording && captureSpeech.recordings == recordingsBeforeBackground && captureStore.draft == "Interrupted draft",
               "Backgrounding during Codex microphone authorization prevents a deferred recording start")
        let captureRestored = ControllerStore(client:client,credentials:credentials,persistence:capturePersistence,speech:FixtureDictation())
        expect(captureRestored.draft == "Interrupted draft" && captureRestored.selectedChat?.id == nextCodexChat.id &&
               capturePersistence.load().ledger.text(for:codexRoute) == originalChatDraft &&
               capturePersistence.load().ledger.text(for:otherCodexRoute) == "Other Mac draft" &&
               capturePersistence.load().ledger.pendingSends.isEmpty,
               "Restart restores local capture drafts by exact Mac/provider/chat without creating pending delivery")
        let correctCodexProfile = codexStore.profile
        codexFixture.overrideProfileProvider("claude"); await codexStore.refresh(); codexFixture.overrideProfileProvider(nil)
        expect(codexStore.profile == correctCodexProfile,
               "A wrong-provider profile is rejected even with a newer revision")
        codexFixture.hold("/v1/chats")
        let oldCodexRefresh = Task { await codexStore.refresh() }
        for _ in 0..<100 {
            if codexFixture.heldCount("/v1/chats") == 1 { break }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        codexStore.selectProvider(.claude)
        codexStore.draft = "Claude draft stays separate"
        for _ in 0..<100 {
            if codexFixture.heldCount("/v1/chats") == 2 { break }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        codexFixture.release("/v1/chats"); await oldCodexRefresh.value
        for _ in 0..<100 {
            if codexStore.chats.first?.id == "chat-\(codexFixture.name)" && !codexStore.isRefreshingChats { break }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        expect(codexStore.selectedProvider == .claude && codexStore.profile.provider == "claude" &&
               codexStore.chats.first?.id == "chat-\(codexFixture.name)" && codexStore.draft == "Claude draft stays separate" && codexStore.canDictate,
               "Delayed Codex refresh cannot replace Claude chats, mappings, draft, or working Talk control")
        expect(codexStore.dictationControl.label == "HOLD TO TALK" && codexStore.dictationControl.explanation == nil,
               "Switching back to ready Claude restores the normal Hold-to-talk presentation")
        codexFixture.setUncertain(true); codexFixture.confirmReceipt()
        await codexStore.sendDraft()
        codexFixture.hold("/v1/commands/receipt")
        let crossProviderRecovery = Task { await codexStore.recoverPendingSend() }
        for _ in 0..<100 {
            if codexFixture.heldCount("/v1/commands/receipt") == 1 { break }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        codexStore.selectProvider(.codex)
        codexFixture.release("/v1/commands/receipt"); await crossProviderRecovery.value
        expect(codexStore.selectedProvider == .codex && codexStore.draft == "Existing local Codex draft" && codexStore.lastReceipt == nil,
               "Late Claude Send recovery cannot overwrite the selected Codex draft or receipt")
        let claudeRoute = DraftRoute(hostID:codexFixture.hostID,provider:"claude",chatID:"chat-\(codexFixture.name)")
        expect(codexPersistence.load().ledger.pendingSends[claudeRoute.storageKey] == nil && codexFixture.sendCount == 1,
               "Claude Send reconciles separately and no Codex Send is issued")
        for _ in 0..<100 {
            if codexStore.canMapChats { break }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        var unavailableCodex = codexInfo; unavailableCodex.readiness = "unavailable"; unavailableCodex.capabilities = ["artifacts"]
        unavailableCodex.reason = "Codex chat navigation is unavailable on this host."
        codexFixture.setProviders([claudeInfo,unavailableCodex])
        await codexStore.refresh()
        for _ in 0..<100 {
            if codexStore.providerInfo?.readiness == "unavailable" { break }
            try? await Task.sleep(nanoseconds:10_000_000)
            await codexStore.refresh()
        }
        expect(!codexStore.canMapChats && codexStore.chatAvailabilityMessage == unavailableCodex.reason && codexStore.availableShortcuts == [.artifacts],
               "Unsupported Codex reports the actual limitation instead of claiming there are no chats")

        let queueFixture = HTTPFixture(name:"fixture-codex-queue"); try await queueFixture.start(); defer { queueFixture.stop() }
        var queueProvider = codexInfo; queueProvider.capabilities.append("sendPrompt")
        queueFixture.setProviders([claudeInfo,queueProvider]); queueFixture.setSendAcceptance("queued"); queueFixture.setReceiptState("queued")
        try credentials.save(queueFixture.token,for:queueFixture.name)
        let queuePersistence = ControllerPersistence(directory:temporary.appendingPathComponent("codex-queue"))
        var queueSettings = LocalControllerSettings()
        queueSettings.hosts = [queueFixture.host]; queueSettings.selectedHostID = queueFixture.name; queueSettings.selectedProvider = .codex
        queueSettings.selectedChats["\(queueFixture.hostID).claude"] = .init(id:"chat-\(queueFixture.name)",title:"Separate Claude chat",state:"Idle")
        try queuePersistence.save(queueSettings)
        let queueSpeech = FixtureDictation()
        let queueStore = ControllerStore(client:client,credentials:credentials,persistence:queuePersistence,speech:queueSpeech)
        await queueStore.refresh(); await queueStore.openSlot(0)
        await queueStore.startDictation(); queueSpeech.emit("One reviewed queued prompt."); await queueStore.stopDictation()
        expect(queueStore.canSend && queueStore.canDictate && queueFixture.sendCount == 0 &&
               queueStore.dictationControl.summary?.contains("queue") == true,
               "Codex capture prepares a reviewed draft, exposes queue semantics, and waits for explicit Send")
        let queuedAction = await queueStore.runAction("sendPrompt")
        let sentQueueCommand = queueFixture.received.compactMap { try? JSONDecoder().decode(RemoteCommand.self,from:$0.2) }.last { $0.action == "sendPrompt" }
        expect(queuedAction && sentQueueCommand?.provider == "codex" && sentQueueCommand?.hostID == queueFixture.hostID &&
               sentQueueCommand?.chatID == queueFixture.codexChatID && sentQueueCommand?.text == "One reviewed queued prompt.",
               "Explicit queue Send posts the reviewed text once to the exact selected Codex UUID and Mac")
        expect(queueStore.lastReceipt?.isQueued == true && queueStore.lastReceipt?.isConfirmed == false &&
               queueStore.draft.isEmpty && !queueStore.hasUnresolvedSend && !queueStore.canSend && queueFixture.sendCount == 1,
               "Accepted queue custody clears only the submitted draft and is never labeled delivered")
        await queueStore.sendDraft()
        expect(queueFixture.sendCount == 1, "A repeated tap after queue acceptance cannot resend the cleared prompt")
        let queuedRestart = ControllerStore(client:client,credentials:credentials,persistence:queuePersistence,speech:FixtureDictation())
        expect(queuedRestart.draft.isEmpty && !queuedRestart.hasUnresolvedSend, "Queue acceptance remains resolved after app restart")

        queueStore.draft = "Submitted before editing"
        queueFixture.hold("/v1/commands/sendPrompt")
        let queueWhileEditing = Task { await queueStore.sendDraft() }
        for _ in 0..<100 { if queueFixture.heldCount("/v1/commands/sendPrompt") == 1 { break }; try? await Task.sleep(nanoseconds:10_000_000) }
        queueStore.draft = "Newer draft for my next turn"
        queueFixture.release("/v1/commands/sendPrompt"); await queueWhileEditing.value
        expect(queueStore.draft == "Newer draft for my next turn" && queueStore.canSend && !queueStore.hasUnresolvedSend && queueFixture.sendCount == 2,
               "A delayed queued receipt preserves newer draft edits and does not send them automatically")

        queueFixture.dropSendResponse(true); queueStore.draft = "Response lost after queueing"
        await queueStore.sendDraft()
        let recoveredQueueID = queueStore.lastReceipt?.id ?? ""
        expect(queueStore.lastReceipt?.isQueued == true && queueStore.lastError == nil && queueStore.draft.isEmpty &&
               !queueStore.hasUnresolvedSend && queueFixture.sendCount == 3 &&
               queueFixture.received.contains(where:{$0.0.hasPrefix("GET /v1/commands/\(recoveredQueueID) ")}),
               "Lost POST response recovers the original queued receipt by GET without a duplicate enqueue")

        queueFixture.setReceiptMissing(true); queueStore.draft = "Uncertain queue operation"
        await queueStore.sendDraft(); await queueStore.sendDraft()
        expect(queueStore.hasUnresolvedSend && !queueStore.canSend && queueStore.draft == "Uncertain queue operation" && queueFixture.sendCount == 4,
               "Unknown queue acceptance keeps the original draft and blocks another POST")
        queueFixture.setReceiptMissing(false); queueFixture.setReceiptWrongID(true)
        await queueStore.recoverPendingSend()
        expect(queueStore.hasUnresolvedSend && queueStore.draft == "Uncertain queue operation", "A different queue receipt cannot resolve the original request")
        queueFixture.setReceiptWrongID(false); queueFixture.hold("/v1/commands/receipt")
        let lateQueueRecovery = Task { await queueStore.recoverPendingSend() }
        for _ in 0..<100 { if queueFixture.heldCount("/v1/commands/receipt") == 1 { break }; try? await Task.sleep(nanoseconds:10_000_000) }
        queueStore.lastError = "Keep this newer controller error"
        queueFixture.release("/v1/commands/receipt"); await lateQueueRecovery.value
        expect(queueStore.lastReceipt?.isQueued == true && !queueStore.hasUnresolvedSend && queueStore.draft.isEmpty &&
               queueStore.lastError == "Keep this newer controller error" && queueFixture.sendCount == 4,
               "Delayed queue recovery resolves custody without erasing an unrelated newer error or retrying")

        queueFixture.dropSendResponse(false); queueFixture.hold("/v1/commands/sendPrompt")
        queueStore.draft = "Queue before switching provider"
        let crossProviderQueue = Task { await queueStore.sendDraft() }
        for _ in 0..<100 { if queueFixture.heldCount("/v1/commands/sendPrompt") == 1 { break }; try? await Task.sleep(nanoseconds:10_000_000) }
        queueStore.selectProvider(.claude); queueStore.draft = "Claude work must remain here"
        queueFixture.release("/v1/commands/sendPrompt"); await crossProviderQueue.value
        let queueRoute = DraftRoute(hostID:queueFixture.hostID,provider:"codex",chatID:queueFixture.codexChatID)
        expect(queueStore.selectedProvider == .claude && queueStore.draft == "Claude work must remain here" && queueStore.lastReceipt == nil &&
               queuePersistence.load().ledger.pendingSends[queueRoute.storageKey] == nil && queuePersistence.load().ledger.text(for:queueRoute).isEmpty,
               "Late queued acceptance reconciles its original Codex draft without modifying the newer Claude route")

        let actionsFixture = HTTPFixture(name:"fixture-actions"); try await actionsFixture.start(); defer { actionsFixture.stop() }
        let newAction = RemoteAction(id:"newChat",title:"New chat",group:"Navigate",detail:"Open a new empty chat.",requiresChat:false,changesChat:true)
        let priorAction = RemoteAction(id:"previousChat",title:"Previous native chat",group:"Navigate",detail:"Use the provider navigation.",requiresChat:false,changesChat:true)
        let focusAction = RemoteAction(id:"focusPrompt",title:"Focus prompt",group:"Compose",detail:"Focus the selected prompt.",requiresChat:true,changesChat:false)
        let attachAction = RemoteAction(id:"addAttachment",title:"Add attachment",group:"Compose",detail:"Choose a file.",requiresChat:true,changesChat:false,opensNavigation:true)
        var actionInfo = claudeInfo
        actionInfo.capabilities += ["newChat","previousChat","focusPrompt","addAttachment","menuNavigation"]
        actionInfo.actions = [newAction,priorAction,focusAction,attachAction]
        actionsFixture.setProviders([actionInfo,codexInfo]); try credentials.save(actionsFixture.token,for:actionsFixture.name)
        let originalChat = ChatRecord(id:"chat-\(actionsFixture.name)",title:"Original chat",state:"Idle")
        let otherChat = ChatRecord(id:"second-action-chat",title:"Second chat",state:"Idle")
        var actionSettings = LocalControllerSettings()
        actionSettings.hosts = [actionsFixture.host]; actionSettings.selectedHostID = actionsFixture.name
        actionSettings.selectedChats["\(actionsFixture.hostID).claude"] = originalChat
        actionSettings.selectedChats["\(actionsFixture.hostID).codex"] = .init(id:actionsFixture.codexChatID,title:"Codex fixture",state:"Idle")
        let actionPersistence = ControllerPersistence(directory:temporary.appendingPathComponent("actions"))
        try actionPersistence.save(actionSettings)
        let actionStore = ControllerStore(client:client,credentials:credentials,persistence:actionPersistence)
        await actionStore.refresh()
        let originalSlots = actionStore.profile.slots
        let quickSaved = await actionStore.saveQuickAction(0,actionID:"newChat")
        expect(quickSaved && actionStore.profile.quickActionIDs[0] == "newChat" && actionStore.profile.slots == originalSlots,
               "Quick-key mapping uses profile revisions while preserving all six chat slots")
        _ = await actionStore.saveSlot(.init(index:2,kind:"action",title:newAction.title,targetID:newAction.id))
        expect(actionStore.profile.quickActionIDs[0] == "newChat" && actionStore.profile.slots[2].targetID == "newChat",
               "Saving a slot preserves the independently editable quick-key row")
        actionStore.draft = "Original chat draft"
        await actionStore.runAction("focusPrompt")
        let focusPosted = actionsFixture.received.compactMap { try? JSONDecoder().decode(RemoteCommand.self,from:$0.2) }.last
        expect(focusPosted?.action == "focusPrompt" && focusPosted?.chatID == originalChat.id && focusPosted?.provider == "claude",
               "Advertised context action targets the selected provider and exact chat")
        await actionStore.openSlot(2)
        expect(actionStore.selectedChat == nil && !actionStore.canSend && !actionStore.canRunAction("focusPrompt"),
               "New-chat action without a verified resulting chat clears the old Send target")
        await actionStore.runAction("previousControllerChat")
        expect(actionStore.selectedChat?.id == originalChat.id && actionStore.draft == "Original chat draft",
               "Previous controller chat restores the exact visited route and its draft")
        await actionStore.selectChat(otherChat); actionStore.draft = "Second chat draft"
        await actionStore.runAction("previousControllerChat")
        expect(actionStore.selectedChat?.id == originalChat.id && actionStore.draft == "Original chat draft",
               "Controller history opens the previous chat without transferring the current draft")
        await actionStore.runAction("nextControllerChat")
        expect(actionStore.selectedChat?.id == otherChat.id && actionStore.draft == "Second chat draft",
               "Forward controller history restores the second chat's own draft")
        let historyRestore = ControllerStore(client:client,credentials:credentials,persistence:actionPersistence)
        await historyRestore.refresh()
        expect(historyRestore.canRunAction("previousControllerChat") && historyRestore.profile.quickActionIDs[0] == "newChat",
               "Visited-chat history and quick-key mappings survive reopening the app")
        let created = ChatRecord(id:"verified-created-chat",title:"Verified new chat",state:"Idle")
        actionsFixture.setActionResult("newChat",chat:created)
        await actionStore.runAction("newChat")
        expect(actionStore.selectedChat == created && actionStore.draft.isEmpty,
               "Verified activeChat receipt becomes the new target with its own draft")
        actionStore.draft = "Keep this new chat draft"
        actionsFixture.setActionResult("previousChat",status:"uncertain")
        await actionStore.runAction("previousChat")
        expect(actionStore.selectedChat == nil && !actionStore.canSend,
               "Uncertain native navigation cannot leave the previous chat eligible for Send")
        await actionStore.runAction("previousControllerChat")
        expect(actionStore.selectedChat?.id == created.id && actionStore.draft == "Keep this new chat draft",
               "Uncertain navigation retains the original target's draft for recovery")
        actionsFixture.dropAction("newChat",value:true); await actionStore.runAction("newChat"); actionsFixture.dropAction("newChat",value:false)
        expect(actionStore.selectedChat == nil && actionStore.lastReceipt?.status == "uncertain",
               "Lost navigation response also clears the old target without retrying the action")
        await actionStore.runAction("previousControllerChat")

        actionsFixture.setNavigation(true)
        await actionStore.runAction("addAttachment")
        expect(actionStore.requestedPanel == "navigate" && actionStore.navigation.active,
               "Opening an advertised menu action fetches a fresh navigation lease")
        let firstLease = actionStore.navigation.session
        await actionStore.navigate("menuNext")
        let navPosted = actionsFixture.received.compactMap { try? JSONDecoder().decode(RemoteCommand.self,from:$0.2) }.last
        expect(navPosted?.navigationSession == firstLease && navPosted?.chatID == created.id && actionsFixture.navigationCount == 1,
               "Navigation input carries its exact session, chat, and generation")
        actionsFixture.setActionResult("menuSelect",chat:created)
        await actionStore.navigate("menuSelect")
        expect(actionStore.selectedChat?.id == created.id && actionStore.draft == "Keep this new chat draft",
               "Verified same-chat file selection keeps the draft and target intact")
        actionsFixture.setActionResult("menuSelect")
        await actionStore.navigate("menuSelect")
        expect(actionStore.selectedChat == nil && !actionStore.canSend,
               "Menu Select without verified activeChat clears a possibly changed target")
        await actionStore.runAction("previousControllerChat"); await actionStore.refreshNavigation()
        let acceptedBefore = actionsFixture.navigationCount
        actionsFixture.setNavigation(true,rotate:true)
        await actionStore.navigate("menuSelect")
        expect(actionsFixture.navigationCount == acceptedBefore && actionStore.selectedChat == nil,
               "Rejected stale lease is never retried and cannot retain an unsafe Send target")
        actionsFixture.setNavigation(false); await actionStore.refreshNavigation()
        let requestsBeforeInactive = actionsFixture.received.count
        await actionStore.navigate("menuNext")
        expect(actionsFixture.received.count == requestsBeforeInactive, "Inactive navigation emits no input")
        await actionStore.runAction("previousControllerChat")
        actionsFixture.setNavigation(true); await actionStore.refreshNavigation(); await actionStore.navigate("menuHome")
        expect(actionStore.selectedChat == nil && !actionStore.navigation.active,
               "Closing menus returns home without retaining a hidden Send target")
        actionsFixture.setNavigation(true); actionsFixture.hold("/v1/navigation")
        let lateNavigation = Task { await actionStore.refreshNavigation() }
        for _ in 0..<100 {
            if actionsFixture.heldCount("/v1/navigation") == 1 { break }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        actionStore.selectProvider(.codex); actionStore.draft = "Codex route draft"
        actionsFixture.release("/v1/navigation"); await lateNavigation.value
        expect(!actionStore.navigation.active && actionStore.draft == "Codex route draft" && actionStore.selectedProvider == .codex,
               "A delayed menu lease cannot activate controls for a different provider")
        expect(actionStore.profile.quickActionIDs == ["newChat","previousControllerChat","keyboardShortcuts","artifacts"],
               "Quick keys remain separate per provider and Codex receives useful defaults")
        actionStore.selectProvider(.claude)
        for _ in 0..<100 {
            if actionStore.canRunAction("newChat") { break }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        actionsFixture.hold("/v1/commands/newChat")
        let lateNewChat = Task { await actionStore.runAction("newChat") }
        for _ in 0..<100 {
            if actionsFixture.heldCount("/v1/commands/newChat") == 1 { break }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        actionStore.selectProvider(.codex); actionStore.draft = "Codex draft after a different action"
        actionsFixture.release("/v1/commands/newChat"); _ = await lateNewChat.value
        expect(actionStore.selectedProvider == .codex && actionStore.selectedChat?.id == actionsFixture.codexChatID &&
               actionStore.draft == "Codex draft after a different action",
               "Late chat-changing result cannot select or clear a newer provider's route")
        let actionCommands = actionsFixture.received.compactMap { try? JSONDecoder().decode(RemoteCommand.self,from:$0.2) }
        expect(!actionCommands.contains(where:{$0.action == "sendPrompt" || $0.action == "previousControllerChat" || $0.action == "nextControllerChat"}),
               "Action browsing, history, and navigation never auto-send or post local-only action IDs")
        let demoStore = ControllerStore(demo:true)
        expect(demoStore.availableActions.contains(where:{$0.id == "modelAndEffort"}) && demoStore.isDemo,
               "Demo clearly exposes the expanded action catalog for visual review")
        await demoStore.refreshNavigation(); await demoStore.navigate("menuHome")
        expect(!demoStore.navigation.active && demoStore.selectedChat == nil, "Demo menu preview closes without remote input")
        demoStore.selectProvider(.codex)
        expect(demoStore.navigationOnly && demoStore.canDictate && !demoStore.canSend && demoStore.availableActions.contains(where:{$0.id == "newChat"}),
               "Demo Codex previews local draft capture and navigation without inventing remote Send support")

        // Regression: .task + scenePhase both reported active while the third Mac
        // was still answering. Polling cancellation must not cancel provisioning.
        let third = HTTPFixture(name:"fixture-c"); try await third.start(); defer { third.stop() }
        third.delayStatus(0.45)
        let setupDirectory = temporary.appendingPathComponent("setup", isDirectory:true)
        try FileManager.default.createDirectory(at: setupDirectory, withIntermediateDirectories:true)
        let setupURL = setupDirectory.appendingPathComponent("GenesisPairing.json")
        let payloads = [first,second,third].map { PairingPayload(v:1,name:$0.name,hostID:$0.hostID,baseURL:$0.baseURL,token:$0.token) }
        try JSONEncoder().encode(payloads).write(to:setupURL)
        let freshProvisioningStore = ControllerStore(client:client, credentials:FixtureCredentials(),
            persistence:ControllerPersistence(directory:temporary.appendingPathComponent("fresh-provisioning")),
            provisioningDirectory:setupDirectory)
        await freshProvisioningStore.importProvisioningIfPresent()
        expect(freshProvisioningStore.isPaired && freshProvisioningStore.selectedHost?.hostID == first.hostID &&
               freshProvisioningStore.hosts.count == 3 && !FileManager.default.fileExists(atPath:setupURL.path),
               "First private provisioning selects the first verified Mac and consumes the provisioning file")
        try JSONEncoder().encode(payloads).write(to:setupURL)
        var setupSettings = LocalControllerSettings()
        setupSettings.hosts = [first,second,third].map { .init(id:$0.name,name:$0.name,baseURL:$0.baseURL,hostID:nil) }
        setupSettings.selectedHostID = second.name
        let setupPersistence = ControllerPersistence(directory:temporary.appendingPathComponent("setup-state"))
        try setupPersistence.save(setupSettings)
        let setupVault = FixtureCredentials()
        let setupStore = ControllerStore(client:client,credentials:setupVault,persistence:setupPersistence,provisioningDirectory:setupDirectory)
        let priorThirdStatusReads = third.received.filter { $0.0.hasPrefix("GET /v1/status ") }.count
        setupStore.setForeground(true)
        for _ in 0..<50 {
            if third.received.filter({ $0.0.hasPrefix("GET /v1/status ") }).count > priorThirdStatusReads { break }
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        expect(!FileManager.default.fileExists(atPath:setupURL.path), "Plaintext provisioning removed before delayed third verification")
        setupStore.setForeground(true)
        setupStore.setForeground(true)
        setupStore.setForeground(false)
        setupStore.setForeground(true)
        for _ in 0..<80 {
            if setupStore.hosts.allSatisfy({$0.hostID != nil}) { break }
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        expect(setupStore.hosts.count == 3 && setupStore.hosts.allSatisfy({$0.hostID != nil}), "All three hosts survive duplicate active and background callbacks")
        expect(setupStore.selectedHostID == second.name, "Provisioning never changes the selected Mac")
        expect([first,second,third].allSatisfy({setupVault.token(for:$0.name) == $0.token}), "Only verified credentials reach the vault")
        let savedState = try Data(contentsOf:temporary.appendingPathComponent("setup-state/controller.json"))
        expect(!String(decoding:savedState,as:UTF8.self).contains(first.token), "Provisioning tokens never enter state JSON")
        setupStore.setForeground(false)

        // A failed candidate survives in memory, not a second plaintext file.
        third.delayStatus(0); third.setStatusUnavailable(true)
        try JSONEncoder().encode([payloads[2]]).write(to:setupURL)
        let retryPersistence = ControllerPersistence(directory:temporary.appendingPathComponent("retry-state"))
        try retryPersistence.save(setupSettings)
        let retryStore = ControllerStore(client:client,credentials:FixtureCredentials(),persistence:retryPersistence,provisioningDirectory:setupDirectory)
        retryStore.setForeground(true)
        for _ in 0..<50 {
            if retryStore.lastError != nil { break }
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        expect(retryStore.hosts.first(where:{$0.id == third.name})?.hostID == nil, "Unavailable host is not marked paired")
        expect(!FileManager.default.fileExists(atPath:setupURL.path), "Failed import does not recreate plaintext credentials")
        third.setStatusUnavailable(false)
        retryStore.setForeground(false); retryStore.setForeground(true)
        for _ in 0..<50 {
            if retryStore.hosts.first(where:{$0.id == third.name})?.hostID != nil { break }
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        expect(retryStore.hosts.first(where:{$0.id == third.name})?.hostID == third.hostID, "Failed verification retries from memory on next foreground")
        retryStore.setForeground(false)
        print("Remote HTTP + ControllerStore: \(count) integration checks passed")
    }
}
