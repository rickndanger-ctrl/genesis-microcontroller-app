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
    @Published private(set) var keepReadingPreference: Bool
    @Published private(set) var supportsKeepReading = false
    @Published private(set) var readingArmed = false
    @Published private(set) var suspended = false
    @Published private(set) var resuming = false
    @Published private(set) var readingChangePending = false
    @Published private(set) var readingMessage = ""

    let sourceID: String
    let sourceName: String
    private let transport: any GlassesDisplayTransport
    private let automaticPolling: Bool
    private let previewOnly: Bool
    private let preferences: UserDefaults?
    private static let readingPreferenceKey = "genesis.glasses.keep-reading-when-locked.v1"
    private var host: RemoteHost?
    private var token: String?
    private var leaseID: String?
    private var sequence = 0
    private var generation = 0
    private var intent = 0
    private var wantsForeground = true
    private var tail: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var draftDebounce: Task<Void, Never>?
    private var scheduledGeneration: Int?
    #if canImport(UIKit)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(transport: any GlassesDisplayTransport, sourceID: String? = nil, sourceName: String? = nil,
         automaticPolling: Bool = true, previewOnly: Bool = false, preferences: UserDefaults? = .standard) {
        self.transport = transport; self.automaticPolling = automaticPolling; self.previewOnly = previewOnly
        self.preferences = preferences
        self.keepReadingPreference = preferences?.bool(forKey: Self.readingPreferenceKey) ?? false
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
    var controlsAvailable: Bool { enabled && !suspended && !resuming }
    var canSetKeepReading: Bool { controlsAvailable && supportsKeepReading && hasChat && !connecting }
    var acknowledged: Bool { enabled && snapshot?.acknowledged == true && snapshot?.state == desired }
    var pageLabel: String {
        guard acknowledged, let snapshot, let feedback = snapshot.feedback else { return "Waiting for glasses" }
        return "Page \(feedback.renderedPage + 1) of \(feedback.pageCount)"
    }
    var canGoNext: Bool {
        guard controlsAvailable, desired.view != .home else { return false }
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
        wantsForeground = true
        suspended = false; resuming = false; readingArmed = false; supportsKeepReading = false; readingChangePending = false; readingMessage = ""
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
                self.leaseID = result.leaseID; self.connecting = false; self.accept(result)
                if !self.suspended {
                    self.updateMessage(); self.startPolling(expected)
                    self.scheduleUpdate() // Catch changes made during claim.
                }
            } catch { await self.fail(error, expected: expected, host: host, token: token) }
        }
    }

    func stop(_ reason: String = "Glasses follow is off.") {
        let oldHost = host, oldToken = token, oldLease = leaseID
        generation &+= 1; intent &+= 1
        enabled = false; connecting = false; leaseID = nil; snapshot = nil; otherOwner = nil
        suspended = false; resuming = false; readingArmed = false; readingChangePending = false; readingMessage = ""
        desired.draft = ""; desired.recording = false; desired.chatID = nil; desired.slotIndex = nil; desired.view = .home
        draftIsExcerpt = false; message = reason
        ticker?.cancel(); ticker = nil; draftDebounce?.cancel(); draftDebounce = nil
        scheduledGeneration = nil
        endBackgroundTask()
        if let oldHost, let oldToken, let oldLease {
            enqueue { [weak self] in await self?.release(host: oldHost, token: oldToken, lease: oldLease) }
        }
    }

    /// Called only with a chat established by the existing command receipt path.
    func confirmedChat(provider: ProviderID, chatID: String?, slotIndex: Int?, draft: String) {
        guard controlsAvailable, provider == desired.provider else { return }
        desired.chatID = chatID; desired.slotIndex = slotIndex; desired.page = 0
        desired.view = chatID == nil ? .home : .reply; desired.recording = false; desired.sendState = .none
        if chatID == nil {
            desired.draft = ""; draftIsExcerpt = false; intent &+= 1; scheduleUpdate(); return
        }
        updateDraft(draft, recording: false, debounce: false)
    }

    func updateDraft(_ text: String, recording: Bool, debounce: Bool = true) {
        guard controlsAvailable, hasChat else { return }
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
        guard controlsAvailable, hasChat, let receipt else { return }
        desired.sendState = GlassesSendState(rawValue: receipt.status) ?? .uncertain
        desired.draft = GlassesDisplayState.excerpt(draft)
        if receipt.isAcceptedSend { desired.view = .reply; desired.page = 0; desired.refreshNonce += 1 }
        intent &+= 1; scheduleUpdate()
    }
    func show(_ view: GlassesDisplayView) {
        guard controlsAvailable, view == .home || hasChat else { return }
        desired.view = view; desired.page = 0; intent &+= 1; scheduleUpdate()
    }
    func page(_ delta: Int) {
        guard controlsAvailable, desired.view != .home else { return }
        let lastPage = acknowledged ? (snapshot?.feedback?.pageCount ?? 1000) - 1 : 999
        desired.page = max(0, min(lastPage, desired.page + delta)); intent &+= 1; scheduleUpdate()
    }
    func refresh() {
        guard controlsAvailable else { return }
        desired.refreshNonce += 1; intent &+= 1; scheduleUpdate()
    }

    /// The display gets no command endpoint, and heartbeats never touch Send.
    func heartbeat() { if controlsAvailable { scheduleUpdate() } }

    func setKeepReading(_ value: Bool) {
        guard canSetKeepReading else { return }
        keepReadingPreference = value
        preferences?.set(value, forKey: Self.readingPreferenceKey)
        scheduleReadingPreference(force: true)
    }

    private func scheduleReadingPreference(force: Bool = false) {
        guard canSetKeepReading, !readingChangePending, force || (keepReadingPreference && !readingArmed) else { return }
        let expected = generation
        readingChangePending = true
        readingMessage = keepReadingPreference ? "Preparing reading after lock…" : "Turning off reading after lock…"
        enqueue { [weak self] in
            guard let self, self.generation == expected, self.enabled else { return }
            self.readingChangePending = false
            guard self.controlsAvailable, let host = self.host, let token = self.token, let lease = self.leaseID else { return }
            let requested = self.keepReadingPreference
            self.readingChangePending = true
            do {
                let result = try await self.transport.write(.init(operation: "setReading", sourceID: self.sourceID,
                                                                  leaseID: lease, enabled: requested), host: host, token: token)
                guard self.generation == expected, self.enabled else { return }
                try self.validate(result, host: host, requiresLease: true)
                guard result.leaseID == lease, result.supportsKeepReading == true, result.keepReading == requested else { throw RemoteError.invalidResponse }
                self.accept(result)
                self.readingMessage = requested ? "Ready: this chat can keep reading for up to one hour after lock." : "Reading after lock is off."
            } catch {
                guard self.generation == expected, self.enabled else { return }
                self.readingMessage = "The Mac has not confirmed this reading setting. Keep Genesis open and try again."
            }
            self.readingChangePending = false
            if self.keepReadingPreference != requested { self.scheduleReadingPreference(force: true) }
        }
    }

    /// Stops all future draft writes before speech cancellation can publish a
    /// callback. A serialized park follows any claim/arm/update already sent.
    @discardableResult func enterBackground() -> Bool {
        wantsForeground = false
        guard enabled, !suspended else { return enabled && suspended }
        guard keepReadingPreference, hasChat else {
            stop("Follow paused in the background. Turn it on when you return."); return false
        }
        suspended = true; resuming = false; intent &+= 1
        ticker?.cancel(); ticker = nil; draftDebounce?.cancel(); draftDebounce = nil
        scheduledGeneration = nil
        desired.view = .reply; desired.page = 0; desired.draft = ""; desired.recording = false; desired.sendState = .none
        draftIsExcerpt = false; snapshot = nil
        message = "Handing this conversation to the Mac for reading…"
        schedulePark()
        return true
    }

    private func schedulePark() {
        beginBackgroundTask()
        let expected = generation
        enqueue { [weak self] in
            guard let self else { return }
            defer { if self.generation == expected { self.endBackgroundTask() } }
            guard self.generation == expected, self.enabled, let host = self.host, let token = self.token, let lease = self.leaseID else { return }
            guard self.supportsKeepReading else {
                self.stop("Update Genesis on this Mac to keep reading after lock."); return
            }
            do {
                if !self.readingArmed {
                    let armed = try await self.transport.write(.init(operation: "setReading", sourceID: self.sourceID,
                                                                     leaseID: lease, enabled: true), host: host, token: token)
                    guard self.generation == expected, self.enabled else { return }
                    try self.validate(armed, host: host, requiresLease: true)
                    guard armed.leaseID == lease, armed.keepReading == true else { throw RemoteError.invalidResponse }
                    self.accept(armed)
                }
                let parked = try await self.transport.write(.init(operation: "park", sourceID: self.sourceID,
                                                                  leaseID: lease), host: host, token: token)
                guard self.generation == expected, self.enabled else { return }
                try self.validate(parked, host: host, requiresLease: true)
                guard parked.leaseID == lease, parked.readingOnly == true, parked.keepReading == true,
                      parked.state?.provider == self.desired.provider, parked.state?.chatID == self.desired.chatID else { throw RemoteError.invalidResponse }
                self.accept(parked)
                self.message = "The Mac is keeping this conversation readable for up to one hour."
            } catch {
                guard self.generation == expected, self.enabled else { return }
                // A park may have succeeded despite a lost reply. Do not replay
                // it or release an armed session. The Mac's expiry is the bound.
                self.message = self.readingArmed ? "Reading handoff was not confirmed. The Mac's armed fallback remains available." : "Reading handoff was not confirmed. Reopen Genesis to check."
            }
        }
    }

    func returnToForeground(draft: @escaping () -> String) {
        wantsForeground = true
        guard enabled, suspended, !resuming else { return }
        resuming = true; message = "Checking the same glasses session…"
        let expected = generation, target = desired
        enqueue { [weak self] in
            guard let self, self.generation == expected, self.enabled, let host = self.host,
                  let token = self.token, let lease = self.leaseID else { return }
            do {
                let current = try await self.transport.read(host: host, token: token)
                guard self.generation == expected, self.enabled else { return }
                try self.validate(current, host: host, requiresLease: false)
                guard current.active, current.sourceID?.lowercased() == self.sourceID.lowercased(),
                      current.expiration.map({ $0 > Date() }) == true,
                      current.state?.provider == target.provider, current.state?.chatID == target.chatID else {
                    self.stop("The reading session ended or changed owner. Turn Follow on again when ready.")
                    self.otherOwner = current.active && current.sourceID?.lowercased() != self.sourceID.lowercased() ? current.sourceName : nil
                    return
                }
                // Only this exact lease may resume. Never claim or take over.
                let result = try await self.transport.write(.init(operation: "resume", sourceID: self.sourceID,
                                                                  leaseID: lease), host: host, token: token)
                guard self.generation == expected, self.enabled else { return }
                try self.validate(result, host: host, requiresLease: true)
                guard result.leaseID != lease, result.readingOnly == false, result.state?.provider == target.provider,
                      result.state?.chatID == target.chatID, let state = result.state else { throw RemoteError.invalidResponse }
                self.sequence = 0
                self.leaseID = result.leaseID; self.resuming = false
                guard self.wantsForeground else {
                    // A second lock happened while resume was in flight. Adopt
                    // its fencing lease, but never restore a private draft.
                    self.desired = state
                    self.desired.view = .reply; self.desired.page = 0; self.desired.draft = ""
                    self.desired.recording = false; self.desired.sendState = .none
                    self.accept(result); self.schedulePark(); return
                }
                self.suspended = false
                self.desired = state; self.accept(result)
                self.updateDraft(draft(), recording: false, debounce: false)
                self.startPolling(expected)
            } catch { await self.fail(error, expected: expected, host: host, token: token) }
        }
    }

    private func beginBackgroundTask() {
        #if canImport(UIKit)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish glasses reading handoff") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        #endif
    }
    private func endBackgroundTask() {
        #if canImport(UIKit)
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask; backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
        #endif
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { await previous?.value; await operation() }
    }
    func waitForWrites() async { await tail?.value }

    private func scheduleUpdate() {
        if previewOnly { updatePreview(); return }
        guard controlsAvailable, leaseID != nil, scheduledGeneration != generation else { return }
        let expected = generation
        scheduledGeneration = expected
        enqueue { [weak self] in
            guard let self, self.generation == expected, self.controlsAvailable, let host = self.host,
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
                guard self.controlsAvailable else { return }
                if sentIntent == self.intent, let page = result.state?.page { self.desired.page = page }
                if sent != self.desired { self.scheduleUpdate() }
                self.scheduleReadingPreference()
            } catch {
                // The queued park owns background cleanup. An older update's
                // failed reply must not release an armed reading session.
                guard !self.suspended else { return }
                await self.fail(error, expected: expected, host: host, token: token, foregroundLease: lease)
            }
        }
    }

    func poll() async {
        guard controlsAvailable, let host, let token, let lease = leaseID else { return }
        let expected = generation, readIntent = intent, requested = desired
        do {
            let result = try await transport.read(host: host, token: token)
            guard generation == expected, controlsAvailable, leaseID == lease, !Task.isCancelled else { return }
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
        } catch {
            guard controlsAvailable, leaseID == lease, !Task.isCancelled else { return }
            await fail(error, expected: expected, host: host, token: token, foregroundLease: lease)
        }
    }

    private func startPolling(_ expected: Int) {
        guard automaticPolling else { return }
        ticker?.cancel()
        ticker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, self.controlsAvailable, self.generation == expected else { return }
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
            if result.readingOnly == true {
                guard result.supportsKeepReading == true, result.keepReading == true,
                      let state = result.state, state.chatID != nil, state.view == .reply,
                      state.page == 0, state.draft.isEmpty, !state.recording, state.sendState == .none else { throw RemoteError.invalidResponse }
            }
        }
        if requiresLease {
            guard result.active, result.sourceID?.lowercased() == sourceID.lowercased(),
                  UUID(uuidString: result.leaseID ?? "") != nil else { throw RemoteError.invalidResponse }
        }
    }
    private func accept(_ result: GlassesDisplaySnapshot) {
        guard result.revision >= (snapshot?.revision ?? -1) else { return }
        supportsKeepReading = result.supportsKeepReading == true
        readingArmed = supportsKeepReading && result.keepReading == true
        if !readingArmed, readingMessage.hasPrefix("Ready:") {
            readingMessage = hasChat ? "Reading after lock is not armed." : "Open a chat to prepare reading after lock."
        }
        if suspended && result.readingOnly != true { return }
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
    private func fail(_ error: Error, expected: Int, host: RemoteHost, token: String, foregroundLease: String? = nil) async {
        func stillCurrent() -> Bool {
            generation == expected && (foregroundLease == nil || (controlsAvailable && leaseID == foregroundLease && !Task.isCancelled))
        }
        guard stillCurrent() else { return }
        var owner: String?
        if case RemoteError.server(409, _) = error {
            if let result = try? await transport.read(host: host, token: token), result.hostID == host.hostID,
               result.active, result.sourceID?.lowercased() != sourceID.lowercased() { owner = result.sourceName }
            guard stillCurrent() else { return }
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
