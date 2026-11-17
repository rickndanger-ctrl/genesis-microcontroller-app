import Foundation

enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case codex, claude, muse
    var id: String { rawValue }
    var name: String { switch self { case .codex: return "Codex"; case .claude: return "Claude"; case .muse: return "Muse" } }
    var slotPrefix: String { switch self { case .codex: return "A"; case .claude: return "C"; case .muse: return "M" } }
}

struct RemoteHost: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var hostID: String?
    static let demoHosts: [RemoteHost] = [
        .init(id: "mini-1", name: "Mini 1", baseURL: "https://preview.invalid:8451", hostID: nil),
        .init(id: "mini-2", name: "Mini 2", baseURL: "https://preview.invalid:8451", hostID: nil),
        .init(id: "neo", name: "Neo", baseURL: "https://preview.invalid:8451", hostID: nil)
    ]
}
struct ProviderInfo: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var installed: Bool
    var readiness: String
    var capabilities: [String]
    var reason: String?
    var actions: [RemoteAction]? = nil
    func supports(_ action: String) -> Bool {
        guard capabilities.contains(action) else { return false }
        if action == "artifacts" { return true } // Registered exports do not require an interactive desktop.
        if action == "launchApp" { return installed && readiness == "closed" } // Only offered while the app is shut.
        if id == "codex", ["newChat", "openSettings", "openSkills"].contains(action) {
            return installed && readiness != "locked" // Explicit launch routes do not need saved-chat inventory.
        }
        return installed && readiness == "ready"
    }
    // Capture is owned by the phone. Allow a local draft for an existing Codex
    // chat without claiming that the Mac can receive it or start native voice.
    var supportsPhoneDictation: Bool { supports("sendPrompt") || (id == "codex" && supports("openChat")) }
    func supportsControllerAction(_ action: RemoteAction) -> Bool {
        action.id == "dictate" ? supportsPhoneDictation : supports(action.capability)
    }
    var navigationOnly: Bool { supports("openChat") && !supports("sendPrompt") }
    var controllerShortcuts: [ControllerShortcut] {
        ControllerShortcut.allCases.filter { $0 == .dictate ? supportsPhoneDictation : supports($0.capability) }
    }
    var actionCatalog: [RemoteAction] {
        var result = RemoteAction.defaults
        if id == "codex", !supports("sendPrompt"), let index = result.firstIndex(where: { $0.id == "dictate" }) {
            result[index].detail = "Record into this chat’s saved iPhone draft. Sending to Codex is not connected yet."
        }
        if id == "codex", supports("sendPrompt"), let index = result.firstIndex(where: { $0.id == "sendPrompt" }) {
            result[index].detail = "Queue your reviewed draft for the selected Codex chat once. Codex may process it later."
        }
        for action in actions ?? [] where !action.id.isEmpty && action.id.count <= 100 && !action.title.isEmpty {
            if !result.contains(where: { $0.id == action.id }) { result.append(action) }
        }
        return result
    }
    var availableActions: [RemoteAction] { actionCatalog.filter(supportsControllerAction) }
}
struct RemoteAction: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var group: String
    var detail: String
    var requiresChat: Bool
    var changesChat: Bool
    var opensNavigation: Bool? = nil
    var capability: String {
        if id == "dictate" { return "sendPrompt" }
        if ["previousControllerChat", "nextControllerChat"].contains(id) { return "openChat" }
        return id
    }
    var icon: String {
        if let local = ControllerShortcut(rawValue: id) { return local.icon }
        switch id {
        case "newChat": return "square.and.pencil"
        case "newWindow", "sideChat": return "macwindow.badge.plus"
        case "previousChat", "previousControllerChat", "goBack": return "arrow.left"
        case "nextChat", "nextControllerChat", "goForward": return "arrow.right"
        case "searchChats": return "magnifyingglass"
        case "reopenChat": return "arrow.uturn.backward"
        case "focusPrompt": return "text.cursor"
        case "addAttachment": return "paperclip"
        case "modelAndEffort", "viewOptions": return "slider.horizontal.3"
        case "permissionOptions": return "lock.shield"
        case "usageLimits": return "chart.bar"
        case "toggleSidebar": return "sidebar.left"
        case "toggleTerminal": return "terminal"
        case "toggleBrowser": return "globe"
        case "toggleFiles": return "folder"
        case "toggleChanges": return "arrow.triangle.branch"
        case "renameChat": return "pencil"
        case "sessionDetails", "chatOptions": return "ellipsis.circle"
        default: return "command"
        }
    }
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [title, group, detail].contains { $0.localizedCaseInsensitiveContains(query) }
    }
    static let groupOrder = ["Compose", "Navigate", "Panels", "Session", "Artifacts"]
    static let defaults: [RemoteAction] = [
        .init(id:"dictate",title:"Hold to talk",group:"Compose",detail:"Record on iPhone, then review your draft before sending.",requiresChat:true,changesChat:false),
        .init(id:"sendPrompt",title:"Send prompt",group:"Compose",detail:"Send the reviewed iPhone draft to the selected chat once.",requiresChat:true,changesChat:false),
        .init(id:"stop",title:"Stop response",group:"Compose",detail:"Stop the selected chat’s current response.",requiresChat:true,changesChat:false),
        .init(id:"nativeVoice",title:"Voice mode",group:"Compose",detail:"Start verified two-way voice in the selected chat.",requiresChat:true,changesChat:false),
        .init(id:"previousControllerChat",title:"Previous controller chat",group:"Navigate",detail:"Go back through chats opened from this controller on this Mac and provider.",requiresChat:false,changesChat:true),
        .init(id:"nextControllerChat",title:"Next controller chat",group:"Navigate",detail:"Go forward through chats opened from this controller on this Mac and provider.",requiresChat:false,changesChat:true),
        .init(id:"artifacts",title:"Artifact shelf",group:"Artifacts",detail:"Browse this Mac’s shared documents, images, and app links.",requiresChat:false,changesChat:false)
    ]
}
enum ControllerShortcut: String, CaseIterable, Identifiable {
    case dictate, artifacts, sendPrompt, stop, nativeVoice
    var id: String { rawValue }
    var capability: String { self == .dictate ? "sendPrompt" : rawValue }
    var title: String {
        switch self {
        case .dictate: return "Hold to talk"
        case .artifacts: return "Artifact shelf"
        case .sendPrompt: return "Send prompt"
        case .stop: return "Stop response"
        case .nativeVoice: return "Voice mode"
        }
    }
    var icon: String {
        switch self {
        case .dictate: return "mic"
        case .artifacts: return "square.stack.3d.up"
        case .sendPrompt: return "arrow.up"
        case .stop: return "stop.fill"
        case .nativeVoice: return "waveform"
        }
    }
}
struct DictationControlPresentation: Equatable {
    var label: String
    var accessibilityLabel: String
    var summary: String?
    var explanation: String?
    var icon: String
    static func make(provider: ProviderID, info: ProviderInfo?, paired: Bool, hasChat: Bool,
                     busy: Bool, recording: Bool, finalizing: Bool) -> DictationControlPresentation {
        if recording { return .init(label:"RELEASE TO REVIEW",accessibilityLabel:"Stop dictation",summary:nil,explanation:nil,icon:"waveform") }
        if finalizing { return blocked("FINISHING…", "Finishing your recording.", "Your recording is being turned into text. Wait a moment before recording again.") }
        if !paired { return blocked("PAIR YOUR MAC", "Pair a Mac to use dictation.", "Open controller settings and pair this Mac before using dictation.") }
        guard let info else { return blocked("NOT CONNECTED", "Connect to your Mac to use dictation.", "Check that Tailscale and the Mac companion are running, then refresh the connection.") }
        if info.readiness == "locked" { return blocked("MAC LOCKED", "Unlock your Mac to use dictation.", "Unlock the selected Mac, then refresh the controller connection.") }
        if info.readiness == "needsAccessibility" { return blocked("SETUP NEEDED", "Allow Accessibility for the companion on your Mac.", "Enable Accessibility for Agent Micro Controller on the selected Mac, then refresh.") }
        if info.readiness == "closed" { return blocked("OPEN THE APP", "Open \(provider.name) on your Mac.", "Open \(provider.name) on the selected Mac, then refresh the controller connection.") }
        if !info.supportsPhoneDictation {
            return blocked("NOT CONNECTED", "\(provider.name) Talk and Send aren’t connected yet.", "Talk and Send aren’t connected to \(provider.name) in this iPhone app yet. The available chat, menu, and artifact controls still work. This button will not start recording.")
        }
        if !hasChat { return blocked("CHOOSE A CHAT", "Choose a chat before recording.", "Select one of your mapped chats, then hold this button to record a draft.") }
        if busy { return blocked("PLEASE WAIT", "Another controller action is finishing.", "Wait for the current action to finish, then hold this button to record.") }
        if provider == .codex, !info.supports("sendPrompt") {
            return .init(label:"HOLD TO TALK",accessibilityLabel:"Dictate a local Codex draft",
                summary:"Records to your iPhone draft. Codex Send is not connected yet.",
                explanation:"Hold to record, then release to review the text saved for this Codex chat on your iPhone. Nothing is sent to the Mac; Codex Send and live voice are not connected yet.",icon:"mic")
        }
        if provider == .codex {
            return .init(label:"HOLD TO TALK",accessibilityLabel:"Start Codex dictation",
                summary:"Record here, then tap Send to queue the draft in your selected Codex chat.",
                explanation:"Hold to record on iPhone, then release to review. Send adds the reviewed text to the selected Codex chat’s queue; a queued receipt confirms acceptance, not delivery or a response.",icon:"mic")
        }
        return .init(label:"HOLD TO TALK",accessibilityLabel:"Start dictation",summary:nil,explanation:nil,icon:"mic")
    }
    private static func blocked(_ label: String, _ summary: String, _ explanation: String) -> DictationControlPresentation {
        .init(label:label,accessibilityLabel:summary,summary:summary,explanation:explanation,icon:"mic.slash")
    }
}
struct HostStatus: Codable, Equatable {
    var protocolVersion: Int
    var hostID: String
    var hostName: String
    var providers: [ProviderInfo]
    /// Absent from companions older than 0.6.0. See `CompanionSupport`.
    var companionVersion: String? = nil
}
struct ChatRecord: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var state: String
}
struct ControllerChatHistory: Codable, Equatable {
    var entries: [ChatRecord] = []
    var cursor = -1
    mutating func record(_ chat: ChatRecord) {
        if entries.indices.contains(cursor), entries[cursor].id == chat.id { entries[cursor] = chat; return }
        if cursor + 1 < entries.count { entries = Array(entries.prefix(max(0, cursor + 1))) }
        entries.append(chat)
        if entries.count > 32 { entries.removeFirst(entries.count - 32) }
        cursor = entries.count - 1
    }
    func destination(_ delta: Int, hasCurrentChat: Bool = true) -> Int? {
        let target = !hasCurrentChat && delta < 0 ? cursor : cursor + delta
        return entries.indices.contains(target) ? target : nil
    }
}
struct SlotMapping: Codable, Identifiable, Equatable {
    var index: Int
    var kind: String
    var title: String
    var targetID: String
    var id: Int { index }
    static func empty(_ index: Int) -> SlotMapping { .init(index: index, kind: "empty", title: "Assign a chat", targetID: "") }
}
struct RemoteProfile: Codable, Equatable {
    var provider: String
    var revision: Int
    var slots: [SlotMapping]
    var quickActions: [String]? = nil
    static let defaultQuickActions = ["sendPrompt", "stop", "nativeVoice", "artifacts"]
    var quickActionIDs: [String] {
        if let quickActions, quickActions.count == 4 { return quickActions }
        return provider == "codex" ? ["newChat", "previousControllerChat", "keyboardShortcuts", "artifacts"] : Self.defaultQuickActions
    }
    static func empty(_ provider: ProviderID) -> RemoteProfile { .init(provider: provider.rawValue, revision: 0, slots: (0..<6).map(SlotMapping.empty)) }
    var orderedSlots: [SlotMapping] { (0..<6).map { index in slots.first { $0.index == index } ?? .empty(index) } }
}
struct RemoteCommand: Codable, Equatable {
    var id: String
    var hostID: String
    var provider: String
    var chatID: String?
    var action: String
    var text: String?
    var artifactID: String?
    var generation: Int
    var navigationSession: String? = nil
}
struct RemoteNavigationState: Codable, Equatable {
    var active: Bool
    var session: String?
    var label: String
    var selection: String?
    static let inactive = RemoteNavigationState(active:false,session:nil,label:"Open a menu or file picker on your Mac.",selection:nil)
}
struct CommandReceipt: Codable, Equatable {
    var id: String
    var status: String
    var message: String
    var activeChat: ChatRecord? = nil
    var navigation: RemoteNavigationState? = nil
    var isConfirmed: Bool { status == "confirmed" }
    var isQueued: Bool { status == "queued" }
    // Accepted queue custody ends this Send attempt, without asserting that
    // Codex consumed the message or that any navigation action completed.
    var isAcceptedSend: Bool { isConfirmed || isQueued }
    var statusIcon: String { isQueued ? "tray.and.arrow.down.fill" : isConfirmed ? "checkmark.circle.fill" : "info.circle" }
    var deliveryNote: String? { isQueued ? "Queue accepted · delivery not confirmed" : nil }
    var isUnresolved: Bool { status == "pending" || status == "uncertain" }
}
struct ArtifactRecord: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var kind: String
    var url: String?
    var mimeType: String?
    var hostID: String
    var provider: String
    var chatID: String
}
struct ChatsResponse: Codable { var chats: [ChatRecord] }
struct ArtifactsResponse: Codable { var artifacts: [ArtifactRecord] }

/// What a pairing QR code carries. In version 1 `token` is the Mac's one
/// shared secret. In version 2 it is a single-use code, which is traded for a
/// secret belonging to this device alone.
struct PairingPayload: Codable, Equatable {
    var v: Int
    var name: String
    var hostID: String
    var baseURL: String
    var token: String

    static func decode(_ url: URL, allowLocalhost: Bool = false) throws -> PairingPayload {
        guard url.scheme?.lowercased() == "genesiscontroller", url.host?.lowercased() == "pair", url.path.isEmpty || url.path == "/",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fields = parts.queryItems, fields.count == 1, fields[0].name == "data",
              let encoded = fields[0].value, encoded.count <= 16_384 else { throw RemoteError.invalidPairing }
        var b64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let payload = try? JSONDecoder().decode(PairingPayload.self, from: data),
              [1, 2].contains(payload.v), UUID(uuidString: payload.hostID) != nil,
              !payload.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, payload.name.count <= 100,
              payload.token.count >= 32, payload.token.count <= 1024,
              payload.token.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
              validEndpoint(payload.baseURL, allowLocalhost: allowLocalhost) else { throw RemoteError.invalidPairing }
        return payload
    }

    static func validEndpoint(_ string: String, allowLocalhost: Bool = false) -> Bool {
        guard let u = URLComponents(string: string), let host = u.host, !host.isEmpty,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              u.path.isEmpty || u.path == "/" else { return false }
        if u.scheme == "https" { return true }
        return allowLocalhost && u.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)
    }
}

enum RemoteError: LocalizedError {
    case invalidPairing, unpaired, invalidEndpoint, wrongHost, unsupportedProtocol, invalidResponse
    case server(Int, String), capability(String), unresolvedSend
    var errorDescription: String? {
        switch self {
        case .invalidPairing: return "This is not a valid pairing code. Scan the code shown by your Mac companion."
        case .unpaired: return "Pair this Mac before connecting."
        case .invalidEndpoint: return "The companion must use a private HTTPS address."
        case .wrongHost: return "This connection belongs to a different Mac. Pair it again before sending."
        case .unsupportedProtocol: return "Update the Mac companion to a compatible version."
        case .invalidResponse: return "The companion returned an unexpected response."
        case let .server(code, message):
            if code == 401 { return "Pairing expired or was revoked. Pair this Mac again." }
            if code == 502 { return "Could not reach the Mac companion (502). Open Agent Micro Controller on the selected Mac, then tap Refresh." }
            return message
        case let .capability(action): return "\(action) is not available for this Mac and provider yet."
        case .unresolvedSend: return "The previous Send is still unconfirmed. Check its receipt before sending another prompt."
        }
    }
}

struct DraftRoute: Hashable, Codable {
    var hostID: String
    var provider: String
    var chatID: String
    var storageKey: String { [hostID, provider, chatID].map { Data($0.utf8).base64EncodedString() }.joined(separator: ".") }
}
struct DraftRecord: Codable, Equatable {
    var text: String
    var modifiedAt: Date
}
struct PendingSend: Codable, Equatable {
    var commandID: String
    var route: DraftRoute
    var textDigest: String
    var createdAt: Date
}

/// A stale network response can never update a newly selected Mac/provider/chat.
struct SelectionGate {
    private(set) var generation = 0
    mutating func advance() { generation &+= 1 }
    func accepts(_ expected: Int) -> Bool { expected == generation }
}

struct DraftLedger: Codable {
    var drafts: [String: DraftRecord] = [:]
    var pendingSends: [String: PendingSend] = [:]
    mutating func set(_ text: String, for route: DraftRoute) {
        drafts[route.storageKey] = DraftRecord(text: text, modifiedAt: Date())
    }
    func text(for route: DraftRoute) -> String { drafts[route.storageKey]?.text ?? "" }
    mutating func begin(_ pending: PendingSend) throws {
        guard pendingSends[pending.route.storageKey] == nil else { throw RemoteError.unresolvedSend }
        pendingSends[pending.route.storageKey] = pending
    }
    mutating func resolve(_ receipt: CommandReceipt, route: DraftRoute) {
        guard pendingSends[route.storageKey]?.commandID == receipt.id else { return }
        if receipt.isAcceptedSend || receipt.status == "failed" { pendingSends.removeValue(forKey: route.storageKey) }
    }
}
