import Foundation

@main struct ClaudeSidebarTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError("FAIL: \(message)") }
    }
    static func main() {
        typealias S = ClaudeSidebar
        // Wording seen in Claude 5.11: the state follows the title, with extra words after it.
        expect(S.state(title: "Screen content review", labels: ["Screen content review Unread response"]) == "Unread", "\"Unread response\" is a finished session")
        expect(S.state(title: "Status check", labels: ["Status check Something went wrong Merged"]) == "Something went wrong", "An error followed by a tag is still an error")
        expect(S.state(title: "Genesis Controller UI redesign", labels: ["Genesis Controller UI redesign Running"]) == "Working", "Running is working")
        expect(S.state(title: "Viral YouTube channel concepts", labels: ["Viral YouTube channel concepts Cloud · Draft"]) == "Open", "Tags alone are not a state")
        expect(S.state(title: "App bug review", labels: ["App bug review"]) == "Open", "A row with only its title is idle")
        expect(S.state(title: "App bug review", labels: []) == "Open", "A row with nothing is idle")
        // Older wording, still accepted.
        expect(S.state(title: "Fix login", labels: ["Fix login Unread"]) == "Unread", "The older exact wording still works")
        expect(S.state(title: "Fix login", labels: ["Needs input Fix login"]) == "Needs input", "A state before the title still works")
        expect(S.state(title: "Fix login", labels: ["More options for Fix login", "Working"]) == "Working", "A label that is only the state still works")
        expect(S.state(title: "Fix login", labels: ["Fix login Awaiting input"]) == "Needs input", "Awaiting input is needs input")
        expect(S.state(title: "Fix login", labels: ["Fix login Needs approval"]) == "Needs input", "Needing approval is needs input")
        expect(S.state(title: "Fix login", labels: ["Fix login Waiting for your input now"]) == "Needs input", "Waiting for input is needs input")
        // Titles that look like states must not fool it.
        expect(S.state(title: "Running", labels: ["Running"]) == "Open", "A session titled Running is not thereby working")
        expect(S.state(title: "Fix Running", labels: ["Fix Running"]) == "Open", "A title ending in a state word is just a title")
        expect(S.state(title: "Fix", labels: ["Fix Runningman"]) == "Open", "A state must be a whole word")
        expect(S.state(title: "Unread", labels: ["Unread Unread response"]) == "Unread", "A session titled Unread can still be unread")
        expect(S.state(title: "Idle", labels: ["Idle Running"]) == "Working", "A session titled Idle can be working")
        expect(S.state(beginning: "Unread response") == "Unread" && S.state(beginning: "Unreadable") == nil && S.state(beginning: "") == nil, "Phrases match whole words from the start")

        // The new, unnamed session.
        expect(S.chosenFolder("Folder: PeakWeek") == "PeakWeek", "A chosen folder is read from its control")
        expect(S.chosenFolder("Folder: Choose folder…") == nil && S.chosenFolder("Folder: Choose folder") == nil, "\"Choose folder\" is no folder")
        expect(S.chosenFolder("Folder: ") == nil && S.chosenFolder(nil) == nil && S.chosenFolder("Permissions: Auto") == nil, "A missing or different control is no folder")
        expect(S.sendBlocker(showing: true, namedHeaders: 0, composers: 1, folder: "PeakWeek") == nil, "A new session with a folder and one message box can take a prompt")
        expect(S.sendBlocker(showing: true, namedHeaders: 0, composers: 1, folder: nil)?.contains("no folder") == true, "Without a folder the prompt is held back, and says why")
        expect(S.sendBlocker(showing: false, namedHeaders: 0, composers: 1, folder: "PeakWeek")?.contains("no longer open") == true, "A prompt never goes anywhere once the new session is gone")
        expect(S.sendBlocker(showing: true, namedHeaders: 1, composers: 1, folder: "PeakWeek")?.contains("no longer open") == true, "A named session on screen is not the new session")
        expect(S.sendBlocker(showing: true, namedHeaders: 0, composers: 0, folder: "PeakWeek") != nil && S.sendBlocker(showing: true, namedHeaders: 0, composers: 2, folder: "PeakWeek") != nil, "There must be exactly one message box")
        expect(S.newSessionTitle(folder: "~/dev/powerlifting-trainer") == "New session · powerlifting-trainer", "The phone is shown which folder the first prompt will run in")
        expect(S.newSessionTitle(folder: "PeakWeek") == "New session · PeakWeek" && S.newSessionTitle(folder: nil) == "New session · no folder yet", "A bare name is used as it is, and a missing folder is said plainly")
        expect(!S.newSessionKey.isEmpty && S.newSessionKey != S.newSessionTitle, "The new session's key cannot collide with a session really titled New session")

        // Finished stays finished until someone looks.
        var latch = DoneLatch()
        func read(_ states: [String: String]) -> [String: String] { latch.observe(states.map { (id: $0.key, state: $0.value) }) }
        expect(read(["a": "Open", "b": "Open"]) == ["a": "Open", "b": "Open"], "Idle chats read as they are")
        expect(read(["a": "Working", "b": "Open"])["a"] == "Working", "A working chat reads as working")
        expect(read(["a": "Idle", "b": "Open"]) == ["a": "Unread", "b": "Open"], "A chat that stopped working is finished, even though the app says idle")
        expect(read(["a": "Idle", "b": "Open"])["a"] == "Unread", "It stays finished on later reads")
        expect(read([:]).isEmpty && read(["a": "Open", "b": "Open"])["a"] == "Unread", "A failed read forgets nothing")
        latch.acknowledge("a")
        expect(read(["a": "Open", "b": "Open"])["a"] == "Open", "Opening it from a controller clears it")
        _ = read(["a": "Working", "b": "Open"]); _ = read(["a": "Open", "b": "Open"])
        expect(read(["a": "Running", "b": "Open"])["a"] == "Running", "Starting work again clears finished")
        expect(read(["a": "Needs input", "b": "Open"])["a"] == "Needs input", "Working then waiting on you is waiting, not finished")
        expect(read(["a": "Open", "b": "Open"])["a"] == "Open", "Answering it leaves it idle, not finished: it never went from working to idle")
        _ = read(["a": "Working", "b": "Open"])
        expect(read(["a": "Something went wrong", "b": "Open"])["a"] == "Something went wrong", "Working then failing is an error, not finished")
        _ = read(["a": "Working", "b": "Working"]); _ = read(["a": "Idle", "b": "Current"])
        expect(latch.done == ["a", "b"], "Several chats can be finished at once")
        expect(read(["b": "Current"]) == ["b": "Unread"] && latch.done == ["b"], "A chat that is gone is forgotten")
        expect(read(["a": "Open", "b": "Unread"]) == ["a": "Open", "b": "Unread"], "A chat that returns starts clean, and the app's own unread is passed through")
        latch.acknowledge("nothing")
        print("Claude sidebar: \(checks) checks passed")
    }
}
