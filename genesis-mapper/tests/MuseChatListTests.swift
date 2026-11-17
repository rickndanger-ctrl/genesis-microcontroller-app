import Foundation

@main struct MuseChatListTests {
    static var passed = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("FAIL: " + message) }
        passed += 1
    }
    static func row(_ label: String, current: Bool = false) -> MuseChatList.Row { .init(label: label, current: current) }

    static func main() {
        // The panel as Muse shows it: the main chat, a view-only channel,
        // panel controls, and side chats, some of which share a title.
        let rows = [
            row("Main chat", current: true),
            row("WhatsApp Channel conversation, view only"),
            row("New side chat"),
            row("Trip planning"),
            row("Lens setup Unread updates"),
            row("Lens setup"),
            row("Book outline Unread updates"),
            row("  "),
        ]
        let listed = MuseChatList.chats(rows)
        expect(listed.chats.map(\.title) == ["Main chat", "Trip planning", "Book outline"], "Only chats with a title of their own are offered, in the panel's order")
        expect(listed.ambiguous == ["Lens setup"], "A title on two rows is reported as shared, read or unread")
        expect(listed.chats.first { $0.title == "Book outline" }?.unread == true && listed.chats[0].unread == false, "The unread marker is read, then dropped from the title")
        expect(MuseChatList.chat(row("WhatsApp Channel conversation, view only")) == nil, "A view-only channel cannot be a target")
        expect(MuseChatList.chat(row("New side chat")) == nil && MuseChatList.chat(row("Side chats")) == nil, "Panel controls are not chats")

        expect(MuseChatList.current(rows)?.title == "Main chat", "The row marked current is the open chat")
        expect(MuseChatList.current(rows.map { row($0.label) }) == nil, "No marked row means the open chat is unknown")
        expect(MuseChatList.current([row("A", current: true), row("B", current: true)]) == nil, "Two marked rows mean the open chat is unknown")
        expect(MuseChatList.current([row("Lens setup Unread updates", current: true)])?.title == "Lens setup", "The current chat's title drops the unread marker too")

        expect(MuseChatList.openChat(fromToggle: "Chats Unread chats Open chat and side chats") == "Main chat", "The main chat's header reads Chats")
        expect(MuseChatList.openChat(fromToggle: "Chats Open chat and side chats") == "Main chat", "With nothing unread the header still names the main chat")
        expect(MuseChatList.openChat(fromToggle: "Trip planning Unread chats Open chat and side chats") == "Trip planning", "A side chat's header starts with its title")
        expect(MuseChatList.openChat(fromToggle: "Trip planning Open chat and side chats") == "Trip planning", "A side chat's header without the unread marker")
        expect(MuseChatList.openChat(fromToggle: "Open chat and side chats") == nil && MuseChatList.openChat(fromToggle: "Invite") == nil, "Any other button names no chat")
        expect(MuseChatList.messageBoxLabel(for: "Main chat") == "Message Attach file\nSend", "The main chat's message box has no chat name")
        expect(MuseChatList.messageBoxLabel(for: "Trip planning") == "Message in Trip planning Attach file\nSend", "A side chat's message box names it")

        let plain = "Message Attach file\nSend"
        expect(MuseChatList.openChat(toggle: nil, hasBackToMain: true, boxLabels: [plain]) == "New side chat", "No header, a way back and the plain box is an unnamed side chat")
        expect(MuseChatList.openChat(toggle: "Chats Open chat and side chats", hasBackToMain: false, boxLabels: [plain]) == "Main chat", "The same plain box under the Chats header is the main chat")
        expect(MuseChatList.openChat(toggle: nil, hasBackToMain: false, boxLabels: [plain]) == nil, "Without a way back the open chat is unknown, not assumed")
        expect(MuseChatList.openChat(toggle: nil, hasBackToMain: true, boxLabels: []) == nil && MuseChatList.openChat(toggle: nil, hasBackToMain: true, boxLabels: [plain, plain]) == nil, "No box or two boxes is unknown")
        expect(MuseChatList.openChat(toggle: nil, hasBackToMain: true, boxLabels: ["Message in Trip planning Attach file\nSend"]) == nil, "A named box without its header is unknown")
        expect(MuseChatList.openChat(toggle: "Trip planning Open chat and side chats", hasBackToMain: true, boxLabels: [plain]) == "Trip planning", "A header always wins")
        expect(MuseChatList.messageBoxLabel(for: "New side chat") == plain, "An unnamed side chat uses the plain message box")
        expect(MuseChatList.chat(row("New side chat")) == nil, "The panel's New side chat button is still not a chat row")

        let draft = "Show me what changed.\nThen list what is left."
        expect(MuseChatList.holdsDraft("Show me what changed.\n\nThen list what is left.\n", prompt: draft), "Line breaks the page reshapes still count as the same draft")
        expect(MuseChatList.holdsDraft("Show  me what changed. Then list what is left.", prompt: draft), "Runs of whitespace compare as one space")
        expect(!MuseChatList.holdsDraft("Show me what changed.", prompt: draft), "A partial paste is not the draft")
        expect(!MuseChatList.holdsDraft("Earlier text. " + draft, prompt: draft), "Text in front of the draft is not the draft")
        expect(!MuseChatList.holdsDraft(nil, prompt: draft) && !MuseChatList.holdsDraft("", prompt: draft), "An empty box does not hold the draft")
        expect(!MuseChatList.holdsDraft("  ", prompt: "  "), "A blank prompt never verifies")

        let history = ["4:05", "User message: Earlier question", "A reply that quotes: Show me what changed.", "Show me what changed.\nThen list what is left."]
        expect(MuseChatList.deliveries(in: history, prompt: draft) == 1, "A message drawn bare counts as this draft")
        expect(MuseChatList.deliveries(in: ["User message: Show me what changed. Then list what is left."], prompt: draft) == 1, "A message behind its label counts too")
        expect(MuseChatList.deliveries(in: history + history, prompt: draft) == 2, "The same text sent twice counts twice")
        expect(MuseChatList.deliveries(in: ["Reply text", "Show me what changed."], prompt: draft) == 0, "A partial or quoting entry is not the draft")
        expect(MuseChatList.deliveries(in: history, prompt: "  ") == 0, "A blank prompt matches nothing")
        expect(MuseChatList.showsAsSent(before: 1, after: 2) && MuseChatList.showsAsSent(before: 0, after: 1), "One more appearance than before confirms this send")
        expect(!MuseChatList.showsAsSent(before: 1, after: 1) && !MuseChatList.showsAsSent(before: 2, after: 1), "An identical older message does not confirm it")
        expect(MuseChatList.answeringBoxLabel(for: "Main chat") == "Message Attach file\nStop", "The main chat's box reads Stop while Muse answers")
        expect(MuseChatList.answeringBoxLabel(for: "Trip planning") == "Message in Trip planning Attach file\nStop", "A side chat's box reads Stop while Muse answers")
        expect(MuseChatList.deliveredByEffect(entriesBefore: 10, entriesAfter: 12, answering: true, boxEmpty: false), "A new entry and Muse answering confirms a re-rendered message")
        expect(MuseChatList.deliveredByEffect(entriesBefore: 10, entriesAfter: 11, answering: false, boxEmpty: true), "A new entry and an emptied box confirms it too")
        expect(!MuseChatList.deliveredByEffect(entriesBefore: 10, entriesAfter: 10, answering: true, boxEmpty: true), "No new entry is never a delivery")
        expect(!MuseChatList.deliveredByEffect(entriesBefore: 10, entriesAfter: 11, answering: false, boxEmpty: false), "A new entry alone could be Muse speaking first")
        print("Muse chat list: \(passed) checks passed")
    }
}
