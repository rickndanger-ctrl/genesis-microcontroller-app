import Foundation

@main struct PromptRouteGateTests {
    static let boot = "303a1001abcdef1234567890abcdef12"
    static let otherBoot = "403a1001abcdef1234567890abcdef12"

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        print("PASS: \(name)")
    }

    static func status(boot: String = boot, route: String = "quiet", owner: String = "",
                       remaining: Int = 0, down: Bool = false) -> PromptRouteGate.Status {
        PromptRouteGate.Status(["prompt_protocol":1,"boot_id":boot,"prompt_route":route,
            "lease_session":owner,"lease_remaining_ms":remaining,"prompt_down":down])!
    }

    static func event(_ edge: String, _ seq: Int, _ gesture: String,
                      boot: String = boot, session: String) -> [String:Any] {
        ["m":"genesis.prompt","p":["v":1,"boot_id":boot,"session":session,
            "gesture":gesture,"seq":seq,"edge":edge]]
    }

    static func leasedGate(session: String = UUID().uuidString.lowercased(),
                           boot: String = boot, sentAt: Double = 10,
                           now: Double = 10.1) -> PromptRouteGate {
        var gate=PromptRouteGate(session:session)
        _=gate.observe(status(boot:boot),now:now)
        precondition(gate.acceptLeaseAck(bootID:boot,session:session,sentAt:sentAt,
            acceptedMS:3_000,now:now))
        _=gate.observe(status(boot:boot,owner:session,remaining:2_800),now:now+0.1)
        return gate
    }

    static func main() {
        check(PromptRouteGate.Status.validBootID(boot),"accepts exactly a 128-bit hex boot identifier")
        check(!PromptRouteGate.Status.validBootID("short"),"rejects malformed boot identifiers")
        check(PromptRouteGate.Status(["prompt_protocol":2,"boot_id":boot,"prompt_route":"quiet","lease_session":"","lease_remaining_ms":0,"prompt_down":false]) == nil,
              "rejects unsupported protocol versions")

        var gate=PromptRouteGate()
        _=gate.observe(status(),now:10)
        let session=gate.session, gesture=boot+":1"
        check(!gate.acceptLeaseAck(bootID:otherBoot,session:session,sentAt:10,acceptedMS:3000,now:10.1),
              "rejects lease ACK for a different boot")
        gate=leasedGate(session:session)
        check(!gate.acceptLeaseAck(bootID:boot,session:session,sentAt:10,acceptedMS:3001,now:10.1),
              "rejects TTL above requested lease")
        gate=PromptRouteGate(session:session)
        _=gate.observe(status(),now:13.01)
        check(!gate.acceptLeaseAck(bootID:boot,session:session,sentAt:10,acceptedMS:3000,now:13.01),
              "rejects delayed ACK after send-time expiry")

        gate=leasedGate(session:session)
        let start=gate.handle(event("down",1,gesture,session:session),targetPID:0,now:10.3)
        check(start == .start(.init(bootID:boot,session:session,id:gesture)),"valid physical down starts once")
        check(gate.handle(event("down",1,gesture,session:session),targetPID:0,now:10.3) == nil,"duplicate sequence is ignored")
        check(gate.handle(event("up",2,gesture,session:session),targetPID:0,now:10.4) == .stop(.init(bootID:boot,session:session,id:gesture)),
              "matching release stops the same gesture")
        check(gate.handle(event("down",3,gesture,session:session),targetPID:0,now:10.5) == nil,"released gesture cannot replay")

        gate=leasedGate(session:session)
        let canceledGesture=boot+":13"
        _=gate.handle(event("down",1,canceledGesture,session:session),targetPID:0,now:10.3)
        check(gate.handle(event("cancel",2,canceledGesture,session:session),targetPID:0,now:10.4) == .cancel(.init(bootID:boot,session:session,id:canceledGesture)),
              "firmware cancel clears active gesture")
        check(gate.handle(event("down",3,boot+":14",session:session),targetPID:0,now:10.5) == nil,"cancelled hold stays quarantined until release")
        _=gate.observe(status(owner:session,remaining:2000,down:false),now:10.6)
        check(gate.handle(event("down",4,boot+":15",session:session),targetPID:0,now:10.7) != nil,"status-observed release exits cancellation quarantine")

        gate=leasedGate(session:session)
        let first=boot+":9", overlap=boot+":10"
        _=gate.handle(event("down",10,first,session:session),targetPID:0,now:10.3)
        check(gate.handle(event("down",11,overlap,session:session),targetPID:0,now:10.4) == .cancel(.init(bootID:boot,session:session,id:first)),
              "overlapping physical down cancels current gesture fail-closed")
        check(gate.handle(event("up",12,overlap,session:session),targetPID:0,now:10.5) == nil,"overlapping gesture remains quarantined through release")

        gate=leasedGate(session:session)
        let quick=boot+":2"
        check(gate.handle(event("up",2,quick,session:session),targetPID:0,now:10.3) == nil,"release-before-start tombstones gesture")
        check(gate.handle(event("down",3,quick,session:session),targetPID:0,now:10.4) == nil,"late down cannot revive tombstone")

        gate=leasedGate(session:session)
        check(gate.handle(event("down",4,boot+":3",session:session),targetPID:0,now:10.3) != nil,"new monotonic sequence accepted")
        check(gate.handle(event("up",3,boot+":3",session:session),targetPID:0,now:10.4) == nil,"reordered stale edge ignored")
        let cancel=gate.leaseExpired(now:13.1)
        check(cancel == .cancel(.init(bootID:boot,session:session,id:boot+":3")),"lease expiry cancels active capture")
        check(gate.handle(event("up",5,boot+":3",session:session),targetPID:0,now:13.2) == nil,"post-expiry release never becomes a stop")

        gate=leasedGate(session:session)
        let leasedGesture=boot+":11"
        _=gate.handle(event("down",1,leasedGesture,session:session),targetPID:0,now:10.3)
        check(!gate.acceptLeaseAck(bootID:otherBoot,session:session,sentAt:10.2,acceptedMS:3000,now:10.4),
              "bad renewal is rejected")
        check(gate.loseLease() == .cancel(.init(bootID:boot,session:session,id:leasedGesture)),
              "known lease loss returns the bound active cancellation")
        check(gate.loseLease() == nil,"lease-loss cancellation is emitted only once")
        let staleStart=PromptRouteGate.Gesture(bootID:boot,session:session,id:boot+":12")
        check(!PromptRouteGate.failedStartBelongs(to:staleStart,current:nil),"failed old start cannot cancel when no longer active")
        check(!PromptRouteGate.failedStartBelongs(to:staleStart,current:.init(bootID:boot,session:session,id:boot+":13")),
              "failed old start cannot cancel a newer gesture")

        gate=leasedGate(session:session)
        check(gate.handle(event("down",1,boot+":4",session:UUID().uuidString),targetPID:0,now:10.3) == nil,"wrong session is ignored")
        check(gate.handle(event("down",1,otherBoot+":4",boot:otherBoot,session:session),targetPID:0,now:10.3) == nil,"wrong boot is ignored")

        gate=leasedGate(session:session)
        let active=boot+":5"
        _=gate.handle(event("down",1,active,session:session),targetPID:0,now:10.3)
        let loss=gate.observe(status(route:"native",owner:session,remaining:2000,down:true),now:10.4)
        check(loss == .cancel(.init(bootID:boot,session:session,id:active)),"route change cancels owned gesture")
        check(gate.handle(event("up",2,active,session:session),targetPID:0,now:10.5) == nil,"native route cannot dispatch release")

        gate=leasedGate(session:session)
        let old=boot+":6"
        _=gate.handle(event("down",1,old,session:session),targetPID:0,now:10.3)
        check(gate.disconnected() == .cancel(.init(bootID:boot,session:session,id:old)),"disconnect cancels active gesture")
        check(gate.session != session,"reconnect receives a new lease session")
        check(gate.handle(event("up",2,old,session:session),targetPID:0,now:10.4) == nil,"old session release is quarantined")

        var held=PromptRouteGate(session:session)
        _=held.observe(status(down:true),now:10)
        _=held.acceptLeaseAck(bootID:boot,session:session,sentAt:10,acceptedMS:3000,now:10.1)
        _=held.observe(status(owner:session,remaining:2800,down:true),now:10.2)
        check(held.handle(event("down",1,boot+":7",session:session),targetPID:0,now:10.3) == nil,"status already held quarantines starts")
        check(held.handle(event("up",2,boot+":7",session:session),targetPID:0,now:10.4) == nil,"quarantined release clears without stopping")
        check(held.handle(event("down",3,boot+":8",session:session),targetPID:0,now:10.5) != nil,"fresh press after release is allowed")

        let startURL=PromptURLBuilder.make(.start,session:session,gesture:gesture,nowMilliseconds:1000)!
        let parts=URLComponents(url:startURL,resolvingAgainstBaseURL:false)!
        check(startURL.host=="controller-start" && parts.queryItems?.first(where:{$0.name=="expires_at_ms"})?.value=="3000",
              "start URL carries explicit gesture and two-second freshness bound")
        let stopURL=PromptURLBuilder.make(.stop,session:session,gesture:gesture,nowMilliseconds:1000)!
        check(URLComponents(url:stopURL,resolvingAgainstBaseURL:false)?.queryItems?.allSatisfy({$0.name != "issued_at_ms" && $0.name != "expires_at_ms"}) == true,
              "stop URL remains available for tombstoning without freshness expiry")
        check(PromptURLBuilder.make(.start,session:"bad-session",gesture:gesture,nowMilliseconds:1000)==nil,
              "rejects malformed session identifier")
        check(PromptAppLifecyclePolicy.desiredRoute(runningPID:nil,currentRoute:"quiet",promptDown:false)=="native",
              "app absent while released restores native route")
        check(PromptAppLifecyclePolicy.desiredRoute(runningPID:nil,currentRoute:"native",promptDown:false)==nil,
              "app absent and native route does not repeatedly reconfigure")
        check(PromptAppLifecyclePolicy.desiredRoute(runningPID:91,currentRoute:"native",promptDown:false)=="quiet",
              "explicitly running app requests quiet route only when released")
        check(PromptAppLifecyclePolicy.desiredRoute(runningPID:91,integrationEnabled:false,
              currentRoute:"quiet",promptDown:false)=="native",
              "open Quiet Studio does not change native Prompt routing while integration is off")
        check(PromptAppLifecyclePolicy.desiredRoute(runningPID:91,integrationEnabled:false,
              currentRoute:"native",promptDown:false)==nil,
              "disabled integration leaves an already-native route untouched")
        check(!PromptAppLifecyclePolicy.mayAcquireLease(runningPID:91,integrationEnabled:false,
              route:"quiet",promptDown:false,leaseOwner:"",session:session),
              "disabled integration cannot acquire a Prompt lease")
        check(!PromptAppLifecyclePolicy.mayDispatch(targetPID:91,livePID:91,integrationEnabled:false),
              "disabled integration cannot dispatch Prompt events even with the app open")
        check(!PromptAppLifecyclePolicy.mayAcceptLeaseAcknowledgment(integrationEnabled:false,
              targetPID:91,livePID:91),
              "a late lease acknowledgment cannot be accepted after integration is turned off")
        check(PromptAppLifecyclePolicy.mayDispatch(targetPID:91,livePID:91,
              integrationEnabled:false,terminalCleanup:true),
              "bound terminal cancellation remains deliverable after integration is turned off")
        check(PromptAppLifecyclePolicy.desiredRoute(runningPID:91,currentRoute:"native",promptDown:true)==nil,
              "running app cannot switch route during native-held gesture")
        check(PromptAppLifecyclePolicy.desiredRoute(runningPID:nil,currentRoute:"quiet",promptDown:true)==nil,
              "app quit during held quiet gesture defers native route change")
        check(!PromptAppLifecyclePolicy.mayDispatch(targetPID:91,livePID:nil),
              "app exit between liveness check and send cannot deliver or launch")
        check(!PromptAppLifecyclePolicy.mayDispatch(targetPID:91,livePID:92),
              "delayed notification cannot bind a relaunched process")
        check(PromptAppLifecyclePolicy.mayDispatch(targetPID:91,livePID:91),
              "notification remains bound to exact live process")
        gate=leasedGate(session:session)
        let pidGesture=boot+":21"
        let pidStart=gate.handle(event("down",30,pidGesture,session:session),targetPID:91,now:10.3)
        check(pidStart == .start(.init(bootID:boot,session:session,id:pidGesture,targetPID:91)),
              "physical down carries the verified target process into the captured gesture")
        check(PromptAppLifecyclePolicy.mayDispatch(targetPID:pidStart.flatMap { action in
            if case .start(let captured)=action { return captured.targetPID }; return nil
        },livePID:91),"captured start can dispatch only to its verified process")
        check(gate.handle(event("up",31,pidGesture,session:session),targetPID:92,now:10.4) == .stop(.init(bootID:boot,session:session,id:pidGesture,targetPID:91)),
              "release stays bound to the original process even if a replacement launches")
        check(!PromptAppLifecyclePolicy.mayAcquireLease(runningPID:nil,route:"quiet",promptDown:false,leaseOwner:"",session:session),
              "companion reconnect with app absent never acquires quiet lease")
        check(!PromptAppLifecyclePolicy.mayAcquireLease(runningPID:91,route:"native",promptDown:false,leaseOwner:"",session:session),
              "lease waits for firmware quiet-route confirmation")
        check(PromptAppLifecyclePolicy.mayAcquireLease(runningPID:91,route:"quiet",promptDown:false,leaseOwner:"",session:session),
              "fresh process may claim released quiet route")
        check(!PromptAppLifecyclePolicy.mayAcquireLease(runningPID:91,route:"quiet",promptDown:true,leaseOwner:"old-session",session:session),
              "reconnect cannot inherit old held lease")
        check(PromptAppLifecyclePolicy.mayAcquireLease(runningPID:91,route:"quiet",promptDown:true,leaseOwner:session,session:session),
              "same live owner may renew while its captured press is held")
        print("PASS: 61 Prompt route assertions")
    }
}
