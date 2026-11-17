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
        typealias Box = MuseChatList.MessageBox
        expect(MuseChatList.messageBox("Message Attach file\nSend") == Box(chat: nil, answering: false), "The plain message box in Muse 12 names no chat")
        expect(MuseChatList.messageBox("Message Attach file Dictate a message Send") == Box(chat: nil, answering: false), "Muse 11 lists Dictate inside the same plain box")
        expect(MuseChatList.messageBox("Message in Trip planning Attach file\nSend") == Box(chat: "Trip planning", answering: false), "A side chat's message box names it")
        expect(MuseChatList.messageBox("Message in Trip planning Attach file Dictate a message Send")?.chat == "Trip planning", "A side chat's box names it in Muse 11 too")
        expect(MuseChatList.messageBox("Message Attach file\nStop") == Box(chat: nil, answering: true), "Stop in place of Send means Muse is answering")
        expect(MuseChatList.messageBox("Message in Trip planning Attach file Dictate a message Stop") == Box(chat: "Trip planning", answering: true), "A side chat's box while Muse answers")
        expect(MuseChatList.messageBox("Search") == nil && MuseChatList.messageBox("Message Send") == nil && MuseChatList.messageBox("Message Attach file") == nil, "Anything missing a part is not the message box")
        expect(MuseChatList.messageBox("Message in  Attach file Send") == nil, "A box that names an empty chat is not trusted")
        expect(Box(chat: nil, answering: false).belongs(to: "Main chat") && Box(chat: nil, answering: false).belongs(to: "New side chat"), "The plain box belongs to the main chat or an unnamed side chat")
        expect(!Box(chat: nil, answering: false).belongs(to: "Trip planning") && !Box(chat: "Trip planning", answering: false).belongs(to: "Main chat"), "A plain box never belongs to a named chat, nor a named box to the main chat")
        expect(Box(chat: "Trip planning", answering: false).belongs(to: "Trip  planning") && !Box(chat: "Trip planning", answering: false).belongs(to: "Trip"), "A named box belongs only to its own chat, spacing aside")

        let plain = "Message Attach file\nSend"
        expect(MuseChatList.openChat(toggle: nil, hasBackToMain: true, boxLabels: [plain]) == "New side chat", "No header, a way back and the plain box is an unnamed side chat")
        expect(MuseChatList.openChat(toggle: "Chats Open chat and side chats", hasBackToMain: false, boxLabels: [plain]) == "Main chat", "The same plain box under the Chats header is the main chat")
        expect(MuseChatList.openChat(toggle: nil, hasBackToMain: false, boxLabels: [plain]) == nil, "Without a way back the open chat is unknown, not assumed")
        expect(MuseChatList.openChat(toggle: nil, hasBackToMain: true, boxLabels: []) == nil && MuseChatList.openChat(toggle: nil, hasBackToMain: true, boxLabels: [plain, plain]) == nil, "No box or two boxes is unknown")
        expect(MuseChatList.openChat(toggle: nil, hasBackToMain: true, boxLabels: ["Message in Trip planning Attach file\nSend"]) == nil, "A named box without its header is unknown")
        expect(MuseChatList.openChat(toggle: "Trip planning Open chat and side chats", hasBackToMain: true, boxLabels: [plain]) == "Trip planning", "A header always wins")
        expect(MuseChatList.openChat(toggle: nil, hasBackToMain: true, boxLabels: ["Message Attach file Dictate a message Send"]) == "New side chat", "The older plain box is recognised as an unnamed side chat as well")
        expect(MuseChatList.openChat(toggle: nil, hasBackToMain: true, boxLabels: ["Message Attach file\nStop"]) == nil, "A box that is answering is not a fresh unnamed chat")
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
        expect(MuseChatList.deliveredByEffect(entriesBefore: 10, entriesAfter: 12, answering: true, boxEmpty: false), "A new entry and Muse answering confirms a re-rendered message")
        expect(MuseChatList.deliveredByEffect(entriesBefore: 10, entriesAfter: 11, answering: false, boxEmpty: true), "A new entry and an emptied box confirms it too")
        expect(!MuseChatList.deliveredByEffect(entriesBefore: 10, entriesAfter: 10, answering: true, boxEmpty: true), "No new entry is never a delivery")
        expect(!MuseChatList.deliveredByEffect(entriesBefore: 10, entriesAfter: 11, answering: false, boxEmpty: false), "A new entry alone could be Muse speaking first")
        // Following a new side chat to the name Muse gives it.
        var tracker = NewSideChatTracker()
        tracker.observe(titles: ["Main chat", "Trip plan"], current: "Main chat")
        expect(tracker.became == nil && !tracker.awaiting, "Nothing is tracked until a new chat is made")
        tracker.started()
        tracker.observe(titles: ["Main chat", "Trip plan", "Packing list"], current: "Packing list")
        expect(tracker.became == "Packing list" && !tracker.awaiting, "A title that did not exist before, now open, is the new chat under its name")
        tracker.observe(titles: ["Main chat", "Trip plan", "Packing list"], current: "Main chat")
        expect(tracker.became == "Packing list", "Looking at another chat does not forget the name")
        tracker.observe(titles: ["Main chat", "Trip plan"], current: "Main chat")
        expect(tracker.became == nil, "A chat that is gone is forgotten")
        tracker.started()
        tracker.observe(titles: ["Main chat", "Trip plan"], current: "Trip plan")
        expect(tracker.became == nil && !tracker.awaiting, "Going to a chat that already existed means the new one was left, not named")
        tracker.started()
        tracker.observe(titles: ["Main chat", "Trip plan"], current: nil)
        expect(tracker.awaiting && tracker.became == nil, "With no open chat readable, it keeps waiting")
        tracker.observe(titles: ["Main chat", "Trip plan", MuseChatList.unnamedSideChat], current: MuseChatList.unnamedSideChat)
        expect(tracker.awaiting, "The placeholder itself is not a name")
        expect(MuseChatList.isUnnamedOnly([.init(title: MuseChatList.unnamedSideChat, current: true, unread: false)]), "A list of just the placeholder is the unnamed-chat view")
        expect(!MuseChatList.isUnnamedOnly([.init(title: "Main chat", current: true, unread: false)]) && !MuseChatList.isUnnamedOnly([]), "Any other list is a real list")

        // The state each chat reports, which the phone shows as a light.
        expect(MuseChatList.state(current: true, unread: false, answering: true) == "Working", "The open chat is working while Muse replies in it")
        expect(MuseChatList.state(current: true, unread: false, answering: false) == "Current", "The open chat is otherwise just current")
        expect(MuseChatList.state(current: false, unread: true, answering: true) == "Unread", "A reply in the open chat does not make another chat work")
        expect(MuseChatList.state(current: false, unread: true, answering: false) == "Unread", "A chat with unseen updates has finished")
        expect(MuseChatList.state(current: false, unread: false, answering: false) == "Open", "Any other chat is open and idle")
        expect(MuseChatList.state(current: true, unread: true, answering: false) == "Current", "The chat you are looking at has nothing unseen")

        // The Status panel on its own: Muse in a narrow window.
        expect(MuseChatList.statusPanelCoversChat(chatScreenFound: false, tabs: ["Activity", "Approvals", "Identity", "Mail"]), "Four Status tabs and no chat screen is the panel covering the chat")
        expect(MuseChatList.statusPanelCoversChat(chatScreenFound: false, tabs: ["Approvals", "Identity", "Mail"]), "Three of the tabs are enough")
        expect(!MuseChatList.statusPanelCoversChat(chatScreenFound: true, tabs: ["Activity", "Approvals", "Identity", "Mail"]), "The panel beside a chat covers nothing")
        expect(!MuseChatList.statusPanelCoversChat(chatScreenFound: false, tabs: []), "An empty window is not the Status panel")
        expect(!MuseChatList.statusPanelCoversChat(chatScreenFound: false, tabs: ["Mail", "Activity"]), "Two tabs could be some other screen")
        expect(!MuseChatList.statusPanelCoversChat(chatScreenFound: false, tabs: ["Mail", "Mail", "Mail", "Settings"]), "Repeats of one tab do not count")
        expect(MuseChatList.needsWiderWindow(chatScreenFound: true, tabs: [], narrowListControl: true), "The narrow layout's pop-up chat list needs a wider window")
        expect(MuseChatList.needsWiderWindow(chatScreenFound: false, tabs: ["Activity", "Approvals", "Identity", "Mail"], narrowListControl: false), "A covered chat needs a wider window")
        expect(!MuseChatList.needsWiderWindow(chatScreenFound: true, tabs: ["Activity", "Approvals", "Identity", "Mail"], narrowListControl: false), "The full layout with the Status panel open is fine as it is")
        expect(!MuseChatList.needsWiderWindow(chatScreenFound: false, tabs: [], narrowListControl: false), "A window still loading is not judged narrow")
        let narrow = CGRect(x: 900, y: 40, width: 620, height: 800)
        expect(MuseChatList.frameForFullLayout(window: narrow, screenMinX: 0, screenMaxX: 1440) == CGRect(x: 440, y: 40, width: 1000, height: 800), "A narrow window is widened and slid left to stay on its screen")
        expect(MuseChatList.frameForFullLayout(window: CGRect(x: 100, y: 40, width: 620, height: 800), screenMinX: 0, screenMaxX: 1440) == CGRect(x: 100, y: 40, width: 1000, height: 800), "A window with room to its right grows in place")
        expect(MuseChatList.frameForFullLayout(window: CGRect(x: -300, y: 40, width: 620, height: 800), screenMinX: 0, screenMaxX: 1440)?.minX == 0, "A window hanging off the left edge is brought on screen")
        expect(MuseChatList.frameForFullLayout(window: CGRect(x: 2000, y: 40, width: 620, height: 800), screenMinX: 1440, screenMaxX: 3360)?.minX == 2000, "A second display uses its own edges")
        expect(MuseChatList.frameForFullLayout(window: CGRect(x: 0, y: 0, width: 1100, height: 800), screenMinX: 0, screenMaxX: 1440) == nil, "A wide window is left alone")
        expect(MuseChatList.frameForFullLayout(window: narrow, screenMinX: 0, screenMaxX: 900) == nil, "A screen too narrow to fit the wide window is not attempted")
        print("Muse chat list: \(passed) checks passed")
    }
}
