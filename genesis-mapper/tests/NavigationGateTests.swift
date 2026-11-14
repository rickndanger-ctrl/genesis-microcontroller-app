import Foundation
@main struct NavigationGateTests {
 static func main() {
  var gate=NavigationGate()
  precondition(!gate.accept(session:1,sequence:1,pid:10,hasMenu:true))
  gate.begin(session:1,pid:10)
  precondition(!gate.accept(session:1,sequence:1,pid:11,hasMenu:true)) // Different app.
  precondition(!gate.accept(session:1,sequence:1,pid:10,hasMenu:false)) // Closed menu / composer.
  precondition(!gate.accept(session:2,sequence:1,pid:10,hasMenu:true)) // Previous device session.
  precondition(gate.accept(session:1,sequence:1,pid:10,hasMenu:true))
  precondition(!gate.accept(session:1,sequence:1,pid:10,hasMenu:true)) // Duplicate.
  precondition(gate.accept(session:1,sequence:3,pid:10,hasMenu:true)) // Lost noncritical report.
  precondition(!gate.accept(session:1,sequence:2,pid:10,hasMenu:true)) // Out of order.
  precondition(!gate.accept(session:1,sequence:90,pid:10,hasMenu:true)) // Invalid jump.
  gate.end();precondition(!gate.accept(session:1,sequence:4,pid:10,hasMenu:true))
  gate.begin(session:2,pid:10)
  precondition(!gate.accept(session:1,sequence:5,pid:10,hasMenu:true))
  precondition(gate.accept(session:2,sequence:1,pid:10,hasMenu:true))
  print("Navigation event replay, ordering, stale session, focus and closed-menu checks passed")
 }
}
