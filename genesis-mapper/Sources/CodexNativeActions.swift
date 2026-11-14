import AppKit
import ApplicationServices
import Foundation

struct CodexNativeActionResult {
    let requested: Bool
    let message: String
}

struct CodexNativeMenuRoute {
    let id: String
    let title: String
    let group: String
    let menu: String
    let item: String
    let requiresChat: Bool
    let changesChat: Bool
}

// These are visible, executable native menu entries in the installed app's
// Electron menu builder, not the larger (non-executable) keycap/command catalog.
// Never turn an arbitrary command ID into keystrokes or an internal IPC message.
enum CodexNativeActionPolicy {
    // Exact public page links only: no caller-supplied URLs, queries, paths,
    // plugin installs, skill invocation, or composer prefill.
    static let pageLinks: [String:String] = [
        "newChat":"codex://threads/new",
        "openSettings":"codex://settings",
        "openSkills":"codex://skills"
    ]
    static func pageURL(actionID:String)->URL? {
        pageLinks[actionID].flatMap(URL.init(string:))
    }
    static let routes: [CodexNativeMenuRoute] = [
        .init(id:"newWindow",title:"New window",group:"Chat",menu:"File",item:"New Window",requiresChat:false,changesChat:true),
        .init(id:"newProject",title:"New project…",group:"Workspace",menu:"File",item:"New Project…",requiresChat:false,changesChat:true),
        .init(id:"openFolder",title:"Open folder…",group:"Workspace",menu:"File",item:"Open Folder…",requiresChat:false,changesChat:true),
        .init(id:"goBack",title:"Back",group:"Navigation",menu:"View",item:"Back",requiresChat:false,changesChat:true),
        .init(id:"goForward",title:"Forward",group:"Navigation",menu:"View",item:"Forward",requiresChat:false,changesChat:true),
        .init(id:"previousSidebarItem",title:"Previous sidebar item",group:"Navigation",menu:"View",item:"Previous Sidebar Item",requiresChat:false,changesChat:true),
        .init(id:"nextSidebarItem",title:"Next sidebar item",group:"Navigation",menu:"View",item:"Next Sidebar Item",requiresChat:false,changesChat:true),
        .init(id:"previousTab",title:"Previous tab",group:"Navigation",menu:"View",item:"Previous Tab",requiresChat:false,changesChat:true),
        .init(id:"nextTab",title:"Next tab",group:"Navigation",menu:"View",item:"Next Tab",requiresChat:false,changesChat:true),
        .init(id:"toggleSidebar",title:"Toggle sidebar",group:"Panels",menu:"View",item:"Toggle Sidebar",requiresChat:false,changesChat:false),
        .init(id:"toggleBottomPanel",title:"Toggle bottom panel",group:"Panels",menu:"View",item:"Toggle Bottom Panel",requiresChat:false,changesChat:false),
        .init(id:"togglePinnedSummary",title:"Toggle pinned summary",group:"Panels",menu:"View",item:"Toggle Pinned Summary",requiresChat:false,changesChat:false),
        .init(id:"toggleNavigationPanel",title:"Toggle navigation panel",group:"Panels",menu:"View",item:"Toggle navigation panel",requiresChat:false,changesChat:false),
        .init(id:"toggleTerminal",title:"Open terminal",group:"Panels",menu:"View",item:"Open Terminal",requiresChat:false,changesChat:false),
        .init(id:"findInChat",title:"Find in current view",group:"Navigation",menu:"View",item:"Find",requiresChat:false,changesChat:false),
        .init(id:"keyboardShortcuts",title:"Keyboard shortcuts",group:"App",menu:"Help",item:"Keyboard Shortcuts",requiresChat:false,changesChat:false)
    ]

    struct MenuItem {
        let menu: String
        let title: String
        let role: String
        let enabled: Bool
        let hidden: Bool
        let canPress: Bool
    }

    static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of:"…",with:"...")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator:" ").lowercased()
    }

    static func matchingIndex(actionID: String, items: [MenuItem]) -> Int? {
        guard let route=routes.first(where:{$0.id==actionID}) else { return nil }
        let matches=items.indices.filter {
            let item=items[$0]
            return normalized(item.menu)==normalized(route.menu)
                && normalized(item.title)==normalized(route.item)
                && item.role==kAXMenuItemRole && item.enabled && !item.hidden && item.canPress
        }
        return matches.count==1 ? matches[0]:nil
    }
}

@MainActor
enum CodexNativeActions {
    static var descriptors: [RemoteAction] {
        CodexNativeActionPolicy.routes.map {
            RemoteAction(id:$0.id,title:$0.title,group:$0.group,
                detail:"Acts on the current Codex view on the Mac using \($0.menu) → \($0.item), when available.",
                requiresChat:$0.requiresChat,changesChat:$0.changesChat)
        } + [
            RemoteAction(id:"newChat",title:"New chat",group:"Chat",detail:"Open a new local Codex chat on the Mac, launching Codex if needed. No prompt is sent.",requiresChat:false,changesChat:true),
            RemoteAction(id:"openSettings",title:"Codex settings",group:"App",detail:"Open Codex's settings page on the Mac. Does not change settings.",requiresChat:false,changesChat:true),
            RemoteAction(id:"openSkills",title:"Browse skills",group:"App",detail:"Open Codex's skills page on the Mac. Does not invoke a skill.",requiresChat:false,changesChat:true)
        ]
    }

    static func perform(_ actionID: String, isCurrent: () -> Bool) async -> CodexNativeActionResult {
        func failed(_ message: String) -> CodexNativeActionResult {.init(requested:false,message:message)}
        if let url=CodexNativeActionPolicy.pageURL(actionID:actionID) {
            guard isCurrent(),!Task.isCancelled,
                  let application=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.openai.codex") else {
                return failed("Install Codex on this Mac and keep this controller selection active before opening the page.")
            }
            let config=NSWorkspace.OpenConfiguration();config.activates=true
            guard isCurrent(),!Task.isCancelled else {return failed("The controller selection changed. No page was opened.")}
            do {
                _ = try await NSWorkspace.shared.open([url],withApplicationAt:application,configuration:config)
                let message:String
                switch actionID {
                case "newChat":message="Requested a new local Codex chat on the Mac. No prompt was sent."
                case "openSettings":message="Requested Codex settings on the Mac."
                default:message="Requested Codex's skills page on the Mac. No skill was invoked."
                }
                return .init(requested:true,message:message)
            } catch {return failed("macOS could not open this Codex page.")}
        }
        guard let route=CodexNativeActionPolicy.routes.first(where:{$0.id==actionID}) else {
            return failed("This Codex action is not connected to a verified native control.")
        }
        guard isCurrent(),!Task.isCancelled else {return failed("The controller selection changed. No menu action ran.")}
        guard AXIsProcessTrusted() else {return failed("Enable Accessibility for Genesis on this Mac to use Codex menu controls.")}
        let bundle="com.openai.codex"
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first(where:{!$0.isTerminated}) else {
            return failed("Open Codex on this Mac before using its menu controls.")
        }
        app.activate(options:[])
        for _ in 0..<8 {
            guard isCurrent(),!Task.isCancelled else {return failed("The controller selection changed. No menu action ran.")}
            if NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier {break}
            try? await Task.sleep(nanoseconds:50_000_000)
        }
        guard isCurrent(),NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else {
            return failed("Codex could not become the active Mac app. No menu action ran.")
        }
        let deadline=ProcessInfo.processInfo.systemUptime+1.5
        func value(_ e: AXUIElement,_ attribute: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime<deadline else {return nil}
            AXUIElementSetMessagingTimeout(e,0.08)
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(e,attribute as CFString,&result) == .success ? result:nil
        }
        let root=AXUIElementCreateApplication(app.processIdentifier)
        guard let raw=value(root,kAXMenuBarAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else {
            return failed("Codex's native menu is unavailable in this view.")
        }
        let menuBar=raw as! AXUIElement
        let top=(value(menuBar,kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
            CodexNativeActionPolicy.normalized(value($0,kAXTitleAttribute) as? String ?? "")==CodexNativeActionPolicy.normalized(route.menu)
        }
        guard top.count==1 else {return failed("This Codex menu is unavailable or uses a different language.")}
        var queue:[(AXUIElement,Int)]=[(top[0],0)],index=0,elements=[AXUIElement](),items=[CodexNativeActionPolicy.MenuItem]()
        while index<queue.count,index<200,ProcessInfo.processInfo.systemUptime<deadline {
            let (element,depth)=queue[index];index+=1
            let role=value(element,kAXRoleAttribute) as? String ?? ""
            // Only immediate native menu leaves. Do not walk a nested submenu
            // and accidentally select a similarly named browser/page command.
            if role==kAXMenuItemRole {
                let title=value(element,kAXTitleAttribute) as? String ?? ""
                if CodexNativeActionPolicy.normalized(title)==CodexNativeActionPolicy.normalized(route.item) {
                    var actions:CFArray?
                    AXUIElementCopyActionNames(element,&actions)
                    items.append(.init(menu:route.menu,title:title,role:role,
                        enabled:value(element,kAXEnabledAttribute) as? Bool == true,
                        hidden:value(element,"AXHidden") as? Bool == true,
                        canPress:(actions as? [String] ?? []).contains(kAXPressAction)))
                    elements.append(element)
                }
                continue
            }
            if depth<3,let children=value(element,kAXChildrenAttribute) as? [AXUIElement] {
                for child in children.prefix(200-queue.count) {queue.append((child,depth+1))}
            }
        }
        guard ProcessInfo.processInfo.systemUptime<deadline,
              let target=CodexNativeActionPolicy.matchingIndex(actionID:actionID,items:items) else {
            return failed("\(route.title) is unavailable, disabled, or ambiguous in Codex's current view.")
        }
        guard isCurrent(),!Task.isCancelled,!app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier,
              value(elements[target],kAXEnabledAttribute) as? Bool == true else {
            return failed("The active Mac view changed. No menu action ran.")
        }
        guard AXUIElementPerformAction(elements[target],kAXPressAction as CFString) == .success else {
            return failed("Codex did not accept this native menu action. Nothing was retried.")
        }
        // AXPress acknowledgement is not evidence of a completed UI transition.
        return .init(requested:true,message:"Requested \(route.title) in Codex on the Mac.")
    }
}
