import Foundation

enum GlassesDisplayView: String, Codable, CaseIterable { case home, reply, draft }
enum GlassesSendState: String, Codable { case none, queued, confirmed, uncertain, failed }

/// Display only. This payload cannot execute a Mac action or send a message.
struct GlassesDisplayState: Codable, Equatable {
    var provider: ProviderID
    var chatID: String?
    var slotIndex: Int?
    var view: GlassesDisplayView = .home
    var page = 0
    var draft = ""
    var recording = false
    var sendState: GlassesSendState = .none
    var refreshNonce = 0

    static let maximumDraftScalars = 16_000
    static func excerpt(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(maximumDraftScalars)))
    }
    var valid: Bool {
        provider != .muse && (chatID == nil || !(chatID?.isEmpty ?? true)) &&
        (slotIndex == nil || (0...5).contains(slotIndex!)) && (0...999).contains(page) &&
        (view == .home || chatID != nil) && draft.unicodeScalars.count <= Self.maximumDraftScalars &&
        (0...9_007_199_254_740_991).contains(refreshNonce)
    }
}

struct GlassesDisplayFeedback: Codable, Equatable {
    var revision: Int
    var pageCount: Int
    var renderedPage: Int
    var connected: Bool
}

struct GlassesDisplaySnapshot: Codable, Equatable {
    var version: Int
    var hostID: String
    var active: Bool
    var revision: Int
    var sourceID: String?
    var sourceName: String?
    var expiresAt: String?
    var state: GlassesDisplayState?
    var feedback: GlassesDisplayFeedback?
    var leaseID: String?
    var chatTitle: String?
    var supportsKeepReading: Bool?
    var keepReading: Bool?
    var readingOnly: Bool?

    var acknowledged: Bool {
        guard active, let feedback, feedback.revision == revision,
              (1...1000).contains(feedback.pageCount),
              (0..<feedback.pageCount).contains(feedback.renderedPage),
              feedback.renderedPage == state?.page else { return false }
        return feedback.connected
    }
    var expiration: Date? {
        guard let expiresAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
    }
}

struct GlassesDisplayRequest: Encodable, Equatable {
    var operation: String
    var sourceID: String
    var sourceName: String?
    var takeover: Bool?
    var leaseID: String?
    var sequence: Int?
    var state: GlassesDisplayState?
    var enabled: Bool?
}

@MainActor
protocol GlassesDisplayTransport {
    func read(host: RemoteHost, token: String) async throws -> GlassesDisplaySnapshot
    func write(_ request: GlassesDisplayRequest, host: RemoteHost, token: String) async throws -> GlassesDisplaySnapshot
}

@MainActor
final class RemoteGlassesDisplayTransport: GlassesDisplayTransport {
    private let client: RemoteClient
    init(client: RemoteClient) { self.client = client }
    func read(host: RemoteHost, token: String) async throws -> GlassesDisplaySnapshot {
        try await client.fetch(GlassesDisplaySnapshot.self, host: host, token: token, path: "/v1/display-session", deadline: 5)
    }
    func write(_ request: GlassesDisplayRequest, host: RemoteHost, token: String) async throws -> GlassesDisplaySnapshot {
        try await client.fetch(GlassesDisplaySnapshot.self, host: host, token: token, path: "/v1/display-session",
                               method: "POST", body: JSONEncoder().encode(request), deadline: 5)
    }
}
