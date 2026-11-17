import Foundation

/// One line of the "Check this Mac" report.
struct SelfCheckItem: Codable, Equatable {
    var provider: String   // "mac", "claude", "muse", "codex"
    var name: String       // short label, e.g. "Message box"
    var ok: Bool
    var detail: String     // one plain sentence: what was found, or what to do about it
}

/// The wording and ordering rules for the self-check. It takes a description
/// of what was observed and never touches the Mac itself, so every rule can be
/// tested without the apps being open.
enum SelfCheck {
    struct Mac { var unlocked: Bool; var accessibility: Bool }

    struct Claude {
        var installed: Bool; var running: Bool
        var sessionRows: Int          // sessions listed in Claude's sidebar
        var promptFields: Int         // message boxes found
        var sendOrStopButtons: Int    // Send (or Stop, while answering) controls found
        var modelChoosers: Int        // "Model: …" choosers found
        var permissionChooserFound: Bool
    }

    struct Muse {
        var installed: Bool; var running: Bool
        var navigable: Bool           // a chat-list header or a "Back to main chat" control is showing
        var messageBoxes: Int
        var answering: Bool           // Muse is replying right now
        var chats: Int                // chats that can be offered
        var sharedTitles: Int         // titles shared by several chats, which are left out
        var callControls: Int
    }

    struct Codex {
        var installed: Bool; var running: Bool
        var inventoryReachable: Bool  // Codex's background service answered
        var savedChats: Int
        var menuBarReadable: Bool
        var queueAvailable: Bool      // the command used to send prompts exists
    }

    // MARK: Mac

    static func mac(_ mac: Mac) -> [SelfCheckItem] {
        [
            item("mac", "Unlocked", mac.unlocked,
                 ok: "This Mac is unlocked.",
                 problem: "This Mac is locked. Unlock it to use any controls."),
            item("mac", "Accessibility", mac.accessibility,
                 ok: "Agent Micro Controller is allowed to control other apps.",
                 problem: "Allow Accessibility for Agent Micro Controller in System Settings, under Privacy & Security."),
        ]
    }

    // MARK: Claude

    static func claude(_ claude: Claude, mac: Mac) -> [SelfCheckItem] {
        if let cause = rootCause("claude", "Claude", installed: claude.installed, running: claude.running, mac: mac) {
            return [cause]
        }
        return [
            item("claude", "Session list", claude.sessionRows > 0,
                 ok: "\(count(claude.sessionRows, "session")) found.",
                 problem: "No sessions found. Show Claude\u{2019}s sidebar."),
            single("claude", "Message box", claude.promptFields,
                   ok: "One message box found.",
                   none: "No message box is showing. Open a session in Claude.",
                   many: "More than one message box is showing, so the target is ambiguous."),
            // Claude only shows Send once there is a draft in the box, so its
            // absence beside an empty message box is the normal resting state.
            claude.sendOrStopButtons == 0 && claude.promptFields == 1
                ? SelfCheckItem(provider: "claude", name: "Send control", ok: true,
                                detail: "Not showing yet. Claude adds it once a draft is in the message box.")
                : single("claude", "Send control", claude.sendOrStopButtons,
                         ok: "The Send control was found.",
                         none: "The Send control was not found. Claude\u{2019}s layout may have changed.",
                         many: "More than one Send control was found, so the target is ambiguous. Claude\u{2019}s layout may have changed."),
            single("claude", "Model chooser", claude.modelChoosers,
                   ok: "The model chooser was found.",
                   none: "The model chooser was not found. Claude\u{2019}s layout may have changed.",
                   many: "More than one model chooser was found, so the target is ambiguous. Claude\u{2019}s layout may have changed."),
            item("claude", "Permissions chooser", claude.permissionChooserFound,
                 ok: "Found beside the model chooser.",
                 problem: "Not found beside the model chooser. Claude\u{2019}s layout may have changed."),
        ]
    }

    // MARK: Muse

    static func muse(_ muse: Muse, mac: Mac) -> [SelfCheckItem] {
        if let cause = rootCause("muse", "Muse", installed: muse.installed, running: muse.running, mac: mac) {
            return [cause]
        }

        // Left-out titles are worth a sentence of their own: the person can fix them.
        var chatsDetail = "\(count(muse.chats, "chat")) offered."
        if muse.chats > 0, muse.sharedTitles > 0 {
            let one = muse.sharedTitles == 1
            chatsDetail += one
                ? " 1 title is shared by several chats and is left out; rename it in Muse to use it."
                : " \(muse.sharedTitles) titles are shared by several chats and are left out; rename them in Muse to use them."
        }

        // While Muse answers, its box is replaced by a Stop control, so a
        // missing or doubled box is expected and not a layout problem.
        let box: SelfCheckItem
        if muse.answering {
            box = SelfCheckItem(provider: "muse", name: "Message box", ok: true,
                                detail: "Muse is answering. Sending waits until it finishes.")
        } else {
            box = single("muse", "Message box", muse.messageBoxes,
                         ok: "One message box found.",
                         none: "No message box is showing. Open a chat in Muse.",
                         many: "More than one message box is showing, so the target is ambiguous.")
        }

        return [
            item("muse", "Chat list", muse.navigable,
                 ok: "The chat list is showing.",
                 problem: "Muse is showing a screen without its chat list."),
            SelfCheckItem(provider: "muse", name: "Chats", ok: muse.chats > 0,
                          detail: muse.chats > 0 ? chatsDetail : "No chats found."),
            box,
            item("muse", "Call control", muse.callControls == 1,
                 ok: "The call control was found.",
                 problem: "Not showing. A call may already be in progress."),
        ]
    }

    // MARK: Codex

    static func codex(_ codex: Codex, mac: Mac) -> [SelfCheckItem] {
        if !codex.installed {
            return [SelfCheckItem(provider: "codex", name: "Installed", ok: false,
                                  detail: "Codex is not installed on this Mac. Install it to use these controls.")]
        }
        if !mac.unlocked {
            return [SelfCheckItem(provider: "codex", name: "Reachable", ok: false,
                                  detail: "This Mac is locked. Unlock it to reach Codex.")]
        }
        // Not running is deliberately not a root cause: chats and sending go
        // through a background service that works with the window closed.

        let menuDetail: String
        if !codex.running {
            menuDetail = "Open Codex to use its menu controls."
        } else if !mac.accessibility {
            menuDetail = "Allow Accessibility for Agent Micro Controller to use Codex\u{2019}s menu controls."
        } else if !codex.menuBarReadable {
            menuDetail = "Codex\u{2019}s menus could not be read."
        } else {
            menuDetail = "Codex\u{2019}s menus can be read."
        }

        return [
            item("codex", "Saved chats", codex.inventoryReachable,
                 ok: "\(count(codex.savedChats, "saved chat")) found.",
                 problem: "Codex\u{2019}s background service is not answering. Restart it by running: codex app-server daemon restart"),
            item("codex", "Send", codex.queueAvailable,
                 ok: "The command used to send prompts was found.",
                 problem: "The command used to send prompts was not found in the installed Codex app."),
            SelfCheckItem(provider: "codex", name: "Menu controls",
                          ok: codex.running && mac.accessibility && codex.menuBarReadable,
                          detail: menuDetail),
        ]
    }

    // MARK: Summary

    static func summary(_ items: [SelfCheckItem]) -> String {
        if items.isEmpty { return "Nothing was checked." }
        let failed = items.filter { !$0.ok }
        if failed.isEmpty { return "All \(count(items.count, "check")) passed." }

        let list = failed.map { "\(label($0.provider)) \u{2013} \($0.name)" }.joined(separator: "; ")
        let verb = failed.count == 1 ? "needs" : "need"
        return "\(failed.count) of \(count(items.count, "check")) \(verb) attention: \(list)."
    }

    // MARK: Helpers

    private static func item(_ provider: String, _ name: String, _ ok: Bool,
                             ok okText: String, problem: String) -> SelfCheckItem {
        SelfCheckItem(provider: provider, name: name, ok: ok, detail: ok ? okText : problem)
    }

    /// A control that must be found exactly once: zero and several are different problems.
    private static func single(_ provider: String, _ name: String, _ found: Int,
                               ok okText: String, none: String, many: String) -> SelfCheckItem {
        SelfCheckItem(provider: provider, name: name, ok: found == 1,
                      detail: found == 1 ? okText : (found == 0 ? none : many))
    }

    /// Apps read through Accessibility share the same four possible root causes.
    /// Reporting only the first keeps one real problem from looking like six.
    private static func rootCause(_ provider: String, _ app: String,
                                  installed: Bool, running: Bool, mac: Mac) -> SelfCheckItem? {
        if !installed {
            return SelfCheckItem(provider: provider, name: "Installed", ok: false,
                                 detail: "\(app) is not installed on this Mac. Install it to use these controls.")
        }
        if !mac.unlocked {
            return SelfCheckItem(provider: provider, name: "Reachable", ok: false,
                                 detail: "This Mac is locked, so \(app) cannot be reached. Unlock it first.")
        }
        if !mac.accessibility {
            return SelfCheckItem(provider: provider, name: "Reachable", ok: false,
                                 detail: "Accessibility is needed to reach \(app). Allow it for Agent Micro Controller in System Settings, under Privacy & Security.")
        }
        if !running {
            return SelfCheckItem(provider: provider, name: "Open", ok: false,
                                 detail: "Open \(app) on this Mac.")
        }
        return nil
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private static func label(_ provider: String) -> String {
        provider.prefix(1).uppercased() + provider.dropFirst()
    }
}
