import AppKit
import ApplicationServices

/// Drives the Muse desktop app through macOS Accessibility.
///
/// Muse shows its chat panel as ordinary buttons, with the open chat marked
/// `aria-current`, so listing and opening chats is plain reading and pressing.
/// Its message box is different: the page exposes it as one merged button with
/// no readable or writable text, and pressing that button opens the file
/// picker. A draft is therefore put there the way a person would do it: click
/// in the box, paste, and read the box back by selecting all and copying. The
/// clipboard and the pointer are put back afterwards.
final class MuseAccess {
    static let bundle = "com.meta.endo"

    struct Outcome {
        let status: String
        let message: String
        static func confirmed(_ message: String) -> Outcome { .init(status: "confirmed", message: message) }
        static func failed(_ message: String) -> Outcome { .init(status: "failed", message: message) }
        static func uncertain(_ message: String) -> Outcome { .init(status: "uncertain", message: message) }
    }

    struct Listing {
        let chats: [MuseChatList.Chat]
        let ambiguous: Set<String>
        /// Muse is replying in the chat that is open, so that chat is working.
        var answering = false
    }

    private struct Snapshot {
        var rows: [(element: AXUIElement, row: MuseChatList.Row)] = []
        var panelOpen = false
        var toggle: AXUIElement?
        var boxes: [AXUIElement] = []
        var newSideChat: [AXUIElement] = []
        var call: [AXUIElement] = []
        var history: AXUIElement?
        /// The chat Muse is showing. The header names it whether or not the
        /// panel is open; the panel's own marker is the fallback.
        var current: String? {
            MuseChatList.openChat(toggle: toggleLabel, hasBackToMain: !backToMain.isEmpty, boxLabels: boxLabels)
                ?? MuseChatList.current(rows.map(\.row))?.title
        }
        var toggleLabel: String?
        var panel: AXUIElement?
        var backToMain: [AXUIElement] = []
        var boxLabels: [String] = []
        /// Labels of message boxes whose Send has become Stop: Muse is answering.
        var answering: [String] = []
        /// Tabs of the Status panel that are showing.
        var statusTabs: [String] = []
        /// The narrow layout's chat list: a pop-up control, or the dialog it opens.
        var narrowListControl = false
        /// Muse's window is too narrow to control; see MuseChatList.needsWiderWindow.
        var needsWiderWindow: Bool { MuseChatList.needsWiderWindow(chatScreenFound: isRecognisable, tabs: statusTabs, narrowListControl: narrowListControl) }
        var historyEntries: Int { history.map { children($0).count } ?? 0 }
        var children: (AXUIElement) -> [AXUIElement] = { _ in [] }
        /// Something of Muse's chat screen was found, so this is a real read.
        var isRecognisable: Bool { toggle != nil || panelOpen || !backToMain.isEmpty || !boxes.isEmpty || !answering.isEmpty }
    }

    var app: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundle).first }
    private var isFrontmost: Bool { app != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == app?.processIdentifier }

    // MARK: Reading

    private func value(_ element: AXUIElement, _ key: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
    private func string(_ element: AXUIElement, _ key: String) -> String { value(element, key) as? String ?? "" }
    private func label(_ element: AXUIElement) -> String {
        let title = string(element, kAXTitleAttribute)
        return title.isEmpty ? string(element, kAXDescriptionAttribute) : title
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let list = value(element, kAXChildrenAttribute), CFGetTypeID(list) == CFArrayGetTypeID() else { return [] }
        return list as? [AXUIElement] ?? []
    }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// One pass over Muse's window. The message history is noted but never
    /// walked here; only `recentHistory` reads it, and only its newest entries.
    private func snapshot(deadline: Double = .infinity) -> Snapshot? {
        guard AXIsProcessTrusted(), let app else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.4)
        var result = Snapshot()
        result.children = { [unowned self] in self.children($0) }
        var queue: [(element: AXUIElement, inPanel: Bool, underHeading: Bool)] = [(root, false, false)], index = 0
        while index < queue.count && index < 6000 {
            // A read that runs out of time is no read: the caller must not act on part of a window.
            if index % 32 == 0, ProcessInfo.processInfo.systemUptime > deadline { return nil }
            let (element, inPanel, underHeading) = queue[index]; index += 1
            let role = string(element, kAXRoleAttribute)
            if role == kAXMenuBarRole { continue }
            let subrole = string(element, kAXSubroleAttribute)
            if subrole == "AXApplicationLog" { result.history = element; continue }
            let name = label(element)
            var panel = inPanel
            if subrole == "AXLandmarkNavigation", name == "Side chats" { panel = true; result.panelOpen = true; result.panel = element }
            if role == kAXButtonRole {
                if panel, !underHeading {
                    if name == "New side chat" { result.newSideChat.append(element) }
                    else { result.rows.append((element, .init(label: name, current: string(element, "AXARIACurrent") == "page"))) }
                } else if name.hasSuffix(MuseChatList.panelToggleSuffix) { result.toggle = element; result.toggleLabel = name }
                if let box = MuseChatList.messageBox(name) {
                    if box.answering { result.answering.append(name) } else { result.boxes.append(element); result.boxLabels.append(name) }
                }
                if name == "Back to main chat" { result.backToMain.append(element) }
                if name == "Call your assistant" { result.call.append(element) }
            } else if role == kAXCheckBoxRole, MuseChatList.statusTabs.contains(name) { result.statusTabs.append(name) }
            else if role == kAXPopUpButtonRole, name.hasSuffix(MuseChatList.panelToggleSuffix) { result.narrowListControl = true }
            if subrole == "AXApplicationDialog", name == MuseChatList.chatListName { result.narrowListControl = true }
            for child in children(element) { queue.append((child, panel, role == "AXHeading")) }
        }
        return result
    }

    /// A snapshot once Muse has something to show.
    ///
    /// Muse draws its window in a web view, and a web view builds what it
    /// tells Accessibility only when first asked. A read after Muse has sat
    /// untouched comes back with a bare window and none of its controls; the
    /// same read a moment later is complete. Without this wait the first
    /// command after a quiet spell failed and the second one worked.
    @MainActor private func settled() async -> Snapshot? {
        var seen = snapshot()
        // A cold start takes Muse several seconds to draw its chat screen, so
        // an app launched moments ago gets longer than one that is merely idle.
        let justLaunched = app?.launchDate.map { Date().timeIntervalSince($0) < 30 } ?? false
        // The phone gives a command twelve seconds, so the waits here and in
        // `panel` together stay under nine.
        for _ in 0..<(justLaunched ? 24 : 12) {
            if let seen, seen.isRecognisable { return seen }
            try? await Task.sleep(nanoseconds: 250_000_000)
            seen = snapshot()
        }
        return seen
    }

    /// The title of the chat Muse is showing, if it can be read. One read; changes nothing.
    func currentChatTitle() -> String? { snapshot()?.current }

    /// True when Muse's window is too narrow to control. One read; changes nothing.
    func needsWiderWindow() -> Bool { snapshot()?.needsWiderWindow ?? false }

    /// Widens Muse's window so it draws its full layout, and leaves it wide.
    /// In a narrow window Muse hides its chat list behind a dialog that covers
    /// the message box, and with the Status panel open it shows no chat at all.
    /// Nothing is closed and nothing is clicked. Returns nil when there was
    /// nothing to do.
    @MainActor func widenWindow() async -> Outcome? {
        guard let seen = snapshot(), seen.needsWiderWindow, let app else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let windows = (value(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard let window = windows.first(where: { (value($0, kAXMinimizedAttribute) as? Bool) != true }) ?? windows.first, let current = frame(window) else {
            return .failed("Muse has no window to show a chat in. Open Muse on the Mac.")
        }
        // Accessibility and NSScreen agree on x, which is all that is needed here.
        let screen = NSScreen.screens.first { $0.frame.minX <= current.midX && current.midX < $0.frame.maxX } ?? NSScreen.main
        guard let screen, let wide = MuseChatList.frameForFullLayout(window: current, screenMinX: screen.frame.minX, screenMaxX: screen.frame.maxX) else {
            return .failed("Muse\u{2019}s window on this Mac is too narrow for the controller to reach its chats, and it could not be widened from here. Widen Muse\u{2019}s window on the Mac.")
        }
        var origin = wide.origin, size = wide.size
        if let position = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) }
        if let extent = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent) }
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let fresh = snapshot(), fresh.isRecognisable, !fresh.needsWiderWindow {
                return .confirmed("Widened Muse\u{2019}s window on this Mac so its chats can be reached.")
            }
        }
        return .uncertain("Muse\u{2019}s window was widened, but its chats have not appeared yet. Refresh in a moment.")
    }

    /// A snapshot with the chat panel showing, opening it if it is closed.
    /// An unnamed side chat has no way to the panel except back through the
    /// main chat, which abandons it, so that step is taken only when asked.
    @MainActor private func panel(leavingUnnamedChat: Bool = false) async -> Snapshot? {
        guard var first = await settled() else { return nil }
        // Muse draws its message box before the button that shows the chat
        // list, so a screen can be recognisable and still have no way to the
        // list. Wait for one: the button, the open panel, or a way back.
        if first.toggle == nil, !first.panelOpen, first.backToMain.isEmpty {
            let justLaunched = app?.launchDate.map { Date().timeIntervalSince($0) < 30 } ?? false
            for _ in 0..<(justLaunched ? 12 : 10) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let fresh = snapshot() else { continue }
                first = fresh
                if fresh.toggle != nil || fresh.panelOpen || !fresh.backToMain.isEmpty { break }
            }
        }
        if first.toggle == nil, !first.panelOpen, leavingUnnamedChat, first.backToMain.count == 1 {
            let back = first.backToMain[0]
            _ = AXUIElementPerformAction(back, kAXPressAction as CFString)
            for attempt in 0..<12 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let fresh = snapshot(), fresh.toggle != nil { first = fresh; break }
                // Muse ignores a press on some controls; fall back to a real click once.
                if attempt == 5, await activate(), let pid = app?.processIdentifier, let area = frame(back) {
                    let point = CGPoint(x: area.midX, y: area.midY)
                    if isMuseWindow(at: point, pid: pid) { click(point) }
                }
            }
        }
        if !first.panelOpen, let toggle = first.toggle, AXUIElementPerformAction(toggle, kAXPressAction as CFString) == .success {
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let fresh = snapshot(), fresh.panelOpen { first = fresh; break }
            }
        }
        // The panel always lists at least the main chat. An open panel with no
        // rows has not finished loading, as happens just after Muse starts.
        if first.panelOpen, first.rows.isEmpty {
            for _ in 0..<16 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let fresh = snapshot(), fresh.panelOpen, !fresh.rows.isEmpty { return fresh }
            }
        }
        return first
    }

    /// The chats that can be addressed. While an unnamed side chat is open
    /// only that chat can be seen; pass `leavingUnnamedChat` when the caller
    /// means to go somewhere else and needs the full list.
    @MainActor func listing(leavingUnnamedChat: Bool = false) async -> Listing? {
        if !leavingUnnamedChat, await settled()?.current == MuseChatList.unnamedSideChat {
            return Listing(chats: [.init(title: MuseChatList.unnamedSideChat, current: true, unread: false)], ambiguous: [])
        }
        guard let shown = await panel(leavingUnnamedChat: leavingUnnamedChat), shown.panelOpen else { return nil }
        let result = MuseChatList.chats(shown.rows.map(\.row))
        return Listing(chats: result.chats, ambiguous: result.ambiguous, answering: !shown.answering.isEmpty)
    }

    /// Every string in the newest entries of the message history. Muse nests
    /// a message a few groups deep, and how deep varies with the entry.
    private func recentHistory(_ history: AXUIElement?) -> [String] {
        guard let history else { return [] }
        var texts: [String] = []
        func collect(_ element: AXUIElement, depth: Int) {
            if string(element, kAXRoleAttribute) == kAXStaticTextRole {
                let text = string(element, kAXValueAttribute)
                if !text.isEmpty { texts.append(text) }
            }
            guard depth < 6 else { return }
            for child in children(element) { collect(child, depth: depth + 1) }
        }
        for entry in children(history).suffix(24) { collect(entry, depth: 0) }
        return texts
    }

    /// The open chat and the newest entries of its message history, for the thread view.
    /// Reading only: no click, key, scroll, focus change or panel toggle. Meant to run off the main
    /// thread. Nil when Muse has no recognisable chat screen or the read ran out of time. The chat is
    /// read before and after the history, and a change in between discards the read.
    func threadRead(deadline: Double, entryLimit: Int = 30) -> MuseThreadRead? {
        guard let first = snapshot(deadline: deadline), first.isRecognisable, let title = first.current, let history = first.history else { return nil }
        let ambiguous = first.panelOpen && MuseChatList.chats(first.rows.map(\.row)).ambiguous.contains(title)
        let container = frame(history)
        let all = children(history), newest = all.suffix(entryLimit)
        var entries: [MuseEntry] = []
        for entry in newest {
            var pieces: [MuseText] = [], labels: [String] = []
            let controls: Set<String> = [kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXMenuItemRole, kAXMenuRole]
            func collect(_ element: AXUIElement, depth: Int, inControl: Bool) {
                let role = string(element, kAXRoleAttribute)
                if role == kAXStaticTextRole {
                    let text = string(element, kAXValueAttribute)
                    if !text.isEmpty { pieces.append(MuseText(text: text, insideControl: inControl, directChild: depth == 1)) }
                }
                let name = label(element)
                if !name.isEmpty, !inControl { labels.append(name) }
                guard depth < 8 else { return }
                for child in children(element) { collect(child, depth: depth + 1, inControl: inControl || controls.contains(role)) }
            }
            if ProcessInfo.processInfo.systemUptime > deadline { return nil }
            collect(entry, depth: 0, inControl: false)
            let box = frame(entry)
            entries.append(MuseEntry(pieces: pieces, labels: labels, x: box.flatMap { b in container.map { Double(b.minX - $0.minX) } }, width: box.map { Double($0.width) }))
        }
        guard let again = snapshot(deadline: deadline), again.current == title else { return nil }
        return MuseThreadRead(openTitle: title, ambiguous: ambiguous, entries: entries, olderEntries: all.count > newest.count, historyWidth: Double(container?.width ?? 0))
    }

    /// Structure of the newest history entries with no text content, for working out where Muse
    /// puts the author of a message. Read-only; meant to run off the main thread.
    func historyShape(deadline: Double, entryLimit: Int = 30, depthLimit: Int = 8, nodeLimit: Int = 900) -> [String: Any]? {
        guard let seen = snapshot(deadline: deadline), let history = seen.history else { return nil }
        let container = frame(history)
        var budget = nodeLimit
        func describe(_ element: AXUIElement, depth: Int) -> [String: Any] {
            budget -= 1
            var node: [String: Any] = ["role": string(element, kAXRoleAttribute), "subrole": string(element, kAXSubroleAttribute),
                                       "roleDescription": string(element, kAXRoleDescriptionAttribute)]
            let identifier = string(element, "AXIdentifier") + string(element, "AXDOMIdentifier")
            node["hasIdentifier"] = !identifier.isEmpty
            if MuseShape.isFixedIdentifier(identifier) { node["identifier"] = identifier }
            if let box = frame(element), let container {
                node["x"] = Int((box.minX - container.minX).rounded()); node["width"] = Int(box.width.rounded())
            }
            var names: CFArray?
            var strings: [[String: Any]] = [], others: [String] = []
            if AXUIElementCopyAttributeNames(element, &names) == .success, let list = names as? [String] {
                for name in list.sorted() where !["AXChildren", "AXParent", "AXWindow", "AXTopLevelUIElement", "AXPosition", "AXSize", "AXFrame"].contains(name) {
                    guard let any = value(element, name) else { continue }
                    if let text = any as? String { if !text.isEmpty { strings.append(MuseShape.string(name: name, text: text)) } }
                    else if let list = any as? [String] { strings.append(MuseShape.strings(name: name, values: list)) }
                    else if let number = any as? NSNumber { others.append(CFGetTypeID(number) == CFBooleanGetTypeID() ? "\(name)=\(number.boolValue)" : "\(name)=number") }
                    else if CFGetTypeID(any) != AXUIElementGetTypeID(), !(any is [Any]) { others.append("\(name)=other") }
                }
            }
            node["stringAttributes"] = strings; node["otherAttributes"] = others
            let kids = children(element)
            node["childCount"] = kids.count
            if depth < depthLimit {
                var described: [[String: Any]] = []
                for child in kids where budget > 0 && ProcessInfo.processInfo.systemUptime < deadline { described.append(describe(child, depth: depth + 1)) }
                node["children"] = described
            }
            return node
        }
        let all = children(history)
        var entries: [[String: Any]] = []
        for entry in all.suffix(entryLimit) where budget > 0 && ProcessInfo.processInfo.systemUptime < deadline { entries.append(describe(entry, depth: 0)) }
        return ["historyEntries": all.count, "entriesDescribed": entries.count, "historyWidth": Int(container?.width.rounded() ?? 0),
                "truncatedByBudget": budget <= 0, "entries": entries]
    }

    /// What a self-check needs to know about Muse's window. Counting the chats
    /// means showing the chat panel, which is the only thing this changes.
    @MainActor func selfCheck(installed: Bool) async -> SelfCheck.Muse {
        guard let seen = await settled() else {
            return .init(installed: installed, running: app != nil, navigable: false, messageBoxes: 0, answering: false, chats: 0, sharedTitles: 0, callControls: 0)
        }
        if seen.needsWiderWindow {
            return .init(installed: installed, running: true, navigable: false, messageBoxes: 0, answering: false, chats: 0, sharedTitles: 0, callControls: 0, windowTooNarrow: true)
        }
        let listed = await listing()
        return .init(installed: installed, running: true, navigable: seen.toggle != nil || seen.panelOpen || !seen.backToMain.isEmpty,
                     messageBoxes: seen.boxes.count, answering: !seen.answering.isEmpty,
                     chats: listed?.chats.count ?? 0, sharedTitles: listed?.ambiguous.count ?? 0, callControls: seen.call.count)
    }

    /// The controls an app is showing, as "role · label" lines, for diagnosing
    /// a screen the controller does not recognise. Only controls are listed:
    /// message history is never entered and no text content is read.
    static func outline(bundle: String, limit: Int = 300) -> [String] {
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first(where: { !$0.isTerminated }) else { return [] }
        func value(_ element: AXUIElement, _ key: String) -> AnyObject? {
            var result: AnyObject?
            return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.4)
        let listed: Set<String> = [kAXButtonRole, kAXPopUpButtonRole, kAXCheckBoxRole, kAXMenuButtonRole, kAXTextFieldRole, kAXTextAreaRole,
                                   kAXWindowRole, kAXSheetRole, "AXLink", "AXHeading", "AXWebArea"]
        var lines: [String] = [], queue: [(AXUIElement, Int)] = [(root, 0)], index = 0
        while index < queue.count, index < 6000, lines.count < limit {
            let (element, depth) = queue[index]; index += 1
            let role = value(element, kAXRoleAttribute) as? String ?? ""
            if role == kAXMenuBarRole { continue }
            let subrole = value(element, kAXSubroleAttribute) as? String ?? ""
            if subrole == "AXApplicationLog" { lines.append("(message history, not read)"); continue }
            let title = value(element, kAXTitleAttribute) as? String ?? ""
            let name = (title.isEmpty ? value(element, kAXDescriptionAttribute) as? String ?? "" : title).replacingOccurrences(of: "\n", with: " / ")
            if listed.contains(role) || subrole.hasPrefix("AXLandmark") {
                // A field's contents are never reported, only that it exists. Window titles, headings
                // and links carry chat titles, so only their length is reported; see OutlineLabel.
                let shown = OutlineLabel.shown(role: role, subrole: subrole, name: name)
                let minimized = role == kAXWindowRole && (value(element, kAXMinimizedAttribute) as? Bool) == true ? " (minimized)" : ""
                lines.append("\(role.replacingOccurrences(of: "AX", with: ""))\(subrole.isEmpty ? "" : "/" + subrole.replacingOccurrences(of: "AX", with: "")) · \(shown)\(minimized)")
            }
            if depth < 40, let children = value(element, kAXChildrenAttribute), CFGetTypeID(children) == CFArrayGetTypeID() {
                for child in (children as? [AXUIElement]) ?? [] { queue.append((child, depth + 1)) }
            }
        }
        if lines.isEmpty { lines.append("(no controls found: the app has no window showing, or has not finished loading)") }
        return lines
    }

    /// How many times this draft appears among the newest messages of the open chat.
    func deliveries(of prompt: String) -> Int {
        MuseChatList.deliveries(in: recentHistory(snapshot()?.history), prompt: prompt)
    }

    // MARK: Chats

    @MainActor func activate() async -> Bool {
        guard let app else { return false }
        // A minimized window has nothing to click or type into. Whoever is
        // holding the phone is not at the Mac to restore it, so do it here.
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if let windows = value(root, kAXWindowsAttribute), CFGetTypeID(windows) == CFArrayGetTypeID() {
            for window in (windows as? [AXUIElement]) ?? [] where (value(window, kAXMinimizedAttribute) as? Bool) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
        }
        if isFrontmost { return true }
        NSApp.yieldActivation(to: app)
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        for _ in 0..<12 {
            if isFrontmost { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return isFrontmost
    }

    /// Opens a chat by clicking its row. Muse ignores an accessibility press
    /// on a row, so this is a real click, made only when Muse is in front and
    /// the row itself is what sits under the pointer.
    @MainActor func open(_ title: String, contextIsCurrent: () -> Bool) async -> Outcome {
        guard var first = await settled() else { return .failed("Open Muse on this Mac first.") }
        // A closed or hidden window shows nothing. Bringing Muse forward
        // reopens it, which is worth one try before giving up.
        if !first.isRecognisable, await activate(), let again = await settled() { first = again }
        if first.current == title {
            _ = await activate()
            return .confirmed("Opened \(title).")
        }
        // An unnamed side chat exists only while it is on screen.
        guard title != MuseChatList.unnamedSideChat else {
            return .failed("That new side chat has since been named or closed. Choose it from the chat list.")
        }
        guard let shown = await panel(leavingUnnamedChat: true), shown.panelOpen else { return .failed("Muse’s chat list could not be shown. Open Muse on this Mac and try again.") }
        let matches = shown.rows.filter { MuseChatList.chat($0.row)?.title == title }
        guard matches.count == 1 else {
            return .failed(matches.isEmpty ? "This Muse chat is no longer in the chat list. Refresh its mapping; nothing was opened."
                                           : "More than one Muse chat has this title. Rename one in Muse before using its key.")
        }
        guard await activate(), let pid = app?.processIdentifier else { return .failed("Muse could not be brought to the front on the Mac. No chat was opened.") }
        let row = matches[0].element
        AXUIElementPerformAction(row, "AXScrollToVisible" as CFString)
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let area = frame(row), area.width > 8, area.height > 8 else { return .failed("Muse’s chat row could not be located. No chat was opened.") }
        let point = CGPoint(x: area.midX, y: area.midY)
        // The row must be inside the visible panel, and the panel on Muse's window.
        guard contextIsCurrent(), isFrontmost, let list = shown.panel.flatMap(frame), list.contains(point),
              string(row, kAXRoleAttribute) == kAXButtonRole, MuseChatList.chat(.init(label: label(row), current: false))?.title == title,
              isMuseWindow(at: point, pid: pid) else {
            return .failed("The Muse chat row is covered or off-screen. No click was sent.")
        }
        // Never click through someone's drag.
        guard await MacInput.waitForQuiet(needed: 0, timeout: 1.5) else { return .failed("\(MacInput.busyMessage); no chat was opened.") }
        let pointer = CGEvent(source: nil)?.location
        click(point)
        defer { if let pointer { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pointer, mouseButton: .left)?.post(tap: .cghidEventTap) } }
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if snapshot()?.current == title { return .confirmed("Opened \(title).") }
        }
        return .failed("Muse took the click but did not show the chat. Nothing else was sent.")
    }

    /// Opens a new, unnamed side chat and confirms Muse is showing it.
    @MainActor func newSideChat(contextIsCurrent: () -> Bool) async -> Outcome {
        let opened = Outcome.confirmed("Opened a new side chat in Muse. Dictate or type a draft, then Send.")
        if await settled()?.current == MuseChatList.unnamedSideChat {
            _ = await activate()
            return opened
        }
        guard let shown = await panel(), shown.panelOpen, shown.newSideChat.count == 1 else { return .failed("Muse is not showing its New side chat control.") }
        guard contextIsCurrent(), AXUIElementPerformAction(shown.newSideChat[0], kAXPressAction as CFString) == .success else { return .failed("Muse did not accept the press.") }
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if snapshot()?.current == MuseChatList.unnamedSideChat {
                _ = await activate()
                return opened
            }
        }
        return .failed("Muse did not open a new side chat.")
    }

    @MainActor func startCall(contextIsCurrent: () -> Bool) async -> Outcome {
        guard let shown = await settled() else { return .failed("Open Muse on this Mac first.") }
        guard shown.call.count == 1 else { return .failed("Muse is not showing its Call control. A call may already be running; check the Mac.") }
        guard contextIsCurrent(), AXUIElementPerformAction(shown.call[0], kAXPressAction as CFString) == .success else { return .failed("Muse did not accept the press.") }
        return .confirmed("Asked Muse to start a call on this Mac. It uses the Mac’s microphone and speakers, not the phone’s.")
    }

    // MARK: Sending

    private func post(_ key: CGKeyCode, command: Bool = false, to pid: pid_t) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            event.flags = command ? .maskCommand : []
            event.postToPid(pid)
            usleep(20_000)
        }
    }

    /// Keyboard focus is in the message box that belongs to this chat.
    private func focusIsMessageBox(_ pid: pid_t, for title: String) -> Bool {
        let root = AXUIElementCreateApplication(pid)
        guard let focused = value(root, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        return string(element, kAXRoleAttribute) == kAXButtonRole && MuseChatList.messageBox(label(element))?.belongs(to: title) == true
    }

    /// The point lies on Muse's own main window, with no other app's window
    /// and no sheet over it. macOS cannot hit-test inside Muse's page, so
    /// this is as far as the check can go; the caller confirms the result of
    /// its click afterwards instead of trusting it.
    private func isMuseWindow(at point: CGPoint, pid: pid_t) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success else { return false }
        for _ in 0..<12 {
            guard let node = hit else { return false }
            var owner: pid_t = 0; AXUIElementGetPid(node, &owner)
            guard owner == pid else { return false }
            let role = string(node, kAXRoleAttribute)
            if role == kAXSheetRole || role == kAXMenuRole || role == kAXPopoverRole { return false }
            // Muse's own window is a standard window in one layout and a dialog in
            // its compact one; either way it is titled Muse. An update prompt is not.
            if role == kAXWindowRole { return string(node, kAXTitleAttribute) == "Muse" }
            guard let parent = value(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            hit = (parent as! AXUIElement)
        }
        return false
    }

    private func click(_ point: CGPoint) {
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(60_000)
        }
    }

    /// The whole contents of the focused field, or nil when it is empty.
    /// A sentinel on the clipboard tells "copied nothing" from "copied text".
    @MainActor private func copyAll(_ pid: pid_t) async -> String? {
        let sentinel = "genesis-muse-\(UUID().uuidString)"
        let board = NSPasteboard.general
        board.clearContents(); board.setString(sentinel, forType: .string)
        post(0, command: true, to: pid)      // select all
        try? await Task.sleep(nanoseconds: 120_000_000)
        post(8, command: true, to: pid)      // copy
        try? await Task.sleep(nanoseconds: 250_000_000)
        let copied = board.string(forType: .string) ?? ""
        return copied == sentinel || MuseChatList.normalized(copied).isEmpty ? nil : copied
    }

    private func saveClipboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }, uniquingKeysWith: { first, _ in first })
        }
    }
    private func restoreClipboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects(saved.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        })
    }

    /// Sends `prompt` to the chat titled `title`, once. Every step that could
    /// overwrite or misdirect text is checked first, and a step that cannot be
    /// confirmed is reported as uncertain rather than repeated.
    ///
    /// `rehearsal` stops short of Return: the draft is pasted, read back, and
    /// removed again. It exists to check a Mac's setup without sending anything.
    @MainActor func send(_ prompt: String, to title: String, rehearsal: Bool = false, contextIsCurrent: @escaping () -> Bool) async -> Outcome {
        let opened = await open(title, contextIsCurrent: contextIsCurrent)
        guard opened.status == "confirmed" else { return opened }
        guard await activate(), let pid = app?.processIdentifier else { return .failed("Muse could not be brought to the front on the Mac. Nothing was typed.") }
        // The message box names the chat it belongs to. It must be this one.
        if let busy = snapshot(), busy.boxes.isEmpty, !busy.answering.isEmpty {
            return .failed("Muse is still answering. Wait for it to finish, then send again; nothing was typed.")
        }
        guard let shown = snapshot(), shown.current == title, shown.boxes.count == 1, MuseChatList.messageBox(label(shown.boxes[0]))?.belongs(to: title) == true,
              let box = frame(shown.boxes[0]), box.width > 160 else {
            return .failed("Muse’s message box could not be matched to this chat. Nothing was typed.")
        }
        // Right of an open chat panel, left of the microphone and Send.
        let point = CGPoint(x: box.minX + box.width * 0.6, y: box.midY)
        // Clear of the chat panel when it is open over the left of the box.
        let clear = shown.panel.flatMap(frame).map { !$0.contains(point) } ?? true
        guard clear, isMuseWindow(at: point, pid: pid) else { return .failed("Muse’s message box is covered by another window or panel. Nothing was typed.") }

        // The next steps click and paste. Wait for hands to be off the keys
        // so nothing the person types lands in the draft.
        guard await MacInput.waitForQuiet() else { return .failed("\(MacInput.busyMessage); nothing was typed.") }
        let pointer = CGEvent(source: nil)?.location
        let clipboard = saveClipboard()
        defer {
            restoreClipboard(clipboard)
            if let pointer { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pointer, mouseButton: .left)?.post(tap: .cghidEventTap) }
        }
        func ready() -> Bool { contextIsCurrent() && isFrontmost && focusIsMessageBox(pid, for: title) }
        // A window that has only just come forward can swallow the first click
        // as the one that activates it. The click lands in the text part of
        // the box, where a second one is harmless, so try up to three times.
        for attempt in 0..<3 {
            click(point)
            try? await Task.sleep(nanoseconds: attempt == 0 ? 350_000_000 : 500_000_000)
            if ready() { break }
            guard contextIsCurrent(), isFrontmost, isMuseWindow(at: point, pid: pid) else { break }
        }
        guard ready() else { return .failed("Muse’s message box did not take the cursor. Nothing was typed.") }
        guard await copyAll(pid) == nil else {
            post(124, to: pid)               // leave their text unselected, as it was
            return .failed("Muse’s message box already contains a draft. Clear it on the Mac first; nothing was replaced or sent.")
        }

        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prompt, forType: .string)
        guard ready() else { return .failed("Muse changed before the draft was pasted. Nothing was typed.") }
        post(9, command: true, to: pid)      // paste
        let pastedAt = ProcessInfo.processInfo.systemUptime
        try? await Task.sleep(nanoseconds: 350_000_000)
        let pasted = await copyAll(pid)
        guard MuseChatList.holdsDraft(pasted, prompt: prompt) else {
            // The box was empty a moment ago, so whatever is selected now came
            // from this attempt. Remove it rather than leave a wrong draft.
            if pasted != nil, ready() { post(51, to: pid) }
            return .failed("Muse did not take the draft as written. Nothing was sent.")
        }
        guard ready(), snapshot()?.current == title else {
            return .failed("The Muse chat changed before Send. The draft is in Muse’s message box on the Mac; nothing was sent.")
        }
        let before = deliveries(of: prompt)
        let entriesBefore = snapshot()?.historyEntries ?? 0
        // A key pressed on the Mac since the paste may have gone into the box.
        // Read it once more; send only what was verified.
        if MacInput.secondsSinceKey <= ProcessInfo.processInfo.systemUptime - pastedAt + 0.05 {
            guard ready(), MuseChatList.holdsDraft(await copyAll(pid), prompt: prompt) else {
                return .failed("Keys were pressed on this Mac while the draft was going in. Check Muse’s message box; nothing was sent.")
            }
        }
        if rehearsal {
            post(51, to: pid)                // the read-back left the draft selected: delete it
            try? await Task.sleep(nanoseconds: 300_000_000)
            return await copyAll(pid) == nil ? .confirmed("The draft reached Muse’s message box, read back correctly, and was removed. Nothing was sent.")
                                             : .uncertain("The draft reached Muse’s message box but could not be removed. Clear it on the Mac.")
        }
        post(124, to: pid)                   // right arrow: drop the selection
        post(36, to: pid)                    // return: send

        // After Return nothing more is typed unless the box must be read
        // once. Delivery is the draft appearing in the chat once more than
        // before; for text Muse re-renders, it is the history gaining an entry
        // while Muse starts to answer.
        let named = title != MuseChatList.unnamedSideChat
        let sent = Outcome.confirmed("Prompt sent to \(title) in Muse.")
        var grew = false
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let now = snapshot() else { break }
            // Muse names a new side chat once its first message lands, so
            // that chat is not expected to keep its placeholder title.
            if named, now.current != title { break }
            if MuseChatList.showsAsSent(before: before, after: deliveries(of: prompt)) { return sent }
            grew = now.historyEntries > entriesBefore
            let answering = now.answering.count == 1 && (!named || MuseChatList.messageBox(now.answering[0])?.belongs(to: title) == true)
            if MuseChatList.deliveredByEffect(entriesBefore: entriesBefore, entriesAfter: now.historyEntries, answering: answering, boxEmpty: false) { return sent }
        }
        // Muse may have answered and gone idle between looks. One read of the
        // box settles it: empty with a new entry is sent; still full is not.
        if grew, isFrontmost, focusIsMessageBox(pid, for: title), await copyAll(pid) == nil { return sent }
        return .uncertain("Send could not be confirmed. Check Muse on the Mac before sending again.")
    }
}
