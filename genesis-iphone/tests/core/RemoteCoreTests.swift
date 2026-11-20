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
    static func dialTrackingChecks() {
        // A face of radius 50: turns count in full from 35 out, and the
        // middle 15 swipes. Thirty-two degree steps click over at 20.8.
        let center = CGPoint(x: 50, y: 50)
        func rim(_ degrees: Double, at distance: Double = 46) -> CGPoint {
            let angle = degrees * .pi / 180
            return CGPoint(x: center.x + distance * cos(angle), y: center.y + distance * sin(angle))
        }

        var dial = DialTracking(start: rim(165), center: center, radius: 50)
        expect(dial.move(to: rim(195)) == 1 && abs(dial.degrees - 30) < 0.01,
               "A clockwise turn across the angle seam advances one step")
        expect(dial.move(to: rim(251)) == 2 && dial.steps == 3,
               "Continuing the same drag advances only the new steps")
        expect(dial.move(to: rim(190)) == -2 && dial.steps == 1,
               "Reversing a turn moves back across the same steps")
        expect(dial.move(to: center) == 0 && dial.move(to: rim(10)) == 0,
               "Crossing the center cannot jump the selection")
        expect(dial.move(to: rim(-20)) == -1 && dial.steps == 0,
               "Circular tracking resumes after crossing the center")

        var swipe = DialTracking(start: center, center: center, radius: 50)
        expect(swipe.move(to: CGPoint(x: 74, y: 57)) == 1, "A center swipe advances the dial")
        expect(swipe.move(to: CGPoint(x: 22, y: 73)) == -2 && swipe.steps == -1,
               "An off-axis movement does not change the swipe direction")

        // A finger wobbling around the point where the dial clicked over must not flicker.
        var resting = DialTracking(start: rim(0), center: center, radius: 50)
        expect(resting.move(to: rim(20)) == 0 && resting.move(to: rim(22)) == 1, "The dial clicks over past the detent hold")
        var flicker = 0
        for wobble in [19.0, 23, 17, 22, 14, 30, 12, 24] { flicker += abs(resting.move(to: rim(wobble))) }
        expect(flicker == 0 && resting.steps == 1, "Wobbling around the click point neither steps back nor repeats")
        expect(resting.move(to: rim(10)) == -1 && resting.steps == 0, "Clearly retreating steps back")
        var reverse = DialTracking(start: rim(0), center: center, radius: 50)
        expect(reverse.move(to: rim(-20)) == 0 && reverse.move(to: rim(-22)) == -1, "The first step takes the same turn in either direction")
        flicker = 0
        for wobble in [-19.0, -23, -14, -30, -12, -24] { flicker += abs(reverse.move(to: rim(wobble))) }
        expect(flicker == 0 && reverse.steps == -1, "Counterclockwise wobble is just as steady")

        // Near the hub a slip of the finger sweeps a big angle; it counts for less.
        var hub = DialTracking(start: rim(0, at: 17.5), center: center, radius: 50)
        expect(hub.move(to: rim(30, at: 17.5)) == 0 && abs(hub.degrees - 15) < 0.01, "The same sweep at half the leverage radius turns half as far")
        expect(hub.move(to: rim(64, at: 17.5)) == 1, "A larger sweep near the hub still turns the dial")

        // A straight swipe across the knob goes the way the finger went,
        // whether it passes just above the center or just below it.
        for y in [44.0, 50, 56] {
            var across = DialTracking(start: CGPoint(x: 8, y: y), center: center, radius: 50)
            var total = 0
            for x in stride(from: 14.0, through: 92, by: 6) { total += across.move(to: CGPoint(x: x, y: y)) }
            expect(total == 2 && across.steps == 2, "A swipe to the right across the knob steps forward at height \(y)")
            var back = DialTracking(start: CGPoint(x: 92, y: y), center: center, radius: 50)
            total = 0
            for x in stride(from: 86.0, through: 8, by: -6) { total += back.move(to: CGPoint(x: x, y: y)) }
            expect(total == -2, "A swipe to the left across the knob steps back at height \(y)")
        }
        var upward = DialTracking(start: CGPoint(x: 53, y: 90), center: center, radius: 50)
        var climbed = 0
        for y in stride(from: 84.0, through: 10, by: -6) { climbed += upward.move(to: CGPoint(x: 53, y: y)) }
        expect(climbed == 2, "A swipe up across the knob steps forward")
        // A stroke along the edge is a turn, even when it is a straight line.
        var edge = DialTracking(start: CGPoint(x: 30, y: 12), center: center, radius: 50)
        expect(edge.move(to: CGPoint(x: 70, y: 12)) == 2 && abs(edge.degrees - 55.5) < 0.5, "A stroke across the top of the knob turns it clockwise")
        var under = DialTracking(start: CGPoint(x: 30, y: 88), center: center, radius: 50)
        expect(under.move(to: CGPoint(x: 70, y: 88)) == -2, "The same stroke under the knob turns it the other way, as a real knob would")
        var thumb = DialTracking(start: center, center: center, radius: 21, degreesPerStep: 60, swipeDistance: 28)
        expect(thumb.move(to: CGPoint(x: 67, y: 50)) == 0 && thumb.move(to: CGPoint(x: 70, y: 50)) == 1 && thumb.move(to: CGPoint(x: 94, y: 50)) == 0,
               "On a small knob a swipe moves one slot per thumb-sized distance")
        var undecided = DialTracking(start: rim(0), center: center, radius: 50)
        expect(undecided.move(to: CGPoint(x: 96, y: 53)) == 0 && undecided.degrees == 0, "A stroke too short to read does nothing yet")

        // The chat dial uses one detent per slot light.
        var slots = DialTracking(start: rim(-90), center: center, radius: 50, degreesPerStep: 60)
        expect(slots.move(to: rim(-52)) == 0 && slots.move(to: rim(-50)) == 1, "A sixty-degree dial clicks over at thirty-nine degrees")
        var passed = 1
        for angle in stride(from: -30.0, through: 270, by: 30) { passed += slots.move(to: rim(angle)) }
        expect(passed == 6 && slots.steps == 6, "A full turn passes all six slots")
        // Circling steadily around the face clicks at even intervals, one slot at a time.
        var circle = DialTracking(start: rim(0, at: 30), center: center, radius: 50, degreesPerStep: 60)
        var clicks: [Double] = []
        for angle in stride(from: 3.0, through: 720, by: 3) {
            let change = circle.move(to: rim(angle, at: angle.truncatingRemainder(dividingBy: 90) < 45 ? 30 : 38))
            expect(abs(change) <= 1, "A steady circle never skips a slot")
            if change != 0 { clicks.append(circle.degrees) }
        }
        let gaps = zip(clicks.dropFirst(), clicks).map { $0 - $1 }
        expect(clicks.count >= 6 && gaps.allSatisfy { abs($0 - 60) <= 3 }, "A steady circle clicks every sixty degrees of turn")
        var slotSwipe = DialTracking(start: center, center: center, radius: 50, degreesPerStep: 60)
        expect(slotSwipe.move(to: CGPoint(x: 74, y: 52)) == 1, "A center swipe covers the same distance per step on any dial")
        var press = DialTracking(start: CGPoint(x: 52, y: 51), center: center, radius: 50)
        _ = press.move(to: CGPoint(x: 58, y: 47))
        expect(press.steps == 0 && abs(press.travel - hypot(6, 4)) < 0.001, "Travel records how far an unsteady press wandered")
    }

    static func deferredTapChecks() {
        let pressed = Date(timeIntervalSinceReferenceDate: 1_000)
        let tap = DeferredTap(target: .slot(2), pressed: pressed)
        expect(tap.shouldRun(now: pressed.addingTimeInterval(1.5), previousSucceeded: true), "A key held for a finished command runs")
        expect(!tap.shouldRun(now: pressed.addingTimeInterval(1.5), previousSucceeded: false), "A key never follows a command that failed")
        expect(!tap.shouldRun(now: pressed.addingTimeInterval(DeferredTap.patience + 0.1), previousSucceeded: true), "A key held too long is dropped")
        expect(!tap.shouldRun(now: pressed.addingTimeInterval(-1), previousSucceeded: true), "A clock that moved backward drops the key")
        expect(!DeferredTap.mayWait("sendPrompt") && !DeferredTap.mayWait("dictate"), "Send and dictation never wait")
        expect(DeferredTap.mayWait("permissionOptions") && DeferredTap.mayWait("stop"), "Other actions may wait their turn")
        expect(DeferredTap(target: .action("stop"), pressed: pressed).target != .action("modelAndEffort"), "A waiting key is identified by its action")
    }

    static func glassesFeatureChecks() {
        func fresh() -> UserDefaults {
            let name = "genesis.glasses.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return defaults
        }
        let newInstall = fresh()
        GlassesFeature.prepare(newInstall, demo: false, hasPairedMac: false)
        expect(newInstall.object(forKey: GlassesFeature.key) as? Bool == false, "A fresh install starts with the glasses controls hidden")
        GlassesFeature.prepare(newInstall, demo: false, hasPairedMac: true)
        expect(newInstall.bool(forKey: GlassesFeature.key) == false, "Pairing later does not turn the glasses controls on by itself")
        let upgrade = fresh()
        GlassesFeature.prepare(upgrade, demo: false, hasPairedMac: true)
        expect(upgrade.bool(forKey: GlassesFeature.key), "An install that already has a Mac keeps the glasses controls it had")
        upgrade.set(false, forKey: GlassesFeature.key)
        GlassesFeature.prepare(upgrade, demo: false, hasPairedMac: true)
        expect(upgrade.bool(forKey: GlassesFeature.key) == false, "A choice already made is kept at the next launch")
        let demo = fresh()
        demo.set(false, forKey: GlassesFeature.demoKey)
        GlassesFeature.prepare(demo, demo: true, hasPairedMac: false)
        expect(demo.bool(forKey: GlassesFeature.demoKey) && demo.object(forKey: GlassesFeature.key) == nil, "The demo shows the glasses controls at every launch and leaves the real setting alone")
        expect(GlassesFeature.storageKey(demo: true) != GlassesFeature.storageKey(demo: false), "The demo and the real app keep separate settings")
    }

    static func wifiPairingChecks() throws {
        let pin = String(repeating: "A", count: 42) + "_"
        let wifi = PairingPayload(v: 2, name: "Test Mac", hostID: "CFC99A4B-34EB-4E90-8413-97BE5866FE84",
            baseURL: "https://test-mac.local:18766", token: String(repeating: "t", count: 64),
            lanURL: "https://test-mac.local:18766", pin: pin)
        expect((try? PairingPayload.decode(pairingURL(wifi))) == wifi, "Wi-Fi pairing round trip")
        var bad = wifi; bad.pin = nil
        expect(rejects(try pairingURL(bad)), "Wi-Fi address without a fingerprint rejected")
        bad = wifi; bad.lanURL = nil
        expect(rejects(try pairingURL(bad)), "Fingerprint without a Wi-Fi address rejected")
        for broken in ["short", String(repeating: "A", count: 43).replacingOccurrences(of: "A", with: "+", options: [], range: nil), String(repeating: "A", count: 44)] {
            bad = wifi; bad.pin = broken
            expect(rejects(try pairingURL(bad)), "Malformed fingerprint rejected")
        }
        bad = wifi; bad.lanURL = "http://test-mac.local:18766"
        expect(rejects(try pairingURL(bad)), "Unencrypted Wi-Fi address rejected")

        // Wi-Fi only, Tailscale only, and both.
        let lanOnly = RemoteHost(id: "m", name: "Mac", baseURL: "https://test-mac.local:18766", hostID: nil, lanURL: "https://test-mac.local:18766", pin: pin)
        expect(lanOnly.routes.map(\.route) == [.wifi], "A Wi-Fi-only Mac has one route")
        let both = RemoteHost(id: "m", name: "Mac", baseURL: "https://mac.tailnet.ts.net:8451", hostID: nil, lanURL: "https://test-mac.local:18766", pin: pin)
        expect(both.routes.map(\.route) == [.wifi, .tailnet], "Wi-Fi is tried before Tailscale")
        let tailnet = RemoteHost(id: "m", name: "Mac", baseURL: "https://mac.tailnet.ts.net:8451", hostID: nil)
        expect(tailnet.routes.map(\.route) == [.tailnet], "A Mac paired before Wi-Fi pairing keeps Tailscale")
        let unpinned = RemoteHost(id: "m", name: "Mac", baseURL: "https://mac.tailnet.ts.net:8451", hostID: nil, lanURL: "https://test-mac.local:18766")
        expect(unpinned.routes.map(\.route) == [.tailnet], "A Wi-Fi address without a fingerprint is never used")
        // Older saved settings, without the new fields, still load.
        let old = try JSONDecoder().decode(RemoteHost.self, from: Data(#"{"id":"m","name":"Mac","baseURL":"https://mac.tailnet.ts.net:8451"}"#.utf8))
        expect(old.lanURL == nil && old.pin == nil, "Saved hosts from earlier versions decode")
    }

    static func main() throws {
        try wifiPairingChecks()
        dialTrackingChecks()
        deferredTapChecks()
        glassesFeatureChecks()
        let valid = PairingPayload(v: 1, name: "Test Mac", hostID: "CFC99A4B-34EB-4E90-8413-97BE5866FE84",
            baseURL: "https://test-mac.example.ts.net:8451", token: String(repeating: "t", count: 64))
        let restored = try PairingPayload.decode(pairingURL(valid))
        expect(restored == valid, "Pairing round trip")
        var codeBased = valid; codeBased.v = 2
        expect((try? PairingPayload.decode(pairingURL(codeBased))) == codeBased, "Single-use code pairing (version 2) round trip")
        var bad = valid; bad.v = 3
        expect(rejects(try pairingURL(bad)), "Unknown protocol rejected")
        bad.v = 0
        expect(rejects(try pairingURL(bad)), "Protocol version zero rejected")
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
        // Replacing text on the Mac is only ever asked for explicitly.
        let plainSend = RemoteCommand(id: "1", hostID: "h", provider: "claude", chatID: "c", action: "sendPrompt", text: "hi", artifactID: nil, generation: 0)
        let plainJSON = String(data: try JSONEncoder().encode(plainSend), encoding: .utf8) ?? ""
        expect(!plainJSON.contains("replaceDraft"), "An ordinary Send never mentions replacing the Mac's draft")
        var replacing = plainSend; replacing.replaceDraft = true
        expect((String(data: try JSONEncoder().encode(replacing), encoding: .utf8) ?? "").contains("\"replaceDraft\":true"), "A replace is sent only when set")
        let blockedReceipt = try JSONDecoder().decode(CommandReceipt.self, from: Data(#"{"id":"1","status":"failed","message":"m","blocker":"macDraft"}"#.utf8))
        expect(blockedReceipt.blocker == "macDraft" && !blockedReceipt.isConfirmed, "The Mac can say a Send was held back by text in its message box")
        let olderReceipt = try JSONDecoder().decode(CommandReceipt.self, from: Data(#"{"id":"1","status":"confirmed","message":"m"}"#.utf8))
        expect(olderReceipt.blocker == nil, "A companion that does not send the field still decodes")

        // What a chat is doing, from the state its app reports.
        for (state, expected) in [("Working", ChatActivity.thinking), ("Running", .thinking), ("Unread", .complete),
                                  ("Awaiting input", .needsInput), ("Needs input", .needsInput), ("Something went wrong", .error),
                                  ("Idle", .idle), ("Open", .idle), ("Current", .idle), ("Saved", .idle)] {
            expect(ChatActivity(state: state) == expected, "\(state) is \(expected.rawValue)")
            expect(ChatRecord(id: "x", title: "t", state: state).activity == expected, "A chat reads its own state as \(expected.rawValue)")
        }
        expect(ChatActivity(state: "  WORKING ") == .thinking, "Case and spacing do not matter")
        expect(ChatActivity(state: "") == .idle && ChatActivity(state: "Something new") == .idle, "A state the app does not know is idle, never a claim of work")
        expect(Set(ChatActivity.allCases.map(\.label)).count == 5 && ChatActivity.allCases.allSatisfy { !$0.meaning.isEmpty }, "Each light has its own name and meaning")
        expect(ChatActivity.needsInput.wantsAttention && ChatActivity.error.wantsAttention && !ChatActivity.thinking.wantsAttention && !ChatActivity.complete.wantsAttention && !ChatActivity.idle.wantsAttention,
               "Only waiting and errors ask for attention")

        // Restarting an app's background service is offered only while that service cannot be reached.
        var service = ProviderInfo(id: "codex", name: "Codex", installed: true, readiness: "unavailable", capabilities: ["restartService"], reason: nil)
        expect(service.supports("restartService"), "An unreachable service can be restarted when the Mac offers it")
        expect(!service.supports("openChat") && !service.supports("sendPrompt"), "Offering a restart enables nothing else")
        service.readiness = "ready"
        expect(!service.supports("restartService"), "A service that answers is never restarted from the phone")
        service.readiness = "locked"
        expect(!service.supports("restartService"), "A locked Mac does not restart a service")
        service.readiness = "unavailable"; service.installed = false
        expect(!service.supports("restartService"), "A missing app has no service to restart")
        service.installed = true; service.capabilities = []
        expect(!service.supports("restartService"), "The phone never offers a restart the Mac did not offer")
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
        expect(lockedMic.label == "HOLD TO TALK" && lockedMic.summary?.contains("locked") == true && lockedMic.summary?.contains("send later") == true,
               "With a chat chosen, a locked Mac still lets you record a draft, and says it will be sent later")
        let lockedNoChat = DictationControlPresentation.make(provider:.claude,info:locked,paired:true,hasChat:false,busy:false,recording:false,finalizing:false)
        expect(lockedNoChat.label == "MAC LOCKED", "Without a chat, a locked Mac gives its actionable temporary reason")
        let offlineMic = DictationControlPresentation.make(provider:.claude,info:nil,paired:true,hasChat:true,busy:false,recording:false,finalizing:false)
        expect(offlineMic.label == "HOLD TO TALK" && offlineMic.summary?.contains("isn’t answering") == true, "An unreachable Mac does not stop a draft being recorded")
        let offlineNoChat = DictationControlPresentation.make(provider:.claude,info:nil,paired:true,hasChat:false,busy:false,recording:false,finalizing:false)
        expect(offlineNoChat.label == "NOT CONNECTED", "Without a chat there is nothing to draft for")
        var closedInfo = ready; closedInfo.readiness = "closed"
        expect(DictationControlPresentation.make(provider:.muse,info:closedInfo,paired:true,hasChat:true,busy:false,recording:false,finalizing:false).label == "HOLD TO TALK",
               "A closed app does not stop a draft either")
        var setupInfo = ready; setupInfo.readiness = "needsAccessibility"
        expect(DictationControlPresentation.make(provider:.claude,info:setupInfo,paired:true,hasChat:true,busy:false,recording:false,finalizing:false).label == "SETUP NEEDED",
               "A Mac that was never set up still says so")
        let unpairedDraftMic = DictationControlPresentation.make(provider:.claude,info:nil,paired:false,hasChat:true,busy:false,recording:false,finalizing:false)
        expect(unpairedDraftMic.label == "PAIR YOUR MAC", "An unpaired device is told to pair first")
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
        let museProfile = RemoteProfile(provider: "muse", revision: 0, slots: [])
        expect(museProfile.quickActionIDs == ["sendPrompt","newChat","nativeVoice","artifacts"] && !museProfile.quickActionIDs.contains("stop"),
               "Muse's default keys leave out Stop, which Muse cannot do, for a new side chat")
        var museSaved = museProfile; museSaved.quickActions = ["sendPrompt","stop","nativeVoice","artifacts"]
        expect(museSaved.quickActionIDs[1] == "stop", "Keys someone chose are kept as they chose them")
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
        // Connection trouble is explained as what to do, not as a system error.
        let denied = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
            "_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited), interface: en0"])
        expect(ConnectionHelp.problem(denied) == .localNetworkBlocked, "A denied Local Network permission is recognised from the path")
        expect(ConnectionHelp.fixedInSettings(.localNetworkBlocked), "Its fix is in Settings")
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "kNWErrorDomainPOSIX", code: 50, userInfo: [NSLocalizedDescriptionKey: "Local network prohibited"])])
        expect(ConnectionHelp.problem(underlying) == .localNetworkBlocked, "It is recognised in an underlying error too")
        expect(ConnectionHelp.problem(URLError(.notConnectedToInternet)) == .phoneOffline, "No network at all")
        expect(ConnectionHelp.problem(URLError(.timedOut)) == .macUnreachable && ConnectionHelp.problem(URLError(.cannotFindHost)) == .macUnreachable,
               "A Mac that does not answer")
        expect(!ConnectionHelp.fixedInSettings(.macUnreachable), "An unreachable Mac is not fixed in the phone's Settings")
        expect(ConnectionHelp.problem(URLError(.serverCertificateUntrusted)) == .untrustedConnection, "A certificate this app does not trust")
        expect(ConnectionHelp.problem(URLError(.cancelled)) == nil, "A cancelled request is not a connection problem")
        expect(ConnectionHelp.problem(RemoteError.invalidPairing) == nil, "The app's own errors keep their wording")
        expect(ConnectionHelp.describe(RemoteError.invalidPairing, mac: nil) == RemoteError.invalidPairing.localizedDescription, "and are shown as they are")
        let unreachable = ConnectionHelp.describe(URLError(.timedOut), mac: "Mac mini")
        expect(unreachable.hasPrefix("“Mac mini” didn’t answer") && unreachable.contains("same Wi-Fi"), "The message names the Mac and the likely fix")
        expect(ConnectionHelp.describe(URLError(.timedOut), mac: nil).hasPrefix("Your Mac didn’t answer"), "Without a name it says your Mac")
        expect(!ConnectionHelp.describe(URLError(.timedOut), mac: nil).contains("timed out"), "The system wording is not shown")
        print("Remote core: \(checks) checks passed")
    }
}
