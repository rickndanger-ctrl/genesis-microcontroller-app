import Foundation

// Session + sequence + foreground checks keep stale HID events out of a new menu.
struct NavigationGate {
    private(set) var session=0
    private(set) var pid:Int32=0
    private(set) var sequence=0
    mutating func begin(session:Int,pid:Int32) {self.session=session;self.pid=pid;sequence=0}
    mutating func end() {session=0;pid=0;sequence=0}
    mutating func accept(session:Int,sequence:Int,pid:Int32,hasMenu:Bool)->Bool {
        guard self.session>0,session==self.session,sequence>self.sequence,sequence-self.sequence<=64,
              self.pid==pid,hasMenu else {return false}
        self.sequence=sequence;return true
    }
}
