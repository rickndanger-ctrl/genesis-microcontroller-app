import Foundation

@main struct RemoteHostTests {
    static var checks=0
    static func expect(_ condition:@autoclosure() throws ->Bool,_ note:String) {
        checks += 1
        guard try! condition() else{fatalError("FAIL: "+note)}
    }
    static func rejects(_ note:String,_ block:() throws -> Void) {
        do{try block();fatalError("FAIL did not reject: "+note)}catch{checks += 1}
    }
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("genesis-remote-test-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=try RemoteStore(directory:root)
        expect(UUID(uuidString:store.hostID) != nil,"host identity")
        expect(store.token.count>=43,"random token size")
        expect(RemotePolicy.equalToken("Bearer "+store.token,"Bearer "+store.token),"auth exact match")
        expect(!RemotePolicy.equalToken("Bearer wrong","Bearer "+store.token),"auth mismatch")
        let profile=try store.profile("claude")
        expect(profile.slots.count==6,"six slots")
        let updated=try store.update(profile)
        expect(updated.revision==2,"mapping revision")
        rejects("stale mapping write") {_ = try store.update(profile)}
        var duplicate=updated;duplicate.slots[5].index=0
        rejects("duplicate slot identity"){_ = try store.update(duplicate)}
        var unsupported=updated;unsupported.slots[0]=RemoteSlot(index:0,kind:"action",title:"Delete",targetID:"delete")
        rejects("unapproved action mapping"){_ = try store.update(unsupported)}
        let command=RemoteCommand(id:UUID().uuidString,hostID:store.hostID,provider:"claude",chatID:"claude-fixture",action:"sendPrompt",text:"private fixture prompt",artifactID:nil,generation:1)
        try RemotePolicy.validate(command,hostID:store.hostID)
        rejects("wrong host identity"){try RemotePolicy.validate(command,hostID:UUID().uuidString)}
        var empty=command;empty.text=" "
        rejects("empty prompt"){try RemotePolicy.validate(empty,hostID:store.hostID)}
        var absent=command;absent.chatID=nil
        rejects("missing target"){try RemotePolicy.validate(absent,hostID:store.hostID)}
        expect(try store.previous(command)==nil,"new command")
        try store.begin(command)
        expect(try store.previous(command)?.status=="pending","persist before action")
        var altered=command;altered.text="different"
        rejects("ID reused for different payload"){_ = try store.previous(altered)}
        let restarted=try RemoteStore(directory:root)
        expect(restarted.hostID==store.hostID && restarted.token==store.token,"persistent identity and pairing")
        expect(try restarted.previous(command)?.status=="uncertain","restart never replays pending send")
        try restarted.finish(RemoteReceipt(id:command.id,status:"confirmed",message:"Confirmed fixture"))
        expect(try restarted.previous(command)?.status=="confirmed","duplicate returns completed receipt")
        let saved=try String(contentsOf:root.appendingPathComponent("state.json"),encoding:.utf8)
        expect(!saved.contains("private fixture prompt"),"no prompt in durable command ledger")
        expect(!saved.contains(store.token),"token not in state or receipts")
        let attributes=try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("pairing-token").path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue==0o600,"private credential permissions")
        let request="POST /v1/commands HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        expect(try RemoteHTTPRequest.parse(Data(request.utf8))?.body==Data("{}".utf8),"JSON HTTP parse")
        expect(try RemoteHTTPRequest.parse(Data(request.dropLast().utf8))==nil,"partial body waits")
        rejects("request smuggling duplicate lengths"){_ = try RemoteHTTPRequest.parse(Data("POST /v1/commands HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 0\r\n\r\n{}".utf8))}
        rejects("transfer encoding rejected"){_ = try RemoteHTTPRequest.parse(Data("POST /v1/commands HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))}
        rejects("browser origin rejected"){_ = try RemoteHTTPRequest.parse(Data("GET /v1/status HTTP/1.1\r\nOrigin: https://untrusted.example\r\n\r\n".utf8))}
        rejects("oversized body"){_ = try RemoteHTTPRequest.parse(Data("POST /v1/commands HTTP/1.1\r\nContent-Length: 200000\r\n\r\n".utf8))}
        rejects("extra pipeline bytes"){_ = try RemoteHTTPRequest.parse(Data((request+"GET /v1/status HTTP/1.1\r\n\r\n").utf8))}
        rejects("absolute target rejected"){_ = try RemoteHTTPRequest.parse(Data("GET http://other/v1/status HTTP/1.1\r\n\r\n".utf8))}
        expect(RemotePolicy.chatID("claude","same") != RemotePolicy.chatID("muse","same"),"provider-scoped identifiers")
        let launchIDs=["newChat","openSettings","openSkills"],nativeIDs=["newChat","openSettings","openSkills","goBack","toggleTerminal"]
        func caps(_ installed:Bool=true,_ running:Bool=false,_ unlocked:Bool=true,_ ax:Bool=false,_ inventory:Bool=true)->Set<String> {
            Set(RemoteCodexAvailability.capabilities(installed:installed,running:running,unlocked:unlocked,accessibility:ax,inventoryAvailable:inventory,launchIDs:launchIDs,nativeIDs:nativeIDs))
        }
        expect(caps()==Set(["artifacts","openChat"]+launchIDs),"closed Codex exposes fixed launch controls without Accessibility")
        expect(caps(true,false,true,false,false)==Set(["artifacts"]+launchIDs),"fixed launch controls do not depend on saved-chat inventory")
        expect(caps(true,true,true,false)==caps(),"running without Accessibility cannot expose native menu inputs")
        expect(caps(true,true,true,true)==Set(["artifacts","openChat","menuNavigation"]+nativeIDs),"native menus need running app plus Accessibility")
        expect(caps(false,true,true,true)==Set(["artifacts"]),"absent app cannot receive launch or native actions")
        expect(caps(true,true,false,true)==Set(["artifacts"]),"locked Mac cannot advertise launch or menu actions")
        let allCaps=RemoteCodexAvailability.capabilities(installed:true,running:true,unlocked:true,accessibility:true,inventoryAvailable:true,launchIDs:launchIDs,nativeIDs:nativeIDs)
        expect(allCaps.count==Set(allCaps).count,"overlapping native and launch IDs advertise only once")
        expect(!allCaps.contains("sendPrompt") && !allCaps.contains("nativeVoice"),"launch availability never enables unverified Send or voice")
        let queueCaps=RemoteCodexAvailability.capabilities(installed:true,running:false,unlocked:true,accessibility:false,inventoryAvailable:true,launchIDs:launchIDs,nativeIDs:nativeIDs,queueAvailable:true)
        expect(queueCaps.contains("sendPrompt"),"official queue route can accept exact-chat text without desktop UI automation")
        expect(!queueCaps.contains("nativeVoice") && !queueCaps.contains("stop"),"queue support does not imply voice or stop support")
        expect(!RemoteCodexAvailability.capabilities(installed:true,running:true,unlocked:true,accessibility:true,inventoryAvailable:false,launchIDs:launchIDs,nativeIDs:nativeIDs,queueAvailable:true).contains("sendPrompt"),"queue needs current-account inventory readiness")
        expect(!RemoteCodexAvailability.capabilities(installed:true,running:true,unlocked:false,accessibility:true,inventoryAvailable:true,launchIDs:launchIDs,nativeIDs:nativeIDs,queueAvailable:true).contains("sendPrompt"),"locked Mac cannot advertise queue Send")
        let codexQueueCommand=RemoteCommand(id:UUID().uuidString,hostID:store.hostID,provider:"codex",chatID:"01a130bc-ebfa-7c92-b84e-5d66a3bc7979",action:"sendPrompt",text:"fixture queue text",artifactID:nil,generation:4)
        try store.begin(codexQueueCommand)
        try store.finish(RemoteReceipt(id:codexQueueCommand.id,status:"queued",message:"Queued for the exact chat; delivery unconfirmed."))
        expect(try store.previous(codexQueueCommand)?.status=="queued","duplicate queue command returns stored receipt instead of reenqueuing")
        expect(try RemoteStore(directory:root).previous(codexQueueCommand)?.status=="queued","queued acceptance survives app restart without replay")
        let codexID="01a130bc-ebfa-7c92-b84e-5d66a3bc7979"
        let codexURL=RemoteCodexNavigation.existingChatURL(id:codexID,inventoryIDs:[codexID])
        expect(codexURL?.absoluteString=="codex://threads/"+codexID,"Codex uses the supported existing-chat deep link")
        expect(codexURL?.query==nil && codexURL?.fragment==nil,"Codex navigation cannot carry draft or command parameters")
        expect(RemoteCodexNavigation.existingChatURL(id:codexID,inventoryIDs:[])==nil,"unknown or other-account chat cannot open")
        expect(RemoteCodexNavigation.existingChatURL(id:"new",inventoryIDs:["new"])==nil,"new chat creation is not a controller destination")
        let injected=codexID+"?prompt=unrequested"
        expect(RemoteCodexNavigation.existingChatURL(id:injected,inventoryIDs:[injected])==nil,"query injection fails even if listed")
        expect(RemoteCodexNavigation.existingChatURL(id:"https://example.com",inventoryIDs:["https://example.com"])==nil,"arbitrary URL cannot become a Codex destination")
        expect(RemoteCodexNavigation.existingChatURL(id:codexID+"/new",inventoryIDs:[codexID+"/new"])==nil,"extra path components cannot create a new chat")
        expect(!RemoteComposerPolicy.isBlank(nil),"unreadable composer is never assumed blank")
        expect(RemoteComposerPolicy.isBlank(""),"empty composer is blank")
        expect(RemoteComposerPolicy.isBlank(" \t\r\n"),"editor whitespace and newline are blank")
        expect(RemoteComposerPolicy.isBlank("\u{00a0}\u{2003}\u{2028}"),"Unicode whitespace-only editor is blank")
        expect(!RemoteComposerPolicy.isBlank(" \nExisting draft\n"),"real draft with surrounding whitespace is protected")
        expect(!RemoteComposerPolicy.isBlank("\u{200b}"),"zero-width non-whitespace text is protected")
        expect(RemoteComposerPolicy.matchesInserted("a  b\nc",prompt:"a  b\nc"),"inserted prompt preserves internal whitespace exactly")
        expect(!RemoteComposerPolicy.matchesInserted("a b\nc",prompt:"a  b\nc"),"changed internal whitespace fails verification")
        expect(!RemoteComposerPolicy.matchesInserted(nil,prompt:"hello"),"unreadable inserted value fails verification")
        expect(!RemoteComposerPolicy.matchesInserted("hello\n",prompt:"hello"),"unexpected trailing newline is not silently normalized")
        expect(RemoteComposerPolicy.matchesInserted("hello\n",prompt:"hello\n"),"intentional prompt newline is preserved")
        let delivery=RemoteDeliveryObservation(matchingHeaderCount:1,composerCount:1,composerIsBlank:true,hasStopControl:true)
        expect(delivery.confirmsDelivery,"current unique blank composer and response activity confirm delivery")
        expect(!RemoteDeliveryObservation(matchingHeaderCount:0,composerCount:1,composerIsBlank:true,hasStopControl:true).confirmsDelivery,"different chat never confirms the original Send")
        expect(!RemoteDeliveryObservation(matchingHeaderCount:2,composerCount:1,composerIsBlank:true,hasStopControl:true).confirmsDelivery,"ambiguous current header does not confirm Send")
        expect(!RemoteDeliveryObservation(matchingHeaderCount:1,composerCount:0,composerIsBlank:true,hasStopControl:true).confirmsDelivery,"missing composer does not confirm Send")
        expect(!RemoteDeliveryObservation(matchingHeaderCount:1,composerCount:2,composerIsBlank:true,hasStopControl:true).confirmsDelivery,"multiple composers do not confirm Send")
        expect(!RemoteDeliveryObservation(matchingHeaderCount:1,composerCount:1,composerIsBlank:false,hasStopControl:true).confirmsDelivery,"remaining or unreadable draft does not confirm Send")
        expect(!RemoteDeliveryObservation(matchingHeaderCount:1,composerCount:1,composerIsBlank:true,hasStopControl:false).confirmsDelivery,"blank composer without response activity does not confirm Send")
        let title="Fixture setup",statuses=["Working","Idle"]
        expect(RemoteClaudeLookup.isSidebarCandidate(label:"Idle "+title,title:title,inToolbar:false,hasMatchingRowMenu:true,statuses:statuses),"status-prefixed sidebar row remains selectable")
        expect(!RemoteClaudeLookup.isSidebarCandidate(label:title,title:title,inToolbar:true,hasMatchingRowMenu:true,statuses:statuses),"primary toolbar is not a second destination")
        expect(!RemoteClaudeLookup.isSidebarCandidate(label:"More options for "+title,title:title,inToolbar:false,hasMatchingRowMenu:false,statuses:statuses),"menu label alone is not a destination")
        expect(!RemoteClaudeLookup.isSidebarCandidate(label:title+", rename session",title:title,inToolbar:true,hasMatchingRowMenu:true,statuses:statuses),"active rename header cannot duplicate sidebar")
        expect(RemoteClaudeLookup.isSidebarCandidate(label:"Fork "+title,title:title,inToolbar:false,hasMatchingRowMenu:true,statuses:statuses),"fork row with matching menu is selectable")
        expect(!RemoteClaudeLookup.isSidebarCandidate(label:"Fork "+title,title:title,inToolbar:false,hasMatchingRowMenu:false,statuses:statuses),"unrelated suffix is rejected")
        expect(RemoteClaudeLookup.isSidebarCandidate(label:title+" Unread response",title:title,inToolbar:false,hasMatchingRowMenu:true,statuses:statuses,hasExactTitleChild:true),"status suffix works with exact title child and nested row menu")
        expect(!RemoteClaudeLookup.isSidebarCandidate(label:title+" Unknown decoration",title:title,inToolbar:false,hasMatchingRowMenu:true,statuses:statuses),"unknown decoration without exact title child is rejected")
        expect(!RemoteClaudeLookup.isSidebarCandidate(label:title+" Unread response",title:title,inToolbar:false,hasMatchingRowMenu:false,statuses:statuses,hasExactTitleChild:true),"title child without matching row menu is rejected")
        expect(!RemoteClaudeLookup.isSidebarCandidate(label:title+" Unread response",title:title,inToolbar:true,hasMatchingRowMenu:true,statuses:statuses,hasExactTitleChild:true),"decorated toolbar button is never a sidebar destination")
        expect(RemoteClaudeLookup.isSidebarCandidate(label:title,title:title,inToolbar:false,hasMatchingRowMenu:true,statuses:statuses),"plain title with nested row menu remains a destination")
        let liveStatuses=["Awaiting input","Something went wrong","Needs input","Working","Running","Idle","Unread"]
        for suffix in liveStatuses+["Unread response","Cloud"] {
            expect(RemoteClaudeLookup.isSidebarCandidate(label:title+" "+suffix,title:title,inToolbar:false,hasMatchingRowMenu:true,statuses:liveStatuses),"exact observed suffix works without text descendants: "+suffix)
            expect(!RemoteClaudeLookup.isSidebarCandidate(label:title+" "+suffix,title:title,inToolbar:false,hasMatchingRowMenu:false,statuses:liveStatuses),"status suffix alone cannot identify a destination: "+suffix)
        }
        expect(!RemoteClaudeLookup.isSidebarCandidate(label:title+" Running",title:title,inToolbar:true,hasMatchingRowMenu:true,statuses:liveStatuses),"running primary toolbar is excluded")
        expect(!RemoteClaudeLookup.isSidebarCandidate(label:title+" Running copy",title:title,inToolbar:false,hasMatchingRowMenu:true,statuses:liveStatuses),"known suffix followed by other text is rejected")
        expect(!RemoteClaudeLookup.isSidebarCandidate(label:"Other "+title+" Running",title:title,inToolbar:false,hasMatchingRowMenu:true,statuses:liveStatuses),"containing the title with a status is insufficient")
        expect(!RemoteClaudeLookup.isSidebarCandidate(label:title+"Extra Running",title:title,inToolbar:false,hasMatchingRowMenu:true,statuses:liveStatuses),"longer similar title cannot match")
        expect(!RemoteClaudeLookup.isAmbiguous(sidebarDestinationCount:1),"one sidebar plus toolbar remains unique")
        expect(RemoteClaudeLookup.isAmbiguous(sidebarDestinationCount:2),"two real sidebar destinations are ambiguous")
        let savedID=RemotePolicy.chatID("claude",title),savedSlot=RemoteSlot(index:0,kind:"chat",title:title,targetID:RemotePolicy.chatID("claude",title))
        expect(RemoteClaudeLookup.savedTarget(id:savedID,candidates:[],profileSlots:[savedSlot],knownTitles:[])?.title==title,"saved mapping can reveal hidden sidebar")
        expect(RemoteClaudeLookup.savedTarget(id:"claude-wrong",candidates:[],profileSlots:[savedSlot],knownTitles:[title])==nil,"saved title cannot authorize mismatched identity")
        expect(RemoteClaudeLookup.savedTarget(id:savedID,candidates:[],profileSlots:[],knownTitles:[title,title])?.title==title,"repeated cached labels do not mean duplicate destinations")
        expect(Set(ControllerAction.all.map(\.id))==Set(RemoteActionCatalog.claude.map(\.controllerID)+["send","dictate","stop"]),"every physical Claude action has a remote or protected local counterpart")
        let descriptors=RemoteActionCatalog.claude.map(\.action)
        expect(descriptors.count==23 && Set(descriptors.map(\.id)).count==23,"Claude catalog is complete and IDs are unique")
        for entry in RemoteActionCatalog.claude {
            let definition=ControllerAction.find(entry.controllerID)
            expect(definition != nil && definition?.sessionRequired==entry.action.requiresChat,"remote action preserves native session requirement: "+entry.action.id)
            expect(!["send","dictate","stop"].contains(entry.controllerID),"generic route cannot bypass guarded Send or use the Mac microphone")
            var fixture=command;fixture.action=entry.action.id;fixture.text=nil;fixture.chatID=nil
            if entry.action.requiresChat {rejects("scoped shortcut needs chat: "+fixture.action){try RemotePolicy.validate(fixture,hostID:store.hostID)}}
            else {try RemotePolicy.validate(fixture,hostID:store.hostID);expect(true,"global shortcut does not require or reselect a chat")}
        }
        expect(RemoteActionCatalog.claudeEntry("previousChat")?.action.changesChat==true,"previous invalidates stale phone route")
        expect(RemoteActionCatalog.claudeEntry("newChat")?.action.changesChat==true,"new chat invalidates stale phone route")
        expect(RemoteActionCatalog.claudeEntry("addAttachment")?.action.opensNavigation==true,"attachment opens bounded navigation")
        expect(!RemoteActionCatalog.acceptsClaudeResult("Requested Send prompt",controllerTitle:"New session"),"success receipt cannot accept another action's acknowledgment")
        expect(!RemoteActionCatalog.acceptsClaudeResult("New session is disabled in this view.",controllerTitle:"New session"),"disabled action is never confirmed")
        expect(RemoteActionCatalog.acceptsClaudeResult("Requested New session",controllerTitle:"New session"),"exact native action acknowledgment is accepted")
        expect(RemoteActionCatalog.acceptsClaudeResult("Prompt focused",controllerTitle:"Focus prompt"),"focus acknowledgment is exact")
        expect(!RemoteActionCatalog.acceptsClaudeResult("Prompt focused",controllerTitle:"New session"),"focus acknowledgment cannot confirm navigation")
        let oldCurrent=RemoteChat(id:"old",title:"Old chat",state:"Open")
        expect(RemoteActionCatalog.changedChat(previousID:"old",candidate:oldCurrent)==nil,"unchanged header after acknowledged navigation cannot remain the phone Send target")
        expect(RemoteActionCatalog.changedChat(previousID:"old",candidate:RemoteChat(id:"new",title:"New chat",state:"Open"))?.id=="new","verified changed header can become the new phone target")
        expect(RemoteActionCatalog.changedChat(previousID:"old",candidate:nil)==nil,"missing new header clears phone route")
        expect(RemoteActionCatalog.menuSelectedChat(previousID:"old",requestedID:"old",candidate:oldCurrent,succeeded:true,stillOpen:false,selectedFile:false)==nil,"search selection cannot adopt old delayed header")
        expect(RemoteActionCatalog.menuSelectedChat(previousID:"old",requestedID:"old",candidate:oldCurrent,succeeded:true,stillOpen:false,selectedFile:true)?.id=="old","verified same-chat native attachment picker preserves phone route")
        expect(RemoteActionCatalog.menuSelectedChat(previousID:"old",requestedID:"other",candidate:oldCurrent,succeeded:true,stillOpen:false,selectedFile:true)==nil,"native file selection cannot inherit another phone chat")
        expect(RemoteActionCatalog.menuSelectedChat(previousID:"old",requestedID:nil,candidate:oldCurrent,succeeded:true,stillOpen:false,selectedFile:true)==nil,"global project picker cannot inherit old chat")
        expect(RemoteActionCatalog.menuSelectedChat(previousID:"old",requestedID:"old",candidate:oldCurrent,succeeded:false,stillOpen:true,selectedFile:true)==nil,"failed menu action never adopts a route")
        expect(RemoteActionCatalog.menuSelectedChat(previousID:"old",requestedID:"old",candidate:oldCurrent,succeeded:true,stillOpen:true,selectedFile:false)?.id=="old","verified still-open submenu retains its context")
        let legacyProfileData=Data("{\"provider\":\"claude\",\"revision\":1,\"slots\":[]}".utf8)
        expect(try JSONDecoder().decode(RemoteProfile.self,from:legacyProfileData).quickActions==nil,"legacy profile remains decodable with default quick controls")
        let legacyReceipt=Data("{\"id\":\"fixture\",\"status\":\"confirmed\",\"message\":\"done\"}".utf8)
        expect(try JSONDecoder().decode(RemoteReceipt.self,from:legacyReceipt).activeChat==nil,"legacy receipts remain decodable")
        var mapped=updated;mapped.quickActions=["previousChat","newChat","dictate","artifacts"]
        mapped.slots[0]=RemoteSlot(index:0,kind:"action",title:"Previous",targetID:"previousChat")
        let savedProfile=try store.update(mapped)
        expect(savedProfile.quickActions==mapped.quickActions,"quick controls persist alongside six slots")
        expect(try RemoteStore(directory:root).profile("claude").quickActions==mapped.quickActions,"quick controls survive restart")
        var legacyEdit=savedProfile;legacyEdit.quickActions=nil;legacyEdit.slots[1]=RemoteSlot(index:1,kind:"action",title:"New",targetID:"newChat")
        let afterLegacyEdit=try store.update(legacyEdit)
        expect(afterLegacyEdit.quickActions==savedProfile.quickActions,"old client slot edit cannot erase newer quick-control mappings")
        var historyMapping=savedProfile;historyMapping.quickActions=["previousControllerChat","nextControllerChat","dictate","artifacts"]
        try RemotePolicy.validate(historyMapping)
        expect(!RemotePolicy.commands.contains("previousControllerChat") && !RemotePolicy.commands.contains("nextControllerChat"),"phone history is a local mapping, never an arbitrary server command")
        var badQuick=savedProfile;badQuick.quickActions=["sendPrompt"]
        rejects("wrong quick-control count"){try RemotePolicy.validate(badQuick)}
        badQuick.quickActions=["newChat","runShell","dictate","artifacts"]
        rejects("arbitrary shortcut cannot become a quick control"){try RemotePolicy.validate(badQuick)}
        var menuCommand=command;menuCommand.action="menuSelect";menuCommand.text=nil;menuCommand.chatID=nil
        rejects("menu input without lease"){try RemotePolicy.validate(menuCommand,hostID:store.hostID)}
        menuCommand.navigationSession=UUID().uuidString
        try RemotePolicy.validate(menuCommand,hostID:store.hostID)
        expect(true,"global menu may use verified token without a selected chat")
        menuCommand.navigationSession="arbitrary"
        rejects("nonUUID menu lease"){try RemotePolicy.validate(menuCommand,hostID:store.hostID)}
        var unknown=command;unknown.action="approveAll"
        rejects("direct approval is not exposed"){try RemotePolicy.validate(unknown,hostID:store.hostID)}
        let routedReceipt=RemoteReceipt(id:command.id,status:"confirmed",message:"Requested navigation.",activeChat:RemoteChat(id:savedID,title:title,state:"Open"),navigation:RemoteNavigationState(active:false,session:nil,label:"Closed",selection:nil))
        let decodedReceipt=try JSONDecoder().decode(RemoteReceipt.self,from:JSONEncoder().encode(routedReceipt))
        expect(decodedReceipt.activeChat?.id==savedID && decodedReceipt.navigation?.active==false,"navigation receipt carries explicit verified route")
        print("PASS \(checks) remote host protocol/storage checks")
    }
}
