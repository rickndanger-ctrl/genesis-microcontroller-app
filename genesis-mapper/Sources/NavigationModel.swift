import AppKit

extension Model {
    func stopMenuNavigation(home:Bool=false) {
        if navigationGate.session>0 {
            hid.send("genesis.navigation",["active":false,"session":navigationGate.session,"home":home,"mode":mode.lowercased()])
        }
        navigationGate.end();navigationActive=false
        menuNavigator.resetFileEntry()
    }
    func pollMenuNavigation() async {
        guard !navigationScanBusy,!navigationInputBusy else{return}
        guard menuNavigationEnabled,supportsNavigation,!isSystemSleeping,hid.device != nil,
              !selecting,!actionBusy,Date().timeIntervalSince(lastReply)<4 else {
            stopMenuNavigation();return
        }
        navigationScanBusy=true
        defer {navigationScanBusy=false}
        let expectedMode=mode
        var snapshot=await menuNavigator.snapshot(mode:expectedMode)
        guard expectedMode==mode,menuNavigationEnabled,supportsNavigation,!isSystemSleeping else{return}
        if let current=snapshot,current.kind == .file {
            await menuNavigator.prepareFileEntry(current,isCurrent:{
                self.mode==expectedMode && self.menuNavigationEnabled && !self.isSystemSleeping && self.hid.device != nil
            })
            snapshot=await menuNavigator.snapshot(mode:expectedMode)
        }
        guard expectedMode==mode,menuNavigationEnabled,supportsNavigation,!isSystemSleeping else{return}
        guard let snapshot else {
            // Keep the session briefly across the menu -> file-picker transition;
            // individual events still require a fresh recognized menu before any input.
            if Date().timeIntervalSince(lastNavigationMenu)>0.9 {stopMenuNavigation();navigationSuppressed=false}
            return
        }
        lastNavigationMenu=Date()
        guard !navigationSuppressed else{return}
        if navigationGate.pid != 0 && navigationGate.pid != snapshot.pid {stopMenuNavigation()}
        if navigationGate.session==0 {
            navigationGate.begin(session:Int.random(in:1...Int(Int32.max)),pid:snapshot.pid)
            lastNavigationSync = .distantPast
            navigationMessage="\(menuNavigator.label(for:snapshot)): turn to move, tap to select, double-tap back, triple-tap home."
            controllerTrace("navigation begin kind=\(snapshot.kind.rawValue)")
        }
        if Date().timeIntervalSince(lastNavigationSync)>0.45 {
            hid.send("genesis.navigation",["active":true,"session":navigationGate.session,"mode":mode.lowercased(),"label":menuNavigator.label(for:snapshot)])
            lastNavigationSync=Date()
        }
    }
    func handleNavigation(_ values:[String:Any]) {
        guard menuNavigationEnabled,supportsNavigation,!isSystemSleeping,
              let kind=values["kind"] as? String,values["mode"] as? String==mode.lowercased() else{return}
        if kind=="request" {
            navigationSuppressed=false
            Task { @MainActor in await pollMenuNavigation() }
            return
        }
        if kind=="cancel" {stopMenuNavigation();return}
        guard ["turn","select","back","home"].contains(kind) else{return}
        if kind=="home" {navigationQueue.removeAll()}
        guard navigationQueue.count<32 else{return}
        navigationQueue.append(values)
        guard !navigationInputBusy else{return}
        navigationInputBusy=true
        Task { @MainActor in
            while !navigationQueue.isEmpty {
                let event=navigationQueue.removeFirst()
                let expectedMode=mode,expectedSession=navigationGate.session
                let snapshot=await menuNavigator.snapshot(mode:expectedMode)
                guard expectedMode==mode,expectedSession==navigationGate.session,
                      let sequence=event["seq"] as? Int,let session=event["session"] as? Int,
                      let kind=event["kind"] as? String else{continue}
                if kind=="home",navigationGate.accept(session:session,sequence:sequence,pid:navigationGate.pid,hasMenu:true) {
                    let owner=navigationGate.pid
                    stopMenuNavigation(home:true);navigationQueue.removeAll();navigationSuppressed=true
                    // Cancel only the recognized popup stack, never close a chat/window.
                    var current=snapshot
                    for _ in 0..<4 {
                        guard let currentSnapshot=current,currentSnapshot.pid==owner else{break}
                        guard await menuNavigator.perform("cancel",direction:0,in:currentSnapshot,isCurrent:{
                            self.mode==expectedMode && self.navigationSuppressed && !self.isSystemSleeping
                        }) else{break}
                        try? await Task.sleep(nanoseconds:100_000_000)
                        current=await menuNavigator.snapshot(mode:expectedMode)
                    }
                    navigationMessage="Returned to the controller’s chat slots."
                    continue
                }
                guard let snapshot,navigationGate.accept(session:session,sequence:sequence,pid:snapshot.pid,hasMenu:true) else{continue}
                let success=await menuNavigator.perform(kind,direction:event["direction"] as? Int ?? 0,in:snapshot,isCurrent:{
                    self.mode==expectedMode && self.navigationGate.session==expectedSession && !self.isSystemSleeping
                })
                controllerTrace("navigation input kind=\(kind) panel=\(snapshot.kind.rawValue) ok=\(success)")
                if !success {navigationMessage="The focused control cannot be navigated safely. No input sent."}
                if kind != "turn" {try? await Task.sleep(nanoseconds:100_000_000)}
            }
            navigationInputBusy=false
        }
    }
}
