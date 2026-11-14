import Foundation

@main struct RemoteCoreTests {
    static var checks = 0
    static func expect(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fatalError("FAIL: \(message)") }
    }
    static func pairingURL(_ payload: PairingPayload) throws -> URL {
        let encoded = try JSONEncoder().encode(payload).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "genesiscontroller://pair?data=\(encoded)")!
    }
    static func rejects(_ url: URL, localhost: Bool = false) -> Bool {
        (try? PairingPayload.decode(url, allowLocalhost: localhost)) == nil
    }
    static func main() throws {
        let valid = PairingPayload(v: 1, name: "Test Mac", hostID: "CFC99A4B-34EB-4E90-8413-97BE5866FE84",
            baseURL: "https://test-mac.example.ts.net:8451", token: String(repeating: "t", count: 64))
        let restored = try PairingPayload.decode(pairingURL(valid))
        expect(restored == valid, "Pairing round trip")
        var bad = valid; bad.v = 2
        expect(rejects(try pairingURL(bad)), "Unknown protocol rejected")
        bad = valid; bad.hostID = "not-a-host-uuid"
        expect(rejects(try pairingURL(bad)), "Host identity required")
        bad = valid; bad.token = "short"
        expect(rejects(try pairingURL(bad)), "Short pairing token rejected")
        for endpoint in ["http://test-mac.example.ts.net:8451", "https://user:pass@test-mac.example.ts.net", "https://test-mac.example.ts.net?token=leak", "https://test-mac.example.ts.net/path", "file:///etc/passwd", "https://test-mac.example.ts.net/#fragment"] {
            bad = valid; bad.baseURL = endpoint
            expect(rejects(try pairingURL(bad)), "Unsafe pairing endpoint rejected")
        }
        bad = valid; bad.baseURL = "http://127.0.0.1:18765"
        let development = try pairingURL(bad)
        expect(rejects(development), "HTTP localhost disabled by default")
        expect(!rejects(development, localhost: true), "Explicit development localhost allowed")
        expect(rejects(URL(string: "https://example.com/pair?data=abc")!), "Unrelated URL rejected")
        expect(rejects(URL(string: "genesiscontroller://pair?data=abc&data=def")!), "Ambiguous pairing fields rejected")

        var gate = SelectionGate()
        let firstHostRequest = gate.generation
        gate.advance()
        expect(!gate.accepts(firstHostRequest), "Old-host reply cannot update new host")
        let providerRequest = gate.generation
        gate.advance()
        expect(!gate.accepts(providerRequest), "Old-provider reply cannot update new provider")
        expect(gate.accepts(gate.generation), "Current response accepted")

        let mini1Claude = DraftRoute(hostID: "mini1-uuid", provider: "claude", chatID: "same-title-chat")
        let mini2Claude = DraftRoute(hostID: "mini2-uuid", provider: "claude", chatID: "same-title-chat")
        let mini1Codex = DraftRoute(hostID: "mini1-uuid", provider: "codex", chatID: "same-title-chat")
        var ledger = DraftLedger()
        ledger.set("First private draft", for: mini1Claude)
        ledger.set("Different host draft", for: mini2Claude)
        ledger.set("Different provider draft", for: mini1Codex)
        expect(ledger.text(for: mini1Claude) == "First private draft", "Host/provider draft isolation")
        expect(ledger.text(for: mini2Claude) == "Different host draft", "Other host draft preserved")
        expect(ledger.text(for: mini1Codex) == "Different provider draft", "Other provider draft preserved")

        let pending = PendingSend(commandID: UUID().uuidString, route: mini1Claude, textDigest: "fixture-digest", createdAt: Date())
        try ledger.begin(pending)
        var rejectedSecond = false
        do { try ledger.begin(PendingSend(commandID: UUID().uuidString, route: mini1Claude, textDigest: "another", createdAt: Date())) }
        catch { rejectedSecond = true }
        expect(rejectedSecond, "Second Send cannot bypass an unresolved Send")
        expect(ledger.pendingSends[mini1Claude.storageKey]?.commandID == pending.commandID, "Original command ID retained")
        ledger.resolve(.init(id: pending.commandID, status: "uncertain", message: "Network interrupted"), route: mini1Claude)
        expect(ledger.pendingSends[mini1Claude.storageKey] != nil, "Uncertain receipt cannot allow resend")
        ledger.resolve(.init(id: "another-id", status: "confirmed", message: "Wrong receipt"), route: mini1Claude)
        expect(ledger.pendingSends[mini1Claude.storageKey] != nil, "Unrelated receipt cannot clear pending Send")
        ledger.resolve(.init(id: pending.commandID, status: "confirmed", message: "Confirmed"), route: mini2Claude)
        expect(ledger.pendingSends[mini1Claude.storageKey] != nil, "Receipt cannot resolve another target's pending Send")
        let roundTrip = try JSONDecoder().decode(DraftLedger.self, from: JSONEncoder().encode(ledger))
        expect(roundTrip.pendingSends[mini1Claude.storageKey]?.commandID == pending.commandID, "Uncertain command survives app restart")
        ledger.resolve(.init(id: pending.commandID, status: "failed", message: "Rejected before action"), route: mini1Claude)
        expect(ledger.pendingSends[mini1Claude.storageKey] == nil, "Definite rejection unlocks deliberate retry")
        expect(ledger.text(for: mini1Claude) == "First private draft", "Failure does not discard draft")
        let queued = CommandReceipt(id:pending.commandID,status:"queued",message:"Queued for Codex")
        expect(queued.isAcceptedSend && !queued.isConfirmed && !queued.isUnresolved,
               "Queued custody completes Send without asserting delivery or successful navigation")
        expect(queued.deliveryNote?.contains("delivery not confirmed") == true && queued.statusIcon != "checkmark.circle.fill",
               "Queued presentation is distinguishable from confirmed delivery")
        try ledger.begin(pending)
        ledger.resolve(.init(id:"unrelated-queue",status:"queued",message:"Wrong request"),route:mini1Claude)
        expect(ledger.pendingSends[mini1Claude.storageKey] != nil, "An unrelated queue receipt cannot unlock this request")
        ledger.resolve(queued,route:mini1Claude)
        expect(ledger.pendingSends[mini1Claude.storageKey] == nil, "Accepted queue receipt resolves the original Send identity")
        let accepted = try JSONDecoder().decode(CommandReceipt.self,from:JSONEncoder().encode(queued))
        expect(accepted.isQueued && !accepted.isConfirmed, "Queue semantics survive wire encoding and receipt recovery")

        let ready = ProviderInfo(id: "claude", name: "Claude", installed: true, readiness: "ready", capabilities: ["openChat","sendPrompt"], reason: nil)
        expect(ready.supports("sendPrompt"), "Advertised ready capability allowed")
        expect(!ready.supports("nativeVoice"), "Native voice cannot be inferred from send support")
        var locked = ready; locked.readiness = "locked"
        expect(!locked.supports("sendPrompt"), "Reachable locked Mac not treated as controllable")
        locked.capabilities.append("artifacts")
        expect(locked.supports("artifacts"), "Registered artifacts remain viewable without an interactive desktop")
        let codex = ProviderInfo(id:"codex",name:"Codex",installed:true,readiness:"ready",capabilities:["openChat","artifacts"],reason:nil)
        expect(codex.navigationOnly && codex.supports("openChat"), "Codex navigation does not require sending capability")
        expect(codex.controllerShortcuts == [.dictate, .artifacts], "Codex offers phone-local dictation separately from remote actions")
        expect(codex.supportsPhoneDictation && !codex.capabilities.contains("sendPrompt"), "Local capture does not advertise or invent a host Send capability")
        expect(codex.availableActions.contains(where: { $0.id == "dictate" && $0.detail.contains("iPhone draft") }) &&
               !codex.availableActions.contains(where: { ["sendPrompt", "nativeVoice"].contains($0.id) }), "Codex mappings describe local capture and exclude unavailable delivery and voice")
        var noCodexChat = codex; noCodexChat.capabilities = ["artifacts"]
        expect(!noCodexChat.supportsPhoneDictation, "Codex capture requires existing-chat control, not just an installed app")
        var lockedCodex = codex; lockedCodex.readiness = "locked"
        expect(!lockedCodex.supportsPhoneDictation, "Locked Codex readiness cannot enable local capture for an unavailable route")
        var muse = codex; muse.id = "muse"
        expect(!muse.supportsPhoneDictation, "Codex local-capture exception cannot enable unimplemented Muse controls")
        expect(!codex.supports("sendPrompt") && !codex.supports("stop") && !codex.supports("nativeVoice"), "Navigation cannot infer Send, Stop, or Voice support")
        expect(ready.controllerShortcuts == [.dictate, .sendPrompt], "Claude Talk and Send remain available when advertised")
        expect(locked.controllerShortcuts == [.artifacts], "Locked readiness cannot offer remote interactive shortcuts")
        var launchOnly = ProviderInfo(id:"codex",name:"Codex",installed:true,readiness:"unavailable",capabilities:["newChat","openSettings","openSkills"],reason:"Saved chats unavailable")
        expect(["newChat","openSettings","openSkills"].allSatisfy(launchOnly.supports), "Explicit Codex launch routes work without saved-chat inventory")
        expect(!launchOnly.supports("sendPrompt") && !launchOnly.supports("openChat"), "Launch availability cannot invent sending or existing-chat control")
        launchOnly.readiness = "locked"
        expect(!launchOnly.supports("newChat") && !launchOnly.supports("openSettings"), "A locked Mac refuses advertised launch routes")
        launchOnly.readiness = "unavailable"; launchOnly.capabilities = []
        expect(!launchOnly.supports("newChat"), "Unadvertised Codex launch routes remain disabled")
        launchOnly.capabilities = ["newChat"]; launchOnly.installed = false
        expect(!launchOnly.supports("newChat"), "Missing Codex installation cannot enable a launch route")
        let localMic = DictationControlPresentation.make(provider:.codex,info:codex,paired:true,hasChat:true,busy:false,recording:false,finalizing:false)
        expect(localMic.label == "HOLD TO TALK" && localMic.icon == "mic", "Eligible Codex offers an actual local Hold-to-talk control")
        expect(localMic.summary?.contains("iPhone draft") == true && localMic.explanation?.contains("Nothing is sent") == true,
               "Local Codex mic clearly distinguishes capture from delivery")
        var queueCodex = codex; queueCodex.capabilities.append("sendPrompt")
        let queueMic = DictationControlPresentation.make(provider:.codex,info:queueCodex,paired:true,hasChat:true,busy:false,recording:false,finalizing:false)
        expect(queueMic.summary?.contains("queue") == true && queueCodex.availableActions.first(where:{$0.id == "sendPrompt"})?.detail.contains("Queue") == true,
               "Advertised Codex Send explains queue semantics in the mic and mapping catalog")
        let unavailableMic = DictationControlPresentation.make(provider:.codex,info:noCodexChat,paired:true,hasChat:true,busy:false,recording:false,finalizing:false)
        expect(unavailableMic.icon == "mic.slash", "Codex without an existing-chat route stays unavailable")
        let unpairedMic = DictationControlPresentation.make(provider:.codex,info:codex,paired:false,hasChat:true,busy:false,recording:false,finalizing:false)
        expect(unpairedMic.label == "PAIR YOUR MAC", "A restored Codex title cannot bypass missing pairing")
        let noCodexSelection = DictationControlPresentation.make(provider:.codex,info:codex,paired:true,hasChat:false,busy:false,recording:false,finalizing:false)
        expect(noCodexSelection.label == "CHOOSE A CHAT", "Codex local dictation needs a selected chat")
        let claudeMic = DictationControlPresentation.make(provider:.claude,info:ready,paired:true,hasChat:true,busy:false,recording:false,finalizing:false)
        expect(claudeMic.label == "HOLD TO TALK" && claudeMic.summary == nil && claudeMic.icon == "mic", "Ready Claude retains its working mic appearance")
        let noChatMic = DictationControlPresentation.make(provider:.claude,info:ready,paired:true,hasChat:false,busy:false,recording:false,finalizing:false)
        expect(noChatMic.label == "CHOOSE A CHAT", "Missing chat is distinguished from an unsupported provider")
        let busyMic = DictationControlPresentation.make(provider:.claude,info:ready,paired:true,hasChat:true,busy:true,recording:false,finalizing:false)
        expect(busyMic.label == "PLEASE WAIT", "Busy state does not falsely claim dictation is unimplemented")
        let lockedMic = DictationControlPresentation.make(provider:.claude,info:locked,paired:true,hasChat:true,busy:false,recording:false,finalizing:false)
        expect(lockedMic.label == "MAC LOCKED", "Locked Mac gives an actionable temporary reason")
        let recordingMic = DictationControlPresentation.make(provider:.claude,info:locked,paired:true,hasChat:true,busy:false,recording:true,finalizing:false)
        expect(recordingMic.label == "RELEASE TO REVIEW" && recordingMic.accessibilityLabel == "Stop dictation", "An active recording always retains its stop control")
        let previous = codex.availableActions.first { $0.id == "previousControllerChat" }
        expect(previous?.capability == "openChat" && previous?.requiresChat == false, "Controller history depends only on verified chat opening")
        var catalog = codex
        let newChat = RemoteAction(id:"newChat",title:"New chat",group:"Navigate",detail:"Open an empty chat without sending.",requiresChat:false,changesChat:true)
        catalog.actions = [newChat, newChat]
        expect(!catalog.availableActions.contains(where:{$0.id == "newChat"}), "Metadata alone cannot enable an unadvertised action")
        catalog.capabilities.append("newChat")
        expect(catalog.availableActions.filter({$0.id == "newChat"}).count == 1, "Catalog deduplicates advertised actions")
        expect(newChat.matches("navigate") && newChat.matches("empty") && !newChat.matches("delete"), "Action search includes category and details")
        let oldProfile = try JSONDecoder().decode(RemoteProfile.self,from:Data("{\"provider\":\"claude\",\"revision\":1,\"slots\":[]}".utf8))
        expect(oldProfile.quickActionIDs == ["sendPrompt","stop","nativeVoice","artifacts"], "Older Claude profiles retain their original quick-key layout")
        var codexProfile = RemoteProfile.empty(.codex)
        expect(codexProfile.quickActionIDs == ["newChat","previousControllerChat","keyboardShortcuts","artifacts"], "Unconfigured Codex quick keys favor useful supported navigation")
        codexProfile.quickActions = ["artifacts","newChat","goBack","keyboardShortcuts"]
        expect(codexProfile.quickActionIDs == codexProfile.quickActions, "Explicit quick-key assignments always override defaults")
        var history = ControllerChatHistory()
        for index in 0..<40 { history.record(.init(id:"chat-\(index)",title:"Chat \(index)",state:"Idle")) }
        expect(history.entries.count == 32 && history.entries.first?.id == "chat-8", "History keeps at most 32 visited chats")
        history.cursor = 29
        expect(history.destination(-1) == 28 && history.destination(1) == 30, "History supports backwards and forwards traversal")
        history.record(.init(id:"branch",title:"Branch",state:"Idle"))
        expect(history.entries.last?.id == "branch" && history.entries.count == 31 && history.destination(1) == nil, "Opening a different chat truncates the forward history branch")
        let command = RemoteCommand(id: pending.commandID, hostID: valid.hostID, provider: "claude", chatID: "chat1", action: "sendPrompt", text: "Reviewed draft", artifactID: nil, generation: 9)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as! [String: Any]
        expect(object["action"] as? String == "sendPrompt", "Wire command uses documented action")
        expect(object["hostID"] as? String == valid.hostID && object["chatID"] as? String == "chat1", "Send carries explicit host and chat")
        expect(object["generation"] as? Int == 9, "Command retains selection generation")
        print("Remote core: \(checks) checks passed")
    }
}
