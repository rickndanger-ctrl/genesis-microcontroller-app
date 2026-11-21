import Foundation
import CoreGraphics

/// What the outline diagnostic may say about a control's label.
enum OutlineLabel {
    /// Roles whose labels are chat titles, conversation headings or page titles.
    static let structural: Set<String> = ["AXWindow", "AXSheet", "AXLink", "AXHeading", "AXWebArea"]
    static func shown(role: String, subrole: String, name: String) -> String {
        if name.isEmpty { return "(no label)" }
        if structural.contains(role) || subrole.hasPrefix("AXLandmark") || name.count > 44 { return "(label of \(name.count) characters)" }
        return name
    }
}

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

    /// The tabs of Muse's Status panel. Beside a chat the panel is harmless,
    /// but in a narrow window Muse draws the panel alone: no chat, no message
    /// box, and no button to close it.
    static let statusTabs: Set<String> = ["Activity", "Approvals", "Identity", "Mail"]
    /// The chat list's name, both as the side panel and as the narrow layout's dialog.
    static let chatListName = "Side chats"
    /// A window this wide gets Muse's full layout: the chat list as a panel
    /// beside the chat, and the Status panel beside both. Measured on Muse
    /// 12.1: the narrow layout starts below about 780 points, and the Status
    /// panel covers the chat somewhere below 860.
    static let fullLayoutWidth: CGFloat = 1000
    /// True when the Status panel is all Muse is showing.
    static func statusPanelCoversChat(chatScreenFound: Bool, tabs: [String]) -> Bool {
        !chatScreenFound && statusTabs.intersection(tabs).count >= 3
    }
    /// True when Muse's window is too narrow to control. In its narrow layout
    /// the chat list is a pop-up that opens a dialog over the whole window,
    /// hiding the message box, and nothing but a click or a key press closes it.
    static func needsWiderWindow(chatScreenFound: Bool, tabs: [String], narrowListControl: Bool) -> Bool {
        narrowListControl || statusPanelCoversChat(chatScreenFound: chatScreenFound, tabs: tabs)
    }
    /// The frame that gives Muse its full layout, kept on its own screen.
    /// Nil when the window is already that wide or the screen cannot fit it.
    static func frameForFullLayout(window: CGRect, screenMinX: CGFloat, screenMaxX: CGFloat) -> CGRect? {
        let wanted = fullLayoutWidth
        guard window.width < wanted, screenMaxX - screenMinX >= wanted else { return nil }
        let x = max(screenMinX, min(window.minX, screenMaxX - wanted))
        return CGRect(x: x, y: window.minY, width: wanted, height: window.height)
    }
    /// The state of the placeholder for a side chat that has no name yet. The
    /// phone works in it but does not offer it for a key: its name will change.
    static let unnamedState = "New"
    /// True when the list holds only that placeholder, which is all Muse shows
    /// while an unnamed side chat is open.
    static func isUnnamedOnly(_ chats: [Chat]) -> Bool { chats.count == 1 && chats[0].title == unnamedSideChat }

    /// The state reported for a chat, which the phone shows as its key's light:
    /// the open chat is working while Muse replies in it, and a chat with
    /// updates you have not seen has finished.
    static func state(current: Bool, unread: Bool, answering: Bool) -> String {
        if current { return answering ? "Working" : "Current" }
        return unread ? "Unread" : "Open"
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
        let plain = boxLabels.count == 1 && messageBox(boxLabels[0]) == MessageBox(chat: nil, answering: false)
        return hasBackToMain && plain ? unnamedSideChat : nil
    }

    /// Muse's message box, as read from its label.
    struct MessageBox: Equatable {
        /// The chat it names, or nil for the plain box used by the main chat
        /// and by an unnamed side chat.
        let chat: String?
        /// Its Send has become Stop: Muse is answering.
        let answering: Bool

        func belongs(to title: String) -> Bool {
            title == MuseChatList.mainChat || title == MuseChatList.unnamedSideChat ? chat == nil : chat == MuseChatList.normalized(title)
        }
    }

    /// Reads the message box's label by its parts. Muse merges the box into
    /// one control whose label lists what is inside it: "Message", then "in"
    /// and the chat's title for a side chat, then "Attach file", then in some
    /// versions "Dictate a message", then "Send" or, while Muse answers,
    /// "Stop". Versions differ in the separators and in what sits in the
    /// middle, so the whole label is never compared: 11.1 reads
    /// "Message Attach file Dictate a message Send" where 12.1 reads
    /// "Message Attach file\nSend".
    static func messageBox(_ label: String) -> MessageBox? {
        let text = normalized(label)
        guard text.hasPrefix("Message"), let attach = text.range(of: " Attach file") else { return nil }
        let answering: Bool
        if text.hasSuffix(" Send") { answering = false } else if text.hasSuffix(" Stop") { answering = true } else { return nil }
        let head = String(text[..<attach.lowerBound])
        if head == "Message" { return MessageBox(chat: nil, answering: answering) }
        guard head.hasPrefix("Message in "), head.count > "Message in ".count else { return nil }
        return MessageBox(chat: String(head.dropFirst("Message in ".count)), answering: answering)
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

    /// Muse re-renders some text when it is sent: markdown loses its marks
    /// and a link becomes its own element, so the exact draft never shows in
    /// the history. For those, delivery is confirmed by what sending causes:
    /// the history gains an entry, and either Muse starts answering or the
    /// message box is seen to be empty. Neither alone is enough.
    static func deliveredByEffect(entriesBefore: Int, entriesAfter: Int, answering: Bool, boxEmpty: Bool) -> Bool {
        entriesAfter > entriesBefore && (answering || boxEmpty)
    }
}

/// Follows a new side chat from having no name to the name Muse gives it.
///
/// The phone is handed a placeholder for the new chat. Once Muse names the
/// chat the placeholder matches nothing, and a second Send had nowhere to go.
/// A chat title that was not in the list before the new chat was made, and is
/// now the open chat, is that chat under its new name.
struct NewSideChatTracker {
    private(set) var knownTitles: Set<String> = []
    private(set) var awaiting = false
    private(set) var became: String?

    /// A new side chat was just opened from a controller.
    mutating func started() { awaiting = true; became = nil }
    /// Feed every full chat list (not the placeholder-only one).
    mutating func observe(titles: [String], current: String?) {
        if awaiting, let current, current != MuseChatList.unnamedSideChat {
            // A title that did not exist before is the new chat, now named.
            // A title that did exist means you went elsewhere and left it.
            if !knownTitles.contains(current) { became = current }
            awaiting = false
        }
        if let named = became, !titles.contains(named) { became = nil }
        knownTitles = Set(titles)
    }
}
