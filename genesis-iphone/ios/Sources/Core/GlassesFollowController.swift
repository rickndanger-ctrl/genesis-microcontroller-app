import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// One foreground native controller owns a short-lived, display-only lease.
/// All writes are serialized, including cleanup of a claim that completes late.
@MainActor
final class GlassesFollowController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var connecting = false
    @Published private(set) var snapshot: GlassesDisplaySnapshot?
    @Published private(set) var desired = GlassesDisplayState(provider: .codex)
    @Published private(set) var message = "Show this controller on your G2 glasses."
    @Published private(set) var otherOwner: String?
    @Published private(set) var unsupported = false
    @Published private(set) var draftIsExcerpt = false

    let sourceID: String
    let sourceName: String
    private let transport: any GlassesDisplayTransport
    private let automaticPolling: Bool
    private let previewOnly: Bool
    private var host: RemoteHost?
    private var token: String?
    private var leaseID: String?
    private var sequence = 0
    private var generation = 0
    private var intent = 0
    private var tail: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var draftDebounce: Task<Void, Never>?
    private var scheduledGeneration: Int?

    init(transport: any GlassesDisplayTransport, sourceID: String? = nil, sourceName: String? = nil,
         automaticPolling: Bool = true, previewOnly: Bool = false) {
        self.transport = transport; self.automaticPolling = automaticPolling; self.previewOnly = previewOnly
        self.sourceID = sourceID ?? Self.installationID()
        #if canImport(UIKit)
        self.sourceName = sourceName ?? (UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")
        #else
        self.sourceName = sourceName ?? "iPad"
        #endif
    }

    private static func installationID() -> String {
        let key = "genesis.glasses.controller-source-id"
        if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil { return saved }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    var hasChat: Bool { desired.chatID != nil }
    var acknowledged: Bool { enabled && snapshot?.acknowledged == true && snapshot?.state == desired }
    var pageLabel: String {
        guard acknowledged, let snapshot, let feedback = snapshot.feedback else { return "Waiting for glasses" }
        return "Page \(feedback.renderedPage + 1) of \(feedback.pageCount)"
    }
    var canGoNext: Bool {
        guard enabled, desired.view != .home else { return false }
        if acknowledged, let feedback = snapshot?.feedback { return desired.page + 1 < feedback.pageCount }
        return desired.page < 999
    }

    func enable(host: RemoteHost, token: String, provider: ProviderID, chatID: String?, slotIndex: Int?,
                draft: String, recording: Bool, takeover: Bool = false) {
        guard !enabled, !connecting else { return }
        guard provider != .muse, host.hostID != nil, UUID(uuidString: sourceID) != nil else {
            message = "Glasses follow supports paired Codex and Claude connections."; return
        }
        generation &+= 1; let expected = generation
        self.host = host; self.token = token; self.leaseID = nil; sequence = 0
        desired = .init(provider: provider, chatID: chatID, slotIndex: slotIndex,
                        view: chatID == nil ? .home : recording ? .draft : .reply,
                        draft: GlassesDisplayState.excerpt(draft), recording: recording)
        draftIsExcerpt = draft.unicodeScalars.count > GlassesDisplayState.maximumDraftScalars
        enabled = true; connecting = true; unsupported = false; otherOwner = nil; snapshot = nil
        message = "Connecting glasses follow…"
        enqueue { [weak self] in
            guard let self, self.generation == expected, self.enabled else { return }
            let request = GlassesDisplayRequest(operation: "claim", sourceID: self.sourceID, sourceName: self.sourceName,
                                                takeover: takeover, state: self.desired)
            do {
                let result = try await self.transport.write(request, host: host, token: token)
                try self.validate(result, host: host, requiresLease: true)
                guard self.generation == expected, self.enabled else {
                    // User left while claim was in flight. Release this exact lease,
                    // never a newer claim from this or a second controller.
                    if let lease = result.leaseID { await self.release(host: host, token: token, lease: lease) }
                    return
                }
                self.leaseID = result.leaseID; self.snapshot = result; self.connecting = false
                self.updateMessage(); self.startPolling(expected)
                self.scheduleUpdate() // Catch changes made during claim.
            } catch { await self.fail(error, expected: expected, host: host, token: token) }
        }
    }

    func stop(_ reason: String = "Glasses follow is off.") {
        let oldHost = host, oldToken = token, oldLease = leaseID
        generation &+= 1; intent &+= 1
        enabled = false; connecting = false; leaseID = nil; snapshot = nil; otherOwner = nil
        desired.draft = ""; desired.recording = false; desired.chatID = nil; desired.slotIndex = nil; desired.view = .home
        draftIsExcerpt = false; message = reason
        ticker?.cancel(); ticker = nil; draftDebounce?.cancel(); draftDebounce = nil
        scheduledGeneration = nil
        if let oldHost, let oldToken, let oldLease {
            enqueue { [weak self] in await self?.release(host: oldHost, token: oldToken, lease: oldLease) }
        }
    }

    /// Called only with a chat established by the existing command receipt path.
    func confirmedChat(provider: ProviderID, chatID: String?, slotIndex: Int?, draft: String) {
        guard enabled, provider == desired.provider else { return }
        desired.chatID = chatID; desired.slotIndex = slotIndex; desired.page = 0
        desired.view = chatID == nil ? .home : .reply; desired.recording = false; desired.sendState = .none
        if chatID == nil {
            desired.draft = ""; draftIsExcerpt = false; intent &+= 1; scheduleUpdate(); return
        }
        updateDraft(draft, recording: false, debounce: false)
    }

    func updateDraft(_ text: String, recording: Bool, debounce: Bool = true) {
        guard enabled, hasChat else { return }
        let wasRecording = desired.recording
        let excerpt = GlassesDisplayState.excerpt(text)
        if desired.draft != excerpt { desired.sendState = .none }
        desired.draft = excerpt; desired.recording = recording
        draftIsExcerpt = text.unicodeScalars.count > GlassesDisplayState.maximumDraftScalars
        if recording && !wasRecording { desired.view = .draft; desired.page = 0; desired.sendState = .none }
        intent &+= 1
        draftDebounce?.cancel()
        if debounce && wasRecording == recording {
            draftDebounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                self?.scheduleUpdate()
            }
        } else { scheduleUpdate() }
    }

    func sendChanged(_ receipt: CommandReceipt?, draft: String) {
        guard enabled, hasChat, let receipt else { return }
        desired.sendState = GlassesSendState(rawValue: receipt.status) ?? .uncertain
        desired.draft = GlassesDisplayState.excerpt(draft)
        if receipt.isAcceptedSend { desired.view = .reply; desired.page = 0; desired.refreshNonce += 1 }
        intent &+= 1; scheduleUpdate()
    }
    func show(_ view: GlassesDisplayView) {
        guard enabled, view == .home || hasChat else { return }
        desired.view = view; desired.page = 0; intent &+= 1; scheduleUpdate()
    }
    func page(_ delta: Int) {
        guard enabled, desired.view != .home else { return }
        let lastPage = acknowledged ? (snapshot?.feedback?.pageCount ?? 1000) - 1 : 999
        desired.page = max(0, min(lastPage, desired.page + delta)); intent &+= 1; scheduleUpdate()
    }
    func refresh() {
        guard enabled else { return }
        desired.refreshNonce += 1; intent &+= 1; scheduleUpdate()
    }

    /// The display gets no command endpoint, and heartbeats never touch Send.
    func heartbeat() { if enabled { scheduleUpdate() } }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { await previous?.value; await operation() }
    }
    func waitForWrites() async { await tail?.value }

    private func scheduleUpdate() {
        if previewOnly { updatePreview(); return }
        guard enabled, leaseID != nil, scheduledGeneration != generation else { return }
        let expected = generation
        scheduledGeneration = expected
        enqueue { [weak self] in
            guard let self, self.generation == expected, self.enabled, let host = self.host,
                  let token = self.token, let lease = self.leaseID else { return }
            self.scheduledGeneration = nil
            let sent = self.desired, sentIntent = self.intent
            self.sequence += 1
            let request = GlassesDisplayRequest(operation: "update", sourceID: self.sourceID, leaseID: lease,
                                                sequence: self.sequence, state: sent)
            do {
                let result = try await self.transport.write(request, host: host, token: token)
                guard self.generation == expected, self.enabled else { return }
                try self.validate(result, host: host, requiresLease: true)
                guard result.leaseID == lease else { throw RemoteError.invalidResponse }
                self.accept(result)
                if sentIntent == self.intent, let page = result.state?.page { self.desired.page = page }
                if sent != self.desired { self.scheduleUpdate() }
            } catch { await self.fail(error, expected: expected, host: host, token: token) }
        }
    }

    func poll() async {
        guard enabled, let host, let token, leaseID != nil else { return }
        let expected = generation, readIntent = intent, requested = desired
        do {
            let result = try await transport.read(host: host, token: token)
            guard generation == expected, enabled else { return }
            try validate(result, host: host, requiresLease: false)
            guard result.active, result.sourceID?.lowercased() == sourceID.lowercased(),
                  result.expiration.map({ $0 > Date() }) == true else {
                let owner = result.active ? result.sourceName : nil
                stop(owner == nil ? "Follow ended. Turn it on again when ready." : "Glasses are following \(owner!).")
                otherOwner = owner; return
            }
            if readIntent == intent, var canonical = result.state,
               result.revision >= (snapshot?.revision ?? -1) {
                // A shorter reply can clamp the current page. Accept that one
                // field only when nothing else changed during this read.
                let page = canonical.page; canonical.page = requested.page
                if canonical == requested { desired.page = page }
            }
            accept(result)
        } catch { await fail(error, expected: expected, host: host, token: token) }
    }

    private func startPolling(_ expected: Int) {
        guard automaticPolling else { return }
        ticker?.cancel()
        ticker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, self.enabled, self.generation == expected else { return }
                tick += 1
                if tick % 5 == 0 { self.heartbeat() }
                await self.poll()
            }
        }
    }
    private func validate(_ result: GlassesDisplaySnapshot, host: RemoteHost, requiresLease: Bool) throws {
        guard result.version == 1, result.hostID.lowercased() == host.hostID?.lowercased(), result.revision >= 0 else { throw RemoteError.invalidResponse }
        if result.active {
            guard result.state?.valid == true, UUID(uuidString: result.sourceID ?? "") != nil,
                  ["iPhone", "iPad"].contains(result.sourceName ?? ""), result.expiration != nil else { throw RemoteError.invalidResponse }
        }
        if requiresLease {
            guard result.active, result.sourceID?.lowercased() == sourceID.lowercased(),
                  UUID(uuidString: result.leaseID ?? "") != nil else { throw RemoteError.invalidResponse }
        }
    }
    private func accept(_ result: GlassesDisplaySnapshot) {
        guard result.revision >= (snapshot?.revision ?? -1) else { return }
        snapshot = result; updateMessage()
    }
    private func updateMessage() {
        if acknowledged {
            message = "Glasses acknowledged this view from your \(sourceName)."
        } else {
            message = "Mac connected. Waiting for the Even app and glasses."
        }
    }
    private func release(host: RemoteHost, token: String, lease: String) async {
        _ = try? await transport.write(.init(operation: "release", sourceID: sourceID, leaseID: lease), host: host, token: token)
    }
    private func fail(_ error: Error, expected: Int, host: RemoteHost, token: String) async {
        guard generation == expected else { return }
        var owner: String?
        if case RemoteError.server(409, _) = error {
            if let result = try? await transport.read(host: host, token: token), result.hostID == host.hostID,
               result.active, result.sourceID?.lowercased() != sourceID.lowercased() { owner = result.sourceName }
            guard generation == expected else { return }
        }
        stop()
        if case RemoteError.server(let code, _) = error, [404, 405, 501].contains(code) {
            unsupported = true; message = "Update Genesis on this Mac to use glasses follow. Other controller features still work."
        } else if let owner {
            otherOwner = owner; message = "Glasses are following another \(owner). Take over only when you want to switch controllers."
        } else {
            message = "Glasses follow stopped: \(error.localizedDescription) Turn it on to reconnect."
        }
    }

    /// Launch-only UI fixture. ControllerStore permits this exclusively together
    /// with --demo. There are no credentials, lease, network calls, or commands.
    func startPreview(provider: ProviderID, chatID: String?, draft: String) {
        guard previewOnly else { return }
        desired = .init(provider: provider, chatID: chatID, slotIndex: 0, view: .reply, draft: draft)
        enabled = true; updatePreview()
    }
    private func updatePreview() {
        guard previewOnly, enabled else { return }
        desired.page = max(0, min(2, desired.page))
        let revision = (snapshot?.revision ?? 0) + 1
        snapshot = .init(version: 1, hostID: "00000000-0000-4000-8000-000000000001", active: true, revision: revision,
                         sourceID: sourceID, sourceName: sourceName, state: desired,
                         feedback: .init(revision: revision, pageCount: 3, renderedPage: desired.page, connected: true))
        message = "Design preview · simulated glasses display"
    }
}
