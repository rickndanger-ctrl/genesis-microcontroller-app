import AppKit

/// Whether someone's hands are on this Mac's keyboard or mouse buttons.
///
/// The controller is also used as a desk-side macro pad, so a Mac being in use
/// is normal and never a reason to refuse outright. What must not happen is a
/// collision: the companion typing into a message box, or clicking, in the
/// same instant as the person. So it waits for a short quiet moment first.
/// Only hardware input counts; the companion's own synthetic events do not.
enum MacInput {
    /// The rule, kept apart from the readings so it can be tested.
    static func isQuiet(secondsSinceKey: Double, buttonDown: Bool, needed: Double) -> Bool {
        !buttonDown && secondsSinceKey >= needed
    }

    static var secondsSinceKey: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }

    static var buttonDown: Bool {
        CGEventSource.buttonState(.hidSystemState, button: .left) || CGEventSource.buttonState(.hidSystemState, button: .right)
    }

    /// Waits until no mouse button is held and no key has been pressed for
    /// `needed` seconds. Returns false if that does not happen within `timeout`.
    @MainActor static func waitForQuiet(needed: Double = 0.7, timeout: Double = 3) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if isQuiet(secondsSinceKey: secondsSinceKey, buttonDown: buttonDown, needed: needed) { return true }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    static let busyMessage = "Keys or the mouse are in use on this Mac. Pause for a moment and try again"
}
