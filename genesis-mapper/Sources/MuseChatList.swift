import Foundation

/// The rules for reading Muse's chat panel and for judging a draft, kept free
/// of accessibility calls so they can be tested without the app.
///
/// Muse gives a chat no stable identifier, only the label on its row. A label
/// that appears on more than one row cannot be told apart, so those chats are
/// left out instead of guessed at.
enum MuseChatList {
    struct Row: Equatable {
        let label: String
        let current: Bool
    }
    struct Chat: Equatable {
        let title: String
        let current: Bool
        let unread: Bool
    }

    static let mainChat = "Main chat"
    static let unreadSuffix = " Unread updates"
    /// Controls in the panel that are buttons but not chats.
    static let controls: Set<String> = ["New side chat", "Channels", "Side chats"]

    static func chat(_ row: Row) -> Chat? {
        var title = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let unread = title.hasSuffix(unreadSuffix)
        if unread { title = String(title.dropLast(unreadSuffix.count)).trimmingCharacters(in: .whitespaces) }
        // A channel Muse marks "view only" cannot take a message from here.
        guard !title.isEmpty, !controls.contains(title), !title.hasSuffix("view only") else { return nil }
        return Chat(title: title, current: row.current, unread: unread)
    }

    /// The chats that can be addressed, in the panel's order, and the titles
    /// left out because several rows share them.
    static func chats(_ rows: [Row]) -> (chats: [Chat], ambiguous: Set<String>) {
        let all = rows.compactMap(chat)
        let counts = Dictionary(grouping: all, by: \.title).mapValues(\.count)
        return (all.filter { counts[$0.title] == 1 }, Set(counts.filter { $0.value > 1 }.keys))
    }

    /// The chat Muse is showing, when exactly one row is marked current.
    static func current(_ rows: [Row]) -> Chat? {
        let marked = rows.filter(\.current).compactMap(chat)
        return marked.count == 1 ? marked[0] : nil
    }

    static let panelToggleSuffix = "Open chat and side chats"

    /// The open chat, as named by the button that shows the chat panel. On the
    /// main chat it reads "Chats …"; on a side chat it starts with that
    /// chat's own title. An unread marker may sit before the suffix.
    static func openChat(fromToggle label: String) -> String? {
        guard label.hasSuffix(panelToggleSuffix) else { return nil }
        var title = String(label.dropLast(panelToggleSuffix.count)).trimmingCharacters(in: .whitespaces)
        if title.hasSuffix("Unread chats") { title = String(title.dropLast("Unread chats".count)).trimmingCharacters(in: .whitespaces) }
        return title.isEmpty ? nil : title == "Chats" ? mainChat : title
    }

    /// A side chat Muse has just opened and not yet named. It has no row in
    /// the panel and no header; Muse names it after its first message. It is
    /// offered under this title so a draft can be sent into it straight away.
    static let unnamedSideChat = "New side chat"

    /// The chat on screen, from what the window shows: the header's name when
    /// there is a header; otherwise an unnamed side chat, recognised by having
    /// no header, a way back to the main chat, and the plain message box.
    static func openChat(toggle: String?, hasBackToMain: Bool, boxLabels: [String]) -> String? {
        if let toggle { return openChat(fromToggle: toggle) }
        return hasBackToMain && boxLabels == [messageBoxLabel(for: unnamedSideChat)] ? unnamedSideChat : nil
    }

    /// What Muse's message box is called while it belongs to this chat. The
    /// box names its chat, which is checked before anything is typed. The main
    /// chat and an unnamed side chat share the plain label, so those two are
    /// told apart by `openChat(toggle:hasBackToMain:boxLabels:)`, never by the box.
    static func messageBoxLabel(for title: String) -> String {
        title == mainChat || title == unnamedSideChat ? "Message Attach file\nSend" : "Message in \(title) Attach file\nSend"
    }

    /// Whitespace varies between what was pasted and what the page hands back,
    /// so runs of it compare as one space.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The message box holds exactly the draft that was put there.
    static func holdsDraft(_ copied: String?, prompt: String) -> Bool {
        guard let copied else { return false }
        let draft = normalized(prompt)
        return !draft.isEmpty && normalized(copied) == draft
    }

    static let sentPrefix = "User message: "

    /// How many of these history strings are this draft. Muse shows a message
    /// either bare or behind a "User message: " label, depending on how the
    /// entry was drawn, so both forms count.
    static func deliveries(in history: [String], prompt: String) -> Int {
        let draft = normalized(prompt)
        guard !draft.isEmpty else { return 0 }
        return history.filter { normalized($0.hasPrefix(sentPrefix) ? String($0.dropFirst(sentPrefix.count)) : $0) == draft }.count
    }

    /// Delivery is confirmed by the draft appearing once more than it did
    /// before Return, so an identical older message cannot stand in for it.
    static func showsAsSent(before: Int, after: Int) -> Bool { after > before }

    /// While Muse answers, the box's Send becomes Stop.
    static func answeringBoxLabel(for title: String) -> String {
        String(messageBoxLabel(for: title).dropLast("Send".count)) + "Stop"
    }

    /// Muse re-renders some text when it is sent: markdown loses its marks
    /// and a link becomes its own element, so the exact draft never shows in
    /// the history. For those, delivery is confirmed by what sending causes:
    /// the history gains an entry, and either Muse starts answering or the
    /// message box is seen to be empty. Neither alone is enough.
    static func deliveredByEffect(entriesBefore: Int, entriesAfter: Int, answering: Bool, boxEmpty: Bool) -> Bool {
        entriesAfter > entriesBefore && (answering || boxEmpty)
    }
}
