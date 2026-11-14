import AppKit
import ApplicationServices

/// Reads focused popups and the foreground agent's native Open panel, never chat history.
final class MenuNavigator {
    enum Kind:String {case menu="Menu",file="Choose file",dialog="Dialog"}
    struct Snapshot {
        let pid:pid_t
        let root:AXUIElement
        let focus:AXUIElement?
        let list:AXUIElement?
        let kind:Kind
        let sidebar:AXUIElement?
    }
    private let worker=DispatchQueue(label:"genesis.menu-access",qos:.userInitiated)
    private var preparedPanel:AXUIElement?
    private var locationsMode=false
    private var fileColumn=0
    private var fileHint:String?
    @MainActor func resetFileEntry() {preparedPanel=nil;locationsMode=false;fileColumn=0;fileHint=nil}
    @MainActor func label(for snapshot:Snapshot)->String {
        if snapshot.kind == .file,let fileHint {return fileHint}
        return snapshot.kind == .file && locationsMode ? "Locations":snapshot.kind.rawValue
    }
    @MainActor func selectionLabel(for snapshot:Snapshot)->String? {
        // Read a short control/file label only. Never return a text field value,
        // composer text, or an arbitrary subtree to the phone.
        let container = snapshot.kind == .file && locationsMode ? snapshot.sidebar : snapshot.list
        let selected = container.flatMap { Self.value($0,kAXSelectedRowsAttribute) as? [AXUIElement] } ??
            container.flatMap { Self.value($0,kAXSelectedChildrenAttribute) as? [AXUIElement] } ?? []
        var candidates=Array(selected.prefix(1))
        if candidates.isEmpty,let focus=snapshot.focus,Self.inside(focus,snapshot.root) {candidates=[focus]}
        var index=0
        while index<candidates.count && index<8 {
            let item=candidates[index];index+=1
            let role=Self.text(item,kAXRoleAttribute)
            if ![kAXTextAreaRole,kAXTextFieldRole,kAXComboBoxRole].contains(role) {
                for attribute in [kAXTitleAttribute,kAXDescriptionAttribute] {
                    let label=Self.text(item,attribute).trimmingCharacters(in:.whitespacesAndNewlines)
                    if !label.isEmpty && label != "Prompt" {return String(label.prefix(160))}
                }
                candidates.append(contentsOf:Self.children(item).prefix(4))
            }
        }
        return nil
    }
    static func bundle(for mode:String)->String? {
        mode=="Claude" ? "com.anthropic.claudefordesktop" : mode=="Codex" ? "com.openai.codex" : nil
    }
    private static func value(_ e:AXUIElement,_ key:String)->CFTypeRef? {
        AXUIElementSetMessagingTimeout(e,0.03)
        var value:CFTypeRef?
        return AXUIElementCopyAttributeValue(e,key as CFString,&value) == .success ? value:nil
    }
    private static func element(_ e:AXUIElement,_ key:String)->AXUIElement? {
        guard let v=value(e,key),CFGetTypeID(v)==AXUIElementGetTypeID() else{return nil}
        return (v as! AXUIElement)
    }
    private static func text(_ e:AXUIElement,_ key:String)->String {value(e,key) as? String ?? ""}
    private static func children(_ e:AXUIElement)->[AXUIElement] {value(e,kAXChildrenAttribute) as? [AXUIElement] ?? []}
    private static func actions(_ e:AXUIElement)->[String] {
        var names:CFArray?;AXUIElementCopyActionNames(e,&names);return names as? [String] ?? []
    }
    private static func isOpenPanel(_ e:AXUIElement)->Bool {
        FilePickerPolicy.isOpenPanel(role:text(e,kAXRoleAttribute),identifier:text(e,kAXIdentifierAttribute))
    }
    private static func nativePanel(_ app:AXUIElement,deadline:Double)->AXUIElement? {
        // macOS can leave AXFocusedUIElement pointing at the web composer (or nil)
        // while its native Open sheet owns keyboard focus. Look at the focused window
        // and its attached sheet, not arbitrary/background application windows.
        guard let window=element(app,kAXFocusedWindowAttribute) else{return nil}
        if isOpenPanel(window) {return window}
        for child in children(window).prefix(16) {
            guard ProcessInfo.processInfo.systemUptime<deadline else{break}
            if isOpenPanel(child) {return child}
            if text(child,kAXRoleAttribute)==kAXSheetRole {
                for nested in children(child).prefix(8) where isOpenPanel(nested) {return nested}
            }
        }
        return nil
    }
    private static func content(in root:AXUIElement,deadline:Double)->(AXUIElement?,Bool,AXUIElement?) {
        var queue=[(root,0)],index=0,best:AXUIElement?,sidebar:AXUIElement?,score=0,hasOpen=false,hasCancel=false
        while index<queue.count && index<80 && ProcessInfo.processInfo.systemUptime<deadline {
            let (e,depth)=queue[index];index+=1
            let role=text(e,kAXRoleAttribute),identifier=text(e,kAXIdentifierAttribute)
            let description=text(e,kAXDescriptionAttribute)
            if role==kAXOutlineRole && (identifier+" "+description).lowercased().contains("sidebar") {sidebar=e;continue}
            if role==kAXButtonRole {
                let title=text(e,kAXTitleAttribute)
                hasOpen = hasOpen || identifier=="OKButton" || ["Open","Choose","Select"].contains(title)
                hasCancel = hasCancel || identifier=="CancelButton" || title=="Cancel"
                continue
            }
            let priority=FilePickerPolicy.contentPriority(role:role,identifier:identifier,description:description)
            if priority>score {best=e;score=priority}
            // Do not enumerate hundreds of filenames or the sidebar's rows. The
            // browser/table itself is the keyboard target, including column view.
            if FilePickerPolicy.isIconView(identifier:identifier) || [kAXBrowserRole,kAXOutlineRole,kAXTableRole,kAXListRole].contains(role) {continue}
            if depth<5 && [kAXSheetRole,kAXWindowRole,kAXGroupRole,kAXSplitGroupRole,kAXScrollAreaRole,"AXDialog"].contains(role) {
                queue.append(contentsOf:children(e).prefix(24).map{($0,depth+1)})
            }
        }
        return (best,hasOpen && hasCancel,sidebar)
    }
    private static func inspect(pid:pid_t)->Snapshot? {
        let app=AXUIElementCreateApplication(pid)
        let deadline=ProcessInfo.processInfo.systemUptime+0.45
        if let panel=nativePanel(app,deadline:deadline) {
            let contents=content(in:panel,deadline:deadline)
            // Native Open panels can host focus in OpenAndSavePanelService instead
            // of the Electron parent. Accept system focus only inside this panel.
            let systemFocus=element(AXUIElementCreateSystemWide(),kAXFocusedUIElementAttribute)
            let focus=inside(systemFocus,panel) ? systemFocus:element(app,kAXFocusedUIElementAttribute)
            return Snapshot(pid:pid,root:panel,focus:focus,list:contents.0,kind:.file,sidebar:contents.2)
        }
        guard let focus=element(app,kAXFocusedUIElementAttribute) else{return nil}
        var node:AXUIElement?=focus,root:AXUIElement?
        var kind:Kind = .menu
        for _ in 0..<20 {
            guard let current=node,ProcessInfo.processInfo.systemUptime<deadline else{break}
            let role=text(current,kAXRoleAttribute),subrole=text(current,kAXSubroleAttribute)
            if FilePickerPolicy.isOpenPanel(role:role,identifier:text(current,kAXIdentifierAttribute)) {root=current;kind = .file;break}
            if role==kAXMenuRole {root=current;break}
            if role==kAXSheetRole || ["AXDialog","AXSystemDialog"].contains(subrole) || role=="AXDialog" {
                root=current;kind = .dialog;break
            }
            if role==kAXGroupRole && actions(current).contains(kAXCancelAction) {root=current;break}
            if role==kAXApplicationRole || role==kAXWindowRole {break}
            node=element(current,kAXParentAttribute)
        }
        guard let root else{return nil}
        var list:AXUIElement?,sidebar:AXUIElement?
        if kind != .menu {
            let contents=content(in:root,deadline:deadline);list=contents.0;sidebar=contents.2
            if contents.1 && list != nil {kind = .file}
        }
        return Snapshot(pid:pid,root:root,focus:focus,list:list,kind:kind,sidebar:sidebar)
    }
    private func inspectAsync(pid:pid_t) async ->Snapshot? {
        await withCheckedContinuation {continuation in
            worker.async {continuation.resume(returning:Self.inspect(pid:pid))}
        }
    }
    @MainActor func snapshot(mode:String) async -> Snapshot? {
        guard AXIsProcessTrusted(),let bundle=Self.bundle(for:mode),let app=NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier==bundle else{return nil}
        let pid=app.processIdentifier,result=await inspectAsync(pid:app.processIdentifier)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==pid else{return nil}
        return result
    }
    private static func inside(_ element:AXUIElement?,_ root:AXUIElement)->Bool {
        var node=element
        let deadline=ProcessInfo.processInfo.systemUptime+0.18
        for _ in 0..<20 {
            guard let current=node,ProcessInfo.processInfo.systemUptime<deadline else{break}
            if CFEqual(current,root) {return true}
            node=Self.element(current,kAXParentAttribute)
        }
        return false
    }
    private static func columns(_ browser:AXUIElement)->[AXUIElement] {
        var queue=[(browser,0)],index=0,result=[AXUIElement]()
        let deadline=ProcessInfo.processInfo.systemUptime+0.2
        while index<queue.count && index<64 && ProcessInfo.processInfo.systemUptime<deadline {
            let (e,depth)=queue[index];index+=1
            let role=text(e,kAXRoleAttribute)
            if role==kAXListRole {result.append(e);continue}
            if depth<4 && [kAXBrowserRole,kAXScrollAreaRole,kAXGroupRole].contains(role) {
                queue.append(contentsOf:children(e).prefix(20).map{($0,depth+1)})
            }
        }
        return result
    }
    private static func selection(in list:AXUIElement)->FilePickerPolicy.Selection {
        let selected=(value(list,kAXSelectedChildrenAttribute) as? [AXUIElement]) ??
            (value(list,kAXSelectedRowsAttribute) as? [AXUIElement]) ?? []
        var queue=Array(selected.prefix(1)),index=0
        while index<queue.count && index<8 {
            let e=queue[index];index+=1
            if let url=value(e,kAXURLAttribute) as? URL,url.isFileURL {return url.hasDirectoryPath ? .folder:.file}
            if let raw=value(e,kAXURLAttribute) as? String,let url=URL(string:raw),url.isFileURL {return url.hasDirectoryPath ? .folder:.file}
            queue.append(contentsOf:children(e).prefix(3))
        }
        return .unknown
    }
    private struct IconItem {
        let element:AXUIElement
        let bounds:CGRect
        let selected:Bool
        let identity:String
    }
    private static func bounds(_ item:AXUIElement)->CGRect? {
        guard let position=value(item,kAXPositionAttribute),CFGetTypeID(position)==AXValueGetTypeID(),
              let sizeValue=value(item,kAXSizeAttribute),CFGetTypeID(sizeValue)==AXValueGetTypeID() else{return nil}
        var point=CGPoint.zero,size=CGSize.zero
        guard AXValueGetValue(position as! AXValue,.cgPoint,&point),AXValueGetValue(sizeValue as! AXValue,.cgSize,&size),size.width>2,size.height>2 else{return nil}
        return CGRect(origin:point,size:size)
    }
    private static func iconItems(_ pane:AXUIElement)->[IconItem] {
        var queue=children(pane).map{($0,0)},index=0,items:[IconItem]=[]
        let selected=(value(pane,kAXSelectedChildrenAttribute) as? [AXUIElement]) ?? []
        let deadline=ProcessInfo.processInfo.systemUptime+0.25
        while index<queue.count && index<160 && ProcessInfo.processInfo.systemUptime<deadline {
            let (item,depth)=queue[index];index+=1
            if text(item,kAXRoleAttribute)==kAXImageRole {
                guard value(item,kAXEnabledAttribute) as? Bool != false,let rect=bounds(item) else{continue}
                items.append(IconItem(element:item,bounds:rect,
                    selected:value(item,kAXSelectedAttribute) as? Bool == true || selected.contains{CFEqual($0,item)},
                    identity:text(item,kAXIdentifierAttribute)+"|"+text(item,kAXTitleAttribute)+"|"+text(item,kAXDescriptionAttribute)))
            } else if depth<2 {queue.append(contentsOf:children(item).prefix(128).map{($0,depth+1)})}
        }
        return items.sorted { a,b in
            FilePickerPolicy.sameIconRow(a.bounds.minY,b.bounds.minY) ? a.bounds.minX<b.bounds.minX:a.bounds.minY<b.bounds.minY
        }
    }
    @MainActor private func iconKey(_ code:CGKeyCode,snapshot:Snapshot,isCurrent:()->Bool)->Bool {
        guard isCurrent(),snapshot.kind == .file,Self.isOpenPanel(snapshot.root),
              NSWorkspace.shared.frontmostApplication?.processIdentifier==snapshot.pid,
              let source=CGEventSource(stateID:.hidSystemState),
              let down=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true),
              let up=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false) else{return false}
        down.post(tap:.cghidEventTap);up.post(tap:.cghidEventTap)
        return true
    }
    @MainActor private func moveIcon(_ direction:Int,in pane:AXUIElement,snapshot:Snapshot,isCurrent:()->Bool) async ->Bool {
        let items=Self.iconItems(pane)
        let current=items.firstIndex{$0.selected}
        switch FilePickerPolicy.iconStep(rows:items.map{Double($0.bounds.minY)},current:current,direction:direction) {
        case .blocked:return false
        case .target(let index):
            controllerTrace("navigation icon row-boundary")
            return await clickNative(items[index].element,in:pane,snapshot:snapshot,isCurrent:isCurrent)
        case .key(let code):
            if !Self.inside(snapshot.focus,pane),let current {
                guard await clickNative(items[current].element,in:pane,snapshot:snapshot,isCurrent:isCurrent) else{return false}
            }
            return iconKey(code,snapshot:snapshot,isCurrent:isCurrent)
        case .vertical(let code):
            guard let current,iconKey(code,snapshot:snapshot,isCurrent:isCurrent) else{return false}
            try? await Task.sleep(nanoseconds:50_000_000)
            guard isCurrent(),let fresh=await inspectAsync(pid:snapshot.pid),CFEqual(fresh.root,snapshot.root),
                  let nextPane=fresh.list,FilePickerPolicy.isIconView(identifier:Self.text(nextPane,kAXIdentifierAttribute)) else{return false}
            let nextItems=Self.iconItems(nextPane)
            guard let selected=nextItems.first(where:{$0.selected}) else{return false}
            // At the first/last file, Up/Down does not change selection. Do not
            // jump across that same row or wrap to a different file accidentally.
            guard selected.identity != items[current].identity || !CFEqual(selected.element,items[current].element) else{return true}
            let row=nextItems.filter{FilePickerPolicy.sameIconRow($0.bounds.minY,selected.bounds.minY)}
            guard let edge=direction>0 ? row.first:row.last else{return false}
            controllerTrace("navigation icon scroll-boundary")
            if CFEqual(edge.element,selected.element) {return true}
            return await clickNative(edge.element,in:nextPane,snapshot:fresh,isCurrent:isCurrent)
        }
    }
    private static func viewport(_ scope:AXUIElement,root:AXUIElement)->CGRect? {
        guard var rect=bounds(scope) else{return nil}
        var ancestor:AXUIElement?=scope
        for _ in 0..<12 {
            guard let current=ancestor else{break}
            if (text(current,kAXRoleAttribute)==kAXScrollAreaRole || CFEqual(current,root)),let clip=bounds(current) {rect=rect.intersection(clip)}
            if CFEqual(current,root) {break}
            ancestor=element(current,kAXParentAttribute)
        }
        return rect.isNull || rect.width<8 || rect.height<8 ? nil:rect
    }
    @MainActor private func reveal(_ target:AXUIElement,in scope:AXUIElement,snapshot:Snapshot,isCurrent:()->Bool) async ->Bool {
        for _ in 0..<4 {
            guard isCurrent(),NSWorkspace.shared.frontmostApplication?.processIdentifier==snapshot.pid,
                  let rect=Self.bounds(target),let visible=Self.viewport(scope,root:snapshot.root) else{return false}
            let margin=min(12,visible.height/4)
            let bottom=visible.maxY-margin,top=visible.minY+margin
            let delta=rect.midY>bottom ? rect.midY-bottom:rect.midY<top ? rect.midY-top:0
            if abs(delta)<1 {return true}
            // Scroll only the validated picker pane under the pointer. This also
            // reveals sidebar destinations below the initially visible section.
            let point=CGPoint(x:visible.midX,y:visible.midY)
            var hit:AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit) == .success,
                  Self.inside(hit,scope),isCurrent(),NSWorkspace.shared.frontmostApplication?.processIdentifier==snapshot.pid,
                  let event=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,
                                    wheel1:Int32(-max(-500,min(500,delta))),wheel2:0,wheel3:0) else{return false}
            let previous=CGEvent(source:nil)?.location
            CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap)
            event.location=point;event.post(tap:.cghidEventTap)
            try? await Task.sleep(nanoseconds:60_000_000)
            if let previous {CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:previous,mouseButton:.left)?.post(tap:.cghidEventTap)}
        }
        return false
    }
    @MainActor private func clickNative(_ target:AXUIElement,in scope:AXUIElement,snapshot:Snapshot,isCurrent:()->Bool) async ->Bool {
        guard isCurrent(),Self.isOpenPanel(snapshot.root),Self.inside(scope,snapshot.root),
              Self.value(target,kAXEnabledAttribute) as? Bool != false,
              NSWorkspace.shared.frontmostApplication?.processIdentifier==snapshot.pid else{return false}
        if Self.actions(target).contains("AXScrollToVisible") {
            AXUIElementPerformAction(target,"AXScrollToVisible" as CFString)
        }
        guard Self.inside(target,scope),await reveal(target,in:scope,snapshot:snapshot,isCurrent:isCurrent),
              let position=Self.value(target,kAXPositionAttribute),CFGetTypeID(position)==AXValueGetTypeID(),
              let sizeValue=Self.value(target,kAXSizeAttribute),CFGetTypeID(sizeValue)==AXValueGetTypeID() else{return false}
        var point=CGPoint.zero,size=CGSize.zero
        guard AXValueGetValue(position as! AXValue,.cgPoint,&point),AXValueGetValue(sizeValue as! AXValue,.cgSize,&size),
              size.width>2,size.height>2 else{return false}
        point.x+=size.width/2;point.y+=size.height/2
        var hit:AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit) == .success,
              Self.inside(hit,target),isCurrent(),NSWorkspace.shared.frontmostApplication?.processIdentifier==snapshot.pid else{return false}
        let previous=CGEvent(source:nil)?.location
        guard let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
              let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else{return false}
        down.setIntegerValueField(.mouseEventClickState,value:1);up.setIntegerValueField(.mouseEventClickState,value:1)
        down.post(tap:.cghidEventTap)
        try? await Task.sleep(nanoseconds:30_000_000)
        up.post(tap:.cghidEventTap)
        if let previous {CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:previous,mouseButton:.left)?.post(tap:.cghidEventTap)}
        try? await Task.sleep(nanoseconds:50_000_000)
        guard isCurrent(),NSWorkspace.shared.frontmostApplication?.processIdentifier==snapshot.pid,
              let fresh=await inspectAsync(pid:snapshot.pid),CFEqual(fresh.root,snapshot.root) else{return false}
        return true
    }
    @MainActor private func chooseLocation(_ target:AXUIElement,in sidebar:AXUIElement,snapshot:Snapshot,isCurrent:()->Bool) async ->Bool {
        // Setting AXSelectedRows can highlight a place without activating its
        // content. Use the same single click as normal pointer navigation.
        guard await clickNative(target,in:sidebar,snapshot:snapshot,isCurrent:isCurrent) else{return false}
        let selected=Self.value(target,kAXSelectedAttribute) as? Bool == true
        controllerTrace("navigation location activated=\(selected)")
        return selected
    }
    @MainActor private func enterFiles(_ snapshot:Snapshot,isCurrent:()->Bool) async ->Bool {
        guard let browser=snapshot.list else{return false}
        let column=Self.columns(browser).first ?? browser
        let selected=(Self.value(column,kAXSelectedChildrenAttribute) as? [AXUIElement]) ??
            (Self.value(column,kAXSelectedRowsAttribute) as? [AXUIElement]) ?? []
        var rows:[AXUIElement]=[]
        if FilePickerPolicy.isIconView(identifier:Self.text(column,kAXIdentifierAttribute)) {
            // IconView contains section wrappers and AXImage file items rather
            // than the rows/text fields exposed by lists and column browsers.
            var queue=Self.children(column).map{($0,0)},index=0
            while index<queue.count && index<80 {
                let (item,depth)=queue[index];index+=1
                if Self.text(item,kAXRoleAttribute)==kAXImageRole {rows.append(item)}
                else if depth<2 {queue.append(contentsOf:Self.children(item).prefix(32).map{($0,depth+1)})}
            }
        } else {
            rows=Self.children(column).filter{[kAXGroupRole,kAXRowRole,kAXTextFieldRole].contains(Self.text($0,kAXRoleAttribute))}
        }
        // A single row click focuses the native column without opening/uploading
        // the file. Failed/offscreen hit tests never advance into Files mode.
        let targets=selected+Array(rows.prefix(32))
        for target in targets.isEmpty ? [column]:targets {
            guard isCurrent() else{return false}
            guard await clickNative(target,in:column,snapshot:snapshot,isCurrent:isCurrent) else{continue}
            guard let fresh=await inspectAsync(pid:snapshot.pid),CFEqual(fresh.root,snapshot.root),isCurrent() else{return false}
            let hasSelection=((Self.value(column,kAXSelectedChildrenAttribute) as? [AXUIElement])?.isEmpty == false)
            let focused=Self.inside(fresh.focus,column)
            controllerTrace("navigation enter-files focused=\(focused) selected=\(hasSelection)")
            guard focused || hasSelection else{return false}
            fileColumn=0
            return true
        }
        return false
    }
    @MainActor func prepareFileEntry(_ snapshot:Snapshot,isCurrent:()->Bool) async {
        guard isCurrent(),snapshot.kind == .file,Self.isOpenPanel(snapshot.root),
              preparedPanel.map({!CFEqual($0,snapshot.root)}) ?? true else{return}
        preparedPanel=snapshot.root
        locationsMode=snapshot.sidebar != nil;fileColumn=0
        controllerTrace("navigation locations-mode=\(locationsMode)")
        if let sidebar=snapshot.sidebar {controllerTrace("navigation sidebar destinations=\(Self.locationRows(sidebar).count)")}
    }
    private static func locationRows(_ sidebar:AXUIElement)->[AXUIElement] {
        children(sidebar).filter { row in
            // Native sidebar headings advertise ShowDefaultUI/ShowAlternateUI,
            // not Expand/Collapse. Their disclosure state identifies the group.
            FilePickerPolicy.isLocationRow(role:text(row,kAXRoleAttribute),
                expanded:value(row,kAXDisclosingAttribute) as? Bool ?? false,
                disclosedRows:(value(row,kAXDisclosedRowsAttribute) as? [AXUIElement])?.count ?? 0,
                enabled:value(row,kAXEnabledAttribute) as? Bool != false)
        }
    }
    @MainActor func perform(_ kind:String,direction:Int,in snapshot:Snapshot,isCurrent:()->Bool) async ->Bool {
        guard isCurrent(),NSWorkspace.shared.frontmostApplication?.processIdentifier==snapshot.pid,
              let fresh=await inspectAsync(pid:snapshot.pid),CFEqual(fresh.root,snapshot.root),fresh.kind==snapshot.kind,
              isCurrent(),NSWorkspace.shared.frontmostApplication?.processIdentifier==snapshot.pid else{return false}
        let role=fresh.focus.map{Self.text($0,kAXRoleAttribute)} ?? ""
        let description=fresh.focus.map{Self.text($0,kAXDescriptionAttribute)} ?? ""
        if fresh.kind != .file {
            guard Self.inside(fresh.focus,fresh.root),description != "Prompt" else{return false}
        }
        if fresh.kind == .file,locationsMode,let sidebar=fresh.sidebar {
            switch kind {
            case "turn":
                fileHint=nil
                let rows=Self.locationRows(sidebar)
                let selected=(Self.value(sidebar,kAXSelectedRowsAttribute) as? [AXUIElement]) ?? []
                let current=rows.firstIndex{row in selected.contains{CFEqual(row,$0)}}
                guard let next=FilePickerPolicy.locationIndex(count:rows.count,current:current,direction:direction) else{return false}
                return await chooseLocation(rows[next],in:sidebar,snapshot:fresh,isCurrent:isCurrent)
            case "select":
                guard fresh.list != nil else{fileHint="Items need mouse";return false}
                guard await enterFiles(fresh,isCurrent:isCurrent) else{return false}
                fileHint=nil
                locationsMode=false
                controllerTrace("navigation locations-mode=false")
                return true
            case "back":return true // Locations is the picker root; triple tap exits.
            default:break
            }
        }
        if fresh.kind == .file,kind=="turn",let pane=fresh.list,
           FilePickerPolicy.isIconView(identifier:Self.text(pane,kAXIdentifierAttribute)) {
            return await moveIcon(direction,in:pane,snapshot:fresh,isCurrent:isCurrent)
        }
        if fresh.kind == .file,kind=="back",fresh.sidebar != nil {
            let columns=fresh.list.map{Self.columns($0)} ?? []
            let actual=columns.firstIndex{Self.inside(fresh.focus,$0)}
            if FilePickerPolicy.backToLocations(column:actual ?? (columns.indices.contains(fileColumn) ? fileColumn:nil)) {
                locationsMode=true;fileColumn=0
                controllerTrace("navigation locations-mode=true")
                return true
            }
        }
        var code:CGKeyCode=0,flags:CGEventFlags=[]
        // Column view expands a folder's preview without moving keyboard focus.
        // Right explicitly enters that column; Left backs out. At the first column,
        // back focuses Locations so Recents/Downloads/iCloud are reachable by knob.
        if fresh.kind == .file,let browser=fresh.list,Self.text(browser,kAXRoleAttribute)==kAXBrowserRole {
            let inLocations=locationsMode
            let columns=Self.columns(browser)
            let actualColumn=columns.firstIndex{Self.inside(fresh.focus,$0)}
            let column=actualColumn ?? (columns.indices.contains(fileColumn) ? fileColumn:nil)
            if let actualColumn {fileColumn=actualColumn}
            if kind=="turn" && inLocations {
                guard direction == -1 || direction == 1 else{return false}
                code=direction>0 ? 125:126
            } else if kind=="select" || kind=="back" {
                var selected=column.map{Self.selection(in:columns[$0])} ?? .unknown
                // A following native file-list column is also positive evidence
                // that the current item is a folder, even if AX omits its URL.
                if selected == .unknown,let column,column+1<columns.count {selected = .folder}
                let action=FilePickerPolicy.columnAction(select:kind=="select",inLocations:inLocations,column:column,selection:selected)
                switch action {
                case .focusLocations:
                    guard fresh.sidebar != nil,isCurrent() else{return false}
                    locationsMode=true
                    controllerTrace("navigation locations-mode=true")
                    return true
                case .focusFiles:
                    guard await enterFiles(fresh,isCurrent:isCurrent) else{return false}
                    locationsMode=false
                    return true
                case .arrowRight:code=124;fileColumn=(column ?? 0)+1
                case .arrowLeft:code=123;fileColumn=max(0,(column ?? 1)-1)
                case .openFile:code=36
                case .blocked:return false
                }
            }
        }
        if code==0 {
        switch kind {
        case "turn","select":
            if kind=="turn" && direction != -1 && direction != 1 {return false}
            if fresh.kind == .file {
                guard let list=fresh.list else{return false}
                // A file's name is an AXTextField too. Do not steal its focus and
                // move to the sidebar simply because its accessibility role is text.
                if Self.inside(fresh.focus,fresh.root) && !Self.inside(fresh.focus,list) {
                    guard AXUIElementSetAttributeValue(list,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success else{return false}
                }
                // Cmd-Down enters a selected directory as well as opening a file;
                // bare Return can leave a directory selected with Open disabled.
                code=kind=="turn" ? (FilePickerPolicy.turnKey(identifier:Self.text(list,kAXIdentifierAttribute),direction:direction) ?? 125):125
                if kind=="select" {flags = .maskCommand}
            } else if kind=="turn" {
                if fresh.kind == .menu {code=direction>0 ? 125:126}
                else {code=48;if direction<0 {flags = .maskShift}}
            } else {
                code=fresh.kind == .dialog && [kAXButtonRole,kAXCheckBoxRole,kAXRadioButtonRole,kAXPopUpButtonRole].contains(role) ? 49:36
            }
        case "back":
            if fresh.kind == .file {code=126;flags = .maskCommand} else {code=53}
        case "cancel":code=53
        default:return false
        }
        }
        let nativeOpen=fresh.kind == .file && Self.isOpenPanel(fresh.root)
        let route=FilePickerPolicy.delivery(nativeOpenPanel:nativeOpen,ownerPID:snapshot.pid,
            frontPID:NSWorkspace.shared.frontmostApplication?.processIdentifier,currentSession:isCurrent())
        guard route != .blocked,
              let source=CGEventSource(stateID:.hidSystemState),
              let down=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true),
              let up=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false) else{return false}
        down.flags=flags;up.flags=flags
        guard isCurrent(),NSWorkspace.shared.frontmostApplication?.processIdentifier==snapshot.pid else{return false}
        if route == .systemFocus {
            // Native Open panels host their controls in OpenAndSavePanelService.
            // Posting directly to the parent Electron PID reports success but is
            // ignored there. Only a freshly validated native panel may use the
            // focused keyboard path; ordinary app menus keep process targeting.
            down.post(tap:.cghidEventTap);up.post(tap:.cghidEventTap)
        } else {
            down.postToPid(snapshot.pid);up.postToPid(snapshot.pid)
        }
        controllerTrace("navigation key route=\(route) code=\(code)")
        return true
    }
}
