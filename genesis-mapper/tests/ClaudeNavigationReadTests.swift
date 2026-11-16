import Foundation

@main struct ClaudeNavigationReadTests {
    @MainActor static func main() async {
        typealias Snapshot=ClaudeNavigationSnapshot<String>
        func sample(_ destinations:[String]=[],header:Int=0,sidebar:[String]=[],complete:Bool=true)->Snapshot {
            Snapshot(headerCount:header,destinations:destinations,sidebarControls:sidebar,complete:complete)
        }
        final class Fixture {
            var time=0.0,reads=0,sleeps=0,context=true
            var afterSleep:(()->Void)?
        }
        func resolve(_ samples:[Snapshot],_ fixture:Fixture=Fixture(),mode:ClaudeNavigationRead.Mode = .destination,
            deadline:Double=2.5,scanDuration:Double=0) async ->ClaudeNavigationReadResult<String> {
            await ClaudeNavigationRead.resolve(mode:mode,deadline:deadline,now:{fixture.time},contextIsCurrent:{fixture.context},read:{_ in
                let snapshot=samples[min(fixture.reads,samples.count-1)]
                fixture.reads+=1;fixture.time+=scanDuration;return snapshot
            },sleep:{ns in
                fixture.sleeps+=1;fixture.time+=Double(ns)/1_000_000_000;fixture.afterSleep?()
            })
        }
        var checks=0
        let missing=Fixture()
        guard case .ready(let recovered)=await resolve([sample(),sample(["exact target"])],missing) else {fatalError("fresh snapshot should recover missing target")}
        precondition(recovered.destinations==["exact target"] && missing.reads==2 && missing.sleeps==1);checks+=1

        let partial=Fixture()
        guard case .ready=await resolve([sample(["exact target"],complete:false),sample(["exact target"])],partial) else {fatalError("transient AX failure should retry")}
        precondition(partial.reads==2);checks+=1

        let ambiguous=Fixture()
        guard case .ambiguous=await resolve([sample(["fork 1","fork 2"],complete:false),sample(["fork 1"])],ambiguous) else {fatalError("duplicate targets must fail immediately")}
        precondition(ambiguous.reads==1 && ambiguous.sleeps==0);checks+=1
        guard case .ambiguous=await resolve([sample(header:2)]) else {fatalError("duplicate current headers must fail")};checks+=1
        guard case .ambiguous=await resolve([sample(["partial fork"],complete:false),sample(["fork 1","fork 2"])]) else {fatalError("partial uniqueness must not authorize before fresh read exposes duplicate")};checks+=1

        let expired=Fixture()
        guard case .unavailable=await resolve([sample(["late target"])],expired,scanDuration:3) else {fatalError("late complete snapshot must not authorize a click")}
        precondition(expired.reads==1);checks+=1

        let changed=Fixture();changed.afterSleep={changed.context=false}
        guard case .contextChanged=await resolve([sample(),sample(["new process target"])],changed) else {fatalError("context/PID/foreground change must stop retry")}
        precondition(changed.reads==1);checks+=1
        let initiallyChanged=Fixture();initiallyChanged.context=false
        guard case .contextChanged=await resolve([sample(["target"])],initiallyChanged) else {fatalError("stale context must not read")}
        precondition(initiallyChanged.reads==0);checks+=1
        let duringRead=Fixture()
        let changedRead=await ClaudeNavigationRead.resolve(mode:.destination,deadline:2.5,now:{0},contextIsCurrent:{duringRead.context},read:{_ in
            duringRead.context=false;return sample(["target from stale process"])
        },sleep:{_ in fatalError("changed context must not wait")})
        guard case .contextChanged=changedRead else {fatalError("context must still match after synchronous read")};checks+=1

        let exhausted=Fixture()
        guard case .unavailable=await resolve([sample()],exhausted) else {fatalError("persistent missing target must fail")}
        precondition(exhausted.reads==3 && exhausted.sleeps==2);checks+=1
        let bounded=Fixture()
        guard case .unavailable=await resolve([sample()],bounded,deadline:0.15,scanDuration:0.1) else {fatalError("retry must share one deadline")}
        precondition(bounded.reads==1 && bounded.sleeps==0);checks+=1

        let confirmation=Fixture()
        guard case .ready(let confirmed)=await resolve([sample(),sample(["exact target"],header:1)],confirmation,mode:.current) else {fatalError("post-click empty snapshot should recover read-only")}
        precondition(confirmed.isCurrent && confirmation.reads==2);checks+=1
        guard case .unavailable=await resolve([sample(["target"])],mode:.current) else {fatalError("sidebar target alone must not confirm navigation")};checks+=1
        let partialHeader=Fixture()
        guard case .ready=await resolve([sample(header:1,complete:false),sample(header:1)],partialHeader,mode:.current) else {fatalError("incomplete header must not confirm")}
        precondition(partialHeader.reads==2);checks+=1

        let sidebar=Fixture()
        guard case .ready(let show)=await resolve([sample(),sample(sidebar:["show sidebar"])],sidebar) else {fatalError("fresh sidebar control should be returned to caller once")}
        precondition(show.sidebarControls.count==1 && sidebar.reads==2);checks+=1
        func inventory(_ observations:[ClaudeInventoryRead.Result<String>],_ fixture:Fixture=Fixture(),scanDuration:Double=0) async ->ClaudeInventoryRead.Result<String> {
            await ClaudeInventoryRead.resolve(deadline:2.5,now:{fixture.time},contextIsCurrent:{fixture.context},read:{_ in
                let result=observations[min(fixture.reads,observations.count-1)];fixture.reads+=1;fixture.time+=scanDuration;return result
            },sleep:{ns in fixture.sleeps+=1;fixture.time+=Double(ns)/1_000_000_000;fixture.afterSleep?()})
        }
        let inventoryFresh=Fixture()
        guard case .found("exact ID")=await inventory([.missing,.found("exact ID")],inventoryFresh) else {fatalError("missing fresh full inventory should recover")}
        precondition(inventoryFresh.reads==2);checks+=1
        let inventoryAmbiguous=Fixture()
        guard case .ambiguous=await inventory([.ambiguous,.found("guessed fork")],inventoryAmbiguous) else {fatalError("ambiguous inventory must fail immediately")}
        precondition(inventoryAmbiguous.reads==1);checks+=1
        let inventoryMissing=Fixture()
        guard case .missing=await inventory([.missing],inventoryMissing) else {fatalError("missing inventory must remain unavailable")}
        precondition(inventoryMissing.reads==3 && inventoryMissing.sleeps==2);checks+=1
        guard case .missing=await inventory([.found("late")],scanDuration:3) else {fatalError("inventory result after deadline cannot authorize")};checks+=1
        let inventoryChanged=Fixture();inventoryChanged.afterSleep={inventoryChanged.context=false}
        guard case .contextChanged=await inventory([.missing,.found("new process")],inventoryChanged) else {fatalError("inventory retries must preserve process and context")}
        precondition(inventoryChanged.reads==1);checks+=1

        enum Cancelled:Error {case fixture}
        let cancelled=await ClaudeNavigationRead.resolve(mode:.destination,deadline:2.5,now:{0},contextIsCurrent:{true},read:{_ in sample()},sleep:{_ in throw Cancelled.fixture})
        guard case .contextChanged=cancelled else {fatalError("cancelled wait must not continue")};checks+=1

        // Each retry must begin a separate synchronous snapshot, including
        // previously cached nil attributes from the missing first AX tree.
        struct Attribute {let value:String?}
        let cache=ReadSnapshotCache<String,Attribute>(),fresh=Fixture()
        let cached=await ClaudeNavigationRead.resolve(mode:.destination,deadline:2.5,now:{fresh.time},contextIsCurrent:{true},read:{_ in
            cache.withSnapshot {
                let value=cache["row"] ?? Attribute(value:fresh.reads==0 ? nil:"exact target")
                cache["row"]=value;fresh.reads+=1
                return sample(value.value.map{[$0]} ?? [])
            }
        },sleep:{_ in fresh.time+=0.1})
        guard case .ready=cached else {fatalError("cached nil must not leak into next attempt")}
        precondition(fresh.reads==2 && cache["row"]==nil);checks+=1
        print("PASS \(checks) bounded Claude navigation read checks")
    }
}
