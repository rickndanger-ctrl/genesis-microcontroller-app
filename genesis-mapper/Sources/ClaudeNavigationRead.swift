import Foundation

// Only reads are retried. A resolved element belongs to the final synchronous
// snapshot; callers may act on it once and must never retry the action itself.
struct ClaudeNavigationSnapshot<Element> {
    let headerCount:Int
    let destinations:[Element]
    let sidebarControls:[Element]
    let complete:Bool
    var isCurrent:Bool {headerCount==1}
    var destinationCount:Int {destinations.count}
}

enum ClaudeNavigationReadResult<Element> {
    case ready(ClaudeNavigationSnapshot<Element>)
    case unavailable,ambiguous,contextChanged
}

@MainActor enum ClaudeNavigationRead {
    enum Mode {case destination,current}
    static func resolve<Element>(mode:Mode,deadline:Double,maximumAttempts:Int=3,
        delayNanoseconds:UInt64=100_000_000,
        now:()->Double={ProcessInfo.processInfo.systemUptime},
        contextIsCurrent:()->Bool,
        read:(Double)->ClaudeNavigationSnapshot<Element>,
        sleep:(UInt64) async throws ->Void={try await Task.sleep(nanoseconds:$0)}
    ) async ->ClaudeNavigationReadResult<Element> {
        for attempt in 0..<maximumAttempts {
            guard !Task.isCancelled,contextIsCurrent() else{return .contextChanged}
            guard now()<deadline else{return .unavailable}
            let snapshot=read(deadline)
            guard !Task.isCancelled,contextIsCurrent() else{return .contextChanged}
            // Even a partial snapshot proving two destinations is ambiguous.
            if snapshot.headerCount>1 || snapshot.destinationCount>1 {return .ambiguous}
            guard now()<deadline else{return .unavailable}
            if snapshot.complete {
                switch mode {
                case .destination:
                    if snapshot.isCurrent || snapshot.destinationCount==1 || snapshot.sidebarControls.count==1 {return .ready(snapshot)}
                case .current:
                    if snapshot.isCurrent {return .ready(snapshot)}
                }
            }
            guard attempt+1<maximumAttempts else{return .unavailable}
            let remaining=deadline-now()
            guard remaining>Double(delayNanoseconds)/1_000_000_000 else{return .unavailable}
            do {try await sleep(delayNanoseconds)} catch{return .contextChanged}
        }
        return .unavailable
    }
}
