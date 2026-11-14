import Foundation

@main struct RemoteNavigationLeaseTests {
    static func main() {
        let id=UUID().uuidString
        let lease=RemoteNavigationLease(session:id,provider:"claude",chatID:"chat-1",generation:7,observedAt:100)
        var count=0
        func check(_ value:Bool,_ name:String) {precondition(value,name);count+=1}
        check(lease.accepts(session:id,provider:"claude",chatID:"chat-1",generation:7,now:101),"current menu")
        check(!lease.accepts(session:UUID().uuidString,provider:"claude",chatID:"chat-1",generation:7,now:101),"stale menu")
        check(!lease.accepts(session:id,provider:"codex",chatID:"chat-1",generation:7,now:101),"other provider")
        check(!lease.accepts(session:id,provider:"claude",chatID:"chat-2",generation:7,now:101),"other chat")
        check(!lease.accepts(session:id,provider:"claude",chatID:nil,generation:7,now:101),"missing chat")
        check(!lease.accepts(session:id,provider:"claude",chatID:"chat-1",generation:8,now:101),"new phone route")
        check(!lease.accepts(session:id,provider:"claude",chatID:"chat-1",generation:7,now:131),"expired")
        check(!lease.accepts(session:id,provider:"claude",chatID:"chat-1",generation:7,now:99),"clock reset")
        check(!lease.accepts(session:id,provider:"claude",chatID:"chat-1",generation:7,now:.nan),"invalid clock")
        check(!lease.accepts(session:id,provider:"claude",chatID:"chat-1",generation:7,now:.infinity),"infinite clock")
        check(Set(RemoteNavigationLease.commands).count==5,"bounded unique command set")
        check(!RemoteNavigationLease.commands.contains("sendPrompt"),"cannot submit from arbitrary action")
        let data=try! JSONEncoder().encode(RemoteNavigationState.inactive)
        let state=try! JSONDecoder().decode(RemoteNavigationState.self,from:data)
        check(!state.active && state.session==nil,"inactive state has no input authority")
        print("Remote navigation: \(count) lease checks passed")
    }
}
