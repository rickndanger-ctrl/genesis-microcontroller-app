import Foundation

@main struct RemoteDisplaySessionTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        func rejects(_ code: Int, _ label: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(label + " unexpectedly succeeded") }
            catch let error as RemoteDisplayFault { check(error.status == code, label) }
            catch { preconditionFailure(label + " returned an unexpected error") }
        }
        let host = UUID().uuidString, phone = UUID(), pad = UUID()
        let a = RemoteDisplayState(provider: "codex", chatID: "a", slotIndex: 0, view: "reply", page: 0, draft: "Private unsent draft", recording: false, sendState: "none", refreshNonce: 0)
        let ta = RemoteDisplaySession.ValidatedTarget(target: .init(provider: "codex", chatID: "a"), title: "Chat A")
        let tb = RemoteDisplaySession.ValidatedTarget(target: .init(provider: "claude", chatID: "b"), title: "Chat B")
        func altered(_ state: RemoteDisplayState = a, provider: String? = nil, chat: String? = nil, view: String? = nil, page: Int? = nil, draft: String? = nil, nonce: Int? = nil) -> RemoteDisplayState {
            .init(provider: provider ?? state.provider, chatID: chat ?? state.chatID, slotIndex: state.slotIndex, view: view ?? state.view, page: page ?? state.page, draft: draft ?? state.draft, recording: state.recording, sendState: state.sendState, refreshNonce: nonce ?? state.refreshNonce)
        }
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        func object<T: Encodable>(_ value: T) throws -> [String: Any] { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any] }
        func feedback(_ revision: Int, provider: String = "codex", chat: String = "a", view: String = "reply", count: Int = 3, page: Int = 0, connected: Bool = true) throws -> RemoteDisplayFeedbackRequest {
            try .decode(json(["revision": revision, "provider": provider, "chatID": chat, "view": view, "pageCount": count, "renderedPage": page, "connected": connected]))
        }

        var session = RemoteDisplaySession()
        let initial = session.snapshot(hostID: host, now: 100)
        check(!initial.active && initial.revision == 0, "starts inactive")
        let initialJSON = try object(initial)
        check(initialJSON["state"] == nil && initialJSON["sourceID"] == nil && initialJSON["leaseID"] == nil, "inactive snapshot has no private fields")
        let claim = RemoteDisplayRequest.claim(sourceID: phone, sourceName: "iPhone", takeover: false, state: a)
        check(try session.requiredTarget(for: claim, now: 100) == ta.target, "first claim requires exact inventory lookup")
        rejects(422, "unvalidated claim") { _ = try session.apply(claim, hostID: host, now: 100) }
        rejects(422, "wrong target result") { _ = try session.apply(claim, hostID: host, now: 100, validated: tb) }
        let claimed = try session.apply(claim, hostID: host, now: 100, validated: ta)
        let lease = claimed.leaseID!
        check(claimed.active && claimed.revision == 1 && claimed.chatTitle == "Chat A", "claim has inventory title")
        check(claimed.sourceID == phone && claimed.sourceName == "iPhone", "claim has native owner")
        check(try object(claimed)["leaseID"] != nil, "owner POST receives lease")
        check(try object(session.snapshot(hostID: host, now: 101))["leaseID"] == nil, "GET never exposes lease")
        rejects(409, "second owner must explicitly take over") {
            _ = try session.requiredTarget(for: .claim(sourceID: pad, sourceName: "iPad", takeover: false, state: a), now: 101)
        }
        rejects(409, "wrong owner update") { _ = try session.apply(.update(sourceID: pad, leaseID: lease, sequence: 1, state: a), hostID: host, now: 101) }
        rejects(409, "wrong lease update") { _ = try session.apply(.update(sourceID: phone, leaseID: UUID(), sequence: 1, state: a), hostID: host, now: 101) }
        let beat = RemoteDisplayRequest.update(sourceID: phone, leaseID: lease, sequence: 1, state: a)
        check(try session.requiredTarget(for: beat, now: 110) == nil, "heartbeat skips AX inventory read")
        let ack = try session.applyFeedback(feedback(1), hostID: host, now: 110)
        check(ack.feedback?.revision == 1 && ack.leaseID == nil, "display feedback is revision scoped and public")
        let heartbeat = try session.apply(beat, hostID: host, now: 111)
        check(heartbeat.revision == 1 && heartbeat.feedback == ack.feedback, "heartbeat retains revision and render ACK")
        check(heartbeat.expiresAt != claimed.expiresAt, "heartbeat renews lease")
        rejects(409, "sequence replay") { _ = try session.apply(beat, hostID: host, now: 112) }
        rejects(422, "zero sequence") { _ = try session.apply(.update(sourceID: phone, leaseID: lease, sequence: 0, state: a), hostID: host, now: 112) }
        let draftEdit = RemoteDisplayRequest.update(sourceID: phone, leaseID: lease, sequence: 2, state: altered(draft: "More words"))
        check(try session.requiredTarget(for: draftEdit, now: 112) == nil, "draft edit skips AX inventory read")
        let edited = try session.apply(draftEdit, hostID: host, now: 112)
        check(edited.revision == 2 && edited.feedback == nil, "changed state awaits fresh render ACK")
        rejects(409, "stale feedback cannot overwrite draft") { _ = try session.applyFeedback(feedback(1), hostID: host, now: 113) }
        rejects(409, "wrong provider feedback") { _ = try session.applyFeedback(feedback(2, provider: "claude"), hostID: host, now: 113) }
        rejects(409, "wrong chat feedback") { _ = try session.applyFeedback(feedback(2, chat: "b"), hostID: host, now: 113) }
        rejects(409, "wrong view feedback") { _ = try session.applyFeedback(feedback(2, view: "draft"), hostID: host, now: 113) }
        let b = altered(provider: "claude", chat: "b")
        let switchChat = RemoteDisplayRequest.update(sourceID: phone, leaseID: lease, sequence: 3, state: b)
        check(try session.requiredTarget(for: switchChat, now: 113) == tb.target, "changed target validates exact provider and chat")
        rejects(422, "changed target missing from inventory") { _ = try session.apply(switchChat, hostID: host, now: 113) }
        check(session.snapshot(hostID: host, now: 113).state?.draft == "More words", "failed target does not replace draft")
        let switched = try session.apply(switchChat, hostID: host, now: 113, validated: tb)
        check(switched.state?.provider == "claude" && switched.chatTitle == "Chat B", "validated target switches display only")

        let taken = try session.apply(.claim(sourceID: pad, sourceName: "iPad", takeover: true, state: b), hostID: host, now: 114)
        check(taken.sourceID == pad && taken.leaseID != lease && taken.feedback == nil, "takeover mints a fresh lease")
        rejects(409, "old owner cannot release new owner") { _ = try session.apply(.release(sourceID: phone, leaseID: lease), hostID: host, now: 115) }
        rejects(409, "old owner cannot update after await") { _ = try session.apply(switchChat, hostID: host, now: 115, validated: tb) }
        let retaken = try session.apply(.claim(sourceID: pad, sourceName: "iPad", takeover: false, state: b), hostID: host, now: 116)
        check(retaken.leaseID != taken.leaseID, "same owner reclaim invalidates previous generation")
        rejects(409, "reclaimed lease invalidates old generation") { _ = try session.apply(.update(sourceID: pad, leaseID: taken.leaseID!, sequence: 50, state: b), hostID: host, now: 117) }
        let resetSequence = try session.apply(.update(sourceID: pad, leaseID: retaken.leaseID!, sequence: 1, state: b), hostID: host, now: 117)
        check(resetSequence.active, "sequence resets to 1 after claim")
        let released = try session.apply(.release(sourceID: pad, leaseID: retaken.leaseID!), hostID: host, now: 118)
        let releasedJSON = try object(released)
        check(!released.active && releasedJSON["state"] == nil && releasedJSON["leaseID"] == nil && releasedJSON["chatTitle"] == nil, "release clears private state")

        var expiration = RemoteDisplaySession()
        let expiring = try expiration.apply(claim, hostID: host, now: 200, validated: ta)
        _ = try expiration.applyFeedback(feedback(expiring.revision), hostID: host, now: 244)
        check(expiration.snapshot(hostID: host, now: 244.99).active, "lease alive before 45 seconds")
        let expired = expiration.snapshot(hostID: host, now: 245)
        check(!expired.active && expired.state == nil && expired.feedback == nil, "feedback does not renew lease and expiry clears private draft")
        rejects(409, "expired update cannot revive lease") { _ = try expiration.apply(.update(sourceID: phone, leaseID: expiring.leaseID!, sequence: 1, state: a), hostID: host, now: 246) }
        let newOwner = try expiration.apply(.claim(sourceID: pad, sourceName: "iPad", takeover: false, state: a), hostID: host, now: 246, validated: ta)
        check(newOwner.active, "expired owner does not prevent new explicit claim")
        check(!expiration.snapshot(hostID: host, now: 240).active, "clock moving backwards clears lease")
        _ = try expiration.apply(claim, hostID: host, now: 300, validated: ta)
        check(!expiration.snapshot(hostID: host, now: .nan).active, "invalid clock clears lease")
        var restarted = RemoteDisplaySession()
        check(!restarted.snapshot(hostID: host, now: 300).active, "process restart never restores display draft")

        var freshness = RemoteDisplaySession()
        let freshOwner = try freshness.apply(claim, hostID: host, now: 300, validated: ta)
        _ = try freshness.applyFeedback(feedback(freshOwner.revision), hostID: host, now: 301)
        _ = try freshness.apply(.update(sourceID: phone, leaseID: freshOwner.leaseID!, sequence: 1, state: a), hostID: host, now: 310)
        check(freshness.snapshot(hostID: host, now: 315.99).feedback != nil, "display ACK remains valid for fifteen seconds")
        let staleACK = freshness.snapshot(hostID: host, now: 316)
        check(staleACK.active && staleACK.feedback == nil, "native heartbeat does not renew glasses ACK freshness")
        check(staleACK.revision == freshOwner.revision && staleACK.state == a && staleACK.sourceID == phone, "ACK expiry preserves ownership revision and private draft")
        check(try object(staleACK)["feedbackReceivedAt"] == nil, "private freshness timestamp never reaches wire")
        let reacknowledged = try freshness.applyFeedback(feedback(freshOwner.revision), hostID: host, now: 317)
        check(reacknowledged.feedback?.connected == true && reacknowledged.revision == freshOwner.revision, "fresh native render can ACK unchanged revision")
        let expiryAfterACK = freshness.snapshot(hostID: host, now: 355)
        check(!expiryAfterACK.active, "fresh feedback never renews ownership")

        var pagination = RemoteDisplaySession()
        let paged = try pagination.apply(.claim(sourceID: phone, sourceName: "iPhone", takeover: false, state: altered(page: 99)), hostID: host, now: 400, validated: ta)
        rejects(409, "different rendered page cannot ACK controller page") { _ = try pagination.applyFeedback(feedback(paged.revision, count: 3, page: 1), hostID: host, now: 401) }
        let disconnected = try pagination.applyFeedback(feedback(paged.revision, count: 3, page: 1, connected: false), hostID: host, now: 401)
        check(disconnected.state?.page == 99 && disconnected.feedback?.connected == false, "disconnected display cannot normalize controller page")
        let normalized = try pagination.applyFeedback(feedback(paged.revision, count: 3, page: 2), hostID: host, now: 401)
        check(normalized.state?.page == 2 && normalized.revision == paged.revision + 1, "feedback clamps requested page downward")
        check(normalized.feedback?.revision == normalized.revision, "normalized ACK matches canonical revision")
        let clamped = try pagination.apply(.update(sourceID: phone, leaseID: paged.leaseID!, sequence: 1, state: altered(page: 999)), hostID: host, now: 402)
        check(clamped.state?.page == 2 && clamped.revision == normalized.revision, "known page count clamps controller requests")
        let refresh = try pagination.apply(.update(sourceID: phone, leaseID: paged.leaseID!, sequence: 2, state: altered(page: 99, nonce: 1)), hostID: host, now: 403)
        check(refresh.state?.page == 99 && refresh.feedback == nil, "refresh invalidates old pagination")
        let draft = try pagination.apply(.update(sourceID: phone, leaseID: paged.leaseID!, sequence: 3, state: altered(view: "draft", draft: "short")), hostID: host, now: 404)
        _ = try pagination.applyFeedback(feedback(draft.revision, view: "draft", count: 1), hostID: host, now: 405)
        let longer = try pagination.apply(.update(sourceID: phone, leaseID: paged.leaseID!, sequence: 4, state: altered(view: "draft", page: 2, draft: "longer")), hostID: host, now: 406)
        check(longer.state?.page == 2 && longer.feedback == nil, "draft content change invalidates old page count")
        pagination.invalidate()
        check(!pagination.snapshot(hostID: host, now: 407).active, "disable and lock can clear session immediately")

        check(initialJSON["supportsKeepReading"] as? Bool == true, "inactive bridge advertises keep-reading support")
        check(initialJSON["keepReading"] == nil && initialJSON["readingOnly"] == nil, "inactive bridge has no reading owner flags")
        check(claimed.keepReading == false && claimed.readingOnly == false, "reading persistence defaults off")
        func readingFixture(provider:String="codex") throws ->(RemoteDisplaySession,UUID) {
            var value=RemoteDisplaySession()
            let state=RemoteDisplayState(provider:provider,chatID:"reading",slotIndex:2,view:"draft",page:9,
                draft:"Private speech must not persist",recording:true,sendState:"confirmed",refreshNonce:7)
            let target=RemoteDisplaySession.ValidatedTarget(target:.init(provider:provider,chatID:"reading"),title:"Exact selected chat")
            let owner=try value.apply(.claim(sourceID:phone,sourceName:"iPhone",takeover:false,state:state),hostID:host,now:1000,validated:target)
            return (value,owner.leaseID!)
        }
        for provider in ["codex","claude"] {
            var (reading,readingLease)=try readingFixture(provider:provider)
            rejects(409,"unarmed park \(provider)") {_ = try reading.apply(.park(sourceID:phone,leaseID:readingLease),hostID:host,now:1001)}
            let armed=try reading.apply(.setReading(sourceID:phone,leaseID:readingLease,enabled:true),hostID:host,now:1002)
            check(armed.keepReading==true && armed.readingOnly==false && armed.leaseID==readingLease,"armed normal lease \(provider)")
            check(armed.expiresAt==ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:1045)),"arming does not renew heartbeat \(provider)")
            let parked=try reading.apply(.park(sourceID:phone,leaseID:readingLease),hostID:host,now:1003)
            check(parked.active && parked.keepReading==true && parked.readingOnly==true,"explicit park stays display-active \(provider)")
            check(parked.state?.provider==provider && parked.state?.chatID=="reading" && parked.state?.slotIndex==2 && parked.chatTitle=="Exact selected chat","park preserves only exact selection \(provider)")
            check(parked.state?.view=="reply" && parked.state?.page==0 && parked.state?.draft=="" && parked.state?.recording==false && parked.state?.sendState=="none","park sanitizes private/live state \(provider)")
            check(parked.revision==armed.revision+1 && parked.feedback==nil,"park requires a fresh display ACK \(provider)")
            check(parked.expiresAt==ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:4603)),"explicit park bound starts at accepted park \(provider)")
            let repeated=try reading.apply(.park(sourceID:phone,leaseID:readingLease),hostID:host,now:1004)
            check(repeated.revision==parked.revision && repeated.expiresAt==parked.expiresAt,"lost park response retry is idempotent \(provider)")
            let rearmed=try reading.apply(.setReading(sourceID:phone,leaseID:readingLease,enabled:true),hostID:host,now:1005)
            check(rearmed.expiresAt==parked.expiresAt && rearmed.revision==parked.revision,"rearming parked session never extends deadline \(provider)")
            rejects(409,"late update while parked \(provider)") {_ = try reading.apply(.update(sourceID:phone,leaseID:readingLease,sequence:99,state:a),hostID:host,now:1006)}
            rejects(409,"other owner cannot resume \(provider)") {_ = try reading.apply(.resume(sourceID:pad,leaseID:readingLease),hostID:host,now:1007)}
            rejects(409,"wrong lease cannot disable reading \(provider)") {_ = try reading.apply(.setReading(sourceID:phone,leaseID:UUID(),enabled:false),hostID:host,now:1008)}
            let resumed=try reading.apply(.resume(sourceID:phone,leaseID:readingLease),hostID:host,now:1009)
            check(resumed.active && resumed.readingOnly==false && resumed.keepReading==true && resumed.leaseID != readingLease,"resume rotates lease and restores control \(provider)")
            check(resumed.state?.draft=="" && resumed.state?.recording==false && resumed.state?.sendState=="none","resume never restores discarded transient input \(provider)")
            check(resumed.expiresAt==ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:1054)),"resumed normal lease lasts45 seconds \(provider)")
            rejects(409,"late pre-park update fenced after resume \(provider)") {_ = try reading.apply(.update(sourceID:phone,leaseID:readingLease,sequence:999,state:a),hostID:host,now:1010)}
            rejects(409,"old parked lease cannot resume twice \(provider)") {_ = try reading.apply(.resume(sourceID:phone,leaseID:readingLease),hostID:host,now:1011)}
            rejects(409,"late park fenced after resume \(provider)") {_ = try reading.apply(.park(sourceID:phone,leaseID:readingLease),hostID:host,now:1012)}
            let beat=try reading.apply(.update(sourceID:phone,leaseID:resumed.leaseID!,sequence:1,state:resumed.state!),hostID:host,now:1013)
            check(beat.active && beat.keepReading==true,"new resume lease accepts sequence1 \(provider)")
        }
        var (fallback,fallbackLease)=try readingFixture()
        _ = try fallback.apply(.setReading(sourceID:phone,leaseID:fallbackLease,enabled:true),hostID:host,now:1001)
        let beforeFallback=fallback.snapshot(hostID:host,now:1044.99)
        check(beforeFallback.readingOnly==false && beforeFallback.state?.draft.isEmpty==false,"normal lease retains draft until exact expiry")
        let atFallback=fallback.snapshot(hostID:host,now:1045)
        check(atFallback.active && atFallback.readingOnly==true && atFallback.state?.draft=="","lost park falls back at exact normal expiry")
        check(atFallback.expiresAt==ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:4645)),"fallback anchors reading expiry to last normal expiry")
        _ = try fallback.applyFeedback(feedback(atFallback.revision,chat:"reading",count:1),hostID:host,now:4644)
        check(fallback.snapshot(hostID:host,now:4644.99).active,"park alive just before fixed deadline")
        check(!fallback.snapshot(hostID:host,now:4645).active,"feedback never extends parked deadline")
        rejects(409,"expired parked resume cannot revive ownership") {_ = try fallback.apply(.resume(sourceID:phone,leaseID:fallbackLease),hostID:host,now:4646)}

        var (latePoll,lateLease)=try readingFixture()
        _ = try latePoll.apply(.setReading(sourceID:phone,leaseID:lateLease,enabled:true),hostID:host,now:1001)
        let late=latePoll.snapshot(hostID:host,now:4000)
        check(late.active && late.readingOnly==true && late.expiresAt==ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:4645)),"late poll cannot start a fresh hour")
        var (tooLate,tooLateLease)=try readingFixture()
        _ = try tooLate.apply(.setReading(sourceID:phone,leaseID:tooLateLease,enabled:true),hostID:host,now:1001)
        check(!tooLate.snapshot(hostID:host,now:4645).active,"first poll after both stages expires without revival")

        var (off,offLease)=try readingFixture()
        _ = try off.apply(.setReading(sourceID:phone,leaseID:offLease,enabled:true),hostID:host,now:1001)
        let unarmed=try off.apply(.setReading(sourceID:phone,leaseID:offLease,enabled:false),hostID:host,now:1002)
        check(unarmed.active && unarmed.keepReading==false && unarmed.readingOnly==false,"off during normal Follow retains ordinary control")
        check(!off.snapshot(hostID:host,now:1045).active,"off restores ordinary45 second expiry")
        var (offParked,offParkedLease)=try readingFixture()
        _ = try offParked.apply(.setReading(sourceID:phone,leaseID:offParkedLease,enabled:true),hostID:host,now:1001)
        _ = try offParked.apply(.park(sourceID:phone,leaseID:offParkedLease),hostID:host,now:1002)
        let ended=try offParked.apply(.setReading(sourceID:phone,leaseID:offParkedLease,enabled:false),hostID:host,now:1003)
        check(!ended.active && ended.state==nil && ended.leaseID==nil,"off while parked ends and clears reading session")

        var (readingTakeover,takeoverLease)=try readingFixture()
        _ = try readingTakeover.apply(.setReading(sourceID:phone,leaseID:takeoverLease,enabled:true),hostID:host,now:1001)
        _ = try readingTakeover.apply(.park(sourceID:phone,leaseID:takeoverLease),hostID:host,now:1002)
        rejects(409,"parked owner still requires explicit takeover") {_ = try readingTakeover.apply(.claim(sourceID:pad,sourceName:"iPad",takeover:false,state:a),hostID:host,now:1003,validated:ta)}
        let newReadingOwner=try readingTakeover.apply(.claim(sourceID:pad,sourceName:"iPad",takeover:true,state:a),hostID:host,now:1004,validated:ta)
        check(newReadingOwner.keepReading==false && newReadingOwner.readingOnly==false && newReadingOwner.leaseID != takeoverLease,"takeover never inherits reading permission")
        rejects(409,"old owner cannot resume taken lease") {_ = try readingTakeover.apply(.resume(sourceID:phone,leaseID:takeoverLease),hostID:host,now:1005)}

        var (rollback,rollbackLease)=try readingFixture()
        _ = try rollback.apply(.setReading(sourceID:phone,leaseID:rollbackLease,enabled:true),hostID:host,now:1001)
        _ = try rollback.apply(.park(sourceID:phone,leaseID:rollbackLease),hostID:host,now:1002)
        _ = rollback.snapshot(hostID:host,now:2000)
        check(!rollback.snapshot(hostID:host,now:1999.99).active,"clock rollback within reading stage clears ownership")
        var (heartbeatFallback,heartbeatLease)=try readingFixture()
        _ = try heartbeatFallback.apply(.setReading(sourceID:phone,leaseID:heartbeatLease,enabled:true),hostID:host,now:1001)
        let heartbeatState=heartbeatFallback.snapshot(hostID:host,now:1010).state!
        _ = try heartbeatFallback.apply(.update(sourceID:phone,leaseID:heartbeatLease,sequence:1,state:heartbeatState),hostID:host,now:1010)
        check(heartbeatFallback.snapshot(hostID:host,now:1055).expiresAt==ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:4655)),"fallback anchor follows last accepted heartbeat")

        let noChat=RemoteDisplayState(provider:"claude",chatID:nil,slotIndex:nil,view:"home",page:0,draft:"",recording:false,sendState:"none",refreshNonce:0)
        var noTarget=RemoteDisplaySession()
        let noTargetOwner=try noTarget.apply(.claim(sourceID:phone,sourceName:"iPhone",takeover:false,state:noChat),hostID:host,now:1000)
        rejects(422,"arming Home without a confirmed target") {_ = try noTarget.apply(.setReading(sourceID:phone,leaseID:noTargetOwner.leaseID!,enabled:true),hostID:host,now:1001)}
        let normalResume=try noTarget.apply(.resume(sourceID:phone,leaseID:noTargetOwner.leaseID!),hostID:host,now:1002)
        check(normalResume.leaseID != noTargetOwner.leaseID && normalResume.expiresAt==ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:1047)),"resume before parking rotates lease and grants normal45 second control")
        var (quickResume,quickLease)=try readingFixture()
        _ = try quickResume.apply(.setReading(sourceID:phone,leaseID:quickLease,enabled:true),hostID:host,now:1001)
        let quick=try quickResume.apply(.resume(sourceID:phone,leaseID:quickLease),hostID:host,now:1002)
        check(quick.leaseID != quickLease && quick.readingOnly==false,"quick foreground rotates even when park has not arrived")
        rejects(409,"timed-out late park cannot park resumed foreground") {_ = try quickResume.apply(.park(sourceID:phone,leaseID:quickLease),hostID:host,now:1003)}
        rejects(409,"old heartbeat cannot mutate quick foreground lease") {_ = try quickResume.apply(.update(sourceID:phone,leaseID:quickLease,sequence:999,state:a),hostID:host,now:1004)}
        let quickBeat=try quickResume.apply(.update(sourceID:phone,leaseID:quick.leaseID!,sequence:1,state:quick.state!),hostID:host,now:1005)
        check(quickBeat.active && quickBeat.keepReading==true,"quick resume accepts sequence1 on its new lease")
        var (homeClear,homeLease)=try readingFixture()
        _ = try homeClear.apply(.setReading(sourceID:phone,leaseID:homeLease,enabled:true),hostID:host,now:1001)
        let homeCleared=try homeClear.apply(.update(sourceID:phone,leaseID:homeLease,sequence:1,state:noChat),hostID:host,now:1002)
        check(homeCleared.keepReading==false,"clearing selected chat disarms persistence")
        var (awaitingTarget,awaitingLease)=try readingFixture()
        _ = try awaitingTarget.apply(.setReading(sourceID:phone,leaseID:awaitingLease,enabled:true),hostID:host,now:1001)
        let delayedTarget=RemoteDisplayRequest.update(sourceID:phone,leaseID:awaitingLease,sequence:1,state:b)
        check(try awaitingTarget.requiredTarget(for:delayedTarget,now:1044)==tb.target,"new target awaits exact inventory before normal lease ends")
        rejects(409,"target read finishing after parking cannot rewrite selected chat") {_ = try awaitingTarget.apply(delayedTarget,hostID:host,now:1045,validated:tb)}
        check(awaitingTarget.snapshot(hostID:host,now:1045).state?.chatID=="reading","late validated target cannot replace parked selection")
        awaitingTarget.invalidate()
        check(!awaitingTarget.snapshot(hostID:host,now:1046).active,"Mac lock invalidation ends parked reading immediately")
        var restartedReading=RemoteDisplaySession()
        check(!restartedReading.snapshot(hostID:host,now:1046).active,"process restart cannot restore parked private context")

        for operation in ["setReading","park","resume"] {
            var body:[String:Any]=["operation":operation,"sourceID":phone.uuidString,"leaseID":UUID().uuidString]
            if operation=="setReading" {body["enabled"]=true}
            check(try RemoteDisplayRequest.decode(json(body)).state==nil,"reading request carries no display state: \(operation)")
            body["action"]="sendPrompt"
            rejects(422,"reading operation cannot carry action: \(operation)") {_ = try RemoteDisplayRequest.decode(json(body))}
        }
        rejects(422,"reading enabled flag requires a real Boolean") {_ = try RemoteDisplayRequest.decode(json(["operation":"setReading","sourceID":phone.uuidString,"leaseID":UUID().uuidString,"enabled":1]))}

        let stateJSON = try object(a)
        let claimJSON: [String: Any] = ["operation": "claim", "sourceID": phone.uuidString.lowercased(), "sourceName": "iPhone", "takeover": false, "state": stateJSON]
        let decoded = try RemoteDisplayRequest.decode(json(claimJSON))
        var decodedSession = RemoteDisplaySession()
        check(try decodedSession.apply(decoded, hostID: host, now: 500, validated: ta).sourceID == phone, "UUID casing has one owner identity")
        for key in ["action", "url", "leaseID", "text"] {
            var bad = claimJSON; bad[key] = "sendPrompt"
            rejects(422, "claim cannot carry " + key) { _ = try RemoteDisplayRequest.decode(json(bad)) }
        }
        for change: [String: Any] in [
            ["provider": "muse"], ["view": "send"], ["slotIndex": 6], ["slotIndex": -1], ["slotIndex": true], ["page": 1000], ["page": -1], ["page": false], ["page": 1.5],
            ["refreshNonce": -1], ["refreshNonce": RemoteDisplayState.maximumInteger + 1], ["recording": 1], ["sendState": "sendPrompt"],
            ["draft": String(repeating: "a", count: 16_001)], ["chatID": ""], ["chatID": String(repeating: "a", count: 513)], ["chatID": "a\n"],
            ["chatID": NSNull()], ["title": "Untrusted title"], ["action": "openChat"], ["url": "https://example.com"]
        ] {
            var changed = stateJSON; changed.merge(change) { _, new in new }
            var body = claimJSON; body["state"] = changed
            rejects(422, "closed state validation " + change.keys.first!) { _ = try RemoteDisplayRequest.decode(json(body)) }
        }
        var scalarState = stateJSON; scalarState["draft"] = String(repeating: "😀", count: 16_000)
        var scalarBody = claimJSON; scalarBody["state"] = scalarState
        check(try RemoteDisplayRequest.decode(json(scalarBody)).state?.draft.unicodeScalars.count == 16_000, "Unicode scalar draft limit permits multibyte characters")
        scalarState["draft"] = String(repeating: "e\u{301}", count: 8001); scalarBody["state"] = scalarState
        rejects(422, "combined characters count as separate Unicode scalars") { _ = try RemoteDisplayRequest.decode(json(scalarBody)) }
        var home = stateJSON; home["view"] = "home"; home["chatID"] = NSNull(); home["slotIndex"] = NSNull()
        var homeBody = claimJSON; homeBody["state"] = home
        check(try RemoteDisplayRequest.decode(json(homeBody)).state?.chatID == nil, "home allows null target")
        let encodedHome = try object(RemoteDisplayRequest.decode(json(homeBody)).state!)
        check(encodedHome["chatID"] is NSNull && encodedHome["slotIndex"] is NSNull, "home snapshot encodes explicit null wire fields")
        var unmappedChat = stateJSON; unmappedChat["slotIndex"] = NSNull()
        var unmappedBody = claimJSON; unmappedBody["state"] = unmappedChat
        let encodedUnmapped = try object(RemoteDisplayRequest.decode(json(unmappedBody)).state!)
        check(encodedUnmapped["slotIndex"] is NSNull && encodedUnmapped["chatID"] as? String == "a", "unmapped chat encodes explicit null slot")
        home.removeValue(forKey: "chatID"); home.removeValue(forKey: "slotIndex"); homeBody["state"] = home
        check(try RemoteDisplayRequest.decode(json(homeBody)).state?.slotIndex == nil, "Swift omitted optionals supported")
        for change: [String: Any] in [["operation": "sendPrompt"], ["sourceID": "not-uuid"], ["sourceName": "Mac"], ["takeover": 1]] {
            var body = claimJSON; body.merge(change) { _, new in new }
            rejects(422, "closed operation validation " + change.keys.first!) { _ = try RemoteDisplayRequest.decode(json(body)) }
        }
        rejects(422, "malformed JSON is structured invalid input") { _ = try RemoteDisplayRequest.decode(Data("{".utf8)) }
        rejects(422, "request byte limit") { _ = try RemoteDisplayRequest.decode(Data(repeating: 32, count: 131_073)) }
        let validFeedback: [String: Any] = ["revision": 1, "provider": "codex", "chatID": "a", "view": "reply", "pageCount": 2, "renderedPage": 0, "connected": true]
        for change: [String: Any] in [["revision": 0], ["revision": true], ["pageCount": 0], ["pageCount": 1001], ["pageCount": 2.5], ["renderedPage": -1], ["renderedPage": 2], ["connected": 1], ["draft": "private text"], ["leaseID": UUID().uuidString], ["action": "sendPrompt"], ["sourceID": phone.uuidString]] {
            var body = validFeedback; body.merge(change) { _, new in new }
            rejects(422, "feedback bounds and no input authority " + change.keys.first!) { _ = try RemoteDisplayFeedbackRequest.decode(json(body)) }
        }
        rejects(422, "feedback byte limit") { _ = try RemoteDisplayFeedbackRequest.decode(Data(repeating: 32, count: 4097)) }
        print("Remote display session: \(checks) checks passed")
    }
}
