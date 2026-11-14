import Foundation

// Carry the physical input identity through Claude's asynchronous stop check.
struct ClaudeTalkFocusContext {
    let boot:String
    let revision:Int
    let generation:Int
    init?(event:[String:Any],generation:Int) {
        guard let boot=event["boot_id"] as? String,boot.count==32,
              boot.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}),
              let revision=event["input_revision"] as? Int,revision>0,revision<=Int(UInt32.max) else{return nil}
        self.boot=boot;self.revision=revision;self.generation=generation
    }
    func request(result:String,currentGeneration:Int,claudeActive:Bool,sameChat:Bool,
                 pendingWork:Bool,sendAction:String) -> [String:Any]? {
        guard result=="Dictation stopped",generation==currentGeneration,claudeActive,sameChat,
              !pendingWork,sendAction=="send" else{return nil}
        return ["boot_id":boot,"input_revision":revision]
    }
}
