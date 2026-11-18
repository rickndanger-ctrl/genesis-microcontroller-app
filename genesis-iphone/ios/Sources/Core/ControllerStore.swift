import Foundation
import Combine
import CryptoKit

@MainActor
final class ControllerStore: ObservableObject {
    @Published private(set) var hosts: [RemoteHost]
    @Published private(set) var selectedHostID: String
    @Published private(set) var selectedProvider: ProviderID
    @Published private(set) var status: HostStatus?
    @Published private(set) var chats: [ChatRecord] = []
    /// Titles the Mac left out of `chats` because more than one chat carries them.
    @Published private(set) var leftOutChatTitles: [String] = []
    var leftOutChatsNotice: String? { CompanionSupport.leftOutNotice(titles: leftOutChatTitles, app: selectedProvider.name) }
    @Published private(set) var profile: RemoteProfile
    @Published private(set) var selectedChat: ChatRecord?
    @Published var draft = "" { didSet { persistDraft(); publishGlassesDraft() } }
    @Published private(set) var artifacts: [ArtifactRecord] = []
    @Published private(set) var connectionMessage = "Pair your Mac to connect"
    @Published private(set) var isBusy = false
    private var navigating = false
    private var queuedMenuSteps: [String] = []
    /// The open menu belongs to the selected chat (model, permissions, an
    /// attachment), so choosing something in it does not leave that chat.
    /// A search does: its result may be any chat.
    private var navigationKeepsChat = false
    @Published private(set) var isRefreshingChats = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var lastReceipt: CommandReceipt?
    @Published var lastError: String? { didSet { errorCommandID = nil } }
    @Published private(set) var sendReady = false
    @Published private(set) var selectedSlotIndex: Int?
    @Published var requestedPanel: String?
    @Published private(set) var navigation = RemoteNavigationState.inactive
    let isDemo: Bool
    let glasses: GlassesFollowController

    private let client: RemoteClient
    private let credentials: any ControllerCredentialVault
    private let persistence: ControllerPersistence
    private let speech: any PhoneDictationService
    private var settings: LocalControllerSettings
    private var gate = SelectionGate()
    private var polling: Task<Void, Never>?
    private var refreshGeneration: Int?
    private var artifactRefreshGeneration: Int?
    private var commandSequence = 0
    private var errorCommandID: String?
    private var recoveringCommands = Set<String>()
    private var navigationGeneration: Int?
    private var navigationRefreshGeneration: Int?
    private var loadingDraft = false
    private var dictationIntent = 0
    private var captureRoute: DraftRoute?
    private var foreground = false
    private var glassesConfirmedChatID: String?
    private var importingProvisioning = false
    private var provisioningTask: Task<Void, Never>?
    private var pendingProvisioning: [PairingPayload] = []
    private let provisioningDirectory: URL?

    init(demo: Bool = false, client: RemoteClient = RemoteClient(),
         credentials: any ControllerCredentialVault = GenesisCredentials(), persistence: ControllerPersistence = ControllerPersistence(),
         provisioningDirectory: URL? = nil, speech: (any PhoneDictationService)? = nil,
         glassesTransport: (any GlassesDisplayTransport)? = nil, demoFollow: Bool = false,
         glassesPreferences: UserDefaults? = .standard) {
        self.client = client; self.credentials = credentials; self.persistence = persistence
        glasses = GlassesFollowController(transport: glassesTransport ?? RemoteGlassesDisplayTransport(client: client),
                                          previewOnly: demo && demoFollow, preferences: glassesPreferences)
        self.speech = speech ?? PhoneDictation()
        self.provisioningDirectory = provisioningDirectory
        isDemo = demo
        let saved = demo ? LocalControllerSettings() : persistence.load()
        settings = saved
        let restoredHosts = demo ? RemoteHost.demoHosts : saved.hosts
        hosts = restoredHosts
        if let glassesPreferences { GlassesFeature.prepare(glassesPreferences, demo: demo, hasPairedMac: !saved.hosts.isEmpty) }
        selectedHostID = restoredHosts.first(where: { $0.id == saved.selectedHostID })?.id ?? restoredHosts.first?.id ?? ""
        selectedProvider = saved.selectedProvider
        profile = .empty(saved.selectedProvider)
        self.speech.onState = { [weak self] state in
            guard let self else { return }
            self.isRecording = state == .authorizing || state == .recording
            self.isFinalizing = state == .finalizing
            let phase: Int
            switch state { case .idle: phase = 0; case .authorizing: phase = 1; case .recording: phase = 2; case .finalizing: phase = 3 }
            DictationDiagnostics.record("store_state", ["phase": phase, "intent": self.dictationIntent])
            if state == .idle {
                self.captureRoute = nil
                self.sendReady = !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            self.publishGlassesDraft()
        }
        self.speech.onError = { [weak self] error in self?.lastError = error }
        restoreSelection()
        if demo {
            loadDemo()
            if demoFollow { glasses.startPreview(provider: selectedProvider, chatID: selectedChat?.id, draft: draft) }
        }
    }

    var selectedHost: RemoteHost? { hosts.first { $0.id == selectedHostID } }
    var providerInfo: ProviderInfo? { status?.providers.first { $0.id == selectedProvider.rawValue } }
    var isPaired: Bool { isDemo || (selectedHost?.hostID != nil && credentials.token(for: selectedHostID) != nil) }
    private var hasDictationChat: Bool {
        guard let chat = selectedChat, !chat.id.isEmpty else { return false }
        return selectedProvider != .codex || isDemo || UUID(uuidString: chat.id) != nil
    }
    var canDictate: Bool {
        isPaired && hasDictationChat && !isBusy && !isFinalizing && (providerInfo?.supportsPhoneDictation == true || !macIsReady)
    }
    /// The Mac is answering and the selected app is ready to be controlled.
    private var macIsReady: Bool { status != nil && providerInfo?.readiness == "ready" }
    var dictationControl: DictationControlPresentation {
        .make(provider:selectedProvider,info:providerInfo,paired:isPaired,hasChat:hasDictationChat,
              busy:isBusy,recording:isRecording,finalizing:isFinalizing)
    }
    var canMapChats: Bool { providerInfo?.supports("openChat") == true }
    var navigationOnly: Bool { providerInfo?.navigationOnly == true }
    var availableShortcuts: [ControllerShortcut] { providerInfo?.controllerShortcuts ?? [] }
    var availableActions: [RemoteAction] { providerInfo?.availableActions ?? [] }
    func action(_ id: String) -> RemoteAction? { (providerInfo?.actionCatalog ?? RemoteAction.defaults).first { $0.id == id } }
    /// Whether an action needs a chat selected. Muse's call belongs to the
    /// assistant, not to a chat, so it works from anywhere.
    private func needsChat(_ action: RemoteAction) -> Bool {
        action.requiresChat && !(action.id == "nativeVoice" && selectedProvider == .muse)
    }
    func canRunAction(_ id: String) -> Bool {
        // A local recording must remain stoppable even if the Mac disconnects.
        if id == "dictate", isRecording { return true }
        guard !isBusy, let action = action(id), providerInfo?.supportsControllerAction(action) == true,
              !needsChat(action) || selectedChat != nil else { return false }
        if id == "sendPrompt" { return canSend }
        if id == "dictate" { return canDictate }
        if ["previousControllerChat", "nextControllerChat"].contains(id) { return historyDestination(id) != nil }
        return true
    }
    /// True while a command in flight is the only thing stopping this action,
    /// so its key stays lit and a press can wait its turn. See `DeferredTap`.
    func canDeferAction(_ id: String) -> Bool {
        guard isBusy, DeferredTap.mayWait(id), let action = action(id), providerInfo?.supportsControllerAction(action) == true,
              !needsChat(action) || selectedChat != nil else { return false }
        if ["previousControllerChat", "nextControllerChat"].contains(id) { return historyDestination(id) != nil }
        return true
    }
    /// A press that could not act: what it needs and how to get there. The
    /// deck shows this in place of a general error.
    @Published var hint: ControllerHint?

    /// Why an action cannot run right now, as something to do about it.
    func hint(forAction id: String) -> ControllerHint {
        let app = selectedProvider.name, mac = selectedHost?.name ?? "your Mac"
        let name: String = id == "dictate" ? "Hold to Talk" : id == "sendPrompt" ? "Send" : (action(id)?.title ?? "This key")
        if !isPaired {
            return .init(title: "Pair a Mac first", message: "\(name) needs a Mac to work with. Pair one in Settings.", step: .pairMac, stepLabel: "Open Settings")
        }
        if id == "sendPrompt", isRecording || isFinalizing {
            return .init(title: "Still recording", message: "Release the microphone and check the draft, then press Send.")
        }
        // Recording a draft only needs a chat; everything else needs the Mac and the app.
        let needsMac = id != "dictate" && id != "artifacts"
        if needsMac {
            guard status != nil, let info = providerInfo else {
                return .init(title: "Can’t reach \(mac)", message: "\(name) needs the Mac. Check that it is awake and on the same Wi-Fi, or that Tailscale is connected, then try again.", step: .refresh, stepLabel: "Refresh")
            }
            switch info.readiness {
            case "locked":
                return .init(title: "\(mac) is locked", message: "Unlock the Mac to use \(name).")
            case "needsAccessibility":
                return .init(title: "Setup needed on \(mac)", message: "Allow Accessibility for Agent Micro Controller in System Settings on that Mac, then refresh.", step: .refresh, stepLabel: "Refresh")
            case "closed":
                if providerNeedsWiderWindow {
                    return .init(title: "\(app)’s window is too narrow", message: "\(app) hides its chats in a narrow window. Widen it from here and \(name) will work.", step: .openApp, stepLabel: "Widen \(app)")
                }
                if info.supports("launchApp") {
                    return .init(title: "\(app) is closed on \(mac)", message: "Open it from here, then \(name) will work.", step: .openApp, stepLabel: "Open \(app)")
                }
                return .init(title: "\(app) is closed on \(mac)", message: "Open \(app) on the Mac to use \(name).")
            case "unavailable":
                if info.supports("restartService") {
                    return .init(title: "\(app)’s background service stopped answering", message: info.reason ?? "Restart it from here to bring your chats back.", step: .restartService, stepLabel: "Restart service")
                }
            default: break
            }
        }
        if id == "stop", selectedProvider == .muse {
            return .init(title: "Stop isn’t available for Muse", message: "Muse can’t be stopped from the controller. Stop it in Muse on the Mac.")
        }
        if id == "nativeVoice", providerInfo?.supports("nativeVoice") != true {
            return .init(title: "Voice isn’t connected here", message: "Two-way voice mode is not connected here yet. Use Hold to talk to dictate a draft, then Send.")
        }
        if id == "sendPrompt", macIsReady, providerInfo?.supports("sendPrompt") != true {
            return .init(title: "Send isn’t connected for \(app) here", message: "This Mac can open \(app) chats from the controller, but it can’t send to them yet.")
        }
        let wantsChat = id == "sendPrompt" || id == "dictate" || (action(id).map(needsChat) ?? false)
        if wantsChat, selectedChat == nil {
            let chatKeys = profile.slots.filter { $0.kind == "chat" }
            if chatKeys.isEmpty {
                let free = (0..<6).first { index in !profile.slots.contains { $0.index == index && $0.kind != "empty" } } ?? 0
                return .init(title: "No chat on any key yet", message: "\(name) works on the chat you have open. Put a chat on a key to begin.", step: .assignKey(free), stepLabel: "Assign a chat")
            }
            return .init(title: "Choose a chat first", message: "\(name) works on the chat you have open. Tap one of your chat keys, then try again.")
        }
        if id == "sendPrompt" {
            if hasUnresolvedSend {
                return .init(title: "Check the last Send first", message: "The Mac never confirmed your previous Send to this chat. Look at it before sending again, so nothing goes twice.", step: .reviewSend, stepLabel: "Review it")
            }
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .init(title: "Nothing to send yet", message: "Hold the microphone to dictate a draft, or type one. Then press Send.", step: .writeDraft, stepLabel: "Type a draft")
            }
        }
        if id == "dictate", !canDictate {
            let control = dictationControl
            return .init(title: control.summary ?? "Hold to Talk isn’t ready", message: control.explanation ?? "Finish the current recording first.")
        }
        if id == "previousControllerChat", historyDestination(id) == nil {
            return .init(title: "No earlier chat", message: "This key steps back through chats you opened from the controller. Open another chat first.")
        }
        if id == "nextControllerChat", historyDestination(id) == nil {
            return .init(title: "No later chat", message: "This key steps forward again after you have gone back. You are on the latest chat.")
        }
        if isBusy { return .init(title: "One moment", message: "Another action is still finishing. Try again in a second.") }
        return .init(title: "\(name) isn’t available right now", message: actionUnavailableReason(id) ?? "This action is not available for \(app) on this Mac.")
    }
    /// A key whose chat is gone from the Mac: say so, and offer to choose another for that key.
    func hint(forMissingChatOn slot: SlotMapping) -> ControllerHint? {
        guard let message = missingChatMessage(slot) else { return nil }
        return .init(title: "This key’s chat can’t be found", message: message, step: .assignKey(slot.index), stepLabel: "Choose a chat")
    }

    func actionUnavailableReason(_ id: String) -> String? {
        if id == "dictate", isRecording { return nil }
        if id == "nativeVoice", providerInfo?.supports("nativeVoice") != true {
            return "Two-way voice mode is not connected here yet. Use Hold to talk to dictate a draft, then Send."
        }
        if id == "stop", selectedProvider == .muse { return "Muse can’t be stopped from the controller. Stop it in Muse on the Mac." }
        guard let action = action(id), providerInfo?.supportsControllerAction(action) == true else { return "This action is not available for this connection." }
        if isBusy { return "Another action is finishing." }
        if needsChat(action) && selectedChat == nil { return "Choose a chat first." }
        if id == "sendPrompt", !canSend { return hasUnresolvedSend ? "Check the previous Send receipt first." : "Finish and review a draft first." }
        if id == "dictate", !canDictate { return dictationControl.explanation ?? "Finish the current recording first." }
        if ["previousControllerChat", "nextControllerChat"].contains(id), historyDestination(id) == nil { return "No \(id == "previousControllerChat" ? "earlier" : "later") chat opened from this controller." }
        return nil
    }
    /// A sentence to show when the selected Mac's companion is older than this app is written for.
    var companionNotice: String? {
        guard !isDemo, let status else { return nil }
        return CompanionSupport.notice(hostName: selectedHost?.name ?? "", reported: status.companionVersion)
    }
    /// The selected app is installed but shut, and the Mac can open it for us.
    var canOpenProviderApp: Bool { !isBusy && providerInfo?.supports("launchApp") == true }
    /// The app is open, but in a window too narrow for the controller; "open" then means widen it.
    var providerNeedsWiderWindow: Bool { providerInfo?.supports("launchApp") == true && providerInfo?.reason?.contains("too narrow") == true }
    /// Opens the selected app on the Mac. It sends nothing to it.
    func openProviderApp() async {
        guard canOpenProviderApp else { return }
        let receipt = await execute(action: "launchApp", chatID: nil)
        guard receipt?.isConfirmed == true else { return }
        // Give the app a moment to draw its window before asking what it shows.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh()
    }
    /// The selected app's background service cannot be reached, and the Mac can restart it for us.
    var canRestartProviderService: Bool { !isBusy && providerInfo?.supports("restartService") == true }
    /// Restarts the selected app's background service on the Mac. It opens no chat and sends nothing.
    func restartProviderService() async {
        guard canRestartProviderService else { return }
        let receipt = await execute(action: "restartService", chatID: nil)
        // Whatever came back, ask the Mac what it has now: a slow restart may have worked.
        if receipt?.isConfirmed != true { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        await refresh()
    }
    /// Asks the selected Mac what it can find in the apps it controls.
    func selfCheck() async throws -> SelfCheckReport {
        if isDemo { return Self.demoSelfCheck }
        let (host, token) = try connection()
        return try await client.fetch(SelfCheckReport.self, host: host, token: token, path: "/v1/diagnostics/selfcheck", deadline: 45)
    }
    func recentActivity() async throws -> ActivityReport {
        if isDemo { return Self.demoActivity }
        let (host, token) = try connection()
        return try await client.fetch(ActivityReport.self, host: host, token: token, path: "/v1/diagnostics/activity", deadline: 10)
    }
    private static let demoSelfCheck = SelfCheckReport(checkedAt: Date(), companionVersion: "0.6.0", summary: "1 of 8 checks needs attention: Codex – Menu controls.", items: [
        .init(provider: "mac", name: "Unlocked", ok: true, detail: "This Mac is unlocked."),
        .init(provider: "mac", name: "Accessibility", ok: true, detail: "Agent Micro Controller is allowed to control other apps."),
        .init(provider: "claude", name: "Session list", ok: true, detail: "6 sessions found."),
        .init(provider: "claude", name: "Message box", ok: true, detail: "One message box found."),
        .init(provider: "muse", name: "Chats", ok: true, detail: "4 chats offered."),
        .init(provider: "muse", name: "Message box", ok: true, detail: "One message box found."),
        .init(provider: "codex", name: "Saved chats", ok: true, detail: "12 saved chats found."),
        .init(provider: "codex", name: "Menu controls", ok: false, detail: "Open Codex to use its menu controls."),
    ])
    private static let demoActivity = ActivityReport(entries: [
        .init(time: Date().addingTimeInterval(-180), provider: "claude", action: "openChat", status: "confirmed", message: "Opened Design studio.", durationMs: 640),
        .init(time: Date().addingTimeInterval(-95), provider: "claude", action: "sendPrompt", status: "confirmed", message: "Prompt sent; Claude is responding.", durationMs: 1820),
        .init(time: Date().addingTimeInterval(-20), provider: "codex", action: "toggleSidebar", status: "failed", message: "Open Codex on this Mac before using its menu controls.", durationMs: 40),
    ])
    var chatAvailabilityMessage: String {
        if !isPaired { return "Pair this Mac to see its available chats." }
        guard let info = providerInfo else {
            if status == nil {
                return connectionMessage == "Connecting…" || refreshGeneration == gate.generation
                    ? "Connecting to \(selectedHost?.name ?? "your Mac"). Wait for the connection, then try again."
                    : "Refresh the connection to check this Mac’s available controls."
            }
            return "Open \(selectedProvider.name) on \(selectedHost?.name ?? "your Mac"), then refresh to check its controls."
        }
        if !info.installed { return "Install \(selectedProvider.name) on \(selectedHost?.name ?? "your Mac"), then refresh." }
        switch info.readiness {
        case "locked": return "Unlock \(selectedHost?.name ?? "your Mac") to open its chats."
        case "needsAccessibility": return "Allow Accessibility for Agent Micro Controller on \(selectedHost?.name ?? "your Mac")."
        case "closed": return "Open \(selectedProvider.name) on \(selectedHost?.name ?? "your Mac"), then refresh."
        default: break
        }
        if info.readiness != "ready" { return info.reason ?? "\(selectedProvider.name) is not ready on \(selectedHost?.name ?? "your Mac"). Open it, then refresh." }
        guard info.supports("openChat") else { return info.reason ?? "Chat switching is not available for \(selectedProvider.name) on this Mac yet." }
        return isRefreshingChats ? "Loading \(selectedProvider.name) chats…" : "No existing \(selectedProvider.name) chats were found on this Mac."
    }
    var canSend: Bool {
        selectedChat != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isBusy && !isRecording && !isFinalizing && providerInfo?.supports("sendPrompt") == true &&
        currentRoute.map { settings.ledger.pendingSends[$0.storageKey] == nil } == true
    }
    var hasUnresolvedSend: Bool { currentRoute.map { settings.ledger.pendingSends[$0.storageKey] != nil } ?? false }
    /// What the chat on a key is doing. Nil when the key holds no chat, or a
    /// chat the Mac did not list this time: its light stays off, not white.
    func activity(slot index: Int) -> ChatActivity? {
        guard let slot = profile.slots.first(where: { $0.index == index && $0.kind == "chat" }) else { return nil }
        // A Send whose result is unknown needs you whatever the Mac reports.
        // That is known on this device, so it shows even while offline.
        let route = DraftRoute(hostID: selectedHost?.hostID ?? selectedHostID, provider: selectedProvider.rawValue, chatID: slot.targetID)
        if settings.ledger.pendingSends[route.storageKey] != nil { return .error }
        guard lightsAreLive else { return nil }
        return chats.first { $0.id == slot.targetID }?.activity
    }
    /// What the open chat is doing.
    var selectedActivity: ChatActivity? {
        if hasUnresolvedSend { return .error }
        guard lightsAreLive, let chat = selectedChat else { return nil }
        // Only what the Mac just listed. A chat that has left the list has no
        // light; its last known state would otherwise pulse on forever.
        return chats.first { $0.id == chat.id }?.activity
    }
    /// A light is only shown while the Mac is answering and its app is ready.
    /// Offline, locked or closed, the last colors would be a guess, so the keys go dark.
    /// Codex is left out: its saved-chat list says nothing about what a chat is
    /// doing, and a white "idle" light on a working chat would be a false claim.
    var lightsAreLive: Bool { isDemo || (status != nil && providerInfo?.readiness == "ready" && selectedProvider != .codex) }
    /// Between full refreshes, re-reads only what the chats are doing, so a
    /// light is a few seconds old at most. Claude only: reading its sidebar
    /// changes nothing on the Mac, whereas listing Muse's chats opens its chat
    /// panel, and Codex's saved-chat list carries no live state.
    func refreshLights() async {
        guard !isDemo, !isBusy, !isRecording, !isFinalizing, refreshGeneration != gate.generation,
              selectedProvider == .claude, lightsAreLive, providerInfo?.supports("openChat") == true else { return }
        let generation = gate.generation, provider = selectedProvider
        guard let (host, token) = try? connection() else { return }
        // A failure here is left to the next status poll, which reports a lost connection.
        try? await refreshChats(host: host, token: token, provider: provider, generation: generation, enabled: true)
    }
    private var scope: String { "\(selectedHost?.hostID ?? selectedHostID).\(selectedProvider.rawValue)" }
    private var currentRoute: DraftRoute? {
        guard let chat = selectedChat else { return nil }
        return DraftRoute(hostID: selectedHost?.hostID ?? selectedHostID, provider: selectedProvider.rawValue, chatID: chat.id)
    }
    @discardableResult private func persist() -> Bool {
        guard !isDemo else { return true }
        settings.hosts = hosts; settings.selectedHostID = selectedHostID; settings.selectedProvider = selectedProvider
        do { try persistence.save(settings); return true }
        catch { lastError = "Your iPhone could not save controller state. Unlock it and free some storage before sending."; return false }
    }
    private func persistDraft() {
        guard !loadingDraft, let route = currentRoute else { return }
        settings.ledger.set(draft, for: route); persist()
    }
    /// After the key mappings change, the ring goes to whichever key now holds the
    /// open chat, or nowhere. Home (no ring, by choice) is left as it is.
    private func syncSelectedSlot() {
        guard let current = selectedSlotIndex else { return }
        let holders = profile.slots.filter { $0.kind == "chat" && $0.targetID == selectedChat?.id }.map(\.index)
        // The same chat may sit on two keys; stay on the one that was pressed.
        selectedSlotIndex = holders.contains(current) ? current : holders.first
    }
    private func restoreSelection() {
        profile = settings.profiles[scope] ?? .empty(selectedProvider)
        selectedChat = settings.selectedChats[scope]
        if let selectedChat, settings.chatHistory?[scope] == nil { recordHistory(selectedChat) }
        loadingDraft = true; draft = currentRoute.map { settings.ledger.text(for: $0) } ?? ""; loadingDraft = false
        selectedSlotIndex = profile.slots.first { $0.kind == "chat" && $0.targetID == selectedChat?.id }?.index
        sendReady = !draft.isEmpty
    }
    private func invalidateSelection() {
        glasses.stop("Selection changed. Turn on Follow for this Mac and provider.")
        glassesConfirmedChatID = nil
        dictationIntent &+= 1; speech.cancel(); captureRoute = nil
        gate.advance(); status = nil; chats = []; leftOutChatTitles = []; artifacts = []; lastReceipt = nil; lastError = nil; requestedPanel = nil
        isBusy = false; isRefreshingChats = false; sendReady = false
        navigation = .inactive; navigationGeneration = nil
    }
    func selectHost(_ id: String) {
        guard id != selectedHostID, hosts.contains(where: { $0.id == id }) else { return }
        persistDraft(); invalidateSelection(); selectedHostID = id; restoreSelection(); persist()
        if isDemo { loadDemo() } else { connectionMessage = isPaired ? "Connecting…" : "Pair this Mac"; Task { await refresh() } }
    }
    func selectProvider(_ provider: ProviderID) {
        guard provider != selectedProvider else { return }
        persistDraft(); invalidateSelection(); selectedProvider = provider; restoreSelection(); persist()
        if isDemo { loadDemo() } else { connectionMessage = isPaired ? "Connecting…" : "Pair this Mac"; Task { await refresh() } }
    }
    /// Home is "no chat selected", on the deck and in the menus alike. The
    /// chat's draft stays saved for when its key is pressed again. Nothing is
    /// sent to the Mac.
    func returnHome() {
        guard !isRecording, !isFinalizing else { return }
        clearChatAfterNavigation()
    }

    func enableGlassesFollow(takeover: Bool = false) {
        guard foreground, !isDemo, selectedProvider != .muse else {
            glasses.stop("Glasses follow is available for Codex and Claude while this app is open."); return
        }
        do {
            let (host, token) = try connection()
            // A restored selection has not opened the Mac chat in this session.
            // Follow starts on Home until the ordinary open receipt confirms it.
            let confirmed = selectedChat?.id == glassesConfirmedChatID ? selectedChat : nil
            glasses.enable(host: host, token: token, provider: selectedProvider, chatID: confirmed?.id,
                           slotIndex: confirmed == nil ? nil : selectedSlotIndex,
                           draft: confirmed == nil ? "" : draft, recording: confirmed != nil && isRecording,
                           takeover: takeover)
        } catch { glasses.stop(error.localizedDescription) }
    }

    private func publishGlassesDraft() {
        guard !loadingDraft, let confirmed = glassesConfirmedChatID, selectedChat?.id == confirmed else { return }
        glasses.updateDraft(draft, recording: isRecording)
    }

    func setForeground(_ active: Bool) {
        // SwiftUI can report active from both .task and scenePhase. A duplicate
        // callback must not cancel an in-flight pair/status operation.
        guard foreground != active else { return }
        foreground = active
        polling?.cancel(); polling = nil
        if !active {
            // Suspend display publishing before speech cancellation's callback;
            // the reviewed local draft remains on this device while parked.
            if !glasses.enterBackground() { glassesConfirmedChatID = nil }
            dictationIntent &+= 1; speech.cancel(); captureRoute = nil
            gate.advance(); isBusy = false; isRefreshingChats = false; persistDraft()
            navigation = .inactive; navigationGeneration = nil
            return
        }
        glasses.returnToForeground { [weak self] in self?.draft ?? "" }
        guard !isDemo else { return }
        if provisioningTask == nil {
            // Provisioning owns its lifetime separately from foreground polling.
            // It only verifies endpoints and saves credentials; no desktop actions.
            provisioningTask = Task { [weak self] in
                await self?.importProvisioningIfPresent()
                self?.provisioningTask = nil
            }
        }
        let provision = provisioningTask
        polling = Task { [weak self] in
            await provision?.value
            guard !Task.isCancelled else { return }
            await self?.refresh()
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, self.foreground else { return }
                tick += 1
                if tick % 5 == 0 { await self.refresh() }
                else { await self.refreshStatus(); if tick % 2 == 0 { await self.refreshLights() } }
            }
        }
    }

    private func connection() throws -> (RemoteHost, String) {
        guard let host = selectedHost, host.hostID != nil, let token = credentials.token(for: host.id) else { throw RemoteError.unpaired }
        return (host, token)
    }
    private func validate(_ status: HostStatus, host: RemoteHost) throws {
        guard status.protocolVersion == 1 else { throw RemoteError.unsupportedProtocol }
        guard host.hostID == status.hostID else { throw RemoteError.wrongHost }
    }
    private func applyStatus(_ status: HostStatus) {
        self.status = status
        let provider = status.providers.first { $0.id == selectedProvider.rawValue }
        switch provider?.readiness {
        case "ready": connectionMessage = "Connected · \(selectedHost?.name ?? status.hostName)"
        case "locked": connectionMessage = "Mac locked · unlock to control"
        case "needsAccessibility": connectionMessage = "Allow Accessibility on this Mac"
        case "closed": connectionMessage = provider?.reason?.contains("too narrow") == true
            ? "\(selectedProvider.name)’s window is too narrow on this Mac" : "Open \(selectedProvider.name) on this Mac"
        default:
            if provider?.id == "codex", provider?.supports("newChat") == true { connectionMessage = "New chat ready · saved chats unavailable" }
            else { connectionMessage = provider?.supports("artifacts") == true ? "Artifacts ready · chat controls unavailable" : (provider?.reason ?? "Provider unavailable") }
        }
    }
    private func failConnection(_ error: Error) {
        status = nil
        if case RemoteError.unpaired = error { connectionMessage = "Pair this Mac" }
        else { connectionMessage = "Offline · drafts saved on iPhone" }
    }
    private func refreshStatus() async {
        guard !isDemo, !isBusy, refreshGeneration != gate.generation else { return }
        let generation = gate.generation
        do {
            let (host, token) = try connection()
            let live = try await client.fetch(HostStatus.self, host: host, token: token, path: "/v1/status")
            guard gate.accepts(generation) else { return }
            try validate(live, host: host); applyStatus(live); missedStatusPolls = 0
            await recoverPendingSend()
        } catch {
            guard gate.accepts(generation) else { return }
            // One dropped poll on a phone network is common. Going offline on it made
            // every light and the Talk key blink; a second miss in a row is believed.
            missedStatusPolls += 1
            if case RemoteError.unpaired = error { failConnection(error) }
            else if missedStatusPolls >= 2 || status == nil { failConnection(error) }
        }
    }
    private var missedStatusPolls = 0
    func refresh() async {
        guard !isDemo, refreshGeneration != gate.generation, !isBusy else { return }
        let generation = gate.generation, provider = selectedProvider
        refreshGeneration = generation
        defer { if refreshGeneration == generation { refreshGeneration = nil } }
        do {
            let (host, token) = try connection()
            let live = try await client.fetch(HostStatus.self, host: host, token: token, path: "/v1/status")
            guard gate.accepts(generation) else { return }
            try validate(live, host: host); applyStatus(live)
            let capability = live.providers.first { $0.id == provider.rawValue }
            // Identity is checked first. These snapshots are independent, so a
            // slow chat scan must not add its latency to mappings or artifacts.
            async let mappings: Void = refreshProfile(host: host, token: token, provider: provider, generation: generation)
            async let list: Void = refreshChats(host: host, token: token, provider: provider, generation: generation,
                                               enabled: capability?.supports("openChat") == true)
            async let shelf: Void = refreshArtifacts(host: host, token: token, provider: provider, generation: generation,
                                                     chat: selectedChat, enabled: capability?.supports("artifacts") == true)
            async let receipts: Void = recoverPendingSend()
            _ = try await (mappings, list, shelf, receipts)
            await recoverOtherPendingSends()
        } catch { if gate.accepts(generation) { failConnection(error); if isPaired { lastError = ConnectionHelp.describe(error, mac: selectedHost?.name) } } }
    }

    private func refreshProfile(host: RemoteHost, token: String, provider: ProviderID, generation: Int) async throws {
        guard gate.accepts(generation), !isBusy else { return }
        let saved = try await client.fetch(RemoteProfile.self, host: host, token: token, path: "/v1/profile",
            query: [URLQueryItem(name: "provider", value: provider.rawValue)])
        // A GET started before a successful PUT may arrive last. Revisions are
        // monotonic on the host; never roll a just-saved mapping backward.
        guard gate.accepts(generation), saved.provider == provider.rawValue, saved.revision >= profile.revision else { return }
        if profile != saved { profile = saved; settings.profiles[scope] = saved; syncSelectedSlot(); persist() }
    }

    private func refreshChats(host: RemoteHost, token: String, provider: ProviderID, generation: Int, enabled: Bool) async throws {
        guard enabled, gate.accepts(generation), !isBusy else { return }
        isRefreshingChats = true
        defer { if gate.accepts(generation) { isRefreshingChats = false } }
        let list = try await client.fetch(ChatsResponse.self, host: host, token: token, path: "/v1/chats",
            query: [URLQueryItem(name: "provider", value: provider.rawValue)])
        guard gate.accepts(generation) else { return }
        chats = list.chats
        leftOutChatTitles = Array((list.leftOut ?? []).prefix(20))
        if let match = list.chats.first(where: { $0.id == selectedChat?.id }) { selectedChat = match }
    }

    func pair(_ url: URL) async throws {
        guard !isDemo else { return }
        let payload = try PairingPayload.decode(url, allowLocalhost: RemoteClient.localDevelopmentAllowed)
        try await installPairing(payload, activate: true)
    }
    /// What this device is called in the Mac's list of paired devices. The app
    /// sets it at launch; the core has no access to the device's name.
    static var deviceName: () -> String = { "iPhone or iPad" }
    private struct PairExchange: Encodable { let code: String; let deviceName: String }
    private struct PairIssued: Decodable { let token: String }

    private func installPairing(_ scanned: PairingPayload, activate: Bool) async throws {
        let generation = gate.generation
        var payload = scanned
        let candidate = RemoteHost(id: payload.hostID, name: payload.name, baseURL: payload.baseURL, hostID: payload.hostID, lanURL: payload.lanURL, pin: payload.pin)
        if payload.v == 2 {
            // The code is good once. Trade it for a secret that belongs to this
            // device alone, which the Mac can later revoke without touching others.
            let body = try JSONEncoder().encode(PairExchange(code: payload.token, deviceName: Self.deviceName()))
            let issued = try await client.fetch(PairIssued.self, host: candidate, token: "", path: "/v1/pair", method: "POST", body: body)
            guard issued.token.count >= 32, issued.token.count <= 1024,
                  issued.token.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { throw RemoteError.invalidPairing }
            payload.token = issued.token
        }
        let remote = try await client.fetch(HostStatus.self, host: candidate, token: payload.token, path: "/v1/status")
        try validate(remote, host: candidate)
        guard !activate || gate.accepts(generation) else { throw CancellationError() }
        let existing = hosts.firstIndex { $0.hostID == payload.hostID || $0.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == payload.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        var paired = candidate
        if let existing { paired.id = hosts[existing].id; paired.name = hosts[existing].name }
        try credentials.save(payload.token, for: paired.id)
        if let existing { hosts[existing] = paired } else { hosts.append(paired) }
        if activate || selectedHostID.isEmpty {
            invalidateSelection(); selectedHostID = paired.id; restoreSelection(); applyStatus(remote); persist()
            if activate { await refresh() }
        } else {
            if paired.id == selectedHostID { invalidateSelection(); restoreSelection(); applyStatus(remote) }
            persist()
        }
    }

    /// Private, one-time devicectl provisioning. Credentials are verified before Keychain import.
    /// The handoff file is removed immediately after reading, including malformed/failed imports.
    func importProvisioningIfPresent() async {
        guard !isDemo, !importingProvisioning else { return }
        let documents = provisioningDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var url = documents.appendingPathComponent("GenesisPairing.json")
        let hasFile = FileManager.default.fileExists(atPath: url.path)
        guard hasFile || !pendingProvisioning.isEmpty else { return }
        importingProvisioning = true; defer { importingProvisioning = false }
        do {
            if hasFile {
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try url.setResourceValues(values)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size > 0, size <= 131_072 else {
                    try? FileManager.default.removeItem(at: url); throw RemoteError.invalidPairing
                }
                let data: Data
                do { data = try Data(contentsOf: url) }
                catch { try? FileManager.default.removeItem(at: url); throw error }
                try FileManager.default.removeItem(at: url)
                let payloads = try JSONDecoder().decode([PairingPayload].self, from: data)
                guard !payloads.isEmpty, payloads.count <= 10 else { throw RemoteError.invalidPairing }
                for payload in payloads {
                    pendingProvisioning.removeAll { $0.hostID == payload.hostID }
                    pendingProvisioning.append(payload)
                }
            }
            var failed = [String]()
            var retry = [PairingPayload]()
            for payload in pendingProvisioning {
                var validated: PairingPayload?
                do {
                    let b64 = try JSONEncoder().encode(payload).base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                    guard let link = URL(string: "genesiscontroller://pair?data=\(b64)") else { throw RemoteError.invalidPairing }
                    let candidate = try PairingPayload.decode(link, allowLocalhost: RemoteClient.localDevelopmentAllowed)
                    validated = candidate
                    try await installPairing(candidate, activate: false)
                } catch {
                    failed.append(payload.name.isEmpty ? "A Mac" : String(payload.name.prefix(50)))
                    // Keep transient failures only in memory. Never persist an
                    // unverified token in settings, logs, or another plaintext file.
                    if let validated { retry.append(validated) }
                }
            }
            pendingProvisioning = retry
            if !failed.isEmpty { lastError = "Could not finish pairing \(failed.joined(separator: ", ")). Join the same Wi-Fi as that Mac (or connect Tailscale) and scan its pairing code." }
        } catch {
            try? FileManager.default.removeItem(at: url)
            lastError = "The private setup file could not be imported. Scan the pairing code from the Mac instead."
        }
    }

    @discardableResult func saveSlot(_ slot: SlotMapping) async -> Bool {
        guard (0..<6).contains(slot.index), ["chat", "action", "empty"].contains(slot.kind), !isBusy else { return false }
        lastError = nil
        var edited = profile
        edited.slots = profile.orderedSlots.map { $0.index == slot.index ? slot : $0 }
        return await saveProfile(edited)
    }
    @discardableResult func saveQuickAction(_ index: Int, actionID: String) async -> Bool {
        guard (0..<4).contains(index), availableActions.contains(where: { $0.id == actionID }), !isBusy else { return false }
        var edited = profile
        var keys = profile.quickActionIDs; keys[index] = actionID; edited.quickActions = keys
        return await saveProfile(edited)
    }
    private func saveProfile(_ edited: RemoteProfile) async -> Bool {
        lastError = nil
        if isDemo { profile = edited; settings.profiles[scope] = edited; syncSelectedSlot(); return true }
        let generation = gate.generation
        isBusy = true; defer { if gate.accepts(generation) { isBusy = false } }
        do {
            let (host, token) = try connection()
            let saved = try await client.fetch(RemoteProfile.self, host: host, token: token, path: "/v1/profile", method: "PUT", body: JSONEncoder().encode(edited))
            guard gate.accepts(generation), saved.provider == selectedProvider.rawValue else { return false }
            profile = saved; settings.profiles[scope] = saved; syncSelectedSlot(); persist()
            return true
        } catch { if gate.accepts(generation) { lastError = ConnectionHelp.describe(error, mac: selectedHost?.name) }; return false }
    }

    func openSlot(_ index: Int) async {
        guard !isBusy, let slot = profile.slots.first(where: { $0.index == index }) else { return }
        lastError = nil
        if slot.kind == "chat" {
            // The Mac gets the first word: it can sometimes reach a chat the list
            // does not show. If it cannot, say why in terms of this key.
            let missing = missingChatMessage(slot)
            let chat = chats.first { $0.id == slot.targetID } ?? ChatRecord(id: slot.targetID, title: slot.title, state: "Unknown")
            await selectChat(chat, preferredSlotIndex: index)
            if missing != nil, selectedChat?.id != chat.id, lastError != nil { lastError = nil; hint = hint(forMissingChatOn: slot) }
        } else if slot.kind == "action" {
            await runAction(slot.targetID)
        }
    }

    /// Why a key's chat probably cannot be opened: the Mac has just listed its
    /// chats and this one is not among them. Nil when it is there, or when the
    /// list is not fresh enough to say. Used to explain a failed open.
    func missingChatMessage(_ slot: SlotMapping) -> String? {
        guard !isDemo, lightsAreLive, !chats.isEmpty, !chats.contains(where: { $0.id == slot.targetID }) else { return nil }
        if leftOutChatTitles.contains(slot.title) {
            return "More than one \(selectedProvider.name) chat is titled “\(slot.title)”, so this key can’t tell them apart. Rename one on the Mac, or hold the key to choose another chat."
        }
        return "“\(slot.title)” isn’t in \(selectedProvider.name) on this Mac any more. It may have been renamed or closed. Hold the key to choose a chat for it."
    }
    @discardableResult func runAction(_ id: String) async -> Bool {
        guard let action = action(id), canRunAction(id) else {
            let message = actionUnavailableReason(id) ?? "This action is not available."
            if id == "sendPrompt", let route = currentRoute, let pending = settings.ledger.pendingSends[route.storageKey] { errorCommandID = pending.commandID }
            _ = message
            hint = hint(forAction: id)
            return false
        }
        lastError = nil
        if id == "dictate" {
            if isRecording { await stopDictation(); return !isRecording }
            await startDictation(); return isRecording
        }
        if id == "artifacts" { requestedPanel = "artifacts"; await refreshArtifacts(); return true }
        if ["previousControllerChat", "nextControllerChat"].contains(id), let (index, chat) = historyDestination(id) {
            let receipt = await execute(action:"openChat",chatID:chat.id)
            guard receipt?.isConfirmed == true else { return false }
            changeChat(chat, historyIndex:index); return true
        }
        if id == "sendPrompt" {
            let generation = gate.generation; await sendDraft()
            return gate.accepts(generation) && lastReceipt?.isAcceptedSend == true
        }
        let generation = gate.generation
        let receipt = await execute(action:id, chatID:action.requiresChat ? selectedChat?.id : nil)
        guard let receipt else {
            if gate.accepts(generation), action.changesChat { clearChatAfterNavigation() }
            return false
        }
        if receipt.isConfirmed, let active = receipt.activeChat, !active.id.isEmpty {
            changeChat(active)
        } else if action.changesChat {
            // Even an uncertain navigation may have moved the desktop. Keep its
            // previous draft, but never retain that chat as an implicit Send target.
            clearChatAfterNavigation()
        }
        if action.changesChat { Task { await refresh() } }
        if receipt.isConfirmed, action.opensNavigation == true {
            navigationKeepsChat = action.requiresChat && !action.changesChat
            let menuGeneration = gate.generation
            await refreshNavigation()
            if gate.accepts(menuGeneration), navigation.active { requestedPanel = "navigate" }
        }
        return receipt.isConfirmed
    }

    private func clearChatAfterNavigation() {
        persistDraft(); dictationIntent &+= 1; speech.cancel(); captureRoute = nil; gate.advance()
        selectedChat = nil; settings.selectedChats.removeValue(forKey:scope); selectedSlotIndex = nil
        loadingDraft = true; draft = ""; loadingDraft = false; sendReady = false; artifacts = []; persist()
        navigation = .inactive; navigationGeneration = nil
        glassesConfirmedChatID = nil
        glasses.confirmedChat(provider: selectedProvider, chatID: nil, slotIndex: nil, draft: "")
    }

    func selectChat(_ chat: ChatRecord, preferredSlotIndex: Int? = nil) async {
        guard !isBusy else { return }
        if isDemo {
            acknowledgeCompletion(chat.id); changeChat(chat, preferredSlotIndex: preferredSlotIndex); return
        }
        guard providerInfo?.supports("openChat") == true else { lastError = chatAvailabilityMessage; return }
        let receipt = await execute(action: "openChat", chatID: chat.id)
        guard let receipt, receipt.isConfirmed else { return }
        acknowledgeCompletion(chat.id)
        if let named = receipt.activeChat, !named.id.isEmpty, named.id != chat.id { changeChat(named) }
        else { changeChat(chat, preferredSlotIndex: preferredSlotIndex) }
    }
    /// Opening a finished chat is what clears its green light. The Mac reports
    /// that on the next refresh; this keeps the key from staying green until then.
    private func acknowledgeCompletion(_ id: String) {
        guard let index = chats.firstIndex(where: { $0.id == id }), chats[index].activity == .complete else { return }
        chats[index].state = "Idle"
    }
    private func historyDestination(_ id: String) -> (Int, ChatRecord)? {
        guard let history = settings.chatHistory?[scope],
              let index = history.destination(id == "previousControllerChat" ? -1 : 1, hasCurrentChat:selectedChat != nil) else { return nil }
        return (index, history.entries[index])
    }
    private func recordHistory(_ chat: ChatRecord, index: Int? = nil) {
        var histories = settings.chatHistory ?? [:], history = histories[scope] ?? .init()
        if let index, history.entries.indices.contains(index) { history.cursor = index; history.entries[index] = chat }
        else { history.record(chat) }
        histories[scope] = history; settings.chatHistory = histories
    }
    private func changeChat(_ chat: ChatRecord, historyIndex: Int? = nil, preferredSlotIndex: Int? = nil) {
        // Multiple keys may target the same chat. Resolve the exact confirmed
        // key before publishing, and retain it for same-chat action receipts.
        let slotToPreserve = preferredSlotIndex ?? (selectedChat?.id == chat.id ? selectedSlotIndex : nil)
        persistDraft(); dictationIntent &+= 1; speech.cancel(); captureRoute = nil; gate.advance()
        selectedChat = chat; settings.selectedChats[scope] = chat
        recordHistory(chat,index:historyIndex)
        loadingDraft = true; draft = currentRoute.map { settings.ledger.text(for: $0) } ?? ""; loadingDraft = false
        let matchingSlots = profile.slots.filter { $0.kind == "chat" && $0.targetID == chat.id }
        selectedSlotIndex = matchingSlots.first { $0.index == slotToPreserve }?.index ?? matchingSlots.first?.index
        sendReady = !draft.isEmpty; artifacts = []; persist()
        navigation = .inactive; navigationGeneration = nil
        glassesConfirmedChatID = chat.id
        glasses.confirmedChat(provider: selectedProvider, chatID: chat.id, slotIndex: selectedSlotIndex, draft: draft)
        if isDemo { loadDemoArtifacts() }
        else { Task { await refreshArtifacts() } }
    }

    func refreshNavigation() async {
        if isDemo {
            if !navigation.active || navigationGeneration != gate.generation {
                navigation = .init(active:true,session:"00000000-0000-4000-8000-000000000099",label:"Demo · Add attachment",selection:"Choose a file from your Mac")
                navigationGeneration = gate.generation
            }
            return
        }
        guard !isDemo, !Task.isCancelled, !isBusy, providerInfo?.supports("menuNavigation") == true,
              navigationRefreshGeneration != gate.generation else { return }
        let generation = gate.generation, provider = selectedProvider
        navigationRefreshGeneration = generation
        defer { if navigationRefreshGeneration == generation { navigationRefreshGeneration = nil } }
        do {
            let (host, token) = try connection()
            var query = [URLQueryItem(name:"provider",value:provider.rawValue), URLQueryItem(name:"generation",value:String(generation))]
            if let chat = selectedChat { query.append(URLQueryItem(name:"chatID",value:chat.id)) }
            let state = try await client.fetch(RemoteNavigationState.self,host:host,token:token,path:"/v1/navigation",query:query,deadline:3)
            guard gate.accepts(generation), !Task.isCancelled else { return }
            applyNavigation(state, generation:generation)
        } catch {
            guard gate.accepts(generation), !Task.isCancelled else { return }
            navigation = .init(active:false,session:nil,label:"This menu is not available. Open it on your Mac and refresh.",selection:nil)
            navigationGeneration = nil
        }
    }
    private func applyNavigation(_ state: RemoteNavigationState, generation: Int) {
        guard gate.accepts(generation) else { return }
        guard !state.active || state.session.flatMap(UUID.init(uuidString:)) != nil else { navigation = .inactive; navigationGeneration = nil; return }
        navigation = state; navigationGeneration = state.active ? generation : nil
    }
    /// Moves or acts on the menu open on the Mac. Previous and Next pressed
    /// while a menu step is still in flight wait their turn, because moving
    /// the highlight is harmless to repeat. Select, Back and Close never wait:
    /// each acts on what the Mac shows at the moment it runs.
    func navigate(_ action: String) async {
        guard ["menuPrevious","menuNext","menuSelect","menuBack","menuHome"].contains(action),
              navigation.active, navigationGeneration == gate.generation else { return }
        if isBusy {
            if navigating, ["menuPrevious","menuNext"].contains(action), queuedMenuSteps.count < 8 { queuedMenuSteps.append(action) }
            return
        }
        navigating = true
        defer { navigating = false; queuedMenuSteps.removeAll() }
        await navigateOnce(action)
        while !queuedMenuSteps.isEmpty {
            let next = queuedMenuSteps.removeFirst()
            guard navigation.active, navigationGeneration == gate.generation, lastError == nil, !isBusy, !Task.isCancelled else { return }
            await navigateOnce(next)
        }
    }
    private func navigateOnce(_ action: String) async {
        guard navigation.active, navigationGeneration == gate.generation, let session = navigation.session, !isBusy else { return }
        if isDemo {
            if action == "menuHome" { clearChatAfterNavigation(); returnHome() }
            else { navigation.selection = action == "menuPrevious" ? "Demo · Previous menu item" : action == "menuNext" ? "Demo · Next menu item" : "Demo · Selection preview" }
            return
        }
        let generation = gate.generation
        let receipt = await execute(action:action,chatID:selectedChat?.id,navigationSession:session)
        guard gate.accepts(generation) else { return }
        guard let receipt else {
            if action == "menuSelect" { clearChatAfterNavigation(); await refreshNavigation() }
            return
        }
        if receipt.isConfirmed, let active = receipt.activeChat, !active.id.isEmpty {
            if active.id != selectedChat?.id { changeChat(active) }
        } else if action == "menuSelect", !(receipt.isConfirmed && navigationKeepsChat) {
            // A confirmed choice in the chat's own menu (its model, an attachment)
            // leaves the chat where it was. Anything else may have moved the Mac.
            clearChatAfterNavigation()
        }
        if action == "menuHome", receipt.isConfirmed { clearChatAfterNavigation(); returnHome() }
        if let state = receipt.navigation, gate.accepts(generation) { applyNavigation(state,generation:generation) }
        else { navigation = .inactive; navigationGeneration = nil; await refreshNavigation() }
    }

    func startDictation() async {
        guard canDictate, !isRecording else {
            DictationDiagnostics.record("store_start_blocked", ["recording": isRecording ? 1 : 0,
                "finalizing": isFinalizing ? 1 : 0, "busy": isBusy ? 1 : 0, "paired": isPaired ? 1 : 0,
                "chat": hasDictationChat ? 1 : 0, "capable": providerInfo?.supportsPhoneDictation == true ? 1 : 0])
            return
        }
        dictationIntent &+= 1; let intent = dictationIntent
        guard let route = currentRoute else { return }
        captureRoute = route; let base = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        sendReady = false; lastError = nil
        if isDemo { isRecording = true; return }
        DictationDiagnostics.record("store_start", ["intent": intent])
        var sawTranscript = false
        speech.onText = { [weak self] text in
            guard let self, self.dictationIntent == intent, self.captureRoute == route else { return }
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if !sawTranscript {
                sawTranscript = true
                DictationDiagnostics.record("store_first_transcript", ["intent": intent])
            }
            let full = base.isEmpty ? text : base + "\n" + text
            self.settings.ledger.set(full, for: route)
            if self.currentRoute == route { self.draft = full } else { self.persist() }
        }
        do {
            try await speech.start()
            // Selection changes and releases already cancel their own capture.
            // An older authorization finishing must not cancel a newer session.
        } catch {
            if dictationIntent == intent {
                captureRoute = nil
                sendReady = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                lastError = ConnectionHelp.describe(error, mac: selectedHost?.name)
            }
        }
    }
    func stopDictation() async {
        if !isDemo { DictationDiagnostics.record("store_stop", ["intent": dictationIntent, "finalizing": isFinalizing ? 1 : 0]) }
        if isDemo {
            isRecording = false
            if draft.isEmpty { draft = "Show me the latest changes and what still needs attention." }
            sendReady = !draft.isEmpty; return
        }
        // The first release owns finalization. A second release must not clear
        // its capture route while the final transcript is still arriving.
        guard speech.state != .finalizing else { return }
        // Cancels an outstanding permission prompt/start even before audio has begun.
        if speech.state == .authorizing || speech.state == .idle {
            dictationIntent &+= 1; speech.cancel(); captureRoute = nil
            sendReady = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return
        }
        let intent = dictationIntent
        await speech.stop()
        if intent == dictationIntent { captureRoute = nil; sendReady = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The last Send was refused because the Mac's message box already has text
    /// in it. The alert then offers to replace that text, which is your call.
    @Published var macDraftBlocksSend = false
    func sendDraft(replacingMacDraft: Bool = false) async {
        macDraftBlocksSend = false
        guard canSend, let route = currentRoute, let chat = selectedChat else {
            if let route = currentRoute, let pending = settings.ledger.pendingSends[route.storageKey] {
                commandError(RemoteError.unresolvedSend.localizedDescription, id: pending.commandID)
            }
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDemo {
            lastReceipt = .init(id: UUID().uuidString, status: "confirmed", message: "Demo only — no prompt sent.")
            draft = ""; sendReady = false; return
        }
        let id = UUID().uuidString
        let pending = PendingSend(commandID: id, route: route, textDigest: Self.digest(text), createdAt: Date())
        do {
            try settings.ledger.begin(pending)
            guard persist() else { settings.ledger.pendingSends.removeValue(forKey: route.storageKey); return }
        }
        catch { lastError = ConnectionHelp.describe(error, mac: selectedHost?.name); return }
        let receipt = await execute(action: "sendPrompt", chatID: chat.id, text: text, id: id, replaceDraft: replacingMacDraft)
        guard let receipt else { return }
        finishSend(receipt, pending: pending)
        macDraftBlocksSend = receipt.status == "failed" && receipt.blocker == "macDraft"
        // A first prompt turns a new, unnamed session into a named chat. The Mac
        // says which; keep working in it instead of in a session that is gone.
        if receipt.isAcceptedSend, let named = receipt.activeChat, !named.id.isEmpty, named.id != chat.id, selectedChat?.id == chat.id {
            changeChat(named); Task { await refresh() }
        }
    }
    private static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func commandError(_ message: String, id: String) {
        lastError = message; errorCommandID = id
    }
    private func finishSend(_ receipt: CommandReceipt, pending: PendingSend) {
        guard settings.ledger.pendingSends[pending.route.storageKey]?.commandID == pending.commandID else { return }
        if receipt.isAcceptedSend {
            let current = settings.ledger.text(for: pending.route).trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.digest(current) == pending.textDigest {
                settings.ledger.set("", for: pending.route)
                if currentRoute == pending.route { loadingDraft = true; draft = ""; loadingDraft = false; sendReady = false }
            }
        }
        settings.ledger.resolve(receipt, route: pending.route); persist()
        // Display observation only. The existing receipt/ledger above remains the
        // sole authority for delivery and clearing a draft; G2 never sends again.
        if currentRoute == pending.route { glasses.sendChanged(receipt, draft: draft) }
    }
    func recoverPendingSend() async {
        guard !isDemo, !isBusy, let route = currentRoute,
              let pending = settings.ledger.pendingSends[route.storageKey],
              recoveringCommands.insert(pending.commandID).inserted else { return }
        defer { recoveringCommands.remove(pending.commandID) }
        let generation = gate.generation, sequence = commandSequence
        do {
            let (host, token) = try connection()
            let receipt = try await client.fetch(CommandReceipt.self, host: host, token: token, path: "/v1/commands/\(pending.commandID)")
            guard receipt.id == pending.commandID else { throw RemoteError.invalidResponse }
            guard settings.ledger.pendingSends[route.storageKey]?.commandID == pending.commandID else { return }
            finishSend(receipt, pending: pending)
            if gate.accepts(generation), sequence == commandSequence {
                lastReceipt = receipt
                if receipt.isAcceptedSend, errorCommandID == pending.commandID { lastError = nil }
                else if receipt.status == "failed", errorCommandID == pending.commandID { commandError(receipt.message, id: receipt.id) }
            }
        } catch {
            if gate.accepts(generation), sequence == commandSequence,
               settings.ledger.pendingSends[route.storageKey]?.commandID == pending.commandID {
                lastReceipt = .init(id: pending.commandID, status: "uncertain", message: "Send has not been confirmed. Check the Mac before sending again.")
            }
        }
    }
    /// Only call after the user explicitly checks the destination chat.
    /// Sends whose result the Mac has not yet confirmed, on any chat.
    var unresolvedSendCount: Int { settings.ledger.pendingSends.count }
    /// A Send left unconfirmed on a chat that is not open still turns that chat's
    /// key red. Ask the Mac about those too, so the key clears once the Mac knows,
    /// without having to open each chat. Nothing is ever sent again.
    private func recoverOtherPendingSends() async {
        guard !isDemo, !isBusy else { return }
        let hostID = selectedHost?.hostID ?? selectedHostID, current = currentRoute?.storageKey
        let others = settings.ledger.pendingSends.values.filter { $0.route.hostID == hostID && $0.route.storageKey != current }
        guard !others.isEmpty, let (host, token) = try? connection() else { return }
        for pending in others.prefix(6) where recoveringCommands.insert(pending.commandID).inserted {
            defer { recoveringCommands.remove(pending.commandID) }
            guard let receipt = try? await client.fetch(CommandReceipt.self, host: host, token: token, path: "/v1/commands/\(pending.commandID)", deadline: 3),
                  receipt.id == pending.commandID,
                  settings.ledger.pendingSends[pending.route.storageKey]?.commandID == pending.commandID else { continue }
            finishSend(receipt, pending: pending)
        }
    }
    func acknowledgeUncertainSend(wasSent: Bool) {
        guard let route = currentRoute, let pending = settings.ledger.pendingSends[route.storageKey] else { return }
        let receipt = CommandReceipt(id: pending.commandID, status: wasSent ? "confirmed" : "failed",
            message: wasSent ? "You confirmed this prompt arrived." : "You confirmed this prompt did not arrive. It has not been resent.")
        finishSend(receipt, pending: pending); lastReceipt = receipt
        if errorCommandID == pending.commandID { lastError = nil }
    }
    func stopResponse() async { _ = await execute(action: "stop", chatID: selectedChat?.id) }
    func startNativeVoice() async { _ = await execute(action: "nativeVoice", chatID: selectedChat?.id) }

    private func execute(action: String, chatID: String?, text: String? = nil, artifactID: String? = nil, id: String = UUID().uuidString,
                         navigationSession: String? = nil, replaceDraft: Bool = false) async -> CommandReceipt? {
        guard !isBusy else { return nil }
        if isDemo {
            let receipt = CommandReceipt(id: id, status: "confirmed", message: "Demo only — no Mac action performed.")
            lastReceipt = receipt; return receipt
        }
        let menuCommand = ["menuPrevious","menuNext","menuSelect","menuBack","menuHome"].contains(action)
        guard providerInfo?.supports(menuCommand ? "menuNavigation" : action == "openArtifact" ? "artifacts" : action) == true else {
            lastError = RemoteError.capability(action).localizedDescription
            return CommandReceipt(id: id, status: "failed", message: lastError ?? "Unavailable")
        }
        let generation = gate.generation, provider = selectedProvider
        commandSequence &+= 1
        isBusy = true; lastError = nil; lastReceipt = nil
        defer { if gate.accepts(generation) { isBusy = false } }
        var posted = false
        var requestContext: (RemoteHost, String)?
        do {
            let (host, token) = try connection()
            requestContext = (host, token)
            let command = RemoteCommand(id: id, hostID: host.hostID!, provider: provider.rawValue, chatID: chatID,
                action: action, text: text, artifactID: artifactID, generation: generation, navigationSession:navigationSession,
                replaceDraft: replaceDraft ? true : nil)
            let body = try JSONEncoder().encode(command)
            posted = true
            let receipt = try await client.fetch(CommandReceipt.self, host: host, token: token, path: "/v1/commands", method: "POST", body: body)
            guard receipt.id == id else { throw RemoteError.invalidResponse }
            if gate.accepts(generation) {
                lastReceipt = receipt
                if receipt.status == "failed" || receipt.status == "uncertain" { commandError(receipt.message, id: id) }
                return receipt
            }
            // Sending receipts still reconcile against their original draft; navigation results must not change selection.
            return action == "sendPrompt" ? receipt : nil
        } catch {
            let definitelyRejected: Bool
            if case let RemoteError.server(code, _) = error { definitelyRejected = [400,401,403,409,413,422].contains(code) }
            else { definitelyRejected = !posted }
            // The Mac may have finished after its POST response was lost. Ask
            // for that exact receipt once before presenting uncertainty. Never
            // repeat the command, and keep the original host even after a switch.
            if action == "sendPrompt", posted, !definitelyRejected, !Task.isCancelled,
               let (host, token) = requestContext,
               let recovered = try? await client.fetch(CommandReceipt.self, host: host, token: token,
                   path: "/v1/commands/\(id)", deadline: 2), recovered.id == id {
                if gate.accepts(generation) {
                    lastReceipt = recovered
                    if recovered.status == "failed" || recovered.status == "uncertain" { commandError(recovered.message, id: id) }
                }
                return recovered
            }
            let receipt = CommandReceipt(id: id, status: definitelyRejected ? "failed" : "uncertain",
                message: definitelyRejected ? error.localizedDescription : "The Mac's result is unconfirmed. Nothing will be sent again automatically.")
            if gate.accepts(generation) { lastReceipt = receipt; commandError(receipt.message, id: id) }
            return action == "sendPrompt" || gate.accepts(generation) ? receipt : nil
        }
    }

    func refreshArtifacts() async {
        guard !isDemo, !isBusy, providerInfo?.supports("artifacts") == true else { return }
        let generation = gate.generation, provider = selectedProvider
        let chat = selectedChat
        do {
            let (host, token) = try connection()
            await refreshArtifacts(host: host, token: token, provider: provider, generation: generation, chat: chat, enabled: true)
        } catch { if gate.accepts(generation) { lastError = ConnectionHelp.describe(error, mac: selectedHost?.name) } }
    }
    private func refreshArtifacts(host: RemoteHost, token: String, provider: ProviderID, generation: Int,
                                  chat: ChatRecord?, enabled: Bool) async {
        guard enabled, gate.accepts(generation), !isBusy, artifactRefreshGeneration != generation else { return }
        artifactRefreshGeneration = generation
        defer { if artifactRefreshGeneration == generation { artifactRefreshGeneration = nil } }
        do {
            var query = [URLQueryItem(name: "provider", value: provider.rawValue)]
            if let chat { query.append(URLQueryItem(name: "chatID", value: chat.id)) }
            let result = try await client.fetch(ArtifactsResponse.self, host: host, token: token, path: "/v1/artifacts", query: query)
            guard gate.accepts(generation) else { return }
            artifacts = result.artifacts.filter { $0.hostID == host.hostID && $0.provider == provider.rawValue && (chat == nil || $0.chatID.isEmpty || $0.chatID == chat?.id) }
        } catch { if gate.accepts(generation) { lastError = ConnectionHelp.describe(error, mac: selectedHost?.name) } }
    }
    func openArtifact(_ artifact: ArtifactRecord) async {
        guard artifact.provider == selectedProvider.rawValue, artifact.hostID == selectedHost?.hostID else { return }
        _ = await execute(action: "openArtifact", chatID: artifact.chatID, artifactID: artifact.id)
    }
    func artifactRequest(_ artifact: ArtifactRecord) -> URLRequest? {
        guard artifact.provider == selectedProvider.rawValue, artifact.hostID == selectedHost?.hostID else { return nil }
        if let urlString = artifact.url, let url = URL(string: urlString), url.scheme == "https",
           url.user == nil, url.password == nil {
            return URLRequest(url: url)
        }
        guard let (host, token) = try? connection(), host.hostID == artifact.hostID,
              UUID(uuidString: artifact.id) != nil else { return nil }
        return try? client.request(host, token: token, path: "/v1/artifacts/\(artifact.id)/content")
    }

    private func loadDemo() {
        let identity = selectedHost?.hostID ?? "00000000-0000-4000-8000-000000000002"
        let demoActions: [RemoteAction] = [
            .init(id:"newChat",title:"New chat",group:"Navigate",detail:"Open an empty chat without sending a prompt.",requiresChat:false,changesChat:true),
            .init(id:"searchChats",title:"Search chats",group:"Navigate",detail:"Find a session on your Mac.",requiresChat:false,changesChat:false,opensNavigation:true),
            .init(id:"modelAndEffort",title:"Model & effort",group:"Compose",detail:"Open the model and reasoning controls.",requiresChat:true,changesChat:false,opensNavigation:true),
            .init(id:"addAttachment",title:"Add attachment",group:"Compose",detail:"Choose a file using the menu navigator.",requiresChat:true,changesChat:false,opensNavigation:true),
            .init(id:"toggleSidebar",title:"Toggle sidebar",group:"Panels",detail:"Show or hide the Mac’s chat sidebar.",requiresChat:false,changesChat:false),
            .init(id:"toggleTerminal",title:"Terminal",group:"Panels",detail:"Show the selected session’s terminal panel.",requiresChat:true,changesChat:false),
            .init(id:"keyboardShortcuts",title:"Keyboard shortcuts",group:"Panels",detail:"Show the provider’s shortcut reference.",requiresChat:false,changesChat:false)
        ]
        status = HostStatus(protocolVersion: 1, hostID: identity, hostName: selectedHost?.name ?? "Mini 2",
            providers: ProviderID.allCases.map { provider in
                var actions = provider == .muse ? [] : demoActions.filter { provider == .claude || ["newChat","modelAndEffort","toggleSidebar","toggleTerminal","keyboardShortcuts"].contains($0.id) }
                if provider == .codex, let index = actions.firstIndex(where: { $0.id == "modelAndEffort" }) {
                    actions[index].title = "Change model"
                    actions[index].detail = "Open model and reasoning choices for the current Codex view on your Mac."
                    actions[index].requiresChat = false
                }
                let base = provider == .muse ? ["artifacts"] : provider == .claude ? ["openChat","sendPrompt","stop","artifacts","menuNavigation"] : ["openChat","artifacts","menuNavigation"]
                return .init(id:provider.rawValue,name:provider.name,installed:true,readiness:"ready",capabilities:base + actions.map(\.id),
                             reason:"Design preview only. No Mac commands are sent. Native live voice is not connected.",actions:actions)
            })
        chats = ["Controller app", "OMAC workspace", "Design studio", "Weekly review", "Build notes", "Ideas & experiments"].enumerated().map {
            // One of each light, so the demo shows what the colors mean.
            ChatRecord(id: "demo-\(selectedProvider.rawValue)-\($0.offset)", title: $0.element,
                       state: ["Working", "Unread", "Needs input", "Idle", "Something went wrong", "Idle"][$0.offset])
        }
        if settings.profiles[scope] == nil {
            profile = .init(provider: selectedProvider.rawValue, revision: 1, slots: chats.enumerated().map {
                .init(index: $0.offset, kind: "chat", title: $0.element.title, targetID: $0.element.id)
            }); settings.profiles[scope] = profile
        }
        if selectedChat == nil { selectedChat = chats[0]; settings.selectedChats[scope] = chats[0]; selectedSlotIndex = 0 }
        connectionMessage = "Interactive preview · no Mac connected"
        loadDemoArtifacts()
    }

    private func loadDemoArtifacts() {
        artifacts = ["Build notes", "Design review", "Test report"].enumerated().map {
            .init(id: "demo-artifact-\($0.offset)", title: $0.element, kind: "text", url: nil,
                  mimeType: "text/plain", hostID: status?.hostID ?? "", provider: selectedProvider.rawValue,
                  chatID: selectedChat?.id ?? "")
        }
    }
}
