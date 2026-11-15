import Foundation

struct RemoteDisplayFault: Error {
    let status: Int
    let message: String
    static let invalid = RemoteDisplayFault(status: 422, message: "Invalid glasses display request.")
    static let conflict = RemoteDisplayFault(status: 409, message: "Glasses control changed or expired. Refresh and choose Follow again.")
}

private struct DisplayCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private func displayContainer(_ decoder: Decoder, keys: Set<String>) throws -> KeyedDecodingContainer<DisplayCodingKey> {
    let container = try decoder.container(keyedBy: DisplayCodingKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: keys) else { throw RemoteDisplayFault.invalid }
    return container
}

struct RemoteDisplayState: Codable, Equatable {
    let provider: String
    let chatID: String?
    let slotIndex: Int?
    let view: String
    var page: Int
    let draft: String
    let recording: Bool
    let sendState: String
    let refreshNonce: Int

    static let maximumInteger = 9_007_199_254_740_991 // Exact in both Swift and JavaScript.
    init(provider: String, chatID: String?, slotIndex: Int?, view: String, page: Int, draft: String,
         recording: Bool, sendState: String, refreshNonce: Int) {
        self.provider = provider; self.chatID = chatID; self.slotIndex = slotIndex; self.view = view
        self.page = page; self.draft = draft; self.recording = recording; self.sendState = sendState; self.refreshNonce = refreshNonce
    }
    init(from decoder: Decoder) throws {
        let c = try displayContainer(decoder, keys: ["provider", "chatID", "slotIndex", "view", "page", "draft", "recording", "sendState", "refreshNonce"])
        provider = try c.decode(String.self, forKey: .init("provider"))
        chatID = try c.decodeIfPresent(String.self, forKey: .init("chatID"))
        slotIndex = try c.decodeIfPresent(Int.self, forKey: .init("slotIndex"))
        view = try c.decode(String.self, forKey: .init("view"))
        page = try c.decode(Int.self, forKey: .init("page"))
        draft = try c.decode(String.self, forKey: .init("draft"))
        recording = try c.decode(Bool.self, forKey: .init("recording"))
        sendState = try c.decode(String.self, forKey: .init("sendState"))
        refreshNonce = try c.decode(Int.self, forKey: .init("refreshNonce"))
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DisplayCodingKey.self)
        try c.encode(provider, forKey: .init("provider"))
        // Home and unmapped chats must retain the explicit nullable wire fields.
        try c.encode(chatID, forKey: .init("chatID"))
        try c.encode(slotIndex, forKey: .init("slotIndex"))
        try c.encode(view, forKey: .init("view"))
        try c.encode(page, forKey: .init("page"))
        try c.encode(draft, forKey: .init("draft"))
        try c.encode(recording, forKey: .init("recording"))
        try c.encode(sendState, forKey: .init("sendState"))
        try c.encode(refreshNonce, forKey: .init("refreshNonce"))
    }
    func validate() throws {
        guard ["codex", "claude"].contains(provider), ["home", "reply", "draft"].contains(view),
              (0...999).contains(page), (0...Self.maximumInteger).contains(refreshNonce),
              ["none", "queued", "confirmed", "uncertain", "failed"].contains(sendState),
              draft.unicodeScalars.count <= 16_000,
              slotIndex == nil || (0...5).contains(slotIndex!),
              chatID == nil || (!chatID!.isEmpty && chatID!.unicodeScalars.count <= 512 && !chatID!.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })),
              view == "home" || chatID != nil else { throw RemoteDisplayFault.invalid }
    }
    func sameTarget(as other: Self) -> Bool { provider == other.provider && chatID == other.chatID }
    func samePagination(as other: Self) -> Bool {
        sameTarget(as: other) && view == other.view && refreshNonce == other.refreshNonce && (view != "draft" || draft == other.draft)
    }
}

enum RemoteDisplayRequest: Decodable {
    case claim(sourceID: UUID, sourceName: String, takeover: Bool, state: RemoteDisplayState)
    case update(sourceID: UUID, leaseID: UUID, sequence: Int, state: RemoteDisplayState)
    case release(sourceID: UUID, leaseID: UUID)

    init(from decoder: Decoder) throws {
        let initial = try decoder.container(keyedBy: DisplayCodingKey.self)
        let operation = try initial.decode(String.self, forKey: .init("operation"))
        let keys: Set<String>
        switch operation {
        case "claim": keys = ["operation", "sourceID", "sourceName", "takeover", "state"]
        case "update": keys = ["operation", "sourceID", "leaseID", "sequence", "state"]
        case "release": keys = ["operation", "sourceID", "leaseID"]
        default: throw RemoteDisplayFault.invalid
        }
        let c = try displayContainer(decoder, keys: keys)
        let sourceID = try c.decode(UUID.self, forKey: .init("sourceID"))
        switch operation {
        case "claim":
            let name = try c.decode(String.self, forKey: .init("sourceName"))
            guard ["iPhone", "iPad"].contains(name) else { throw RemoteDisplayFault.invalid }
            self = .claim(sourceID: sourceID, sourceName: name, takeover: try c.decode(Bool.self, forKey: .init("takeover")), state: try c.decode(RemoteDisplayState.self, forKey: .init("state")))
        case "update":
            let sequence = try c.decode(Int.self, forKey: .init("sequence"))
            guard (1...RemoteDisplayState.maximumInteger).contains(sequence) else { throw RemoteDisplayFault.invalid }
            self = .update(sourceID: sourceID, leaseID: try c.decode(UUID.self, forKey: .init("leaseID")), sequence: sequence, state: try c.decode(RemoteDisplayState.self, forKey: .init("state")))
        default:
            self = .release(sourceID: sourceID, leaseID: try c.decode(UUID.self, forKey: .init("leaseID")))
        }
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 131_072 else { throw RemoteDisplayFault.invalid }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw RemoteDisplayFault.invalid }
    }
    var state: RemoteDisplayState? {
        switch self { case .claim(_, _, _, let state), .update(_, _, _, let state): return state; case .release: return nil }
    }
}

struct RemoteDisplayFeedbackRequest: Decodable {
    let revision: Int
    let provider: String
    let chatID: String?
    let view: String
    let pageCount: Int
    let renderedPage: Int
    let connected: Bool
    init(from decoder: Decoder) throws {
        let c = try displayContainer(decoder, keys: ["revision", "provider", "chatID", "view", "pageCount", "renderedPage", "connected"])
        revision = try c.decode(Int.self, forKey: .init("revision"))
        provider = try c.decode(String.self, forKey: .init("provider"))
        chatID = try c.decodeIfPresent(String.self, forKey: .init("chatID"))
        view = try c.decode(String.self, forKey: .init("view"))
        pageCount = try c.decode(Int.self, forKey: .init("pageCount"))
        renderedPage = try c.decode(Int.self, forKey: .init("renderedPage"))
        connected = try c.decode(Bool.self, forKey: .init("connected"))
        guard (1...RemoteDisplayState.maximumInteger).contains(revision), ["codex", "claude"].contains(provider),
              ["home", "reply", "draft"].contains(view), (1...1000).contains(pageCount), (0..<pageCount).contains(renderedPage),
              chatID == nil || (!chatID!.isEmpty && chatID!.unicodeScalars.count <= 512), view == "home" || chatID != nil else { throw RemoteDisplayFault.invalid }
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw RemoteDisplayFault.invalid }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw RemoteDisplayFault.invalid }
    }
}

struct RemoteDisplayFeedback: Encodable, Equatable {
    let revision: Int
    let pageCount: Int
    let renderedPage: Int
    let connected: Bool
}

struct RemoteDisplaySnapshot: Encodable {
    let version = 1
    let hostID: String
    let active: Bool
    let revision: Int
    var sourceID: UUID? = nil
    var sourceName: String? = nil
    var expiresAt: String? = nil
    var chatTitle: String? = nil
    var state: RemoteDisplayState? = nil
    var feedback: RemoteDisplayFeedback? = nil
    // Only an accepted owner POST may set this. GET/feedback never expose it.
    var leaseID: UUID? = nil
}

/// Memory-only display state. It has no persistence, desktop commands, networking,
/// microphone, or Send dependencies. Inventory validation is a separate read-only step.
struct RemoteDisplaySession {
    struct Target: Equatable { let provider: String; let chatID: String }
    struct ValidatedTarget { let target: Target; let title: String }
    private struct Lease {
        let sourceID: UUID
        let leaseID: UUID
        let sourceName: String
        var expiresAt: TimeInterval
        var sequence = 0
        var state: RemoteDisplayState
        var chatTitle: String?
        var feedback: RemoteDisplayFeedback?
        var feedbackReceivedAt: TimeInterval?
    }
    static let lifetime: TimeInterval = 45
    static let feedbackLifetime: TimeInterval = 15
    private var lease: Lease?
    private(set) var revision = 0

    mutating func invalidate() {
        if lease != nil { revision += 1 }
        lease = nil // Includes the transient private draft and feedback.
    }
    mutating func expire(now: TimeInterval) {
        if let lease, !now.isFinite || now >= lease.expiresAt || now < lease.expiresAt - Self.lifetime { invalidate(); return }
        if let receivedAt = lease?.feedbackReceivedAt, now >= receivedAt + Self.feedbackLifetime || now < receivedAt {
            // Ownership heartbeats do not prove the glasses remain connected.
            // Clearing an old ACK requests a new native render without changing
            // the controller's revision, page, draft, or ownership lease.
            lease?.feedback = nil; lease?.feedbackReceivedAt = nil
        }
    }
    mutating func snapshot(hostID: String, now: TimeInterval) -> RemoteDisplaySnapshot {
        expire(now: now)
        guard let lease else { return RemoteDisplaySnapshot(hostID: hostID, active: false, revision: revision) }
        let expiry = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: lease.expiresAt))
        return RemoteDisplaySnapshot(hostID: hostID, active: true, revision: revision, sourceID: lease.sourceID,
                                     sourceName: lease.sourceName, expiresAt: expiry, chatTitle: lease.chatTitle,
                                     state: lease.state, feedback: lease.feedback)
    }
    private mutating func preflight(_ request: RemoteDisplayRequest, now: TimeInterval) throws {
        expire(now: now)
        guard now.isFinite else { throw RemoteDisplayFault.invalid }
        try request.state?.validate()
        switch request {
        case .claim(let source, let name, let takeover, _):
            guard ["iPhone", "iPad"].contains(name) else { throw RemoteDisplayFault.invalid }
            if let lease, lease.sourceID != source, !takeover { throw RemoteDisplayFault.conflict }
        case .update(let source, let id, let sequence, _):
            guard (1...RemoteDisplayState.maximumInteger).contains(sequence) else { throw RemoteDisplayFault.invalid }
            guard let lease, lease.sourceID == source, lease.leaseID == id, sequence > lease.sequence else { throw RemoteDisplayFault.conflict }
        case .release(let source, let id):
            guard let lease, lease.sourceID == source, lease.leaseID == id else { throw RemoteDisplayFault.conflict }
        }
    }
    /// Call before awaiting an inventory read. Heartbeats and draft edits return nil.
    mutating func requiredTarget(for request: RemoteDisplayRequest, now: TimeInterval) throws -> Target? {
        try preflight(request, now: now)
        guard let state = request.state, let chatID = state.chatID, lease?.state.sameTarget(as: state) != true else { return nil }
        return Target(provider: state.provider, chatID: chatID)
    }
    mutating func apply(_ request: RemoteDisplayRequest, hostID: String, now: TimeInterval, validated: ValidatedTarget? = nil) throws -> RemoteDisplaySnapshot {
        // Recheck after the asynchronous inventory read: expiry, takeover, or a later
        // sequence may have happened while this request was waiting.
        let target = try requiredTarget(for: request, now: now)
        if let target {
            guard validated?.target == target, validated?.title.isEmpty == false else {
                throw RemoteDisplayFault(status: 422, message: "This chat is unavailable for glasses display. Refresh the controller's chats.")
            }
        }
        let title = target != nil ? validated.map { String($0.title.unicodeScalars.prefix(240)) } : request.state?.chatID != nil ? lease?.chatTitle : nil
        switch request {
        case .claim(let source, let name, _, let state):
            revision += 1
            lease = Lease(sourceID: source, leaseID: UUID(), sourceName: name, expiresAt: now + Self.lifetime, state: state, chatTitle: title)
        case .update(_, _, let sequence, var state):
            var current = lease!
            let paginationMatches = current.state.samePagination(as: state)
            if paginationMatches, current.feedback?.connected == true, let count = current.feedback?.pageCount { state.page = min(state.page, count - 1) }
            if current.state != state {
                revision += 1
                // Feedback is always revision-scoped. A new state must be rendered.
                current.feedback = nil; current.feedbackReceivedAt = nil
            }
            current.state = state; current.sequence = sequence; current.expiresAt = now + Self.lifetime; current.chatTitle = title
            lease = current
        case .release:
            invalidate()
        }
        var result = snapshot(hostID: hostID, now: now)
        result.leaseID = lease?.leaseID
        return result
    }
    mutating func applyFeedback(_ feedback: RemoteDisplayFeedbackRequest, hostID: String, now: TimeInterval) throws -> RemoteDisplaySnapshot {
        expire(now: now)
        guard var current = lease, feedback.revision == revision, current.state.provider == feedback.provider,
              current.state.chatID == feedback.chatID, current.state.view == feedback.view else { throw RemoteDisplayFault.conflict }
        let normalizedPage = min(current.state.page, feedback.pageCount - 1)
        guard !feedback.connected || feedback.renderedPage == normalizedPage else { throw RemoteDisplayFault.conflict }
        if feedback.connected, normalizedPage != current.state.page { current.state.page = normalizedPage; revision += 1 }
        current.feedback = RemoteDisplayFeedback(revision: revision, pageCount: feedback.pageCount, renderedPage: feedback.renderedPage, connected: feedback.connected)
        current.feedbackReceivedAt = now
        lease = current // Does not renew expiry, change target, or execute any action.
        return snapshot(hostID: hostID, now: now)
    }
}
