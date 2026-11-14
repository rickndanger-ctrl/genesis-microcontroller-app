import Foundation
@main struct ClaudeTalkFocusTests {
    static func main() {
        let event:[String:Any]=["boot_id":"0123456789abcdef0123456789abcdef","input_revision":42]
        let context=ClaudeTalkFocusContext(event:event,generation:7)!
        func request(_ result:String="Dictation stopped",generation:Int=7,claude:Bool=true,
                     sameChat:Bool=true,pending:Bool=false,send:String="send") -> [String:Any]? {
            context.request(result:result,currentGeneration:generation,claudeActive:claude,
                            sameChat:sameChat,pendingWork:pending,sendAction:send)
        }
        precondition(request()?["input_revision"] as? Int==42)
        precondition(request("Dictation started")==nil)
        precondition(request("Microphone did not change state. Try again.")==nil)
        precondition(request("Sent composer")==nil)
        precondition(request(generation:8)==nil) // Chat switch or reconnect during stop.
        precondition(request(claude:false)==nil)
        precondition(request(sameChat:false)==nil) // User changes chat with the mouse.
        precondition(request(pending:true)==nil) // Queued chat or microphone change.
        precondition(request(send:"new")==nil) // Repurposed Send slot is not selected.
        precondition(ClaudeTalkFocusContext(event:[:],generation:7)==nil) // Older firmware.
        var invalid=event;invalid["input_revision"]=0
        precondition(ClaudeTalkFocusContext(event:invalid,generation:7)==nil)
        invalid=event;invalid["boot_id"]="previous-boot"
        precondition(ClaudeTalkFocusContext(event:invalid,generation:7)==nil)
        print("Claude talk handoff: confirmed stop, queued work, changed chat/mode and old firmware checks passed")
    }
}
