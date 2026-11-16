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
        let publisher = GlassesFollowController(transport: fixture, sourceName: "iPad", automaticPolling: false, preferences: nil)
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

        let second = GlassesFollowController(transport: fixture, sourceID: UUID().uuidString, sourceName: "iPhone", automaticPolling: false, preferences: nil)
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
        let late = GlassesFollowController(transport: lateFixture, sourceName: "iPad", automaticPolling: false, preferences: nil)
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
        let unsupported = GlassesFollowController(transport: old, automaticPolling: false, preferences: nil)
        unsupported.enable(host: host, token: "fixture", provider: .codex, chatID: nil, slotIndex: nil, draft: "", recording: false)
        await settle(unsupported)
        expect(!unsupported.enabled && unsupported.unsupported && unsupported.message.contains("Other controller features still work"), "Older companion is explained without disabling native controller")

        let expiryFixture = GlassesFollowFixture()
        let expired = GlassesFollowController(transport: expiryFixture, automaticPolling: false, preferences: nil)
        expired.enable(host: host, token: "fixture", provider: .codex, chatID: nil, slotIndex: nil, draft: "", recording: false)
        await settle(expired)
        expiryFixture.snapshots[host.hostID!]?.expiresAt = "2020-01-01T00:00:00Z"
        expired.heartbeat(); await settle(expired)
        expect(!expired.enabled && expiryFixture.requests.filter { $0.1.operation == "claim" }.count == 1, "Expired lease stops and never silently reclaims")

        let demoFixture = GlassesFollowFixture()
        let preview = GlassesFollowController(transport: demoFixture, automaticPolling: false, previewOnly: true, preferences: nil)
        preview.startPreview(provider: .claude, chatID: "demo", draft: "Preview draft")
        preview.show(.draft); preview.page(1); preview.refresh(); preview.heartbeat()
        expect(preview.acknowledged && preview.desired.page == 1 && demoFixture.requests.isEmpty, "Launch-only preview exercises UI without any transport writes")
        let regular = GlassesFollowController(transport: demoFixture, automaticPolling: false, preferences: nil)
        regular.startPreview(provider: .claude, chatID: "demo", draft: "No")
        expect(!regular.enabled, "Preview is inaccessible on a normal publisher")

        // Keep-reading is explicit, capability-gated and never a Send command.
        let prefs = UserDefaults(suiteName: "genesis-reading-tests-\(UUID().uuidString)")!
        let key = "genesis.glasses.keep-reading-when-locked.v1"
        defer { prefs.removeObject(forKey: key) }
        let readingFixture = GlassesFollowFixture()
        let reading = GlassesFollowController(transport: readingFixture, automaticPolling: false, preferences: prefs)
        expect(!reading.keepReadingPreference, "Keep reading defaults off")
        reading.enable(host: host, token: "fixture", provider: .claude, chatID: "confirmed", slotIndex: 0, draft: "Private draft", recording: false)
        await settle(reading)
        readingFixture.holdOperation = "setReading"
        reading.setKeepReading(true)
        await waitUntil { !readingFixture.held.isEmpty }
        expect(reading.readingChangePending && !reading.readingArmed && !reading.readingMessage.contains("Ready:"), "Toggle waits for arm ACK before claiming readiness")
        readingFixture.resumeWrites(); await settle(reading)
        expect(reading.readingArmed && prefs.bool(forKey: key), "Explicit preference is persisted and armed only after ACK")
        let oldLease = readingFixture.current(host).leaseID
        reading.enterBackground(); reading.enterBackground(); await settle(reading)
        let parked = readingFixture.current(host)
        expect(reading.enabled && reading.suspended && parked.readingOnly == true && parked.state?.draft == "" && parked.state?.view == .reply && parked.state?.recording == false && parked.state?.sendState == GlassesSendState.none, "Background parks a sanitized reply while retaining ownership")
        expect(readingFixture.requests.filter { $0.1.operation == "park" }.count == 1, "Duplicate background does not extend or repeat parking")
        let countWhileParked = readingFixture.requests.count
        reading.updateDraft("Must not leak", recording: true, debounce: false); reading.heartbeat(); reading.refresh()
        await settle(reading)
        expect(readingFixture.requests.count == countWhileParked, "Parked controller cannot publish draft or heartbeat")
        reading.returnToForeground { "Private draft restored" }; reading.returnToForeground { "Duplicate" }
        await settle(reading)
        let resumed = readingFixture.current(host)
        expect(reading.controlsAvailable && resumed.leaseID != oldLease && resumed.readingOnly == false && resumed.state?.draft == "Private draft restored", "Foreground resumes exact owner with new fencing lease before restoring actual draft")
        expect(readingFixture.requests.filter { $0.1.operation == "resume" }.count == 1 && readingFixture.sequences[resumed.leaseID!] == 1, "Duplicate foreground does not replay resume and new sequence starts at one")
        expect(readingFixture.requests.allSatisfy { ["claim", "update", "setReading", "park", "resume"].contains($0.1.operation) }, "Reading lifecycle has no Send or desktop action effects")

        // Rapid toggles retain the last explicit choice through an in-flight ACK.
        readingFixture.holdOperation = "setReading"
        reading.setKeepReading(false); await waitUntil { !readingFixture.held.isEmpty }
        reading.setKeepReading(true); readingFixture.resumeWrites(); await settle(reading)
        expect(reading.readingArmed && readingFixture.current(host).keepReading == true && prefs.bool(forKey: key), "Last rapid toggle wins without parallel writes")
        reading.confirmedChat(provider: .claude, chatID: nil, slotIndex: nil, draft: "")
        await settle(reading)
        expect(!reading.readingArmed && !reading.readingMessage.contains("Ready:"), "Cleared chat disarms and removes stale readiness text")
        reading.confirmedChat(provider: .claude, chatID: "confirmed", slotIndex: 0, draft: "Private")
        await settle(reading)
        expect(reading.readingArmed, "A newly confirmed chat reapplies the explicit saved preference after update ACK")
        reading.enterBackground(); await settle(reading)
        reading.stop("Host changed"); await settle(reading)
        expect(!readingFixture.current(host).active, "Explicit stop releases parked lease")

        // A saved preference is reapplied only after a fresh claim and confirmed target.
        let claimed = GlassesFollowFixture(); claimed.holdOperation = "claim"
        let claimPublisher = GlassesFollowController(transport: claimed, automaticPolling: false, preferences: prefs)
        claimPublisher.enable(host: host, token: "fixture", provider: .codex, chatID: "confirmed", slotIndex: 0, draft: "Secret during claim", recording: true)
        await waitUntil { !claimed.held.isEmpty }
        claimPublisher.enterBackground(); claimed.resumeWrites(); await settle(claimPublisher)
        expect(claimed.current(host).readingOnly == true && claimed.current(host).state?.draft == "" && claimPublisher.suspended, "Background during claim arms and parks serially without leaking restored state")
        expect(claimed.maximumConcurrentWrites == 1, "Claim arm and park writes remain serialized")
        claimPublisher.stop(); await settle(claimPublisher)

        let oldReading = GlassesFollowFixture(); oldReading.supportsReading = false
        let legacy = GlassesFollowController(transport: oldReading, automaticPolling: false, preferences: prefs)
        legacy.enable(host: host, token: "fixture", provider: .claude, chatID: "confirmed", slotIndex: 0, draft: "Local", recording: false)
        await settle(legacy)
        expect(!legacy.supportsKeepReading && !legacy.canSetKeepReading, "Legacy companion disables Keep reading while normal Follow works")
        legacy.enterBackground(); await settle(legacy)
        expect(!legacy.enabled && !oldReading.current(host).active && !oldReading.requests.contains { $0.1.operation == "park" || $0.1.operation == "setReading" }, "Legacy companion uses safe release despite saved preference")

        // Update or arm in flight may finish, but cannot restore draft after lock.
        for operation in ["update", "setReading"] {
            let f = GlassesFollowFixture()
            let c = GlassesFollowController(transport: f, automaticPolling: false, preferences: nil)
            c.enable(host: host, token: "fixture", provider: .claude, chatID: "confirmed", slotIndex: 0, draft: "Private", recording: false)
            await settle(c)
            if operation == "update" { c.setKeepReading(true); await settle(c) }
            f.holdOperation = operation
            if operation == "setReading" { c.setKeepReading(true) } else { c.updateDraft("Latest secret", recording: true, debounce: false) }
            await waitUntil { !f.held.isEmpty }
            c.enterBackground(); f.resumeWrites(); await settle(c)
            expect(f.current(host).readingOnly == true && f.current(host).state?.draft == "" && c.desired.draft == "", "Background fences in-flight \(operation) response")
            c.stop(); await settle(c)
        }

        for operation in ["update", "poll"] {
            let f = GlassesFollowFixture()
            let c = GlassesFollowController(transport: f, automaticPolling: false, preferences: prefs)
            c.enable(host: host, token: "fixture", provider: .claude, chatID: "confirmed", slotIndex: 0, draft: "Private", recording: false)
            await settle(c)
            var pendingRead: Task<Void, Never>?
            if operation == "update" {
                f.holdOperation = "update"; f.failAfter = "update"
                c.refresh(); await waitUntil { !f.held.isEmpty }
            } else {
                f.holdReads = true; f.failReadAfterHold = true
                pendingRead = Task { await c.poll() }; await waitUntil { !f.heldReads.isEmpty }
            }
            c.enterBackground()
            if operation == "update" { f.resumeWrites() } else { f.resumeReads(); await pendingRead?.value }
            await settle(c)
            expect(c.enabled && c.suspended && f.current(host).readingOnly == true && !f.requests.contains { $0.1.operation == "release" }, "Late \(operation) failure cannot release the parked reading session")
            c.stop(); await settle(c)
        }

        for staleKind in ["error", "inactive"] {
            let f = GlassesFollowFixture()
            let c = GlassesFollowController(transport: f, automaticPolling: false, preferences: prefs)
            c.enable(host: host, token: "fixture", provider: .claude, chatID: "confirmed", slotIndex: 0, draft: "Private", recording: false)
            await settle(c)
            let saved = f.current(host)
            f.holdReads = true; f.failReadAfterHold = staleKind == "error"
            if staleKind == "inactive" { f.snapshots[host.hostID!]?.active = false }
            let oldPoll = Task { await c.poll() }; await waitUntil { !f.heldReads.isEmpty }
            f.snapshots[host.hostID!] = saved; f.holdReads = false
            c.enterBackground(); await settle(c)
            c.returnToForeground { "Resumed draft" }; await settle(c)
            let currentLease = f.current(host).leaseID
            f.resumeReads(); await oldPoll.value; await settle(c)
            expect(c.controlsAvailable && f.current(host).leaseID == currentLease && f.current(host).state?.draft == "Resumed draft", "Pre-resume poll \(staleKind) cannot release rotated foreground lease")
            c.stop(); await settle(c)
        }

        // Park never reached the Mac: resume still rotates the normal lease,
        // fencing a delayed original park request if transport later delivers it.
        let delayedPark = GlassesFollowFixture(); delayedPark.failBefore = "park"
        let delayedPublisher = GlassesFollowController(transport: delayedPark, automaticPolling: false, preferences: prefs)
        delayedPublisher.enable(host: host, token: "fixture", provider: .claude, chatID: "confirmed", slotIndex: 0, draft: "Private", recording: false)
        await settle(delayedPublisher); delayedPublisher.enterBackground(); await settle(delayedPublisher)
        let lateParkRequest = delayedPark.requests.last!.1
        expect(delayedPublisher.suspended && delayedPark.current(host).readingOnly == false && delayedPark.current(host).keepReading == true, "Failed pre-arrival park retains the armed normal fallback")
        delayedPublisher.returnToForeground { "Current foreground draft" }; await settle(delayedPublisher)
        delayedPark.failBefore = nil
        var rejectedLatePark = false
        do { _ = try await delayedPark.write(lateParkRequest, host: host, token: "fixture") } catch { rejectedLatePark = true }
        expect(rejectedLatePark && delayedPublisher.controlsAvailable && delayedPark.current(host).state?.draft == "Current foreground draft", "Rotated normal resume rejects late pre-resume park")
        delayedPublisher.stop(); await settle(delayedPublisher)

        // Lost park reply is not a reason to erase an armed reading session.
        let lostPark = GlassesFollowFixture()
        let parkPublisher = GlassesFollowController(transport: lostPark, automaticPolling: false, preferences: prefs)
        parkPublisher.enable(host: host, token: "fixture", provider: .claude, chatID: "confirmed", slotIndex: 0, draft: "Private", recording: false)
        await settle(parkPublisher)
        lostPark.failAfter = "park"
        parkPublisher.enterBackground(); await settle(parkPublisher)
        expect(parkPublisher.enabled && parkPublisher.suspended && lostPark.current(host).readingOnly == true && !lostPark.requests.contains { $0.1.operation == "release" }, "Lost park response keeps armed session without replay or release")
        lostPark.failAfter = nil
        parkPublisher.returnToForeground { "Private" }; await settle(parkPublisher)
        expect(parkPublisher.controlsAvailable && lostPark.requests.filter { $0.1.operation == "park" }.count == 1, "Lost park reply recovers by exact resume once")
        // Resume can finish after the phone locks a second time.
        parkPublisher.enterBackground(); await settle(parkPublisher)
        lostPark.holdOperation = "resume"
        parkPublisher.returnToForeground { "Must remain local" }
        await waitUntil { !lostPark.held.isEmpty }
        parkPublisher.enterBackground(); lostPark.resumeWrites(); await settle(parkPublisher)
        expect(parkPublisher.suspended && lostPark.current(host).readingOnly == true && lostPark.current(host).state?.draft == "", "Second lock during resume reparks rotated lease without a draft update")
        parkPublisher.returnToForeground { "Local after second lock" }; await settle(parkPublisher)
        expect(parkPublisher.controlsAvailable && lostPark.current(host).state?.draft == "Local after second lock", "Later foreground resumes the second parked lease")
        // A lost resume response cannot be replayed or silently reclaimed.
        parkPublisher.enterBackground(); await settle(parkPublisher)
        lostPark.failAfter = "resume"
        let claimsBeforeLostResume = lostPark.requests.filter { $0.1.operation == "claim" }.count
        parkPublisher.returnToForeground { "Never uploaded" }; await settle(parkPublisher)
        expect(!parkPublisher.enabled && lostPark.current(host).active && lostPark.current(host).state?.draft == "", "Lost resume ACK stops native Follow; stale release cannot clear rotated lease")
        expect(lostPark.requests.filter { $0.1.operation == "claim" }.count == claimsBeforeLostResume, "Uncertain resume never automatically claims again")

        let changed = GlassesFollowFixture()
        let changedPublisher = GlassesFollowController(transport: changed, automaticPolling: false, preferences: prefs)
        changedPublisher.enable(host: host, token: "fixture", provider: .claude, chatID: "confirmed", slotIndex: 0, draft: "Private", recording: false)
        await settle(changedPublisher); changedPublisher.enterBackground(); await settle(changedPublisher)
        changed.snapshots[host.hostID!]?.sourceID = UUID().uuidString
        changed.snapshots[host.hostID!]?.sourceName = "iPhone"
        changed.snapshots[host.hostID!]?.leaseID = UUID().uuidString
        changedPublisher.returnToForeground { "Never uploaded" }; await settle(changedPublisher)
        expect(!changedPublisher.enabled && changedPublisher.otherOwner == "iPhone" && !changed.requests.contains { $0.1.operation == "resume" }, "New owner during lock blocks resume and preserves their lease")

        let expiredReading = GlassesFollowFixture()
        let expiredPublisher = GlassesFollowController(transport: expiredReading, automaticPolling: false, preferences: prefs)
        expiredPublisher.enable(host: host, token: "fixture", provider: .claude, chatID: "confirmed", slotIndex: 0, draft: "Private", recording: false)
        await settle(expiredPublisher); expiredPublisher.enterBackground(); await settle(expiredPublisher)
        expiredReading.snapshots[host.hostID!]?.expiresAt = "2020-01-01T00:00:00Z"
        expiredPublisher.returnToForeground { "Never uploaded" }; await settle(expiredPublisher)
        expect(!expiredPublisher.enabled && !expiredReading.requests.contains { $0.1.operation == "resume" }, "Expired reading requires explicit Follow and no draft restore")

        print("Glasses follow: \(count) checks passed")
    }
}
