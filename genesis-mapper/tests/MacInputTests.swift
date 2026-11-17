import Foundation

@main struct MacInputTests {
    static var passed = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("FAIL: " + message) }
        passed += 1
    }
    static func main() {
        expect(MacInput.isQuiet(secondsSinceKey: 5, buttonDown: false, needed: 0.7), "No keys for five seconds and no button held is quiet")
        expect(!MacInput.isQuiet(secondsSinceKey: 0.2, buttonDown: false, needed: 0.7), "A key a fifth of a second ago is not quiet")
        expect(MacInput.isQuiet(secondsSinceKey: 0.7, buttonDown: false, needed: 0.7), "Exactly the needed gap counts as quiet")
        expect(!MacInput.isQuiet(secondsSinceKey: 60, buttonDown: true, needed: 0.7), "A held mouse button is never quiet, however long since a key")
        expect(MacInput.isQuiet(secondsSinceKey: 0, buttonDown: false, needed: 0), "With no gap needed, only a held button matters")
        expect(!MacInput.isQuiet(secondsSinceKey: 0, buttonDown: true, needed: 0), "A held button blocks even when no gap is needed")
        expect(MacInput.busyMessage.hasSuffix("try again"), "The busy message leaves room for what was not done")
        print("Mac input: \(passed) checks passed")
    }
}
