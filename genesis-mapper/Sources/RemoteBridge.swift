import SwiftUI
import AppKit
import ApplicationServices
import CoreImage.CIFilterBuiltins

@MainActor final class GenesisRemoteBridge: ObservableObject {
    static let shared=GenesisRemoteBridge()
    @Published var serviceStatus="Starting remote service…"
    @Published var baseURL:String=UserDefaults.standard.string(forKey:"remote.baseURL") ?? ""
    @Published var enabled:Bool=UserDefaults.standard.object(forKey:"remote.enabled") as? Bool ?? true
    @Published var chats:[RemoteChat]=[]
    @Published var artifacts:[RemoteArtifact]=[]
    @Published var lastResult="No remote commands yet."
    /// The newest command results, newest first, for the companion's window.
    @Published var recentActivity:[ActivityEntry]=[]
    @Published var lastSelfCheck:RemoteSelfCheck?
    @Published var checking=false
    private var activity:ActivityLog?
    /// Which phones may talk to this Mac. Loaded from and saved to devices.json.
    private var registry=DeviceRegistry()
    private var pairingCodes=PairingCodes()
    @Published var devices:[PairedDevice]=[]
    @Published var legacySecretAccepted=true
    /// The single-use code in the QR code now on screen.
    @Published var pairingCode:String?
    static let companionVersion=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development"
    private(set) var store:RemoteStore?
    private var server:RemoteHTTPServer?
    private let access=ClaudeAccess()
    private let muse=MuseAccess()
    private let menuNavigation=RemoteMenuNavigation()
    private var displaySession=RemoteDisplaySession()
    private var displayExpiryTask:Task<Void,Never>?
    private var commandBusy=false
    private var registrations:[NSObjectProtocol]=[]
    private var screenLocked=false
    private var recentChats:[String:RemoteChat]=[:]
    private var ambiguousClaudeIDs=Set<String>()
    /// Titles carried by more than one chat at the last listing, per app.
    private var claudeLeftOut=Set<String>(),museLeftOut=Set<String>()
    /// Muse is running in a window too narrow to control; see MuseAccess.widenWindow.
    private var museChatHidden=false,museChatHiddenCheckedAt=Date.distantPast
    private var codexChats:[RemoteChat]=[]
    private var codexInventoryAvailable=false
    private var codexInventoryCheckedAt:Date?
    private var codexRefresh:(id:UUID,task:Task<[CodexSavedChat],Error>)?
    var hostName:String {Host.current().localizedName ?? "Mac"}
    var isLocked:Bool {
        let session=CGSessionCopyCurrentDictionary() as? [String:Any]
        return screenLocked || session?["CGSSessionScreenIsLocked"] as? Bool == true || session?["kCGSessionOnConsoleKey"] as? Bool == false
    }
    init() {
        do {
            let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Genesis Agent Micro Controller/Remote",isDirectory:true)
            store=try RemoteStore(directory:directory);artifacts=store?.archive.artifacts ?? []
            startIfEnabled()
        } catch {serviceStatus="Remote storage could not be loaded. Existing controller is unchanged."}
        let center=DistributedNotificationCenter.default()
        registrations.append(center.addObserver(forName:NSNotification.Name("com.apple.screenIsLocked"),object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.screenLocked=true;self?.menuNavigation.invalidate();self?.clearDisplaySession()}})
        registrations.append(center.addObserver(forName:NSNotification.Name("com.apple.screenIsUnlocked"),object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.screenLocked=false}})
        if baseURL.isEmpty {Task {await discoverAddress()}}
        Task {_ = await loadCodexChats()}
    }
    func setEnabled(_ value:Bool) {if !value {menuNavigation.invalidate();clearDisplaySession()};enabled=value;UserDefaults.standard.set(value,forKey:"remote.enabled");if value {startIfEnabled()} else {server?.stop();server=nil;serviceStatus="Remote access is off"}}
    func saveAddress() {UserDefaults.standard.set(baseURL,forKey:"remote.baseURL")}
    func startIfEnabled() {
        guard enabled,server==nil,store != nil else{return}
        loadRegistry()
        let server=RemoteHTTPServer {[weak self] request in guard let self else{return .error(503,"Companion closed.")};return await self.route(request)}
        server.stateChanged={[weak self] state in Task{@MainActor in self?.serviceStatus=state}}
        do {try server.start();self.server=server} catch {serviceStatus="Remote service could not start."}
    }
    func discoverAddress() async {
        let address=await Task.detached(priority:.utility) { () -> String? in
            let paths=["/Applications/Tailscale.app/Contents/MacOS/Tailscale","/opt/homebrew/bin/tailscale","/usr/local/bin/tailscale"]
            guard let binary=paths.first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else{return nil}
            let process=Process();process.executableURL=URL(fileURLWithPath:binary);process.arguments=["status","--json"]
            let pipe=Pipe();process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
            do {try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
                let json=try JSONSerialization.jsonObject(with:data) as? [String:Any]
                guard let name=(json?["Self"] as? [String:Any])?["DNSName"] as? String,!name.isEmpty else{return nil}
                return "https://"+name.trimmingCharacters(in:CharacterSet(charactersIn:"."))+":8451"
            } catch{return nil}
        }.value
        if let address,baseURL.isEmpty {baseURL=address;saveAddress()}
    }
    var pairingLink:URL? {
        guard enabled,let store,let parsed=URLComponents(string:baseURL),parsed.scheme=="https",let host=parsed.host,!host.isEmpty,parsed.user==nil,parsed.password==nil,parsed.query==nil,parsed.fragment==nil,parsed.path.isEmpty || parsed.path=="/" else{return nil}
        // The code is good once and for ten minutes; it is not the Mac's secret.
        guard let code=pairingCode else{return nil}
        let payload=RemotePairing(name:hostName,hostID:store.hostID,baseURL:baseURL.trimmingCharacters(in:CharacterSet(charactersIn:"/")),token:code)
        guard let data=try? JSONEncoder().encode(payload) else{return nil}
        let encoded=data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        return URL(string:"genesiscontroller://pair?data="+encoded)
    }
    var qrImage:NSImage? {
        guard let link=pairingLink else{return nil}
        let filter=CIFilter.qrCodeGenerator();filter.message=Data(link.absoluteString.utf8);filter.correctionLevel="M"
        guard let output=filter.outputImage,let cg=CIContext().createCGImage(output,from:output.extent) else{return nil}
        return NSImage(cgImage:cg,size:NSSize(width:output.extent.width,height:output.extent.height))
    }
    func status()->RemoteHostStatus {
        // Status polling must not wait on inventory IPC. Prewarm at launch and
        // refresh in the background; chat listing/navigation can await a read.
        if !isLocked,codexRefresh==nil,Date().timeIntervalSince(codexInventoryCheckedAt ?? .distantPast)>30 {
            Task {_ = await loadCodexChats()}
        }
        let providers=RemotePolicy.providers.map { provider -> RemoteProvider in
            let bundle=provider=="claude" ? "com.anthropic.claudefordesktop":provider=="muse" ? "com.meta.endo":"com.openai.codex"
            let installed=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) != nil
            let running=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first != nil
            if provider=="codex" {
                let readiness=isLocked ? "locked":installed && codexInventoryAvailable ? "ready":"unavailable"
                let nativeReady = !isLocked && running && AXIsProcessTrusted()
                let queueAvailable=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle).flatMap(CodexQueuePolicy.executable) != nil && CodexQueuePolicy.usesDefaultHome(environment:ProcessInfo.processInfo.environment,home:FileManager.default.homeDirectoryForCurrentUser)
                let sendReason=queueAvailable ? "Phone Send queues to the exact selected chat; delivery is not yet confirmed.":"Phone Send needs the bundled Codex queue command and default account storage."
                let reason=isLocked ? "Unlock this Mac to open Codex.":!installed ? "Install Codex on this Mac.":codexInventoryAvailable ? (nativeReady ? "Saved chat selection and native Mac menu controls are available. Menus act on the current Codex view on the Mac. "+sendReason+" Stop and live voice are not connected.":"New chat, Settings, and Skills can open Codex on this Mac. Other menu controls need Codex running with Accessibility enabled for Agent Micro Controller. "+sendReason+" Stop and live voice are not connected."):codexInventoryCheckedAt==nil ? "Checking this Mac's saved Codex chats…":CodexService.reason(codexService) ?? "The current-account Codex chat inventory is unavailable. Open Codex on this Mac and refresh."
                // Offered only once a check has failed, and only when the tool that restarts it is the one inside the installed app.
                let restart = !isLocked && installed && codexInventoryCheckedAt != nil && queueAvailable && CodexService.canRestart(codexService) ? ["restartService"]:[]
                let capabilities=restart+RemoteCodexAvailability.capabilities(installed:installed,running:running,unlocked:!isLocked,accessibility:AXIsProcessTrusted(),inventoryAvailable:codexInventoryAvailable,launchIDs:CodexNativeActionPolicy.pageLinks.keys.sorted(),nativeIDs:CodexNativeActions.descriptors.map(\.id),queueAvailable:queueAvailable)
                return RemoteProvider(id:provider,name:"Codex",installed:installed,readiness:readiness,capabilities:capabilities,reason:reason,actions:CodexNativeActions.descriptors)
            }
            if provider=="muse" {
                // Chats open through Accessibility. A draft is pasted into Muse's
                // message box and read back before Return; see MuseAccess.
                // "closed" also covers Muse running in a window too narrow to control: either way the phone offers to open it.
                let covered=running && museChatHidden && !isLocked && AXIsProcessTrusted()
                if covered,Date().timeIntervalSince(museChatHiddenCheckedAt)>4 {
                    // Nobody asks for chats while they are hidden, so look again here to notice when they are back.
                    museChatHiddenCheckedAt=Date()
                    Task {self.museChatHidden=self.muse.needsWiderWindow()}
                }
                let readiness=isLocked ? "locked":!AXIsProcessTrusted() ? "needsAccessibility":!running || covered ? "closed":"ready"
                let reason=readiness=="ready" ? "Chats, Send, New side chat and Call are connected. Send briefly brings Muse to the front and uses the clipboard, which is restored afterwards. Chats that share a title are left out.":readiness=="locked" ? "Unlock this Mac to use Muse.":covered ? "Muse\u{2019}s window on this Mac is too narrow for the controller to reach its chats. Open Muse from here to widen it.":readiness=="closed" ? "Open Muse on this Mac.":"Enable Accessibility for Agent Micro Controller."
                return RemoteProvider(id:provider,name:"Muse",installed:installed,readiness:readiness,capabilities:readiness=="ready" ? RemoteMuse.capabilities:readiness=="closed" && installed ? ["artifacts","launchApp"]:["artifacts"],reason:reason,actions:RemoteMuse.actions)
            }
            let readiness=isLocked ? "locked":!AXIsProcessTrusted() ? "needsAccessibility":!running ? "closed":"ready"
            let reason=readiness=="ready" ? "Native live voice is not yet available on the phone.":readiness=="locked" ? "Unlock this Mac to use desktop controls.":readiness=="closed" ? "Open Claude on this Mac.":"Enable Accessibility for Agent Micro Controller."
            return RemoteProvider(id:provider,name:"Claude",installed:installed,readiness:readiness,capabilities:readiness=="ready" ? ["openChat","sendPrompt","stop","artifacts","menuNavigation"] + RemoteActionCatalog.claude.map{$0.action.id}:readiness=="closed" && installed ? ["artifacts","launchApp"]:["artifacts"],reason:reason,actions:RemoteActionCatalog.claude.map(\.action))
        }
        return RemoteHostStatus(hostID:store?.hostID ?? "",hostName:hostName,providers:providers,companionVersion:Self.companionVersion)
    }
    func loadCodexChats(force:Bool=false) async -> [RemoteChat] {
        guard !isLocked,NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.openai.codex") != nil else{return []}
        if !force,let checked=codexInventoryCheckedAt,Date().timeIntervalSince(checked)<5 {return codexInventoryAvailable ? codexChats:[]}
        let flight:(id:UUID,task:Task<[CodexSavedChat],Error>)
        if let current=codexRefresh {flight=current}
        else {flight=(UUID(),Task {try await CodexReadOnly.chats(maximum:500)});codexRefresh=flight}
        do {
            let saved=try await flight.task.value
            // The separate daemon supplies metadata, not live desktop activity.
            let records=saved.map{RemoteChat(id:$0.id,title:String($0.name.prefix(240)),state:"Saved")}
            if codexRefresh?.id==flight.id {
                codexChats=records;codexInventoryAvailable=true;codexInventoryCheckedAt=Date();codexRefresh=nil
            }
            return isLocked ? []:records
        } catch {
            if codexRefresh?.id==flight.id {
                codexChats=[];codexInventoryAvailable=false;codexInventoryCheckedAt=Date();codexRefresh=nil
            }
            return []
        }
    }
    /// Records what a command was and how it ended. Never the prompt: a
    /// command's text does not reach this function, only its action and result.
    private func note(_ command:RemoteCommand,status:String,message:String,started:Date) {
        if activity==nil,let store {activity=ActivityLog(url:store.directory.appendingPathComponent("activity.jsonl"))}
        activity?.record(provider:command.provider,action:command.action,status:status,message:message,durationMs:Int(Date().timeIntervalSince(started)*1000))
        recentActivity=Array((activity?.recent(40) ?? []).reversed())
    }
    func loadActivity() {
        if activity==nil,let store {activity=ActivityLog(url:store.directory.appendingPathComponent("activity.jsonl"))}
        recentActivity=Array((activity?.recent(40) ?? []).reversed())
    }
    /// Looks at each app the controller drives and reports what it can find.
    /// Read-only, except that counting Muse's chats shows Muse's chat panel.
    func selfCheck() async -> RemoteSelfCheck {
        checking=true;defer{checking=false}
        func installed(_ bundle:String)->Bool {NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) != nil}
        func running(_ bundle:String)->Bool {NSRunningApplication.runningApplications(withBundleIdentifier:bundle).contains{!$0.isTerminated}}
        let mac=SelfCheck.Mac(unlocked:!isLocked,accessibility:AXIsProcessTrusted())
        var items=SelfCheck.mac(mac)
        let readable=mac.unlocked && mac.accessibility
        items += SelfCheck.claude(readable ? access.readSnapshot {access.selfCheck(installed:installed(access.bundle),running:running(access.bundle))}
                                           : access.selfCheck(installed:installed(access.bundle),running:false),mac:mac)
        let museSeen:SelfCheck.Muse = readable && running(MuseAccess.bundle) ? await muse.selfCheck(installed:installed(MuseAccess.bundle))
            : .init(installed:installed(MuseAccess.bundle),running:running(MuseAccess.bundle),navigable:false,messageBoxes:0,answering:false,chats:0,sharedTitles:0,callControls:0)
        items += SelfCheck.muse(museSeen,mac:mac)
        let codexBundle="com.openai.codex"
        let saved=mac.unlocked ? await loadCodexChats(force:true):[]
        var menus=false
        if readable,let app=NSRunningApplication.runningApplications(withBundleIdentifier:codexBundle).first(where:{!$0.isTerminated}) {
            let root=AXUIElementCreateApplication(app.processIdentifier);AXUIElementSetMessagingTimeout(root,0.4)
            var bar:CFTypeRef?
            menus=AXUIElementCopyAttributeValue(root,kAXMenuBarAttribute as CFString,&bar) == .success
        }
        let queue=NSWorkspace.shared.urlForApplication(withBundleIdentifier:codexBundle).flatMap(CodexQueuePolicy.executable) != nil
            && CodexQueuePolicy.usesDefaultHome(environment:ProcessInfo.processInfo.environment,home:FileManager.default.homeDirectoryForCurrentUser)
        items += SelfCheck.codex(.init(installed:installed(codexBundle),running:running(codexBundle),inventoryReachable:codexInventoryAvailable,savedChats:saved.count,menuBarReadable:menus,queueAvailable:queue),mac:mac)
        let report=RemoteSelfCheck(checkedAt:Date(),companionVersion:Self.companionVersion,summary:SelfCheck.summary(items),items:items)
        lastSelfCheck=report
        return report
    }
    func loadMuseChats() async -> [RemoteChat] {
        guard enabled,!isLocked,AXIsProcessTrusted() else{museLeftOut=[];return []}
        guard let listing=await muse.listing() else {
            // No chat list. Find out whether Muse's window is too narrow, so the phone can say so and offer to widen it.
            museLeftOut=[];museChatHidden=muse.needsWiderWindow();museChatHiddenCheckedAt=Date();return []
        }
        museLeftOut=listing.ambiguous;museChatHidden=false;museChatHiddenCheckedAt=Date()
        return listing.chats.map{RemoteChat(id:RemotePolicy.chatID("muse",$0.title),title:$0.title,state:$0.current ? "Current":$0.unread ? "Unread":"Open")}
    }
    /// Opens a provider's app so someone away from the Mac is not stuck at
    /// "open it on the Mac". It only opens the app; it sends and changes nothing.
    /// Where Codex's background service stands, from the last chat-list check and what is on disk.
    private var codexService:CodexService.State {
        CodexService.probe(home:FileManager.default.homeDirectoryForCurrentUser,answering:codexInventoryAvailable)
    }
    private var restartingCodexService=false
    /// Restarts Codex's background service with Codex's own command, and only
    /// when the service cannot be reached. It opens no chat and sends nothing.
    private func restartCodexService(_ command:RemoteCommand) async -> RemoteReceipt {
        func result(_ state:String,_ message:String)->RemoteReceipt {RemoteReceipt(id:command.id,status:state,message:message)}
        guard command.provider=="codex" else{return result("failed","Only Codex has a background service to restart.")}
        guard enabled,!isLocked else{return result("failed","Unlock this Mac to restart Codex’s background service.")}
        let home=FileManager.default.homeDirectoryForCurrentUser
        guard CodexQueuePolicy.usesDefaultHome(environment:ProcessInfo.processInfo.environment,home:home),
              let application=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.openai.codex"),
              let executable=CodexQueuePolicy.executable(in:application) else{return result("failed","The installed Codex app and its default account storage are needed to restart its background service.")}
        guard !restartingCodexService else{return result("failed","A restart is already under way. Refresh in a moment.")}
        restartingCodexService=true;defer{restartingCodexService=false}
        // Ask again first: a service that answers is never restarted.
        let before=await loadCodexChats(force:true)
        let state=codexService
        guard CodexService.canRestart(state) else {
            return state == .answering ? result("confirmed","Codex’s background service is already answering (\(before.count) saved chats). Nothing was restarted."):result("failed","Codex’s background service has not been set up on this Mac. Open Codex on the Mac first.")
        }
        let environment=CodexQueuePolicy.environment(home:home)
        let run=await Task.detached(priority:.userInitiated) { ()->CodexService.Run in
            guard CodexQueuePolicy.isTrustedExecutable(executable) else{return .notLaunched}
            switch CodexQueueProcess.run(executable:executable,arguments:CodexService.restartArguments,environment:environment,timeout:30).completion {
            case .notLaunched:return .notLaunched
            case .exited(let code):return .exited(code)
            case .interrupted,.timedOut:return .timedOut
            }
        }.value
        // The service takes a moment to listen again after the command returns.
        var chats=[RemoteChat]()
        if run != .notLaunched {
            for attempt in 0..<8 {
                chats=await loadCodexChats(force:true)
                if codexInventoryAvailable {break}
                if attempt<7 {try? await Task.sleep(nanoseconds:750_000_000)}
            }
        }
        var outcome=run
        if CodexService.shouldTryStart(after:run,answering:codexInventoryAvailable) {
            // The restart stopped the service and could not start it again. Do not leave it down.
            outcome=await Task.detached(priority:.userInitiated) { ()->CodexService.Run in
                switch CodexQueueProcess.run(executable:executable,arguments:CodexService.startArguments,environment:environment,timeout:30).completion {
                case .notLaunched:return .notLaunched
                case .exited(let code):return .exited(code)
                case .interrupted,.timedOut:return .timedOut
                }
            }.value
            for attempt in 0..<8 {
                chats=await loadCodexChats(force:true)
                if codexInventoryAvailable {break}
                if attempt<7 {try? await Task.sleep(nanoseconds:750_000_000)}
            }
        }
        let receipt=CodexService.receipt(outcome,answeringAfter:codexInventoryAvailable,chats:chats.count)
        return result(receipt.status,receipt.message)
    }
    private func launchApp(_ command:RemoteCommand) async -> RemoteReceipt {
        func result(_ state:String,_ message:String)->RemoteReceipt {RemoteReceipt(id:command.id,status:state,message:message)}
        let names=["claude":"Claude","muse":"Muse","codex":"Codex"],bundles=["claude":access.bundle,"muse":MuseAccess.bundle,"codex":"com.openai.codex"]
        guard let name=names[command.provider],let bundle=bundles[command.provider] else{return result("failed","Unknown app.")}
        guard !isLocked else{return result("failed","Unlock this Mac to open \(name).")}
        func running()->Bool {NSRunningApplication.runningApplications(withBundleIdentifier:bundle).contains{!$0.isTerminated}}
        if running() {
            // Muse can be open in a window too narrow to control; see MuseAccess.widenWindow.
            if command.provider=="muse",AXIsProcessTrusted(),let outcome=await muse.widenWindow() {
                museChatHidden=muse.needsWiderWindow();museChatHiddenCheckedAt=Date()
                return result(outcome.status,outcome.message)
            }
            return result("confirmed","\(name) is already open on this Mac.")
        }
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) else{return result("failed","\(name) is not installed on this Mac.")}
        let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
        do {_ = try await NSWorkspace.shared.openApplication(at:url,configuration:configuration)} catch{return result("failed","macOS could not open \(name).")}
        for _ in 0..<40 {
            if running() {return result("confirmed","Opened \(name) on this Mac. Give it a moment to load, then refresh.")}
            try? await Task.sleep(nanoseconds:250_000_000)
        }
        return result("uncertain","\(name) was asked to open but has not appeared yet. Refresh in a moment.")
    }
    private func executeMuse(_ command:RemoteCommand) async -> RemoteReceipt {
        func result(_ outcome:MuseAccess.Outcome)->RemoteReceipt {RemoteReceipt(id:command.id,status:outcome.status,message:outcome.message)}
        guard !isLocked,AXIsProcessTrusted() else{return result(.failed("Unlock the Mac and enable Accessibility for Agent Micro Controller first."))}
        guard let pid=muse.app?.processIdentifier else{return result(.failed("Open Muse on this Mac first."))}
        func contextOK()->Bool {self.enabled && !self.isLocked && AXIsProcessTrusted() && self.muse.app?.processIdentifier==pid}
        // A command needs Muse's full layout. If its window is too narrow, widen it first.
        if let revealed=await muse.widenWindow() {
            museChatHidden=muse.needsWiderWindow();museChatHiddenCheckedAt=Date()
            if revealed.status != "confirmed" {return result(revealed)}
        }
        if command.action=="nativeVoice" {return result(await muse.startCall(contextIsCurrent:contextOK))}
        let unnamed=RemoteChat(id:RemotePolicy.chatID("muse",MuseChatList.unnamedSideChat),title:MuseChatList.unnamedSideChat,state:"Current")
        if command.action=="newChat" {
            // Hand the phone the new chat so a draft can go into it at once.
            let outcome=await muse.newSideChat(contextIsCurrent:contextOK)
            var receipt=result(outcome);if outcome.status=="confirmed" {receipt.activeChat=unnamed}
            return receipt
        }
        guard ["openChat","sendPrompt"].contains(command.action) else{return result(.failed("This action is not connected for Muse."))}
        // Reaching any other chat from an unnamed side chat means leaving it.
        guard let id=command.chatID,let listing=await muse.listing(leavingUnnamedChat:command.chatID != unnamed.id) else{return result(.failed("Muse’s chat list could not be read. Open Muse on this Mac and refresh."))}
        // The opaque ID only names a title. The fresh listing above decides
        // whether that title still points at exactly one chat.
        guard let target=listing.chats.first(where:{RemotePolicy.chatID("muse",$0.title)==id}) else {
            let shared=listing.ambiguous.contains{RemotePolicy.chatID("muse",$0)==id}
            return result(.failed(shared ? "More than one Muse chat has this title. Rename one in Muse before using its key.":"This Muse chat is no longer in the chat list. Refresh its mapping; nothing was opened."))
        }
        if command.action=="openChat" {return result(await muse.open(target.title,contextIsCurrent:contextOK))}
        guard let prompt=command.text else{return result(.failed("The prompt is empty."))}
        return result(await muse.send(prompt,to:target.title,contextIsCurrent:contextOK))
    }
    func refreshChats() {Task {chats=loadChats("claude")}}
    func loadChats(_ provider:String,deadline:Double?=nil)->[RemoteChat] {
        ambiguousClaudeIDs.removeAll(keepingCapacity:true);claudeLeftOut.removeAll(keepingCapacity:true)
        guard provider=="claude",!isLocked,AXIsProcessTrusted() else{return []}
        func read()->[RemoteChat] {
            let all=access.nodes(),sessions=access.sessions(all)
            // Reuse attribute reads only within this synchronous snapshot.
            return Dictionary(grouping:sessions,by:{$0.title}).compactMap { title,values -> RemoteChat? in
                guard !RemoteClaudeLookup.isAmbiguous(sidebarDestinationCount:access.sidebarTargets(title,in:all).count) else {
                    ambiguousClaudeIDs.insert(RemotePolicy.chatID(provider,title));claudeLeftOut.insert(title);return nil
                }
                return RemoteChat(id:RemotePolicy.chatID(provider,title),title:title,state:values.last?.state ?? "Open")
            }.sorted{$0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending}
        }
        let records:[RemoteChat]
        if let deadline {records=access.readSnapshot(deadline:deadline,read) ?? []}
        else {records=access.readSnapshot(read)}
        recentChats=Dictionary(uniqueKeysWithValues:records.map{($0.id,$0)})
        chats=records;return records
    }
    func seededProfile(_ provider:String) throws -> RemoteProfile {
        guard let store else{throw RemoteFault(status:503,message:"Storage unavailable.")}
        guard provider=="claude" else{return try store.profile(provider)}
        let titles=UserDefaults.standard.stringArray(forKey:"slots") ?? [],actions=UserDefaults.standard.stringArray(forKey:"slotActions") ?? []
        let seed=(0..<6).map { index -> RemoteSlot in
            let title=index<titles.count ? titles[index]:"",action=index<actions.count ? actions[index]:"chat"
            if action=="chat",!title.isEmpty {return RemoteSlot(index:index,kind:"chat",title:title,targetID:RemotePolicy.chatID("claude",title))}
            if action=="send" {return RemoteSlot(index:index,kind:"action",title:"Send prompt",targetID:"sendPrompt")}
            if action=="stop" {return RemoteSlot(index:index,kind:"action",title:"Stop response",targetID:"stop")}
            return RemoteSlot(index:index,kind:"empty",title:"",targetID:"")
        }
        return try store.profile(provider,seed:seed)
    }
    // Private paired diagnostics deliberately report only structure around saved
    // slot labels. Never include composer values, message text, or credentials.
    func claudeLookupDiagnostics()->RemoteHTTPResponse {
        guard !isLocked,AXIsProcessTrusted() else{return .error(423,"Unlock the Mac and enable Accessibility first.")}
        let all=access.nodes(),sessions=access.sessions(all)
        let saved=(UserDefaults.standard.stringArray(forKey:"slots") ?? []) + (store?.archive.profiles["claude"]?.slots.filter{$0.kind=="chat"}.map(\.title) ?? [])
        let titles=Array(Set(saved.filter{!$0.isEmpty})).sorted().prefix(12)
        func relation(_ value:String,_ title:String)->String {
            if value==title{return "title"}
            if value=="More options for "+title{return "menu"}
            if value==title+", rename session"{return "header"}
            if access.states.contains(where:{value==$0+" "+title}){return "statePrefix"}
            if value.contains(title){return "containsTitle"}
            return "unrelated"
        }
        func shape(_ element:AXUIElement,_ title:String)->[String:Any] {
            let attributes=[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].reduce(into:[String:String]()) {result,key in
                if let value=access.value(element,key) as? String,!value.isEmpty {result[key]=relation(value,title)}
            }
            return ["role":access.value(element,kAXRoleAttribute) as? String ?? "", "attributes":attributes,"chosenLabel":relation(access.text(element),title)]
        }
        let slots=titles.map {title -> [String:Any] in
            let matching=all.filter {element in [kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].contains {key in
                guard let value=access.value(element,key) as? String else{return false};return relation(value,title) != "unrelated"
            }}.prefix(16)
            let matches=matching.map {element -> [String:Any] in
                var record=shape(element,title)
                if let parent=access.value(element,kAXParentAttribute),CFGetTypeID(parent)==AXUIElementGetTypeID() {
                    let parent=parent as! AXUIElement;record["parent"]=shape(parent,title)
                    let children=access.value(parent,kAXChildrenAttribute) as? [AXUIElement] ?? []
                    record["siblings"]=children.prefix(12).map{shape($0,title)}
                }
                return record
            }
            return ["title":title,"discovered":sessions.contains{$0.title==title},"sidebarTargets":access.sidebarTargets(title,in:all).count,"matches":matches]
        }
        let roles=all.reduce(into:[String:Int]()) {result,element in result[access.value(element,kAXRoleAttribute) as? String ?? "unknown",default:0]+=1}
        func promptLabelClass(_ value:AnyObject?)->String {
            guard let text=value as? String else{return value==nil ? "absent":"nonString"}
            if text.isEmpty {return "empty"}
            return text=="Prompt" ? "exactPrompt":text.contains("Prompt") ? "containsPrompt":"other"
        }
        let composers=all.filter {[kAXTextAreaRole,kAXTextFieldRole,kAXComboBoxRole].contains(access.value($0,kAXRoleAttribute) as? String ?? "")}.prefix(12).map {field -> [String:Any] in
            var raw:CFTypeRef?,writable=DarwinBoolean(false)
            let read=AXUIElementCopyAttributeValue(field,kAXValueAttribute as CFString,&raw)
            let write=AXUIElementIsAttributeSettable(field,kAXValueAttribute as CFString,&writable)
            let text=raw as? String
            return ["role":access.value(field,kAXRoleAttribute) as? String ?? "",
                    "descriptionClass":promptLabelClass(access.value(field,kAXDescriptionAttribute)),
                    "titleClass":promptLabelClass(access.value(field,kAXTitleAttribute)),
                    "valueType":text != nil ? "string":raw==nil ? "absent":"nonString",
                    "valueReadError":read.rawValue,"valueLength":text?.count ?? -1,
                    "whitespaceOnly":text?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? false,
                    "settableReadError":write.rawValue,"valueSettable":writable.boolValue]
        }
        let payload:[String:Any]=["nodeCount":all.count,"sessionCount":sessions.count,"roles":roles,"slots":slots,"composers":composers]
        guard let data=try? JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]) else{return .error(500,"Diagnostics unavailable.")}
        return RemoteHTTPResponse(data:data)
    }
    // MARK: Paired devices
    private var registryURL:URL? {store?.directory.appendingPathComponent("devices.json")}
    private func loadRegistry() {
        guard let url=registryURL,let data=try? Data(contentsOf:url),let saved=try? JSONDecoder().decode(DeviceRegistry.self,from:data) else {publishRegistry();return}
        registry=saved;publishRegistry()
    }
    private func saveRegistry() {
        publishRegistry()
        guard let url=registryURL,let data=try? JSONEncoder().encode(registry) else{return}
        try? data.write(to:url,options:.atomic)
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func publishRegistry() {devices=registry.devices;legacySecretAccepted=registry.legacySecretAccepted}
    /// Shows a fresh single-use code. Called when the pairing window opens,
    /// after a code is used, and before one would expire.
    func refreshPairingCode() {pairingCode=pairingCodes.issue(now:Date())}
    func revokeDevice(_ id:String) {if registry.revoke(id) {saveRegistry()}}
    /// Cuts off every phone that paired before per-device secrets. They show
    /// "Pair this Mac" and can be paired again with the QR code.
    func stopAcceptingLegacySecret() {registry.legacySecretAccepted=false;saveRegistry()}
    /// Whether a request carries a secret this Mac accepts. Both checks always
    /// run, so the answer's timing does not say which kind of secret it was.
    private func authorized(_ request:RemoteHTTPRequest)->Bool {
        guard let store else{return false}
        let header=request.headers["authorization"] ?? ""
        let supplied=header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)):""
        let legacy=RemotePolicy.equalToken(supplied,store.token) && registry.legacySecretAccepted
        let device=registry.device(for:supplied)
        if let device,registry.seen(device.id,now:Date()) {saveRegistry()}
        return legacy || device != nil
    }
    /// Trades the single-use code from the QR code for a secret of the phone's own.
    private func pair(_ request:RemoteHTTPRequest)->RemoteHTTPResponse {
        guard enabled else{return .error(403,"Remote access is off on this Mac.")}
        guard let body=try? JSONDecoder().decode(RemotePairRequest.self,from:request.body) else{return .error(400,"Invalid pairing request.")}
        switch pairingCodes.redeem(body.code,now:Date()) {
        case .lockedOut:return .error(429,"Too many wrong pairing codes. Wait a minute, then scan a fresh code from the Mac.")
        case .rejected:return .error(403,"This pairing code is no longer valid. Scan a fresh code from the Mac.")
        case .accepted:
            let enrolled=registry.enroll(name:body.deviceName ?? "",now:Date())
            saveRegistry()
            // A used code is gone; put a new one on screen for the next device.
            refreshPairingCode()
            lastResult="Paired \(enrolled.device.name)."
            return .json(RemotePairResponse(token:enrolled.token,deviceID:enrolled.device.id,deviceName:enrolled.device.name))
        }
    }
    func route(_ request:RemoteHTTPRequest) async -> RemoteHTTPResponse {
        guard let store else{return .error(503,"Remote storage unavailable.")}
        guard let url=URLComponents(string:"http://localhost"+request.target) else{return .error(400,"Invalid path.")}
        let path=url.path,query=url.queryItems ?? []
        // Pairing is the one request that cannot carry a secret yet.
        if request.method=="POST",path=="/v1/pair" {return pair(request)}
        guard authorized(request) else{return .error(401,"Pair this iPhone with the Mac first.")}
        // Someone signed in on this Mac can issue a pairing code without the window, for setting
        // devices up from the command line. Refused for anything relayed from the network.
        if request.method=="POST",path=="/v1/pair/code" {
            guard LocalCaller.isDirect(headers:request.headers) else{return .error(403,"Pairing codes can only be issued on the Mac itself.")}
            let address=baseURL.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            guard enabled,let parsed=URLComponents(string:address),parsed.scheme=="https",parsed.host?.isEmpty==false else{return .error(409,"Set this Mac\u{2019}s private address in the pairing window first.")}
            return .json(RemotePairing(name:hostName,hostID:store.hostID,baseURL:address,token:pairingCodes.issue(now:Date())))
        }
        func parameter(_ key:String)->String {query.first{$0.name==key}?.value ?? ""}
        do {
            if request.method=="GET",path=="/v1/status" {return .json(status())}
            if request.method=="GET",path=="/v1/display-session" {
                if isLocked {clearDisplaySession()}
                return .json(displaySession.snapshot(hostID:store.hostID,now:Date().timeIntervalSince1970))
            }
            if request.method=="POST",path=="/v1/display-session" {
                guard !isLocked else {clearDisplaySession();return .error(423,"Unlock this Mac to follow a controller.")}
                let operation=try RemoteDisplayRequest.decode(request.body)
                let target=try displaySession.requiredTarget(for:operation,now:Date().timeIntervalSince1970)
                var validated:RemoteDisplaySession.ValidatedTarget?
                if let target {
                    // Inventory reads only on a changed target. Draft updates and
                    // heartbeats never perform an accessibility traversal.
                    if target.provider=="claude" {
                        if let pid=NSRunningApplication.runningApplications(withBundleIdentifier:access.bundle).first?.processIdentifier {
                            let observed=await ClaudeInventoryRead.resolve(deadline:ProcessInfo.processInfo.systemUptime+2.5,
                                contextIsCurrent:{self.enabled && !self.isLocked && AXIsProcessTrusted() && NSRunningApplication.runningApplications(withBundleIdentifier:self.access.bundle).first?.processIdentifier==pid},
                                read:{deadline ->ClaudeInventoryRead.Result<RemoteChat> in
                                    let matches=self.loadChats("claude",deadline:deadline).filter{$0.id==target.chatID}
                                    if self.ambiguousClaudeIDs.contains(target.chatID) || matches.count>1 {return .ambiguous}
                                    return matches.first.map{.found($0)} ?? .missing
                                })
                            if case .ambiguous=observed {throw RemoteDisplayFault(status:409,message:"This Claude title resolves to more than one sidebar chat. Rename one before following it.")}
                            if case .found(let match)=observed {validated = .init(target:target,title:match.title)}
                        }
                    } else {
                        let matches=await loadCodexChats().filter{$0.id==target.chatID}
                        if matches.count==1 {validated = .init(target:target,title:matches[0].title)}
                    }
                }
                guard enabled,!isLocked else {clearDisplaySession();return .error(423,"Unlock this Mac to follow a controller.")}
                let result=try displaySession.apply(operation,hostID:store.hostID,now:Date().timeIntervalSince1970,validated:validated)
                scheduleDisplayExpiry()
                return .json(result)
            }
            if request.method=="POST",path=="/v1/display-feedback" {
                if isLocked {clearDisplaySession()}
                let feedback=try RemoteDisplayFeedbackRequest.decode(request.body)
                return .json(try displaySession.applyFeedback(feedback,hostID:store.hostID,now:Date().timeIntervalSince1970))
            }
            if request.method=="GET",path=="/v1/navigation" {
                let provider=parameter("provider"),chatID=parameter("chatID").isEmpty ? nil:parameter("chatID")
                guard ["claude","codex"].contains(provider),let generation=Int(parameter("generation")),generation>=0 else{return .error(422,"Invalid navigation context.")}
                guard !commandBusy else{return .json(RemoteNavigationState(active:false,session:nil,label:"Finishing the previous controller action…",selection:nil))}
                return .json(await menuNavigation.inspect(provider:provider,chatID:chatID,generation:generation,isCurrent:{self.navigationContextIsCurrent(provider:provider,chatID:chatID)}))
            }
            if request.method=="GET",path=="/v1/diagnostics/claude" {return claudeLookupDiagnostics()}
            if request.method=="GET",path=="/v1/chats" {
                guard RemotePolicy.providers.contains(parameter("provider")) else{return .error(422,"Unknown provider.")}
                if parameter("provider")=="codex" {return .json(RemoteChatList(chats:await loadCodexChats()))}
                if parameter("provider")=="muse" {let chats=await loadMuseChats();return .json(RemoteChatList(chats:chats,leftOut:RemoteLeftOut.titles(museLeftOut)))}
                let chats=loadChats(parameter("provider"))
                return .json(RemoteChatList(chats:chats,leftOut:RemoteLeftOut.titles(claudeLeftOut)))
            }
            if request.method=="GET",path=="/v1/profile" {return .json(try seededProfile(parameter("provider")))}
            if request.method=="PUT",path=="/v1/profile" {
                let profile=try JSONDecoder().decode(RemoteProfile.self,from:request.body)
                return .json(try store.update(profile))
            }
            if request.method=="POST",path=="/v1/commands" {
                let command=try JSONDecoder().decode(RemoteCommand.self,from:request.body)
                try RemotePolicy.validate(command,hostID:store.hostID)
                if let receipt=try store.previous(command) {return .json(receipt)}
                // 409, not 503: the phone must be able to tell "refused, nothing ran" from "result unknown".
                guard !commandBusy else {
                    note(command,status:"refused",message:"Another controller action was still finishing.",started:Date())
                    return .error(409,"Another controller action is finishing. Nothing was sent.")
                }
                try store.begin(command);commandBusy=true
                defer{commandBusy=false}
                let started=Date()
                let receipt=await execute(command)
                note(command,status:receipt.status,message:receipt.message,started:started)
                do {try store.finish(receipt)} catch{return .json(RemoteReceipt(id:command.id,status:"uncertain",message:"Could not persist the command result. Inspect the chat before sending again."))}
                lastResult=receipt.message;return .json(receipt)
            }
            if request.method=="GET",path=="/v1/diagnostics/selfcheck" {return .json(await selfCheck())}
            if request.method=="GET",path=="/v1/diagnostics/outline" {
                // Control names only, for working out what screen an app is on.
                let bundles=["claude":access.bundle,"muse":MuseAccess.bundle,"codex":"com.openai.codex"]
                guard let bundle=bundles[parameter("provider")] else{return .error(422,"Unknown provider.")}
                guard !isLocked,AXIsProcessTrusted() else{return .error(423,"Unlock the Mac and enable Accessibility first.")}
                return .json(["lines":MuseAccess.outline(bundle:bundle)])
            }
            if request.method=="GET",path=="/v1/diagnostics/activity" {return .json(RemoteActivity(entries:activity?.recent(100) ?? []))}
            if request.method=="GET",path.hasPrefix("/v1/commands/") {
                let id=String(path.dropFirst("/v1/commands/".count))
                guard let receipt=store.archive.ledger[id]?.receipt else{return .error(404,"Command is not known. Do not assume it is safe to resend.")}
                return .json(receipt)
            }
            if request.method=="GET",path=="/v1/artifacts" {
                guard RemotePolicy.providers.contains(parameter("provider")) else{return .error(422,"Unknown provider.")}
                return .json(["artifacts":store.archive.artifacts.filter{$0.provider==parameter("provider") && (parameter("chatID").isEmpty || $0.chatID.isEmpty || $0.chatID==parameter("chatID"))}])
            }
            if request.method=="GET",path.hasPrefix("/v1/artifacts/"),path.hasSuffix("/content") {
                let id=String(path.dropFirst("/v1/artifacts/".count).dropLast("/content".count))
                guard UUID(uuidString:id) != nil,let record=store.archive.artifacts.first(where:{$0.id==id}),record.url==nil else{return .error(404,"Exported artifact not found.")}
                let file=store.directory.appendingPathComponent("exports").appendingPathComponent(id)
                let metadata=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                guard metadata.isRegularFile==true,metadata.isSymbolicLink != true,(metadata.fileSize ?? Int.max)<=20_000_000 else{return .error(422,"Exported artifact is invalid.")}
                let content=try Data(contentsOf:file)
                return RemoteHTTPResponse(contentType:record.mimeType ?? "application/octet-stream",data:content)
            }
            return .error(404,"Unknown endpoint.")
        } catch let error as RemoteDisplayFault {return .error(error.status,error.message)}
        catch let error as RemoteFault {return .error(error.status,error.message)}
        catch {return .error(400,"Invalid request or unavailable artifact.")}
    }
    private func clearDisplaySession() {
        displayExpiryTask?.cancel();displayExpiryTask=nil;displaySession.invalidate()
    }
    private func scheduleDisplayExpiry() {
        displayExpiryTask?.cancel();displayExpiryTask=nil
        guard let expiry=displaySession.nextExpiry else{return}
        let delay=max(0,expiry-Date().timeIntervalSince1970)
        displayExpiryTask=Task { @MainActor [weak self] in
            do {try await Task.sleep(nanoseconds:UInt64(delay * 1_000_000_000)+10_000_000)} catch{return}
            // Delete transient drafts even when every display client disconnects.
            guard let self else{return}
            self.displaySession.expire(now:Date().timeIntervalSince1970)
            self.scheduleDisplayExpiry()
        }
    }
    private func navigationContextIsCurrent(provider:String,chatID:String?)->Bool {
        guard enabled,!isLocked,AXIsProcessTrusted() else{return false}
        if provider=="claude",let chatID {
            guard let target=resolveClaudeTarget(chatID) else{return false}
            return access.current(target.title)
        }
        return ["claude","codex"].contains(provider)
    }
    private func resolveClaudeTarget(_ id:String)->RemoteChat? {
        let savedSlots=(try? seededProfile("claude").slots) ?? []
        let known=(UserDefaults.standard.stringArray(forKey:"knownSessionTitles") ?? [])+(UserDefaults.standard.stringArray(forKey:"slots") ?? [])
        return RemoteClaudeLookup.savedTarget(id:id,candidates:Array(recentChats.values),profileSlots:savedSlots,knownTitles:known)
            ?? RemoteClaudeLookup.savedTarget(id:id,candidates:loadChats("claude"),profileSlots:[],knownTitles:[])
    }
    private func verifiedActiveClaudeChat()->RemoteChat? {
        access.readSnapshot {
            let all=access.nodes(),suffix=", rename session"
            let headers=all.filter{access.value($0,kAXRoleAttribute) as? String==kAXButtonRole && access.text($0).hasSuffix(suffix)}
            guard headers.count==1 else{return nil}
            let title=String(access.text(headers[0]).dropLast(suffix.count))
            guard !title.isEmpty,access.sidebarTargets(title,in:all).count==1 else{return nil}
            let chat=RemoteChat(id:RemotePolicy.chatID("claude",title),title:title,state:"Open")
            recentChats[chat.id]=chat;return chat
        }
    }
    private func executeClaudeShortcut(_ command:RemoteCommand,entry:RemoteActionCatalog.ClaudeEntry) async ->RemoteReceipt {
        func result(_ status:String,_ message:String,_ chat:RemoteChat?=nil)->RemoteReceipt {
            RemoteReceipt(id:command.id,status:status,message:message,activeChat:chat)
        }
        guard !isLocked,AXIsProcessTrusted(),let app=NSRunningApplication.runningApplications(withBundleIdentifier:access.bundle).first,
              let definition=ControllerAction.find(entry.controllerID),definition.sessionRequired==entry.action.requiresChat else {
            return result("failed","Unlock this Mac, open Claude, and enable Accessibility for Agent Micro Controller first.")
        }
        // Global navigation is relative to the desktop's current view. Never
        // reselect the phone's old chat before Previous, Next, Back, or New.
        let target=entry.action.requiresChat ? command.chatID.flatMap(resolveClaudeTarget):nil
        if entry.action.requiresChat,target==nil {return result("failed","This chat mapping is unavailable. Refresh before using this control.")}
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            NSApp.yieldActivation(to:app)
            if let url=app.bundleURL {let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true;_ = try? await NSWorkspace.shared.openApplication(at:url,configuration:configuration)}
            try? await Task.sleep(nanoseconds:150_000_000)
        }
        func contextOK()->Bool {
            guard enabled,!isLocked,NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else{return false}
            guard let target else{return !entry.action.requiresChat}
            let snapshot=access.targetSnapshot(target.title)
            return snapshot.isCurrent && snapshot.destinationCount==1
        }
        guard contextOK() else{return result("failed","The active Claude chat does not match this control's target. Select the chat again; no input was sent.")}
        let previousID=entry.action.changesChat ? verifiedActiveClaudeChat()?.id:nil
        let message=await access.extraAction(definition,title:target?.title ?? "",app:app,contextIsCurrent:contextOK)
        guard RemoteActionCatalog.acceptsClaudeResult(message,controllerTitle:definition.title) else{return result("failed",message)}
        if entry.action.changesChat {
            try? await Task.sleep(nanoseconds:180_000_000)
            guard !isLocked,NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else{return result("uncertain","The command was requested, but the foreground changed before its destination could be checked.")}
            // AXPress may acknowledge before the new page replaces its header.
            // Never hand the previous conversation back as the new destination.
            var current=RemoteActionCatalog.changedChat(previousID:previousID,candidate:verifiedActiveClaudeChat())
            if current==nil {
                try? await Task.sleep(nanoseconds:180_000_000)
                if !isLocked,NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier {
                    current=RemoteActionCatalog.changedChat(previousID:previousID,candidate:verifiedActiveClaudeChat())
                }
            }
            return result("confirmed",message + (current==nil ? ". Choose a named chat before sending from the phone.":"."),current)
        }
        return result("confirmed",message+".",target)
    }
    func execute(_ command:RemoteCommand) async -> RemoteReceipt {
        func result(_ state:String,_ message:String)->RemoteReceipt {RemoteReceipt(id:command.id,status:state,message:message)}
        guard let store else{return result("failed","Remote storage unavailable.")}
        if RemoteNavigationLease.commands.contains(command.action) {
            let previousID=command.provider=="claude" && command.action=="menuSelect" ? verifiedActiveClaudeChat()?.id:nil
            let outcome=await menuNavigation.perform(action:command.action,session:command.navigationSession ?? "",provider:command.provider,chatID:command.chatID,generation:command.generation,isCurrent:{self.navigationContextIsCurrent(provider:command.provider,chatID:command.chatID)})
            // A search/menu selection can navigate. Never report the old phone
            // route as current; re-observe a unique native Claude header.
            let candidate=command.provider=="claude" && command.action=="menuSelect" && !isLocked ? verifiedActiveClaudeChat():nil
            // An open same-context submenu is safe to keep navigating. Once it
            // closes, require a different verified chat before adopting a route;
            // the old header may be waiting for an async search-result transition.
            let active=RemoteActionCatalog.menuSelectedChat(previousID:previousID,requestedID:command.chatID,candidate:candidate,succeeded:outcome.success,stillOpen:outcome.state.active,selectedFile:outcome.selectionWasFile)
            return RemoteReceipt(id:command.id,status:outcome.success ? "confirmed":"failed",message:outcome.message,activeChat:active,navigation:outcome.state)
        }
        menuNavigation.invalidate()
        if command.action=="openArtifact" {
            guard let item=store.archive.artifacts.first(where:{$0.id==command.artifactID && $0.provider==command.provider && ($0.chatID.isEmpty || $0.chatID==command.chatID)}) else{return result("failed","Artifact does not belong to this target.")}
            guard !isLocked else{return result("failed","Unlock this Mac to open an artifact.")}
            let url=item.url.flatMap(URL.init(string:)) ?? store.directory.appendingPathComponent("exports").appendingPathComponent(item.id)
            if item.url==nil {
                let app=URL(fileURLWithPath:["image","pdf"].contains(item.kind) ? "/System/Applications/Preview.app":"/System/Applications/TextEdit.app")
                do { _ = try await NSWorkspace.shared.open([url],withApplicationAt:app,configuration:NSWorkspace.OpenConfiguration());return result("confirmed","Opened artifact on this Mac.") }
                catch{return result("failed","The Mac could not open this exported artifact.")}
            }
            return NSWorkspace.shared.open(url) ? result("confirmed","Opened artifact on this Mac."):result("failed","The Mac could not open this artifact.")
        }
        if command.action=="launchApp" {return await launchApp(command)}
        if command.action=="restartService" {return await restartCodexService(command)}
        if command.provider=="muse" {return await executeMuse(command)}
        if command.provider=="codex" {
            if command.action=="sendPrompt" {
                let home=FileManager.default.homeDirectoryForCurrentUser
                guard enabled,!isLocked,CodexQueuePolicy.usesDefaultHome(environment:ProcessInfo.processInfo.environment,home:home),
                      let application=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.openai.codex"),
                      let executable=CodexQueuePolicy.executable(in:application) else{return result("failed","Unlock this Mac and use the installed Codex app with its default account storage before queueing a prompt.")}
                let records=await loadCodexChats(force:true)
                guard enabled,!isLocked,let id=command.chatID,let text=command.text,
                      let arguments=CodexQueuePolicy.arguments(threadID:id,text:text,inventoryIDs:Set(records.map(\.id))) else{return result("failed","This exact Codex chat is not in the current account’s fresh inventory, or the prompt is invalid. Nothing was queued.")}
                let outcome=await CodexQueueProcess.enqueue(executable:executable,arguments:arguments,home:home,threadID:id)
                return result(outcome.status,outcome.message)
            }
            if CodexNativeActions.descriptors.contains(where:{$0.id==command.action}) {
                let requested=await CodexNativeActions.perform(command.action,isCurrent:{self.enabled && !self.isLocked})
                return result(requested.requested ? "confirmed":"failed",requested.message)
            }
            guard command.action=="openChat" else{return result("failed","This Codex action is unavailable. Chat selection, phone Send, and available Mac menu controls are supported; Stop and native live voice are not connected yet.")}
            guard !isLocked,let application=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.openai.codex") else{return result("failed","Unlock this Mac and install Codex before opening a chat.")}
            let records=await loadCodexChats(force:true)
            guard !isLocked,let id=command.chatID,let target=records.first(where:{$0.id==id}),
                  let url=RemoteCodexNavigation.existingChatURL(id:id,inventoryIDs:Set(records.map(\.id))) else{return result("failed","This Codex chat is not in the current account's available inventory. Refresh its mapping; no chat was opened.")}
            let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
            do {
                _ = try await NSWorkspace.shared.open([url],withApplicationAt:application,configuration:configuration)
                return result("confirmed","Asked Codex to open \(target.title).")
            } catch {return result("failed","macOS could not open the existing Codex chat.")}
        }
        guard command.provider=="claude" else{return result("failed","Existing-chat control is not verified for this provider. No action was sent.")}
        guard !isLocked,AXIsProcessTrusted() else{return result("failed","Unlock the Mac and enable Accessibility for Agent Micro Controller first.")}
        guard command.action != "nativeVoice" else{return result("failed","Two-way native phone voice is not available yet.")}
        if let entry=RemoteActionCatalog.claudeEntry(command.action) {return await executeClaudeShortcut(command,entry:entry)}
        guard let id=command.chatID else{return result("failed","Choose a chat first.")}
        // Saved/cached labels only resolve the opaque ID. Fresh targeted AX
        // checks below still authorize every navigation, Send, and Stop.
        let target=resolveClaudeTarget(id)
        guard let target else{return result("failed","Chat is missing or ambiguous. Show Claude’s Code sidebar and refresh.")}
        guard !RemoteClaudeLookup.isAmbiguous(sidebarDestinationCount:access.targetSnapshot(target.title).destinationCount) else{return result("failed","More than one sidebar chat has this title. Rename one before using its remote key.")}
        guard let claudePID=NSRunningApplication.runningApplications(withBundleIdentifier:access.bundle).first?.processIdentifier else{return result("failed","Open Claude first.")}
        func selectionContextOK()->Bool {
            self.enabled && !self.isLocked && AXIsProcessTrusted() &&
            NSRunningApplication.runningApplications(withBundleIdentifier:self.access.bundle).first?.processIdentifier==claudePID
        }
        let opened=await access.select(target.title,contextIsCurrent:selectionContextOK)
        guard opened.hasPrefix("Opened ") else{return result("failed",opened)}
        guard selectionContextOK() else{return result("failed","Claude navigation context changed before confirmation. No Send or Stop action was sent.")}
        let confirmation=await access.confirmedTarget(target.title,processIdentifier:claudePID,contextIsCurrent:selectionContextOK)
        guard case .ready(let selected)=confirmation else {
            if case .ambiguous=confirmation {return result("failed","This title resolves to multiple sidebar chats. No action was sent.")}
            return result("failed","Claude navigation could not be confirmed. Select the chat again; no Send or Stop action was sent.")
        }
        if command.action=="openChat" {return result("confirmed","Opened \(target.title).")}
        // Sending/stopping requires a fresh unique sidebar destination as well
        // as the active header. A cached label only allowed us to navigate.
        if selected.destinationCount==0 {
            let show=access.readSnapshot {access.nodes().filter{access.text($0)=="Show sidebar" && access.value($0,kAXRoleAttribute) as? String==kAXButtonRole}}
            if show.count==1,let app=NSRunningApplication.runningApplications(withBundleIdentifier:access.bundle).first {
                _=await access.navigationClick(show[0],app:app,contextIsCurrent:{!self.isLocked && self.access.current(target.title)})
                try? await Task.sleep(nanoseconds:250_000_000)
            }
        }
        let actionable=access.targetSnapshot(target.title)
        guard actionable.destinationCount==1,actionable.isCurrent else{return result("failed","The active chat could not be matched to one sidebar destination. Nothing was sent.")}
        if command.action=="stop" {
            let all=access.nodes(),buttons=all.filter{access.text($0)=="Stop" && access.value($0,kAXRoleAttribute) as? String==kAXButtonRole}
            guard buttons.count==1,let app=NSRunningApplication.runningApplications(withBundleIdentifier:access.bundle).first else{return result("failed","No response is running in this chat.")}
            guard await access.navigationClick(buttons[0],app:app,contextIsCurrent:{!self.isLocked && self.access.current(target.title)}) else{return result("failed","Stop control is unavailable or the chat changed.")}
            for _ in 0..<12 {try? await Task.sleep(nanoseconds:100_000_000);if access.current(target.title),!access.nodes().contains(where:{access.text($0)=="Stop" && access.value($0,kAXRoleAttribute) as? String==kAXButtonRole}) {return result("confirmed","Response stopped.")}}
            return result("uncertain","Stop was requested but could not be confirmed.")
        }
        guard command.action=="sendPrompt",let prompt=command.text else{return result("failed","Unsupported action.")}
        func composer()->AXUIElement? {
            let fields=access.nodes().filter{access.value($0,kAXRoleAttribute) as? String==kAXTextAreaRole && access.value($0,kAXDescriptionAttribute) as? String=="Prompt"}
            return fields.count==1 ? fields[0]:nil
        }
        // Wait for hands to be off the keys so nothing typed on the Mac lands in the draft.
        guard await MacInput.waitForQuiet() else{return result("failed","\(MacInput.busyMessage); nothing was inserted.")}
        guard let field=composer() else{return result("failed","Send could not find one Claude Prompt composer in this chat. Nothing was inserted or replaced.")}
        guard let existing=access.value(field,kAXValueAttribute) as? String else{return result("failed","Send could not read the Mac composer to check for an existing draft. Nothing was inserted or replaced.")}
        guard RemoteComposerPolicy.isBlank(existing) else{return result("failed","The Mac composer already contains a draft. Clear it on the Mac first; nothing was replaced or sent.")}
        var settable=DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(field,kAXValueAttribute as CFString,&settable) == .success,settable.boolValue else{return result("failed","Claude does not expose a writable composer in this view. No text was inserted.")}
        guard AXUIElementSetAttributeValue(field,kAXValueAttribute as CFString,prompt as CFString) == .success else{return result("failed","Claude did not accept the draft. Nothing was sent.")}
        try? await Task.sleep(nanoseconds:150_000_000)
        guard !isLocked,access.current(target.title),let fresh=composer(),RemoteComposerPolicy.matchesInserted(access.value(fresh,kAXValueAttribute) as? String,prompt:prompt) else{return result("uncertain","The draft could not be verified. Inspect the Mac composer before retrying.")}
        let buttons=access.nodes().filter{access.text($0)=="Send" && access.value($0,kAXRoleAttribute) as? String==kAXButtonRole}
        guard buttons.count==1,let app=NSRunningApplication.runningApplications(withBundleIdentifier:access.bundle).first else{return result("failed","Draft is on the Mac, but no unique Send control is available.")}
        let sent=await access.navigationClick(buttons[0],app:app,contextIsCurrent:{
            guard !self.isLocked,self.access.current(target.title),let field=composer() else{return false}
            return RemoteComposerPolicy.matchesInserted(self.access.value(field,kAXValueAttribute) as? String,prompt:prompt)
        })
        guard sent else{return result("failed","Draft remains on the Mac; Send was not clicked because its target changed or was unavailable.")}
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds:150_000_000)
            // One fresh synchronous read per tick. The snapshot ends before
            // the next await, and its three checks must agree to confirm Send.
            let observation=access.readSnapshot { ()->RemoteDeliveryObservation in
                let all=access.nodes()
                let fields=all.filter{access.value($0,kAXRoleAttribute) as? String==kAXTextAreaRole && access.value($0,kAXDescriptionAttribute) as? String=="Prompt"}
                let blank=fields.count==1 && RemoteComposerPolicy.isBlank(access.value(fields[0],kAXValueAttribute) as? String)
                return RemoteDeliveryObservation(
                    matchingHeaderCount:all.filter{access.text($0)==target.title+", rename session"}.count,
                    composerCount:fields.count,composerIsBlank:blank,
                    hasStopControl:all.contains{access.text($0)=="Stop" && access.value($0,kAXRoleAttribute) as? String==kAXButtonRole})
            }
            guard observation.isCurrent else{return result("uncertain","The active chat changed before delivery could be verified.")}
            if observation.confirmsDelivery {return result("confirmed","Prompt sent; Claude is responding.")}
        }
        return result("uncertain","Send was clicked once, but response start could not be confirmed. Check the chat before sending again.")
    }
    func registerFile(provider:String,chatID:String) {
        guard let store else{return}
        let panel=NSOpenPanel();panel.allowsMultipleSelection=false;panel.canChooseDirectories=false
        guard panel.runModal() == .OK,let source=panel.url else{return}
        let types:[String:(String,String)]=["png":("image","image/png"),"jpg":("image","image/jpeg"),"jpeg":("image","image/jpeg"),"heic":("image","image/heic"),"pdf":("pdf","application/pdf"),"txt":("text","text/plain; charset=utf-8"),"md":("text","text/plain; charset=utf-8"),"json":("text","text/plain; charset=utf-8"),"swift":("text","text/plain; charset=utf-8")]
        guard let type=types[source.pathExtension.lowercased()] else{lastResult="Choose an image, PDF, text, Markdown, JSON, or Swift file.";return}
        do {
            let metadata=try source.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard metadata.isRegularFile==true,metadata.isSymbolicLink != true,(metadata.fileSize ?? Int.max)<=20_000_000 else{lastResult="Choose a regular file smaller than 20 MB.";return}
            let id=UUID().uuidString,exports=store.directory.appendingPathComponent("exports",isDirectory:true)
            try FileManager.default.createDirectory(at:exports,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let destination=exports.appendingPathComponent(id)
            try FileManager.default.copyItem(at:source,to:destination);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
            try store.add(RemoteArtifact(id:id,title:source.lastPathComponent,kind:type.0,url:nil,mimeType:type.1,hostID:store.hostID,provider:provider,chatID:chatID));artifacts=store.archive.artifacts;lastResult="Artifact copied to the phone shelf."
        } catch{lastResult="Could not register this artifact."}
    }
    func registerURL(_ raw:String,title:String,provider:String,chatID:String) {
        guard let store,RemotePolicy.providers.contains(provider),let url=URLComponents(string:raw),url.scheme=="https",let host=url.host,!host.isEmpty,url.user==nil,url.password==nil,!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{lastResult="Enter a title and an HTTPS link without embedded credentials.";return}
        do {try store.add(RemoteArtifact(id:UUID().uuidString,title:title,kind:"web",url:url.url?.absoluteString,mimeType:nil,hostID:store.hostID,provider:provider,chatID:chatID));artifacts=store.archive.artifacts;lastResult="Link added. Provider sign-in may be required on the phone."} catch{lastResult="Could not save the artifact link."}
    }
    func removeArtifact(_ id:String) {do{try store?.removeArtifact(id);artifacts=store?.archive.artifacts ?? []}catch{lastResult="Could not remove artifact."}}
}

struct RemotePairingView:View {
    @ObservedObject var bridge:GenesisRemoteBridge
    @State private var provider="claude"
    @State private var chatID=""
    @State private var linkTitle=""
    @State private var linkURL=""
    @State private var revoking:PairedDevice?
    @State private var retiringLegacy=false
    var body:some View {
        ScrollView {VStack(alignment:.leading,spacing:18) {
            Text("Agent Micro Controller on iPhone").font(.largeTitle.bold())
            Text("Pair your phone to this Mac over your private Tailscale network.").foregroundStyle(.secondary)
            Toggle("Enable private remote access",isOn:Binding(get:{bridge.enabled},set:bridge.setEnabled))
            Label(bridge.serviceStatus,systemImage:"network")
            TextField("https://your-mac.tailnet.ts.net:8451",text:$bridge.baseURL).textFieldStyle(.roundedBorder).onSubmit{bridge.saveAddress()}
            HStack(alignment:.top,spacing:20) {
                if let image=bridge.qrImage {Image(nsImage:image).interpolation(.none).resizable().frame(width:220,height:220).padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius:14))}
                VStack(alignment:.leading,spacing:12) {
                    Text("Scan from Agent Micro Controller on your iPhone").font(.headline)
                    Text("This code pairs one device, once, and stops working after ten minutes. Scanning it gives that device control of the apps on this Mac, so show it only to your own phone or tablet.").font(.callout)
                    Text("The HTTPS endpoint must be connected to this Mac’s local service on port 18765. Tailscale reachability is checked during pairing.").font(.caption).foregroundStyle(.secondary)
                    Button("Copy pairing link") {if let link=bridge.pairingLink {NSPasteboard.general.clearContents();NSPasteboard.general.setString(link.absoluteString,forType:.string)}}.disabled(bridge.pairingLink==nil)
                    Button("Save address"){bridge.saveAddress()}
                }
            }
            Divider()
            Text("Phone artifact shelf").font(.title2.bold())
            Text("Add exported documents/images or an HTTPS link to an interactive artifact. These items are separate from your original files.").foregroundStyle(.secondary)
            HStack {
                Picker("Provider",selection:$provider){Text("Claude").tag("claude");Text("Codex").tag("codex");Text("Muse").tag("muse")}.frame(width:190).onChange(of:provider){chatID=""}
                Picker("Chat",selection:$chatID){Text("All chats for this provider").tag("");if provider=="claude" {ForEach(bridge.chats,id:\.id){Text($0.title).tag($0.id)}}}
                Button("Refresh chats"){bridge.refreshChats()}
            }
            Button("Add exported file…"){bridge.registerFile(provider:provider,chatID:chatID)}
            HStack {TextField("Artifact title",text:$linkTitle);TextField("https://…",text:$linkURL);Button("Add link"){bridge.registerURL(linkURL,title:linkTitle,provider:provider,chatID:chatID)}}.textFieldStyle(.roundedBorder)
            ForEach(bridge.artifacts.filter{$0.provider==provider},id:\.id) { item in HStack {Image(systemName:item.kind=="web" ? "globe":"doc");Text(item.title);Spacer();Button("Remove"){bridge.removeArtifact(item.id)}}.padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8)) }
            Divider()
            Text(bridge.lastResult).font(.callout).textSelection(.enabled)
            Divider()
            Text("Paired devices").font(.title3.bold())
            Text("Each device has its own secret. Revoking one cuts off that device only; pair it again to restore it.").font(.caption).foregroundStyle(.secondary)
            if bridge.devices.isEmpty {Text("No devices have paired with the new codes yet.").font(.callout).foregroundStyle(.secondary)}
            ForEach(bridge.devices) { device in
                HStack(spacing:10) {
                    Image(systemName:"iphone")
                    VStack(alignment:.leading,spacing:2) {
                        Text(device.name).font(.callout.weight(.medium))
                        Text("Paired \(device.pairedAt.formatted(date:.abbreviated,time:.shortened))"+(device.lastSeenAt.map{" · last seen \($0.formatted(date:.abbreviated,time:.shortened))"} ?? " · not seen yet")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke",role:.destructive){revoking=device}
                }.padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            }
            if bridge.legacySecretAccepted {
                HStack(spacing:10) {
                    Image(systemName:"key")
                    VStack(alignment:.leading,spacing:2) {
                        Text("Devices paired before version 0.7").font(.callout.weight(.medium))
                        Text("They share one older secret and cannot be told apart. The Genesis G2 glasses bridge on this Mac uses it too, so keep accepting it if you use the glasses.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop accepting…",role:.destructive){retiringLegacy=true}
                }.padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            }
            Divider()
            HStack {
                Text("Check this Mac").font(.title3.bold())
                Spacer()
                Text("Version \(GenesisRemoteBridge.companionVersion)").font(.caption).foregroundStyle(.secondary)
                Button(bridge.checking ? "Checking…":"Run check"){Task{_ = await bridge.selfCheck()}}.disabled(bridge.checking)
            }
            Text("Looks for each control the phone relies on in Claude, Muse and Codex. Nothing is sent or changed, except that Muse’s chat list is shown so its chats can be counted.").font(.caption).foregroundStyle(.secondary)
            if let report=bridge.lastSelfCheck {
                Text(report.summary).font(.callout.weight(.semibold))
                ForEach(Array(report.items.enumerated()),id:\.offset) { _,item in
                    HStack(alignment:.firstTextBaseline,spacing:8) {
                        Image(systemName:item.ok ? "checkmark.circle.fill":"exclamationmark.triangle.fill").foregroundStyle(item.ok ? .green:.orange)
                        Text("\(item.provider.capitalized) · \(item.name)").font(.callout.weight(.medium)).frame(width:210,alignment:.leading)
                        Text(item.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer(minLength:0)
                    }
                }
            }
            Divider()
            Text("Recent activity").font(.title3.bold())
            Text("What each phone command was and how it ended. Message text is never recorded.").font(.caption).foregroundStyle(.secondary)
            if bridge.recentActivity.isEmpty {Text("No commands yet.").font(.callout).foregroundStyle(.secondary)}
            ForEach(Array(bridge.recentActivity.enumerated()),id:\.offset) { _,entry in
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    Text(entry.time,format:.dateTime.month(.abbreviated).day().hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width:128,alignment:.leading)
                    Text("\(entry.provider.capitalized) · \(entry.action)").font(.callout.weight(.medium)).frame(width:190,alignment:.leading)
                    Text(entry.status).font(.caption.weight(.semibold)).foregroundStyle(entry.status=="confirmed" || entry.status=="queued" ? .green:.orange).frame(width:74,alignment:.leading)
                    Text(entry.message).font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength:0)
                }
            }
            Text("Claude desktop controls require Claude to be open, an unlocked Mac, and Accessibility. Codex supports saved-chat selection, phone Send, and available Mac menu controls. Stop and native live voice are not connected for Codex; native live voice is also unavailable for Claude. Muse needs to be open: its chats, Send, New side chat and Call are connected, and side chats that share a title are left out.").font(.caption).foregroundStyle(.secondary)
        }.padding(28)}.frame(minWidth:740,minHeight:640).task{bridge.loadActivity()}
            // A code lasts ten minutes; replace it a little before that while the window is open.
            .task{while !Task.isCancelled {bridge.refreshPairingCode();try? await Task.sleep(nanoseconds:540_000_000_000)}}
            .confirmationDialog("Revoke \(revoking?.name ?? "this device")?",isPresented:Binding(get:{revoking != nil},set:{if !$0 {revoking=nil}}),titleVisibility:.visible) {
                Button("Revoke",role:.destructive){if let device=revoking {bridge.revokeDevice(device.id)};revoking=nil}
                Button("Cancel",role:.cancel){revoking=nil}
            } message:{Text("It will stop working at once and show “Pair this Mac”. Scan a new code to pair it again.")}
            .confirmationDialog("Stop accepting the older shared secret?",isPresented:$retiringLegacy,titleVisibility:.visible) {
                Button("Stop accepting it",role:.destructive){bridge.stopAcceptingLegacySecret()}
                Button("Cancel",role:.cancel){}
            } message:{Text("Every phone and tablet that paired before version 0.7 will stop working until it scans a new code. So will anything on this Mac that reads the secret from its file, such as the Genesis G2 glasses bridge. This cannot be undone.")}
    }
}
