import SwiftUI
import AppKit
import ApplicationServices
import IOKit.hid

func controllerTrace(_ message:String) {
 let url=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("genesis-microphone-trace.log")
 let data=Data("\(Date().timeIntervalSince1970) \(message)\n".utf8)
 if !FileManager.default.fileExists(atPath:url.path) {FileManager.default.createFile(atPath:url.path,contents:nil)}
 if let f=try? FileHandle(forWritingTo:url) {defer {try? f.close()};_ = try? f.seekToEnd();try? f.write(contentsOf:data)}
}
struct Session: Identifiable { var id: String { title }; let title: String; let state: String }
final class ClaudeAccess {
    let bundle = "com.anthropic.claudefordesktop"
    private var scanDeadline=Double.infinity
    private var scanExpired=false
    private let scanCache=ReadSnapshotCache<String,(AXUIElement,AnyObject?)>()
    func readSnapshot<Result>(_ read:()->Result)->Result {scanCache.withSnapshot(read)}
    func sessionSnapshot()->[Session]? {
        scanExpired=false;scanDeadline=ProcessInfo.processInfo.systemUptime+2
        defer {scanDeadline = .infinity}
        let result=readSnapshot {sessions(nodes())}
        return scanExpired ? nil:result
    }
    func value(_ e: AXUIElement, _ key: String) -> AnyObject? {
        let cacheKey="\(CFHash(e)):\(key)"
        if let (cachedElement,cachedValue)=scanCache[cacheKey],CFEqual(e,cachedElement) {return cachedValue}
        if ProcessInfo.processInfo.systemUptime>scanDeadline {scanExpired=true;return nil}
        AXUIElementSetMessagingTimeout(e,0.06)
        var v: CFTypeRef?;let result=AXUIElementCopyAttributeValue(e,key as CFString,&v)
        let value:AnyObject?=result == .success ? v:nil
        scanCache[cacheKey]=(e,value)
        return value
    }
    func text(_ e: AXUIElement) -> String {
        for k in [kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute] { if let s=value(e,k) as? String, !s.isEmpty { return s } }; return ""
    }
    func nodes() -> [AXUIElement] {
        guard AXIsProcessTrusted(), let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first else { return [] }
        let root=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,0.3)
        var queue=[root], result=[AXUIElement](), index=0
        while index<queue.count && index<4500 { let e=queue[index]; index+=1; result.append(e)
            if ["Chat messages","Changes"].contains(text(e)) { continue }
            if let children=value(e,kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf:children) }
        }; return result
    }
    var lastActivitySnapshot=""
    let states=["Awaiting input","Something went wrong","Needs input","Working","Running","Idle","Unread"]
    func sessions(_ nodes: [AXUIElement]) -> [Session] {
        var result=[Session]()
        for e in nodes where value(e,kAXRoleAttribute) as? String == kAXButtonRole {
            let label=text(e)
            for state in states where label.hasPrefix(state+" ") {
                result.append(Session(title:String(label.dropFirst(state.count+1)),state:state));break
            }
        }
        let menuTitles=Set(nodes.filter {value($0,kAXRoleAttribute) as? String == kAXPopUpButtonRole && text($0).hasPrefix("More options for ")}.map {String(text($0).dropFirst("More options for ".count))})
        for title in menuTitles {
            // Claude nests the menu inside a group next to its title button.
            // Discovery and selection must use the same row qualification.
            guard !title.isEmpty,!result.contains(where:{$0.title==title}),
                let destination=sidebarTargets(title,in:nodes).first,
                let parent=value(destination,kAXParentAttribute),CFGetTypeID(parent)==AXUIElementGetTypeID(),
                let row=value(parent as! AXUIElement,kAXChildrenAttribute) as? [AXUIElement] else {continue}
            var children=row,index=0,labels=[String]()
            while index<children.count && index<40 {
                let e=children[index];index+=1;labels.append(text(e))
                if let nested=value(e,kAXChildrenAttribute) as? [AXUIElement] {children.append(contentsOf:nested)}
            }
            let state=states.first {state in labels.contains{ $0==title+" "+state || $0==state+" "+title || $0==state }} ?? "Open"
            result.append(Session(title:title,state:state))
        }
        // An open fork may lack a recognized status prefix in the sidebar.
        // The session header is also used to verify navigation and dictation.
        let suffix=", rename session"
        for e in nodes {
            let label=text(e)
            if label.hasSuffix(suffix) {
                let title=String(label.dropLast(suffix.count))
                if !title.isEmpty && !result.contains(where: {$0.title==title}) {
                    result.append(Session(title:title,state:"Open"))
                }
            }
        }
        let headers=nodes.filter {text($0).hasSuffix(suffix)}
        let buttons=nodes.filter {value($0,kAXRoleAttribute) as? String == kAXButtonRole}
        if let state=ClaudeActivity.activeState(headerCount:headers.count,
            stopCount:buttons.filter{text($0)=="Stop"}.count,
            sendCount:buttons.filter{text($0)=="Send"}.count), let header=headers.first {
            let title=String(text(header).dropLast(suffix.count))
            result.removeAll {$0.title==title}
            result.append(Session(title:title,state:state))
        }
        return result
    }
    func press(_ e: AXUIElement) -> Bool {
        if let enabled=value(e,kAXEnabledAttribute) as? Bool, !enabled { return false }
        return AXUIElementPerformAction(e,kAXPressAction as CFString) == .success
    }
    func current(_ title: String) -> Bool {
        readSnapshot {nodes().filter { text($0)==title+", rename session" }.count==1}
    }
    func targetSnapshot(_ title:String)->(isCurrent:Bool,destinationCount:Int) {
        readSnapshot {
            let all=nodes()
            return (all.filter{text($0)==title+", rename session"}.count==1,sidebarTargets(title,in:all).count)
        }
    }
    // A session can have matching menus in its sidebar row and primary toolbar.
    // Only navigable sidebar buttons establish distinct destinations.
    func sidebarTargets(_ title:String,in all:[AXUIElement]) -> [AXUIElement] {
        var matches=[AXUIElement]()
        for e in all {
            guard value(e,kAXRoleAttribute) as? String == kAXButtonRole else {continue}
            let label=text(e)
            guard !title.isEmpty,label.contains(title) else {continue}
            // Status badges can decorate the button label. Known suffixes are
            // checked exactly by the shared policy; otherwise an exact title
            // text child and matching row menu must independently agree.
            var descendants=value(e,kAXChildrenAttribute) as? [AXUIElement] ?? [],childIndex=0,exactTitleChild=false
            while childIndex<descendants.count && childIndex<40 {
                let child=descendants[childIndex];childIndex+=1
                if value(child,kAXRoleAttribute) as? String == kAXStaticTextRole,text(child)==title {exactTitleChild=true;break}
                if let children=value(child,kAXChildrenAttribute) as? [AXUIElement] {descendants.append(contentsOf:children)}
            }
            var ancestor=value(e,kAXParentAttribute) as! AXUIElement?,toolbar=false
            for _ in 0..<6 {
                guard let parent=ancestor else {break}
                if value(parent,kAXRoleAttribute) as? String == kAXToolbarRole {toolbar=true;break}
                ancestor=value(parent,kAXParentAttribute) as! AXUIElement?
            }
            guard !toolbar else {continue}
            var valid=states.contains(where:{label==$0+" "+title})
            if !valid,let parent=value(e,kAXParentAttribute),CFGetTypeID(parent)==AXUIElementGetTypeID(),
               let siblings=value(parent as! AXUIElement,kAXChildrenAttribute) as? [AXUIElement] {
                var row=siblings,index=0
                while index<row.count && index<40 {
                    let node=row[index];index+=1
                    if text(node)=="More options for "+title {valid=true;break}
                    if let children=value(node,kAXChildrenAttribute) as? [AXUIElement] {row.append(contentsOf:children)}
                }
            }
            if RemoteClaudeLookup.isSidebarCandidate(label:label,title:title,inToolbar:toolbar,hasMatchingRowMenu:valid,statuses:states,hasExactTitleChild:exactTitleChild),!matches.contains(where:{CFEqual($0,e)}) {matches.append(e)}
        }
        return matches
    }
    // Electron can acknowledge AXPress without activating its DOM button.
    // Only click a freshly resolved, unobscured Claude navigation control.
    @MainActor func navigationClick(_ element: AXUIElement, app: NSRunningApplication, contextIsCurrent: (() -> Bool)? = nil) async -> Bool {
        guard (value(element,kAXEnabledAttribute) as? Bool) != false,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let pv=value(element,kAXPositionAttribute), let sv=value(element,kAXSizeAttribute),
              CFGetTypeID(pv)==AXValueGetTypeID(), CFGetTypeID(sv)==AXValueGetTypeID() else {return false}
        var point=CGPoint.zero, size=CGSize.zero
        guard AXValueGetValue(pv as! AXValue,.cgPoint,&point), AXValueGetValue(sv as! AXValue,.cgSize,&size), size.width>0,size.height>0 else {return false}
        point.x += size.width/2;point.y += size.height/2
        let previous=CGEvent(source:nil)?.location
        var matched=false
        for attempt in 0..<3 {
            if let position=value(element,kAXPositionAttribute),let dimensions=value(element,kAXSizeAttribute),CFGetTypeID(position)==AXValueGetTypeID(),CFGetTypeID(dimensions)==AXValueGetTypeID() {
                var origin=CGPoint.zero,extent=CGSize.zero
                if AXValueGetValue(position as! AXValue,.cgPoint,&origin),AXValueGetValue(dimensions as! AXValue,.cgSize,&extent),extent.width>0,extent.height>0 {size=extent;point=CGPoint(x:origin.x+extent.width/2,y:origin.y+extent.height/2)}
            }
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit) == .success {
                for _ in 0..<8 {
                    guard let node=hit else {break}
                    var pid:pid_t=0;AXUIElementGetPid(node,&pid)
                    if pid==app.processIdentifier && (CFEqual(node,element) ||
                        (value(node,kAXRoleAttribute) as? String == value(element,kAXRoleAttribute) as? String && text(node)==text(element))) {matched=true;break}
                    hit=value(node,kAXParentAttribute) as! AXUIElement?
                }
            }
            if matched {break}
            controllerTrace("hit check retry=\(attempt)")
            // Dismiss hover overlays and let Electron refresh its hit-test tree.
            CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:CGPoint(x:point.x+size.width+20,y:point.y),mouseButton:.left)?.post(tap:.cghidEventTap)
            try? await Task.sleep(nanoseconds:180_000_000)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {break}
        }
        guard matched else {
            if let previous {CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:previous,mouseButton:.left)?.post(tap:.cghidEventTap)}
            return false
        }
        guard contextIsCurrent?() != false else {return false}
        CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap)
        try? await Task.sleep(nanoseconds:80_000_000)
        CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap)
        try? await Task.sleep(nanoseconds:80_000_000)
        if let previous {CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:previous,mouseButton:.left)?.post(tap:.cghidEventTap)}
        return true
    }
    @MainActor func select(_ title: String) async -> String {
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first else {return "Open Claude first."}
        NSApp.yieldActivation(to: app)
        if let url=app.bundleURL {
            let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
            _ = try? await NSWorkspace.shared.openApplication(at:url,configuration:configuration)
        } else {app.activate()}
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {break}
            try? await Task.sleep(nanoseconds:100_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {return "Claude could not come to the foreground. No click sent."}
        try? await Task.sleep(nanoseconds:200_000_000)
        let initial=readSnapshot { ()->(Bool,[AXUIElement],[AXUIElement]) in
            let all=nodes()
            return (all.filter{text($0)==title+", rename session"}.count==1,sidebarTargets(title,in:all),all.filter{text($0)=="Show sidebar" && value($0,kAXRoleAttribute) as? String==kAXButtonRole})
        }
        if initial.0 {return "Opened \(title)"}
        var matches=initial.1
        if matches.isEmpty,initial.2.count==1 {
            _=await navigationClick(initial.2[0],app:app)
            try? await Task.sleep(nanoseconds:300_000_000)
            matches=readSnapshot {sidebarTargets(title,in:nodes())}
        }
        controllerTrace("navigation matches=\(matches.count)")
        guard matches.count==1 else { return "Session missing or ambiguous. Open Claude’s Code sidebar and refresh." }
        guard await navigationClick(matches[0],app:app) else {return "Claude session is obscured or off-screen. No click sent."}
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds:150_000_000)
            if current(title) {return "Opened \(title)"}
        }
        return "Claude accepted the click but did not open the session. No Send or Dictate action is enabled."
    }
    @MainActor func discover() async -> [Session] {
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first else {return []}
        NSApp.yieldActivation(to:app)
        if let url=app.bundleURL {let c=NSWorkspace.OpenConfiguration();c.activates=true;_ = try? await NSWorkspace.shared.openApplication(at:url,configuration:c)}
        try? await Task.sleep(nanoseconds:300_000_000)
        if sessions(nodes()).isEmpty {
            let buttons=nodes().filter {text($0)=="Show sidebar" && value($0,kAXRoleAttribute) as? String == kAXButtonRole}
            if buttons.count==1 {_ = press(buttons[0]);try? await Task.sleep(nanoseconds:400_000_000);if sessions(nodes()).isEmpty {_ = await navigationClick(buttons[0],app:app);try? await Task.sleep(nanoseconds:400_000_000)}}
        }
        return sessions(nodes())
    }
    @MainActor func extraAction(_ action:ControllerAction,title:String,app:NSRunningApplication,contextIsCurrent:(()->Bool)?=nil) async -> String {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else {return "Claude is not in front. No input sent."}
        let all=nodes()
        if action.sessionRequired && (title.isEmpty || all.filter({text($0)==title+", rename session"}).count != 1) {return "Select a Claude Code session first."}
        func contextOK()->Bool {NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier && (contextIsCurrent?() ?? true)}
        guard contextOK() else{return "The target changed. No input sent."}
        if let menu=action.menu {
            let bars=all.filter {value($0,kAXRoleAttribute) as? String==kAXMenuBarItemRole && text($0)==menu}
            guard bars.count==1,contextOK(),press(bars[0]) else {return "Claude’s \(menu) menu is unavailable."}
            var descendants=[bars[0]],index=0
            while index<descendants.count && index<300 {
                let node=descendants[index];index+=1
                if let children=value(node,kAXChildrenAttribute) as? [AXUIElement] {descendants.append(contentsOf:children)}
            }
            let items=descendants.filter {value($0,kAXRoleAttribute) as? String==kAXMenuItemRole && action.labels.contains(text($0))}
            guard items.count==1 else {return "This command is not available in this Claude version."}
            guard contextOK(),press(items[0]) else {return "\(action.title) is disabled in this view."}
            return "Requested \(action.title)"
        }
        let roles=[kAXButtonRole,kAXPopUpButtonRole,kAXCheckBoxRole,"AXToggleButton","AXSwitch"]
        var candidates=all.filter {element in roles.contains(value(element,kAXRoleAttribute) as? String ?? "") && (action.labels.contains(text(element)) || action.prefixes.contains{prefix in text(element).hasPrefix(prefix)})}
        if action.id=="focus" {
            let fields=all.filter {value($0,kAXRoleAttribute) as? String==kAXTextAreaRole && value($0,kAXDescriptionAttribute) as? String=="Prompt"}
            guard fields.count==1,contextOK() else {return "No unique prompt field is available."}
            return AXUIElementSetAttributeValue(fields[0],kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success ? "Prompt focused" : "Could not focus the prompt."
        }
        if action.id=="rename" {candidates=all.filter{text($0)==title+", rename session" && value($0,kAXRoleAttribute) as? String==kAXButtonRole}}
        if action.id=="options" {
            // Scope to the session toolbar, not an identically labelled sidebar row.
            candidates=all.filter {e in
                guard text(e)=="More options for "+title else {return false}
                var parent=value(e,kAXParentAttribute) as! AXUIElement?
                for _ in 0..<4 {guard let p=parent else {break};if value(p,kAXRoleAttribute) as? String==kAXToolbarRole {return true};parent=value(p,kAXParentAttribute) as! AXUIElement?}
                return false
            }
        }
        if ["terminal","browser","changes","files","details"].contains(action.id) {
            candidates=candidates.filter {element in value(element,kAXRoleAttribute) as? String != kAXButtonRole || value(element,kAXValueAttribute) != nil}
        }
        guard candidates.count==1 else {return "\(action.title) is unavailable or ambiguous in this view. No click sent."}
        guard (value(candidates[0],kAXEnabledAttribute) as? Bool) != false else {return "\(action.title) is disabled in this view."}
        return await navigationClick(candidates[0],app:app,contextIsCurrent:contextOK) ? "Requested \(action.title)" : "Control is obscured or off-screen. No click sent."
    }
    @MainActor func action(_ action: String, title: String) async -> String {
        guard let foregroundApp=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first else {return "Open Claude first."}
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != foregroundApp.processIdentifier {
            NSApp.yieldActivation(to:foregroundApp)
            if let url=foregroundApp.bundleURL {let c=NSWorkspace.OpenConfiguration();c.activates=true;_ = try? await NSWorkspace.shared.openApplication(at:url,configuration:c)}
            try? await Task.sleep(nanoseconds:250_000_000)
        }
        guard let definition=ControllerAction.find(action) else {return "Unknown action. No input sent."}
        if action != "send" && action != "dictate" {return await extraAction(definition,title:title,app:foregroundApp)}
        let all=nodes()
        guard !title.isEmpty, all.filter({text($0)==title+", rename session"}).count==1 else { return "Select the mapped session first; current session does not match." }
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first else {return "Open Claude first."}
        let target=action=="send" ? "Send" : (all.contains {text($0)=="Stop dictation"} ? "Stop dictation" : "Dictate")
        controllerTrace("resolve action=\(action) target=\(target)")
        let candidates=all.filter { text($0)==target && [kAXButtonRole,kAXCheckBoxRole,"AXToggleButton","AXSwitch"].contains(value($0,kAXRoleAttribute) as? String ?? "") }
        guard candidates.count==1 else {return action=="dictate" ? "Set Claude Dictation settings → Hold to record OFF, then retry." : "No unique Send button is available."}
        NSApp.yieldActivation(to: app)
        app.activate()
        if action=="dictate" {
            let wasRecording=target=="Stop dictation"
            func recordingState() -> Bool? {
                let controls=nodes().filter { ["Dictate","Stop dictation"].contains(text($0)) && [kAXButtonRole,kAXCheckBoxRole,"AXToggleButton","AXSwitch"].contains(value($0,kAXRoleAttribute) as? String ?? "") }
                guard controls.count==1 else {return nil}
                let recording=text(controls[0])=="Stop dictation"
                controllerTrace("observed recording=\(recording)")
                return recording
            }
            guard recordingState()==wasRecording, current(title) else {return "Could not confirm microphone state. No click sent."}
            let fresh=nodes().filter {text($0)==target && [kAXButtonRole,kAXCheckBoxRole,"AXToggleButton","AXSwitch"].contains(value($0,kAXRoleAttribute) as? String ?? "")}
            guard fresh.count==1, await navigationClick(fresh[0],app:app) else {return "Microphone control is unavailable."}
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds:100_000_000)
                if recordingState() == !wasRecording {return wasRecording ? "Dictation stopped" : "Dictation started"}
            }
            return "Microphone did not change state. Try again."
        }
        return await navigationClick(candidates[0],app:app) ? "Sent composer" : "Control is disabled or unavailable."
    }
}

final class HIDLink {
    var manager: IOHIDManager!; var device: IOHIDDevice?
    let buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:128)
    var bytes=Data(); var nextID=40000
    var received: (([String:Any])->Void)?
    func start() {
        manager=IOHIDManagerCreate(kCFAllocatorDefault,IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:0x303a,kIOHIDProductIDKey:0x8360] as CFDictionary)
        let context=Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager,{ context,_,_,dev in
            guard let context else{return};let me=Unmanaged<HIDLink>.fromOpaque(context).takeUnretainedValue()
            guard let configuredSerial = UserDefaults.standard.string(forKey: "GenesisUSBSerial"),
                  !configuredSerial.isEmpty,
                  IOHIDDeviceGetProperty(dev, kIOHIDSerialNumberKey as CFString) as? String == configuredSerial else { return }
            guard IOHIDDeviceOpen(dev,0)==kIOReturnSuccess else{return};me.device=dev
            IOHIDDeviceRegisterInputReportCallback(dev,me.buffer,128,{ctx,_,_,_,_,report,length in
                guard let ctx else{return};Unmanaged<HIDLink>.fromOpaque(ctx).takeUnretainedValue().input(Data(bytes:report,count:length))
            },context)
        },context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager,{context,_,_,_ in
            guard let context else{return};let me=Unmanaged<HIDLink>.fromOpaque(context).takeUnretainedValue();me.device=nil;me.bytes.removeAll();me.received?(["disconnected":true])
        },context)
        IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager,0)
    }
    func input(_ report: Data) {
        var r=[UInt8](report);if r.count==64 && r[0]==6 {r.removeFirst()}
        guard r.count>=2,r[0]==2,Int(r[1])<=61,r.count>=Int(r[1])+2 else{return}
        bytes.append(contentsOf:r[2..<(Int(r[1])+2)])
        if bytes.count>16384 {bytes.removeAll();return}
        while let end=bytes.firstIndex(of:10) {
            let line=bytes.prefix(upTo:end);bytes.removeSubrange(...end)
            if let object=try? JSONSerialization.jsonObject(with:line) as? [String:Any] {received?(object)}
        }
    }
    @discardableResult func send(_ method: String,_ params: Any) -> Int? {
        guard let device else{return nil};nextID+=1
        guard let data=try? JSONSerialization.data(withJSONObject:["method":method,"params":params,"id":nextID]) else{return nil}
        let raw=[UInt8](data)
        for start in stride(from:0,to:raw.count,by:61) {
            let count=min(61,raw.count-start);var report=[UInt8](repeating:0,count:64)
            report[0]=6;report[1]=2;report[2]=UInt8(count);report.replaceSubrange(3..<3+count,with:raw[start..<start+count])
            let status=report.withUnsafeBufferPointer {IOHIDDeviceSetReport(device,kIOHIDReportTypeOutput,6,$0.baseAddress!,64)}
            if status != kIOReturnSuccess {return nil}
        }
        return nextID
    }
}

@MainActor final class Model: ObservableObject {
    @Published var sessions=[Session]()
    @Published var knownTitles=UserDefaults.standard.stringArray(forKey:"knownSessionTitles") ?? [String]()
    @Published var slots: [String] = (UserDefaults.standard.stringArray(forKey:"slots") ?? Array(repeating:"",count:6)) { didSet {UserDefaults.standard.set(slots,forKey:"slots")} }
    @Published var slotActions: [String] = UserDefaults.standard.stringArray(forKey:"slotActions") ?? Array(repeating:"chat",count:6) {didSet {UserDefaults.standard.set(slotActions,forKey:"slotActions")}}
    func slotLabel(_ i:Int)->String {slotActions[i]=="chat" ? (slots[i].isEmpty ? "Assign chat" : slots[i]) : (ControllerAction.find(slotActions[i])?.title ?? "Unassigned")}
    @Published var menuActions=ControllerAction.menu(UserDefaults.standard.stringArray(forKey:"menuActions")) {didSet {UserDefaults.standard.set(menuActions,forKey:"menuActions");syncCatalog()}}
    @Published var nativeControls=CodexControls.current()
    @Published var supportsCatalog=false
    var catalogSignature=""
    var catalogRequest:(id:Int,signature:String,sent:Date)?
    func toggleMenu(_ id:String,_ enabled:Bool) {
        guard id != "send",id != "dictate" else {return}
        menuActions=ControllerAction.menu(enabled ? menuActions+[id] : menuActions.filter{$0 != id})
    }
    func syncCatalog() {
        guard supportsCatalog else {return}
        if let pending=catalogRequest,Date().timeIntervalSince(pending.sent)>5 {catalogRequest=nil}
        guard catalogRequest==nil else {return}
        let actions=ControllerAction.menu(menuActions).compactMap {id -> [String:String]? in
            guard let action=ControllerAction.find(id) else {return nil}
            let mapped=id=="dictate" ? microphoneAction : id=="send" ? sendAction : id
            let title=ControllerAction.find(mapped)?.title ?? "Do nothing"
            return ["key":action.id.uppercased(),"label":CodexControls.screenLabel(title)]
        }
        let controls=CodexControls.current();if controls != nativeControls {nativeControls=controls}
        let talkIndex=controls.indices.first{controls[$0].id=="ACT10" && controls[$0].isTalk} ?? controls.indices.first{controls[$0].isTalk} ?? -1
        let sendMask=controls.enumerated().reduce(0){$0 | ($1.element.isSend ? 1<<$1.offset:0)}
        let payload:[String:Any]=["codex_talk_index":talkIndex,"codex_send_mask":sendMask,"claude_actions":actions,"codex_labels":controls.map{CodexControls.screenLabel($0.title)},"codex_enabled":controls.enumerated().reduce(0){$0 | ($1.element.enabled ? 1<<$1.offset:0)}]
        guard let data=try? JSONSerialization.data(withJSONObject:payload,options:.sortedKeys),let signature=String(data:data,encoding:.utf8),signature != catalogSignature else {return}
        if let id=hid.send("genesis.settings",payload) {catalogRequest=(id,signature,Date())}
    }
    @Published var mode="Waiting for Genesis"
    @Published var status="Open Claude’s Code sidebar, then Refresh sessions."
    @Published var trusted=false
    @Published var selected = -1
    @Published var selecting=false
    @Published var loginEnabled=LoginLaunch.enabled
    @Published var soundEnabled=true
    @Published var encoderDetents=1
    @Published var firmware="Not connected"
    @Published var talkAfterSelect=UserDefaults.standard.object(forKey:"talkAfterSelect") as? Bool ?? true {didSet {UserDefaults.standard.set(talkAfterSelect,forKey:"talkAfterSelect");configure(["talk_after_select":talkAfterSelect])}}
    @Published var microphoneAction=UserDefaults.standard.string(forKey:"microphoneAction") ?? "dictate" {didSet {UserDefaults.standard.set(microphoneAction,forKey:"microphoneAction");syncCatalog()}}
    @Published var sendAction=UserDefaults.standard.string(forKey:"sendAction") ?? "send" {didSet {UserDefaults.standard.set(sendAction,forKey:"sendAction");syncCatalog()}}
    @Published var quietStudioPromptIntegrationEnabled=UserDefaults.standard.bool(forKey:"quietStudioPromptIntegrationEnabled") {
        didSet {
            UserDefaults.standard.set(quietStudioPromptIntegrationEnabled,forKey:"quietStudioPromptIntegrationEnabled")
            reconcileQuietStudioIntegrationChange()
        }
    }
    var supportsSettings: Bool {firmware != "Not connected" && firmware.compare("v0.2.2",options:.numeric) != .orderedAscending}
    func configure(_ params:[String:Any]) {guard supportsSettings else{return};hid.send("genesis.settings",params);hid.send("device.status",[:])}
    func setLogin(_ enabled:Bool) {do {try LoginLaunch.set(enabled);loginEnabled=LoginLaunch.enabled} catch {status="Could not update login startup: \(error.localizedDescription)"}}
    func slotState(_ i:Int)->String {if slotActions[i] != "chat" {return "Shortcut"};let matches=sessions.filter{$0.title==slots[i]};return slots[i].isEmpty ? "Unassigned" : matches.count==1 ? matches[0].state : "Not visible"}

    @Published var menuNavigationEnabled=UserDefaults.standard.object(forKey:"menuNavigationEnabled") as? Bool ?? true {
        didSet {UserDefaults.standard.set(menuNavigationEnabled,forKey:"menuNavigationEnabled");if !menuNavigationEnabled {stopMenuNavigation()}}
    }
    @Published var supportsNavigation=false
    @Published var navigationActive=false
    @Published var navigationMessage="Opens automatically inside supported menus and file pickers."
    let menuNavigator=MenuNavigator()
    var navigationGate=NavigationGate()
    var navigationTimer:Timer?
    var navigationScanBusy=false,navigationInputBusy=false,navigationSuppressed=false
    var navigationQueue=[[String:Any]]()
    var lastNavigationSync=Date.distantPast,lastNavigationMenu=Date.distantPast
    var actionBusy=false
    let sessionScanQueue=DispatchQueue(label:"genesis.session-refresh",qos:.utility)
    var sessionScanBusy=false
    var pendingDictation=false
    var pendingTalkFocus:ClaudeTalkFocusContext?
    var talkFocusRequestID:Int?
    var selectionGeneration=0
    var pendingSlot:Int?
    let ax=ClaudeAccess();let hid=HIDLink();var timer:Timer?;var lastReply=Date.distantPast
    private var promptGate=PromptRouteGate()
    private var promptHandlerReady=false
    private var pendingLeaseRequest:(id:Int,boot:String,session:String,sentAt:TimeInterval,targetPID:Int)?
    private var pendingRouteRequest:(id:Int,boot:String,target:String,sentAt:TimeInterval,acknowledged:Bool,statusConfirmed:Bool)?
    private var lastLeaseRequestAt:TimeInterval=0
    private var observedPromptBoot:String?
    private var lastPromptEventAt=Date.distantPast
    private var terminationObserver:NSObjectProtocol?
    private var workspaceObservers=[NSObjectProtocol]()
    private var verifiedQuietStudioPID:Int?
    var isSystemSleeping=false
    init() {
        if slotActions.count != 6 {slotActions=Array(repeating:"chat",count:6)}
        if slots.count != 6 {slots=Array(repeating:"",count:6)}
        hid.received={ [weak self] message in Task { @MainActor in self?.receive(message) } };hid.start()
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        navigationTimer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in
            Task { @MainActor in await self?.pollMenuNavigation() }
        }
        terminationObserver=NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.stopPromptRouteForShutdown() }
        }
        let workspaceCenter=NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.refreshQuietStudioProcess() }
            })
        }
        workspaceObservers.append(workspaceCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.handleSystemSleep() }
        })
        workspaceObservers.append(workspaceCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.handleSystemWake() }
        })
        refresh()
    }
    func refresh() {
        trusted=AXIsProcessTrusted()
        guard trusted else {status="Enable Accessibility for Genesis Agent Micro Controller to read Claude controls.";return}
        guard !sessionScanBusy else{return}
        sessionScanBusy=true
        sessionScanQueue.async { [weak self] in
            // Use an isolated reader. A native picker must never stall app launch or HID handling.
            let result=ClaudeAccess().sessionSnapshot()
            Task { @MainActor [weak self] in
                guard let self else{return};self.sessionScanBusy=false
                if let result {self.sessions=result;self.rememberSessions()}
            }
        }
    }
    func rememberSessions() {
        knownTitles=Array(Set(knownTitles+sessions.map(\.title)+slots.filter{!$0.isEmpty})).sorted()
        UserDefaults.standard.set(knownTitles,forKey:"knownSessionTitles")
    }
    func discoverSessions() {
        Task { @MainActor in
            sessions=await ax.discover();rememberSessions()
            status=sessions.isEmpty ? "No chats found. Open Claude’s Code tab and try Refresh sessions." : "Found \(sessions.count) chats. Choose a key and its Claude session."
            NSApp.activate()
        }
    }
    private let quietControllerNotification=Notification.Name("studio.quiet.controller.v2")
    private func verifiedQuietStudioBundleURL() -> URL? {
        let url=FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Quiet Studio.app",isDirectory:true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard let appBundle=Bundle(url:url),
              appBundle.bundleIdentifier=="studio.quiet.prototype.mac",
              let protocolNumber=appBundle.object(forInfoDictionaryKey:"QuietStudioControllerProtocol") as? NSNumber,
              protocolNumber.intValue==2 else { return nil }
        return url
    }
    private func canonicalBundlePath(_ url:URL?) -> String? {
        url?.standardizedFileURL.resolvingSymlinksInPath().path
    }
    private func matchingQuietStudioProcess() -> NSRunningApplication? {
        guard let expectedURL=verifiedQuietStudioBundleURL(),
              let expectedPath=canonicalBundlePath(expectedURL) else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier:"studio.quiet.prototype.mac")
            .first { app in
                !app.isTerminated && app.isFinishedLaunching && app.processIdentifier > 0 &&
                canonicalBundlePath(app.bundleURL)==expectedPath &&
                Bundle(url:app.bundleURL ?? expectedURL)?.bundleIdentifier=="studio.quiet.prototype.mac" &&
                (Bundle(url:app.bundleURL ?? expectedURL)?.object(forInfoDictionaryKey:"QuietStudioControllerProtocol") as? NSNumber)?.intValue==2
            }
    }
    private func refreshQuietStudioProcess() {
        guard !isSystemSleeping else { return }
        let livePID=matchingQuietStudioProcess().map { Int($0.processIdentifier) }
        promptHandlerReady=verifiedQuietStudioBundleURL() != nil
        guard livePID != verifiedQuietStudioPID else { return }
        if verifiedQuietStudioPID != nil {
            if let cancel=promptGate.disconnected() { sendPromptURL(cancel) }
            pendingLeaseRequest=nil
            pendingRouteRequest=nil
        }
        verifiedQuietStudioPID=livePID
    }
    private func handleSystemSleep() {
        guard !isSystemSleeping else { return }
        if let cancel=promptGate.disconnected() { sendPromptURL(cancel) }
        pendingLeaseRequest=nil
        pendingRouteRequest=nil
        stopMenuNavigation();navigationQueue.removeAll();isSystemSleeping=true
    }
    private func handleSystemWake() {
        isSystemSleeping=false
        pendingLeaseRequest=nil
        pendingRouteRequest=nil
        lastLeaseRequestAt=0
        refreshQuietStudioProcess()
        hid.send("device.status",[:])
    }
    private func sendPromptURL(_ action:PromptRouteGate.Action) {
        let command:PromptURLCommand
        let gesture:PromptRouteGate.Gesture
        switch action {
        case .start(let value): command = .start; gesture=value
        case .stop(let value): command = .stop; gesture=value
        case .cancel(let value): command = .cancel; gesture=value
        }
        openPromptURL(command,gesture:gesture)
    }
    private func openPromptURL(_ command:PromptURLCommand,gesture:PromptRouteGate.Gesture) {
        let now=Int64(Date().timeIntervalSince1970*1_000)
        guard let url=PromptURLBuilder.make(command,session:gesture.session,gesture:gesture.id,nowMilliseconds:now) else { return }
        let cleanupCommand = command == .stop || command == .cancel
        guard !isSystemSleeping,
              (quietStudioPromptIntegrationEnabled || cleanupCommand),
              let live=matchingQuietStudioProcess(),
              PromptAppLifecyclePolicy.mayDispatch(targetPID:gesture.targetPID,livePID:Int(live.processIdentifier),
                  integrationEnabled:quietStudioPromptIntegrationEnabled,terminalCleanup:cleanupCommand) else {
            if command == .start, promptGate.cancelCurrent() != nil {
                _=promptGate.loseLease()
                status="Quiet Studio closed during the press; handoff canceled."
            }
            return
        }
        DistributedNotificationCenter.default().postNotificationName(quietControllerNotification,object:nil,
            userInfo:["url":url.absoluteString,"targetPID":gesture.targetPID],deliverImmediately:true)
    }
    private func reconcileQuietStudioIntegrationChange() {
        guard !quietStudioPromptIntegrationEnabled else {
            if !isSystemSleeping { hid.send("device.status",[:]) }
            return
        }
        pendingLeaseRequest=nil
        if let cancel=promptGate.loseLease() { sendPromptURL(cancel) }
        if !isSystemSleeping { hid.send("device.status",[:]) }
    }
    private func requestPromptRoute(_ route:String,boot:String,now:TimeInterval) {
        guard pendingRouteRequest==nil,
              let id=hid.send("genesis.settings",["prompt_route":route]) else { return }
        pendingRouteRequest=(id,boot,route,now,false,false)
    }
    private func processPromptStatus(_ values:[String:Any]) {
        guard !isSystemSleeping else { return }
        let uptime=ProcessInfo.processInfo.systemUptime
        guard let statusValue=PromptRouteGate.Status(values) else {
            promptHandlerReady=false
            pendingLeaseRequest=nil
            if observedPromptBoot != nil || promptGate.active != nil || promptGate.leaseIsLive {
                if let cancel=promptGate.disconnected() { sendPromptURL(cancel) }
            }
            observedPromptBoot=nil
            return
        }
        if let old=observedPromptBoot,old != statusValue.bootID {
            if let cancel=promptGate.disconnected() { sendPromptURL(cancel) }
            pendingLeaseRequest=nil
            pendingRouteRequest=nil
            lastLeaseRequestAt=0
        }
        observedPromptBoot=statusValue.bootID
        refreshQuietStudioProcess()
        let livePID=verifiedQuietStudioPID
        guard !isSystemSleeping else { return }
        let wantsQuiet=quietStudioPromptIntegrationEnabled && mode=="Codex" && livePID != nil && promptHandlerReady
        let preferredPID=wantsQuiet ? livePID:nil
        let desiredRoute=wantsQuiet ? "quiet":"native"
        let routeChange=PromptAppLifecyclePolicy.desiredRoute(runningPID:preferredPID,
            integrationEnabled:quietStudioPromptIntegrationEnabled,
            currentRoute:statusValue.route,promptDown:statusValue.promptDown)
        if let pending=pendingRouteRequest, uptime-pending.sentAt>2.0 { pendingRouteRequest=nil }
        if let pending=pendingRouteRequest, pending.boot != statusValue.bootID || pending.target != desiredRoute {
            pendingRouteRequest=nil
        }
        if var pending=pendingRouteRequest, pending.boot==statusValue.bootID, pending.target==statusValue.route {
            pending.statusConfirmed=true
            if pending.acknowledged { pendingRouteRequest=nil }
            else { pendingRouteRequest=pending;return }
        }
        if statusValue.route != desiredRoute {
            pendingLeaseRequest=nil
            if let cancel=promptGate.loseLease() { sendPromptURL(cancel) }
            if let routeChange { requestPromptRoute(routeChange,boot:statusValue.bootID,now:uptime) }
            return
        }
        guard wantsQuiet else {
            pendingLeaseRequest=nil
            if let cancel=promptGate.loseLease() { sendPromptURL(cancel) }
            return
        }
        guard PromptAppLifecyclePolicy.mayAcquireLease(runningPID:livePID,
              integrationEnabled:quietStudioPromptIntegrationEnabled,route:statusValue.route,
              promptDown:statusValue.promptDown,leaseOwner:statusValue.leaseSession.lowercased(),session:promptGate.session) else {
            return
        }
        if let cancel=promptGate.observe(statusValue,now:uptime) { sendPromptURL(cancel) }

        if pendingLeaseRequest != nil, uptime-lastLeaseRequestAt>1.8 {
            pendingLeaseRequest=nil
            if let cancel=promptGate.loseLease() { sendPromptURL(cancel) }
            status="Prompt lease acknowledgment timed out; waiting for a fresh press."
        }
        let leaseOwner=statusValue.leaseSession.lowercased()
        let sameOwner=leaseOwner==promptGate.session
        let availableOwner=leaseOwner.isEmpty || sameOwner
        let mayClaim = !statusValue.promptDown && leaseOwner.isEmpty
        let mayRenew = sameOwner
        guard availableOwner,(mayClaim || mayRenew),pendingLeaseRequest==nil,
              uptime-lastLeaseRequestAt>=0.85 else { return }
        let sentAt=uptime
        guard let id=hid.send("genesis.prompt.lease",["v":1,"boot_id":statusValue.bootID,
            "session":promptGate.session,"lease_ms":3_000]) else {
            if let cancel=promptGate.loseLease() { sendPromptURL(cancel) }
            return
        }
        pendingLeaseRequest=(id,statusValue.bootID,promptGate.session,sentAt,livePID!)
        lastLeaseRequestAt=sentAt
    }
    private func receivePromptRouteAck(_ message:[String:Any]) -> Bool {
        guard let pending=pendingRouteRequest,let id=message["id"] as? Int,id==pending.id,
              let result=message["result"] as? [String:Any] else { return false }
        guard (result["ok"] as? Int)==1 || (result["ok"] as? Bool)==true else {
            pendingRouteRequest=nil
            status="Firmware did not accept the Prompt route change."
            return true
        }
        if pending.statusConfirmed { pendingRouteRequest=nil }
        else {
            var updated=pending;updated.acknowledged=true;pendingRouteRequest=updated
            hid.send("device.status",[:])
        }
        return true
    }
    private func receivePromptLeaseAck(_ message:[String:Any]) -> Bool {
        guard let pending=pendingLeaseRequest,let id=message["id"] as? Int,id==pending.id,
              let result=message["result"] as? [String:Any] else { return false }
        pendingLeaseRequest=nil
        let accepted=(result["ok"] as? Bool)==true
        let boot=(result["boot_id"] as? String)?.lowercased() ?? ""
        let session=(result["session"] as? String)?.lowercased() ?? ""
        let ttl=result["accepted_lease_ms"] as? Int ?? 0
        let currentPID=matchingQuietStudioProcess().map { Int($0.processIdentifier) }
        guard accepted,boot==pending.boot,session==pending.session,
              !isSystemSleeping,mode=="Codex",promptHandlerReady,
              PromptAppLifecyclePolicy.mayAcceptLeaseAcknowledgment(
                  integrationEnabled:quietStudioPromptIntegrationEnabled,
                  targetPID:pending.targetPID,livePID:currentPID),
              promptGate.acceptLeaseAck(bootID:boot,session:session,sentAt:pending.sentAt,
                  acceptedMS:ttl,requestedMS:3_000,now:ProcessInfo.processInfo.systemUptime) else {
            if let cancel=promptGate.loseLease() { sendPromptURL(cancel) }
            status="Prompt lease was rejected or expired; no controller handoff is active."
            return true
        }
        return true
    }
    private func stopPromptRouteForShutdown() {
        if let cancel=promptGate.cancelCurrent() { sendPromptURL(cancel) }
        _=promptGate.loseLease()
        pendingLeaseRequest=nil
        stopMenuNavigation();navigationTimer?.invalidate();navigationTimer=nil
        timer?.invalidate()
        timer=nil
    }
    func tick() {
        let uptime=ProcessInfo.processInfo.systemUptime
        refreshQuietStudioProcess()
        guard !isSystemSleeping else { return }
        if let cancel=promptGate.leaseExpired(now:uptime) { sendPromptURL(cancel) }
        if hid.device==nil {
            if let cancel=promptGate.disconnected() { sendPromptURL(cancel) }
            observedPromptBoot=nil;pendingLeaseRequest=nil;promptHandlerReady=false
            mode="Genesis disconnected";return
        }
        hid.send("device.status",[:])
        syncCatalog()
        hid.send("genesis.settings",["codex_chat_mask":CodexSlotTypes.currentMask()])
        if Date().timeIntervalSince(lastReply)>6 {
            if let cancel=promptGate.disconnected() { sendPromptURL(cancel) }
            pendingLeaseRequest=nil;promptHandlerReady=false
            mode="Waiting for firmware reply"
        }
        if quietStudioPromptIntegrationEnabled,let active=promptGate.active,Date().timeIntervalSince(lastPromptEventAt)>=0.9 {
            openPromptURL(.heartbeat,gesture:active)
            lastPromptEventAt=Date()
        }
        if mode=="Claude" { if !selecting && !actionBusy && !navigationActive {refresh()};let entries=(0..<6).map { i -> [String:Any] in
            let matches=sessions.filter{$0.title==slots[i]};let state=matches.count==1 ? matches[0].state : ""
            let color: Int
            switch state {case "Awaiting input","Needs input":color=0xff6d00;case "Something went wrong":color=0xff0033;case "Working","Running":color=0x304ffe;case "Unread":color=0x00ff4c;case "Idle":color=0xffffff;default:color=0}
            return ["id":i,"c":color,"b":1]
        }
        hid.send("genesis.claude.status",entries)}
    }
    func selectSlot(_ slot: Int) {
        guard mode=="Claude" else {return}
        if selecting || actionBusy {
            pendingSlot=slot
            status="Chat switch queued"
            return
        }
        if slotActions[slot] != "chat" {runAction(slotActions[slot]);return}
        guard !slots[slot].isEmpty else {status="Assign C\(slot+1) first.";return}
        selected = -1;selecting=true;selectionGeneration+=1
        let generation=selectionGeneration,title=slots[slot]
        status="Opening \(title)…"
        Task { @MainActor in
            let result=await ax.select(title)
            controllerTrace("navigation result=\(result)")
            selecting=false
            if let next=pendingSlot {
                pendingSlot=nil
                if mode=="Claude" && generation==selectionGeneration && next != slot {selectSlot(next);return}
            }
            guard generation==selectionGeneration,mode=="Claude",slots[slot]==title else {return}
            status=result;selected=result.hasPrefix("Opened ") ? slot : -1
            if selected==slot && talkAfterSelect {configure(["focus_dictate":true])}
        }
    }
    func runAction(_ action:String,talkFocus:ClaudeTalkFocusContext?=nil) {
        guard let definition=ControllerAction.find(action) else {return}
        controllerTrace("request action=\(action) busy=\(actionBusy)")
        if selecting {status="Wait for the chat to open before using its actions.";return}
        if actionBusy {
            if action=="dictate" {
                pendingDictation.toggle();pendingTalkFocus=pendingDictation ? talkFocus:nil
                status="Microphone change queued"
            }
            return
        }
        let headers=ax.nodes().map{ax.text($0)}.filter{$0.hasSuffix(", rename session")}
        guard !definition.sessionRequired || headers.count==1 else {status="Open a Claude Code chat first.";return}
        let title=headers.count==1 ? String(headers[0].dropLast(", rename session".count)) : ""
        actionBusy=true
        Task { @MainActor in
            var result=await ax.action(action,title:title)
            var completedTalkFocus=talkFocus
            status=result
            controllerTrace("result=\(result)")
            while pendingDictation {
                pendingDictation=false
                completedTalkFocus=pendingTalkFocus;pendingTalkFocus=nil
                guard mode=="Claude",ax.current(title) else {break}
                result=await ax.action("dictate",title:title)
                status=result;controllerTrace("result=\(result)")
            }
            if let completedTalkFocus,let params=completedTalkFocus.request(
                result:result,currentGeneration:selectionGeneration,claudeActive:mode=="Claude",
                sameChat:ax.current(title),pendingWork:pendingSlot != nil || pendingDictation,
                sendAction:sendAction) {
                talkFocusRequestID=hid.send("genesis.claude.focus_send",params)
                controllerTrace("claude send-focus requested=\(talkFocusRequestID != nil)")
            }
            actionBusy=false
            if let next=pendingSlot {pendingSlot=nil;if mode=="Claude" {selectSlot(next)}}
        }
    }
    func receive(_ msg: [String:Any]) {
        if let id=talkFocusRequestID,msg["id"] as? Int==id {
            let accepted=(msg["result"] as? [String:Any])?["focus_send_ok"] as? Bool ?? false
            controllerTrace("claude send-focus accepted=\(accepted)");talkFocusRequestID=nil
        }
        if msg["m"] as? String=="genesis.navigate",let values=msg["p"] as? [String:Any] {handleNavigation(values);return}
        if let pending=catalogRequest,msg["id"] as? Int==pending.id {
            if let result=msg["result"] as? [String:Any],result["catalog_ok"] as? Bool==true {catalogSignature=pending.signature}
            catalogRequest=nil
        }

        if receivePromptRouteAck(msg) { return }
        if receivePromptLeaseAck(msg) { return }
        if msg["disconnected"] != nil {
            stopMenuNavigation();supportsNavigation=false;navigationQueue.removeAll()
            if let cancel=promptGate.disconnected() { sendPromptURL(cancel) }
            pendingLeaseRequest=nil;observedPromptBoot=nil;promptHandlerReady=false
            supportsCatalog=false;catalogSignature="";catalogRequest=nil;mode="Genesis disconnected";firmware="Not connected";selected = -1;selectionGeneration+=1;pendingSlot=nil;return
        }
        if let result=msg["result"] as? [String:Any],result["version"] != nil {
            let firstReply=firmware=="Not connected"
            firmware=result["version"] as? String ?? "Not connected"
            supportsCatalog=(result["action_catalog"] as? Int)==1
            supportsNavigation=(result["navigation_protocol"] as? Int)==1
            if navigationActive && (result["navigation_active"] as? Bool) != true {stopMenuNavigation()}
            navigationActive=(result["navigation_active"] as? Bool)==true
            soundEnabled=result["sound_enabled"] as? Bool ?? soundEnabled
            encoderDetents=result["encoder_detents"] as? Int ?? encoderDetents
            if firstReply {configure(["talk_after_select":talkAfterSelect])}
            lastReply=Date();let updated=(result["controller_mode"] as? String)=="claude" ? "Claude" : "Codex"
            if updated != mode {stopMenuNavigation();navigationQueue.removeAll();selected = -1;selectionGeneration+=1;pendingSlot=nil};mode=updated
            if result["controller_mode"] == nil {status="Working Codex firmware detected. Dual-mode update is not installed."}
            processPromptStatus(result)
        }
        if msg["m"] as? String == "genesis.prompt" {
            refreshQuietStudioProcess()
            guard quietStudioPromptIntegrationEnabled,!isSystemSleeping, promptHandlerReady,mode=="Codex",
                  let live=matchingQuietStudioProcess(),
                  Int(live.processIdentifier)==verifiedQuietStudioPID,
                  promptGate.leaseIsLive else { return }
            if let action=promptGate.handle(msg,targetPID:Int(live.processIdentifier),now:ProcessInfo.processInfo.systemUptime) {
                lastPromptEventAt=Date()
                sendPromptURL(action)
            }
            return
        }
        guard msg["m"] as? String == "genesis.input",let p=msg["p"] as? [String:Any],p["act"] as? Int==1 else{return}
        let key=p["k"] as? String ?? ""
        controllerTrace("HID key=\(key)")
        if key=="MODE" {
            stopMenuNavigation();navigationQueue.removeAll();navigationSuppressed=false
            let next=(p["mode"] as? String)=="claude" ? "Claude" : "Codex"
            if next != "Codex" {
                if let cancel=promptGate.modeChangedAwayFromCodex() { sendPromptURL(cancel) }
                pendingLeaseRequest=nil;promptHandlerReady=false
            }
            mode=next;selected = -1;selectionGeneration+=1;pendingSlot=nil;return
        }
        guard mode=="Claude" else{return}
        if let slot=p["ag"] as? Int,(0..<6).contains(slot) {
            selectSlot(slot);return
        }
        let action=key=="DICTATE" ? microphoneAction : key=="SEND" ? sendAction : (ControllerAction.find(key.lowercased())?.id ?? "none")
        if action != "none" {
            let context=key=="DICTATE" && action=="dictate" ? ClaudeTalkFocusContext(event:p,generation:selectionGeneration):nil
            runAction(action,talkFocus:context)
        }
    }
}
