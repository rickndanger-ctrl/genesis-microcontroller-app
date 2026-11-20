import Foundation

/// A key pressed while the Mac was still finishing the previous command.
/// Rather than being thrown away, it waits for that command and then runs,
/// provided the wait was short and the command it followed went through.
struct DeferredTap: Equatable {
    enum Target: Equatable {
        case slot(Int)
        case action(String)
    }

    /// Longer than this and the press no longer reflects what is on screen.
    static let patience: TimeInterval = 4

    /// Send and dictation never wait: each must act on exactly what the
    /// person sees at the moment they press.
    static func mayWait(_ actionID: String) -> Bool { !["sendPrompt", "dictate"].contains(actionID) }

    let target: Target
    let pressed: Date

    func shouldRun(now: Date, previousSucceeded: Bool) -> Bool {
        previousSucceeded && now.timeIntervalSince(pressed) >= 0 && now.timeIntervalSince(pressed) <= Self.patience
    }
}
