import Foundation

/// Reading Claude's sidebar: what a session row says its session is doing.
///
/// Claude writes the state into the row's label after the title, and the
/// wording changes between versions ("Unread" became "Unread response", and
/// tags such as "Cloud", "Draft" or "Merged" may follow). So a state is
/// recognised by how its phrase begins, and reported in one fixed wording.
enum ClaudeSidebar {
    /// Phrases a row may carry, most specific first, and the state each means.
    static let phrases: [(phrase: String, state: String)] = [
        ("Something went wrong", "Something went wrong"),
        ("Awaiting input", "Needs input"), ("Awaiting approval", "Needs input"), ("Awaiting your input", "Needs input"),
        ("Needs input", "Needs input"), ("Needs your input", "Needs input"), ("Needs approval", "Needs input"), ("Needs permission", "Needs input"),
        ("Waiting for input", "Needs input"), ("Waiting for your input", "Needs input"), ("Waiting for approval", "Needs input"),
        ("Working", "Working"), ("Running", "Working"), ("Thinking", "Working"),
        ("Unread", "Unread"),
        ("Idle", "Idle"),
    ]

    /// The state a phrase begins with: the whole phrase, or the phrase followed by more words.
    static func state(beginning text: String) -> String? {
        phrases.first { text == $0.phrase || text.hasPrefix($0.phrase + " ") }?.state
    }

    /// The state of the session called `title`, from the labels found in its row.
    /// "Open" when the row carries no state, which is how an idle session reads.
    static func state(title: String, labels: [String]) -> String {
        for label in labels {
            // "Title State …", "State Title" or a label that is only the state.
            if label.hasPrefix(title + " "), let found = state(beginning: String(label.dropFirst(title.count + 1))) { return found }
            if label.hasSuffix(" " + title), let found = state(beginning: String(label.dropLast(title.count + 1))),
               label == phraseText(found, in: label) + " " + title { return found }
            if label != title, let found = phrases.first(where: { $0.phrase == label })?.state { return found }
        }
        return "Open"
    }
    private static func phraseText(_ state: String, in label: String) -> String {
        phrases.first { $0.state == state && label.hasPrefix($0.phrase + " ") }?.phrase ?? ""
    }

    /// A new, unnamed session: what the phone is given to work in after New chat.
    static let newSessionTitle = "New session"
    /// What the phone shows for the new session: its folder is part of the name,
    /// because Claude may reuse the folder of an earlier new session and the
    /// first prompt will run there.
    static func newSessionTitle(folder: String?) -> String {
        guard let folder else { return newSessionTitle + " · no folder yet" }
        let name = folder.split(separator: "/").last.map(String.init) ?? folder
        return newSessionTitle + " · " + name
    }
    /// The internal name behind the new session's chat ID. No real title can equal it.
    static let newSessionKey = "\u{1}new-session"
    /// The folder a new session will work in, from its "Folder: …" control. Nil until one is chosen.
    static func chosenFolder(_ label: String?) -> String? {
        guard let label, label.hasPrefix("Folder: ") else { return nil }
        let folder = String(label.dropFirst("Folder: ".count)).trimmingCharacters(in: .whitespaces)
        return folder.isEmpty || folder.hasPrefix("Choose folder") ? nil : folder
    }
    /// Why a first prompt cannot go into the new session, or nil when it can.
    static func sendBlocker(showing: Bool, namedHeaders: Int, composers: Int, folder: String?) -> String? {
        guard showing, namedHeaders == 0 else { return "The new session is no longer open on the Mac. Press New chat again; nothing was sent." }
        guard composers == 1 else { return "The new session has no single message box. Nothing was sent." }
        guard folder != nil else { return "The new session has no folder yet. Choose one in Claude on the Mac, then send; nothing was sent." }
        return nil
    }
}

/// Keeps a finished chat marked as finished until someone looks at it.
///
/// An app only marks a chat unread while it is not on screen. The chat that is
/// open on the Mac goes from working straight back to idle, and the phone,
/// which is where you are looking, would never show that it finished. This
/// remembers which chats were working at the last read; one that has since gone
/// idle is reported as "Unread" until it is opened or sent to from a
/// controller, or starts working again.
struct DoneLatch {
    private(set) var working: Set<String> = []
    private(set) var done: Set<String> = []

    static func isWorking(_ state: String) -> Bool { ["Working", "Running"].contains(state) }
    static func isIdle(_ state: String) -> Bool { ["Idle", "Open", "Current"].contains(state) }

    /// Takes what was just read and returns the state to report for each chat.
    mutating func observe(_ chats: [(id: String, state: String)]) -> [String: String] {
        // An empty read is a failed read, not a Mac with no chats: forget nothing.
        guard !chats.isEmpty else { return [:] }
        let present = Set(chats.map(\.id))
        working.formIntersection(present); done.formIntersection(present)
        var reported: [String: String] = [:]
        for chat in chats {
            if Self.isWorking(chat.state) {
                working.insert(chat.id); done.remove(chat.id)
            } else if Self.isIdle(chat.state) {
                if working.remove(chat.id) != nil { done.insert(chat.id) }
            } else {
                // Unread, needs input or an error: the app is already saying so.
                working.remove(chat.id); done.remove(chat.id)
            }
            reported[chat.id] = done.contains(chat.id) ? "Unread" : chat.state
        }
        return reported
    }
    /// Someone has looked at this chat from a controller.
    mutating func acknowledge(_ id: String) { done.remove(id) }
}
