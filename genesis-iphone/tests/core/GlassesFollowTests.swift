import Foundation

@main
struct GlassesFollowTests {
    @MainActor static func main() async throws {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            count += 1
        }
        func settle(_ publisher: GlassesFollowController) async {
            for _ in 0..<4 { await Task.yield(); await publisher.waitForWrites() }
        }
        func waitUntil(_ test: () -> Bool) async {
            for _ in 0..<100 { if test() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
            fatalError("Fixture timed out")
        }
        let host = RemoteHost(id: "fixture-mini", name: "Fixture Mini", baseURL: "https://fixture.invalid", hostID: UUID().uuidString)
        let otherHost = RemoteHost(id: "fixture-other", name: "Other Mini", baseURL: "https://other.invalid", hostID: UUID().uuidString)
        let fixture = GlassesFollowFixture()
        let publisher = GlassesFollowController(transport: fixture, sourceName: "iPad", automaticPolling: false)
        expect(!publisher.enabled && fixture.requests.isEmpty, "Follow requires explicit enable")
        publisher.enable(host: host, token: "fixture", provider: .codex, chatID: nil, slotIndex: nil, draft: "", recording: false)
        await settle(publisher)
        expect(publisher.enabled && !publisher.connecting && fixture.current(host).state?.view == .home, "Claim starts safely at Home without a confirmed chat")
        expect(fixture.requests.first?.1.takeover == false && fixture.requests.first?.1.sourceName == "iPad", "Normal claim cannot steal another controller")
        expect(fixture.requests.allSatisfy { ["claim", "update"].contains($0.1.operation) }, "Display enable performs no commands")
        expect(!publisher.acknowledged, "A Mac claim is not evidence of G2 rendering")

        publisher.confirmedChat(provider: .codex, chatID: "chat-a", slotIndex: 0, draft: "Saved draft")
        await settle(publisher)
        expect(fixture.current(host).state?.chatID == "chat-a" && fixture.current(host).state?.draft == "Saved draft", "Confirmed chat carries its route-specific draft")
        fixture.acknowledge(host, stale: true); await publisher.poll()
        expect(!publisher.acknowledged, "Stale feedback cannot acknowledge a new view")
        fixture.acknowledge(host, page: 1); await publisher.poll()
        expect(!publisher.acknowledged, "Wrong rendered page cannot acknowledge the current view")
        fixture.acknowledge(host); await publisher.poll()
        expect(publisher.acknowledged && publisher.pageLabel == "Page 1 of 3", "Current feedback displays actual page count")
        publisher.page(1); await settle(publisher)
        expect(publisher.desired.page == 1 && !publisher.acknowledged, "Page change waits for fresh display feedback")
        fixture.acknowledge(host); await publisher.poll()
        expect(publisher.acknowledged && publisher.pageLabel == "Page 2 of 3", "Page acknowledgment arrives through polling")
        var shrunk = fixture.current(host); shrunk.revision += 1; shrunk.state?.page = 0
        shrunk.feedback = .init(revision: shrunk.revision, pageCount: 1, renderedPage: 0, connected: true)
        fixture.snapshots[host.hostID!] = shrunk
        await publisher.poll()
        expect(publisher.desired.page == 0 && publisher.acknowledged && !publisher.canGoNext, "Shrinking reply clamps a page immediately without a heartbeat delay")

        publisher.updateDraft("First", recording: true)
        await settle(publisher)
        expect(fixture.current(host).state?.view == .draft && fixture.current(host).state?.recording == true, "Recording switches display to draft without Send")
        let beforeDrafts = fixture.requests.count
        publisher.updateDraft("First second", recording: true)
        publisher.updateDraft("First second third", recording: true)
        publisher.updateDraft("First second third fourth", recording: true)
        try await Task.sleep(nanoseconds: 300_000_000); await settle(publisher)
        expect(fixture.requests.count == beforeDrafts + 1 && fixture.current(host).state?.draft == "First second third fourth", "Partial speech bursts debounce to one latest snapshot")
        publisher.updateDraft(String(repeating: "🦉", count: 16_010), recording: false, debounce: false)
        await settle(publisher)
        expect(publisher.draftIsExcerpt && publisher.desired.draft.unicodeScalars.count == 16_000 && publisher.desired.valid, "Glasses excerpt is bounded by Unicode scalars without truncating native storage")
        publisher.show(.reply); await settle(publisher)
        let nonce = publisher.desired.refreshNonce
        publisher.sendChanged(.init(id: "receipt", status: "queued", message: "Queued"), draft: "")
        await settle(publisher)
        expect(publisher.desired.sendState == .queued && publisher.desired.refreshNonce == nonce + 1, "Queued Send remains queued and refreshes reply; no delivery claim")
        publisher.updateDraft("Typed but not sent", recording: false, debounce: false)
        publisher.show(.draft); await settle(publisher)
        expect(publisher.desired.sendState == .none && publisher.desired.draft == "Typed but not sent", "A typed new draft cannot inherit the previous Send receipt")
        expect(fixture.requests.allSatisfy { ["claim", "update"].contains($0.1.operation) }, "Dictation, paging and Send observation never dispatch a Mac command")

        fixture.holdOperation = "update"
        publisher.refresh()
        await waitUntil { !fixture.held.isEmpty }
        publisher.confirmedChat(provider: .codex, chatID: "chat-b", slotIndex: 1, draft: "B draft")
        publisher.updateDraft("B latest", recording: false, debounce: false)
        fixture.resumeWrites(); await settle(publisher)
        expect(fixture.current(host).state?.chatID == "chat-b" && fixture.current(host).state?.draft == "B latest", "Late response cannot restore earlier chat or draft")
        expect(fixture.maximumConcurrentWrites == 1, "All claim/update/release writes are serialized")
        fixture.acknowledge(host); await publisher.poll()
        expect(publisher.acknowledged, "New chat is acknowledged after its own feedback")
        fixture.snapshots[host.hostID!]?.feedback = nil
        await publisher.poll()
        expect(!publisher.acknowledged, "Server expiration clears old feedback even at an unchanged revision")
        let sequences = fixture.requests.compactMap { $0.1.sequence }
        expect(sequences == Array(1...sequences.count), "Every update uses a strictly increasing sequence")
        publisher.confirmedChat(provider: .codex, chatID: nil, slotIndex: nil, draft: "")
        await settle(publisher)
        expect(fixture.current(host).state?.view == .home && fixture.current(host).state?.chatID == nil && fixture.current(host).state?.draft == "", "Uncertain chat navigation immediately clears display target and draft")

        let second = GlassesFollowController(transport: fixture, sourceID: UUID().uuidString, sourceName: "iPhone", automaticPolling: false)
        second.enable(host: host, token: "fixture", provider: .claude, chatID: nil, slotIndex: nil, draft: "", recording: false)
        await settle(second)
        expect(!second.enabled && second.otherOwner == "iPad", "Other owner produces explicit takeover affordance")
        expect(fixture.current(host).sourceID == publisher.sourceID, "Conflict leaves existing owner in place")
        second.enable(host: host, token: "fixture", provider: .claude, chatID: nil, slotIndex: nil, draft: "", recording: false, takeover: true)
        await settle(second)
        expect(second.enabled && fixture.current(host).sourceID == second.sourceID, "Explicit takeover acquires a fresh lease")
        await publisher.poll(); await settle(publisher)
        expect(!publisher.enabled && publisher.otherOwner == "iPhone" && fixture.current(host).sourceID == second.sourceID, "Old owner notices takeover and cannot release new owner's lease")
        second.stop(); await settle(second)
        expect(!fixture.current(host).active, "Disabling Follow clears Mac display state")

        let lateFixture = GlassesFollowFixture(); lateFixture.holdOperation = "claim"
        let late = GlassesFollowController(transport: lateFixture, sourceName: "iPad", automaticPolling: false)
        late.enable(host: host, token: "fixture", provider: .codex, chatID: "old", slotIndex: 0, draft: "Old private draft", recording: false)
        await waitUntil { !lateFixture.held.isEmpty }
        late.stop("Host changed")
        late.enable(host: otherHost, token: "fixture-other", provider: .claude, chatID: "new", slotIndex: 1, draft: "New draft", recording: false)
        lateFixture.resumeWrites(); await settle(late)
        expect(!lateFixture.current(host).active && lateFixture.current(otherHost).state?.chatID == "new", "Late claim after host switch releases exact old lease and preserves new host")
        expect(late.snapshot?.hostID == otherHost.hostID && late.desired.provider == .claude, "Generation prevents late claim UI restoration")
        lateFixture.holdReads = true
        let stalePoll = Task { await late.poll() }
        await waitUntil { !lateFixture.heldReads.isEmpty }
        late.stop("Background")
        lateFixture.resumeReads(); await stalePoll.value; await settle(late)
        expect(!late.enabled && late.snapshot == nil && late.desired.draft.isEmpty, "In-flight read cannot restore state after background release")

        let old = GlassesFollowFixture(); old.errorCode = 404
        let unsupported = GlassesFollowController(transport: old, automaticPolling: false)
        unsupported.enable(host: host, token: "fixture", provider: .codex, chatID: nil, slotIndex: nil, draft: "", recording: false)
        await settle(unsupported)
        expect(!unsupported.enabled && unsupported.unsupported && unsupported.message.contains("Other controller features still work"), "Older companion is explained without disabling native controller")

        let expiryFixture = GlassesFollowFixture()
        let expired = GlassesFollowController(transport: expiryFixture, automaticPolling: false)
        expired.enable(host: host, token: "fixture", provider: .codex, chatID: nil, slotIndex: nil, draft: "", recording: false)
        await settle(expired)
        expiryFixture.snapshots[host.hostID!]?.expiresAt = "2020-01-01T00:00:00Z"
        expired.heartbeat(); await settle(expired)
        expect(!expired.enabled && expiryFixture.requests.filter { $0.1.operation == "claim" }.count == 1, "Expired lease stops and never silently reclaims")

        let demoFixture = GlassesFollowFixture()
        let preview = GlassesFollowController(transport: demoFixture, automaticPolling: false, previewOnly: true)
        preview.startPreview(provider: .claude, chatID: "demo", draft: "Preview draft")
        preview.show(.draft); preview.page(1); preview.refresh(); preview.heartbeat()
        expect(preview.acknowledged && preview.desired.page == 1 && demoFixture.requests.isEmpty, "Launch-only preview exercises UI without any transport writes")
        let regular = GlassesFollowController(transport: demoFixture, automaticPolling: false)
        regular.startPreview(provider: .claude, chatID: "demo", draft: "No")
        expect(!regular.enabled, "Preview is inaccessible on a normal publisher")
        print("Glasses follow: \(count) checks passed")
    }
}
