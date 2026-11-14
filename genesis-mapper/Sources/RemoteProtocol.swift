import Foundation
import CryptoKit
import Security

struct RemoteProvider: Codable { var id: String; var name: String; var installed: Bool; var readiness: String; var capabilities: [String]; var reason: String?; var actions: [RemoteAction]? = nil }
struct RemoteHostStatus: Codable { var protocolVersion = 1; var hostID: String; var hostName: String; var providers: [RemoteProvider] }
struct RemoteChat: Codable { var id: String; var title: String; var state: String }
struct RemoteSlot: Codable { var index: Int; var kind: String; var title: String; var targetID: String }
struct RemoteProfile: Codable { var provider: String; var revision: Int; var slots: [RemoteSlot]; var quickActions: [String]? = nil }
struct RemoteCommand: Codable { var id: String; var hostID: String; var provider: String; var chatID: String?; var action: String; var text: String?; var artifactID: String?; var generation: Int; var navigationSession: String? = nil }
struct RemoteReceipt: Codable { var id: String; var status: String; var message: String; var activeChat: RemoteChat? = nil; var navigation: RemoteNavigationState? = nil }
struct RemoteArtifact: Codable { var id: String; var title: String; var kind: String; var url: String?; var mimeType: String?; var hostID: String; var provider: String; var chatID: String }
struct RemotePairing: Codable { var v = 1; var name: String; var hostID: String; var baseURL: String; var token: String }
struct RemoteFault: Error { let status: Int; let message: String }

struct RemoteAction: Codable, Equatable {
    var id: String; var title: String; var group: String; var detail: String
    var requiresChat: Bool; var changesChat: Bool; var opensNavigation: Bool? = nil
}

/// Closed catalog; IDs never become user-supplied key sequences or shell commands.
enum RemoteActionCatalog {
    struct ClaudeEntry {
        let action: RemoteAction
        let controllerID: String
    }
    static let claude: [ClaudeEntry] = [
        entry("focusPrompt", "focus", "Focus prompt", "Compose", "Focus the Mac composer without inserting text."),
        entry("addAttachment", "attach", "Add attachment", "Compose", "Open the attachment menu on the Mac."),
        entry("modelAndEffort", "model", "Model & effort", "Compose", "Open model and effort choices."),
        entry("permissionOptions", "permissions", "Permissions", "Compose", "Open the permissions chooser; this does not approve a request."),
        entry("usageLimits", "usage", "Usage limits", "Compose", "Show the current usage and limits."),
        entry("newChat", "new", "New chat", "Navigate", "Open a new Claude Code session.", false, true),
        entry("newWindow", "newwindow", "New window", "Navigate", "Open a new Claude Code window.", false, true),
        entry("sideChat", "sidechat", "New side chat", "Navigate", "Open a new side chat.", false, true),
        entry("searchChats", "search", "Search chats", "Navigate", "Open the Mac chat search.", false),
        entry("previousChat", "previous", "Previous chat", "Navigate", "Move to the previous session in Claude.", false, true),
        entry("nextChat", "next", "Next chat", "Navigate", "Move to the next session in Claude.", false, true),
        entry("goBack", "back", "Go back", "Navigate", "Go back in Claude navigation history.", false, true),
        entry("goForward", "forward", "Go forward", "Navigate", "Go forward in Claude navigation history.", false, true),
        entry("reopenChat", "reopen", "Reopen chat", "Navigate", "Reopen the last closed session.", false, true),
        entry("toggleSidebar", "sidebar", "Toggle sidebar", "Panels", "Show or hide the sidebar.", false),
        entry("toggleTerminal", "terminal", "Terminal", "Panels", "Open or close this session's terminal."),
        entry("toggleBrowser", "browser", "Browser", "Panels", "Open or close this session's browser."),
        entry("toggleChanges", "changes", "Changes", "Panels", "Open or close this session's changes."),
        entry("toggleFiles", "files", "Files", "Panels", "Open or close this session's files."),
        entry("sessionDetails", "details", "Session details", "Panels", "Show session details."),
        entry("viewOptions", "view", "View options", "Panels", "Open Claude view options.", false),
        entry("renameChat", "rename", "Rename chat", "Session", "Open the session name editor."),
        entry("chatOptions", "options", "Chat options", "Session", "Open this session's options menu.")
    ]
    private static func entry(_ id:String,_ controllerID:String,_ title:String,_ group:String,_ detail:String,_ required:Bool=true,_ changes:Bool=false)->ClaudeEntry {
        ClaudeEntry(action:RemoteAction(id:id,title:title,group:group,detail:detail,requiresChat:required,changesChat:changes,opensNavigation:["addAttachment","modelAndEffort","permissionOptions","usageLimits","searchChats","viewOptions","chatOptions"].contains(id)),controllerID:controllerID)
    }
    static func claudeEntry(_ id:String)->ClaudeEntry? {claude.first{$0.action.id==id}}
    static let codexAdditionalIDs = ["previousSidebarItem","nextSidebarItem","previousTab","nextTab","toggleBottomPanel","togglePinnedSummary","toggleNavigationPanel","keyboardShortcuts","newProject","openFolder","findInChat","openSettings","openSkills"]
    static let menuIDs = ["menuPrevious","menuNext","menuSelect","menuBack","menuHome"]
    static let commandIDs = claude.map{$0.action.id} + codexAdditionalIDs + menuIDs
    static let localMappingIDs = ["dictate","artifacts","previousControllerChat","nextControllerChat"]
    static let defaultQuickActions = ["sendPrompt","stop","nativeVoice","artifacts"]
    static func changedChat(previousID:String?,candidate:RemoteChat?)->RemoteChat? {
        guard let candidate,candidate.id != previousID else{return nil}
        return candidate
    }
    static func menuSelectedChat(previousID:String?,requestedID:String?,candidate:RemoteChat?,succeeded:Bool,stillOpen:Bool,selectedFile:Bool)->RemoteChat? {
        guard succeeded else{return nil}
        if stillOpen {return candidate}
        if selectedFile,let candidate,candidate.id==requestedID {return candidate}
        return changedChat(previousID:previousID,candidate:candidate)
    }
    static func acceptsClaudeResult(_ message:String,controllerTitle:String)->Bool {
        message == "Requested " + controllerTitle || (controllerTitle == "Focus prompt" && message == "Prompt focused")
    }
}

enum RemotePolicy {
    static let providers = ["codex", "claude", "muse"]
    static let commands = ["openChat", "sendPrompt", "stop", "openArtifact", "nativeVoice"] + RemoteActionCatalog.commandIDs
    static let maximumBody = 131_072
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format:"%02x", $0) }.joined() }
    static func chatID(_ provider: String, _ title: String) -> String { "\(provider)-" + String(digest(Data(title.utf8)).prefix(32)) }
    static func validate(_ command: RemoteCommand, hostID: String) throws {
        guard UUID(uuidString: command.id) != nil, command.hostID == hostID,
              providers.contains(command.provider), commands.contains(command.action), command.generation >= 0 else { throw RemoteFault(status:422,message:"Invalid command or host identity.") }
        if (["openChat", "sendPrompt", "stop", "nativeVoice"].contains(command.action) || (command.provider == "claude" && RemoteActionCatalog.claudeEntry(command.action)?.action.requiresChat == true)), command.chatID?.isEmpty != false { throw RemoteFault(status:422,message:"Choose a chat first.") }
        if RemoteActionCatalog.menuIDs.contains(command.action), UUID(uuidString:command.navigationSession ?? "") == nil {throw RemoteFault(status:422,message:"Open and refresh a controller menu first.")}
        if command.action == "sendPrompt", command.text?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty != false { throw RemoteFault(status:422,message:"The prompt is empty.") }
        if (command.text?.utf8.count ?? 0) > 64_000 { throw RemoteFault(status:413,message:"The prompt is too long.") }
    }
    static func validate(_ profile: RemoteProfile) throws {
        guard providers.contains(profile.provider), profile.slots.count == 6, Set(profile.slots.map(\.index)) == Set(0..<6), profile.revision > 0 else { throw RemoteFault(status:422,message:"A profile must contain six unique slots.") }
        if let quick=profile.quickActions {
            guard quick.count==4,quick.allSatisfy({(commands + RemoteActionCatalog.localMappingIDs).contains($0)}) else {throw RemoteFault(status:422,message:"Choose four supported quick controls.")}
        }
        for slot in profile.slots {
            guard ["empty","chat","action"].contains(slot.kind), slot.title.count <= 240, slot.targetID.count <= 512 else {throw RemoteFault(status:422,message:"Invalid slot mapping.")}
            if slot.kind == "chat", slot.targetID.isEmpty {throw RemoteFault(status:422,message:"A chat mapping needs a target.")}
            if slot.kind == "action", !(commands + RemoteActionCatalog.localMappingIDs).contains(slot.targetID) {throw RemoteFault(status:422,message:"Unsupported shortcut.")}
        }
    }
    static func equalToken(_ supplied: String, _ expected: String) -> Bool {
        let left = Array(supplied.utf8), right = Array(expected.utf8)
        guard left.count == right.count else { return false }
        return zip(left,right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum RemoteComposerPolicy {
    // Electron's empty editor may expose a newline through AXValue. Only
    // whitespace is blank; an unreadable value or any real text is protected.
    static func isBlank(_ value:String?)->Bool {
        guard let value else{return false}
        return value.unicodeScalars.allSatisfy{$0.properties.isWhitespace}
    }
    static func matchesInserted(_ value:String?,prompt:String)->Bool {value==prompt}
}

enum RemoteCodexAvailability {
    // Fixed public links can launch a closed app. Menu input still requires a
    // live foregroundable process and Accessibility; inventory enables only
    // existing-chat selection, never Send or native voice.
    static func capabilities(installed:Bool,running:Bool,unlocked:Bool,accessibility:Bool,inventoryAvailable:Bool,launchIDs:[String],nativeIDs:[String],queueAvailable:Bool=false)->[String] {
        var result=["artifacts"]
        guard installed,unlocked else{return result}
        if inventoryAvailable {result.append("openChat");if queueAvailable {result.append("sendPrompt")}}
        result.append(contentsOf:launchIDs)
        if running,accessibility {result.append(contentsOf:nativeIDs);result.append("menuNavigation")}
        var seen=Set<String>()
        return result.filter{seen.insert($0).inserted}
    }
}

enum RemoteCodexNavigation {
    // Existing local chats only. Never allow /new, arbitrary URLs, query
    // parameters, or IDs not returned by the current-account inventory.
    static func existingChatURL(id:String,inventoryIDs:Set<String>)->URL? {
        guard let uuid=UUID(uuidString:id),inventoryIDs.contains(id),uuid.uuidString.lowercased()==id.lowercased() else{return nil}
        return URL(string:"codex://threads/"+uuid.uuidString.lowercased())
    }
}

struct RemoteDeliveryObservation {
    let matchingHeaderCount:Int
    let composerCount:Int
    let composerIsBlank:Bool
    let hasStopControl:Bool
    var isCurrent:Bool {matchingHeaderCount==1}
    var confirmsDelivery:Bool {isCurrent && composerCount==1 && composerIsBlank && hasStopControl}
}

enum RemoteClaudeLookup {
    static func isAmbiguous(sidebarDestinationCount:Int) -> Bool { sidebarDestinationCount > 1 }
    static func isSidebarCandidate(label:String,title:String,inToolbar:Bool,hasMatchingRowMenu:Bool,statuses:[String],hasExactTitleChild:Bool=false)->Bool {
        guard !title.isEmpty,!inToolbar else{return false}
        if statuses.contains(where:{label==$0+" "+title}) {return true}
        // Inactive Electron rows may omit their text descendants and append a
        // status to the button's AXTitle. Match the complete known suffix, and
        // still require the independently named menu in this same row.
        let suffixes=statuses+["Unread response","Cloud"]
        let knownStatusSuffix=suffixes.contains{label==title+" "+$0}
        return hasMatchingRowMenu && (label==title || label.hasSuffix(" "+title) || knownStatusSuffix || (hasExactTitleChild && label.contains(title)))
    }
    // Cached labels can locate a hidden sidebar, but never authorize a Send.
    static func savedTarget(id:String,candidates:[RemoteChat],profileSlots:[RemoteSlot],knownTitles:[String]) -> RemoteChat? {
        if let match=candidates.first(where:{$0.id==id && $0.id==RemotePolicy.chatID("claude",$0.title)}) {return match}
        let titles=profileSlots.filter{$0.kind=="chat" && $0.targetID==id}.map(\.title)+knownTitles
        let matches=Set(titles.filter{!$0.isEmpty && RemotePolicy.chatID("claude",$0)==id})
        guard matches.count==1,let title=matches.first else{return nil}
        return RemoteChat(id:id,title:title,state:"Saved")
    }
}

final class RemoteStore {
    struct Entry: Codable { var fingerprint: String; var receipt: RemoteReceipt }
    struct Archive: Codable { var hostID = UUID().uuidString; var profiles: [String:RemoteProfile] = [:]; var ledger: [String:Entry] = [:]; var artifacts: [RemoteArtifact] = [] }
    let directory: URL
    let token: String
    private(set) var archive: Archive
    var hostID: String { archive.hostID }
    let encoder: JSONEncoder = { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }()
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let tokenURL = directory.appendingPathComponent("pairing-token")
        if FileManager.default.fileExists(atPath:tokenURL.path) {
            token = try String(contentsOf:tokenURL,encoding:.utf8)
            guard token.utf8.count >= 43 else { throw RemoteFault(status:500,message:"Pairing credential is invalid; restore its backup.") }
        } else {
            var bytes = [UInt8](repeating:0,count:32)
            guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else {throw RemoteFault(status:500,message:"Could not generate pairing credential.")}
            token = Data(bytes).base64EncodedString()
            try Data(token.utf8).write(to:tokenURL,options:.atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:tokenURL.path)
        let archiveURL = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath:archiveURL.path) { archive = try JSONDecoder().decode(Archive.self,from:Data(contentsOf:archiveURL)) }
        else { archive = Archive() }
        for id in archive.ledger.keys where archive.ledger[id]?.receipt.status == "pending" {
            archive.ledger[id]?.receipt = RemoteReceipt(id:id,status:"uncertain",message:"The Mac restarted during this command. Check the chat before sending again.")
        }
        try persist()
    }
    func persist() throws {
        let url = directory.appendingPathComponent("state.json")
        try encoder.encode(archive).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func profile(_ provider: String, seed: [RemoteSlot]? = nil) throws -> RemoteProfile {
        guard RemotePolicy.providers.contains(provider) else {throw RemoteFault(status:422,message:"Unknown provider.")}
        if let profile = archive.profiles[provider] { return profile }
        let profile = RemoteProfile(provider:provider,revision:1,slots:seed ?? (0..<6).map { RemoteSlot(index:$0,kind:"empty",title:"",targetID:"") })
        try RemotePolicy.validate(profile)
        archive.profiles[provider] = profile
        try persist()
        return profile
    }
    func update(_ requested: RemoteProfile) throws -> RemoteProfile {
        try RemotePolicy.validate(requested)
        let previous=try profile(requested.provider)
        guard previous.revision == requested.revision else {throw RemoteFault(status:409,message:"Mappings changed on another device. Refresh and try again.")}
        var next = requested
        // Older clients omit this additive field; their slot edits must not
        // erase newer quick-key choices. Reset uses the four explicit defaults.
        if next.quickActions==nil {next.quickActions=previous.quickActions}
        next.revision += 1
        archive.profiles[next.provider] = next; try persist(); return next
    }
    func previous(_ command: RemoteCommand) throws -> RemoteReceipt? {
        guard let entry = archive.ledger[command.id] else {return nil}
        guard entry.fingerprint == RemotePolicy.digest(try encoder.encode(command)) else {throw RemoteFault(status:409,message:"This request ID was already used for different content.")}
        return entry.receipt
    }
    func begin(_ command: RemoteCommand) throws {
        archive.ledger[command.id] = Entry(fingerprint:RemotePolicy.digest(try encoder.encode(command)),receipt:RemoteReceipt(id:command.id,status:"pending",message:"Command accepted."))
        try persist()
    }
    func finish(_ receipt: RemoteReceipt) throws {
        guard archive.ledger[receipt.id] != nil else {throw RemoteFault(status:500,message:"Missing command ledger.")}
        archive.ledger[receipt.id]?.receipt = receipt; try persist()
    }
    func add(_ artifact: RemoteArtifact) throws { archive.artifacts.append(artifact); try persist() }
    func removeArtifact(_ id: String) throws {
        archive.artifacts.removeAll {$0.id == id}; try persist()
        try? FileManager.default.removeItem(at:directory.appendingPathComponent("exports").appendingPathComponent(id))
    }
}

struct RemoteHTTPRequest {
    var method: String; var target: String; var headers: [String:String]; var body: Data
    static func parse(_ data: Data) throws -> RemoteHTTPRequest? {
        guard data.count <= RemotePolicy.maximumBody + 16_384 else {throw RemoteFault(status:413,message:"Request too large.")}
        guard let split = data.range(of:Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 {throw RemoteFault(status:431,message:"Headers too large.")}; return nil
        }
        guard split.lowerBound <= 16_384, let header = String(data:data[..<split.lowerBound],encoding:.utf8) else {throw RemoteFault(status:400,message:"Invalid headers.")}
        let lines = header.components(separatedBy:"\r\n"), first = lines[0].split(separator:" ")
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET","PUT","POST"].contains(String(first[0])), first[1].hasPrefix("/v1/") else {throw RemoteFault(status:400,message:"Invalid request.")}
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of:":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {throw RemoteFault(status:400,message:"Invalid header.")}
            let key = line[..<colon].lowercased(), value = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            guard headers[key] == nil else {throw RemoteFault(status:400,message:"Duplicate header.")}
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil, headers["origin"] == nil else {throw RemoteFault(status:400,message:"Unsupported request framing or browser origin.")}
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy(\.isNumber), let parsed = Int(raw) else {throw RemoteFault(status:400,message:"Invalid content length.")}; length = parsed
        } else {length = 0}
        guard length <= RemotePolicy.maximumBody else {throw RemoteFault(status:413,message:"Request too large.")}
        let available = data.count - split.upperBound
        guard available >= length else {return nil}
        guard available == length else {throw RemoteFault(status:400,message:"Pipelined requests are not supported.")}
        return RemoteHTTPRequest(method:String(first[0]),target:String(first[1]),headers:headers,body:Data(data[split.upperBound...]))
    }
}
