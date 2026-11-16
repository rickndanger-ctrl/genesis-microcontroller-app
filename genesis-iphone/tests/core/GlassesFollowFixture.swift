import Foundation

/// In-memory display service. No desktop app, private pairing or physical G2.
@MainActor
final class GlassesFollowFixture: GlassesDisplayTransport {
    var snapshots: [String: GlassesDisplaySnapshot] = [:]
    var requests: [(String, GlassesDisplayRequest)] = []
    var sequences: [String: Int] = [:]
    var holdOperation: String?
    var held: [CheckedContinuation<Void, Never>] = []
    var holdReads = false
    var failReadAfterHold = false
    var heldReads: [CheckedContinuation<Void, Never>] = []
    var errorCode: Int?
    var supportsReading = true
    var failBefore: String?
    var failAfter: String?
    var activeWrites = 0
    var maximumConcurrentWrites = 0

    func current(_ host: RemoteHost) -> GlassesDisplaySnapshot {
        snapshots[host.hostID!] ?? .init(version: 1, hostID: host.hostID!, active: false, revision: 0, supportsKeepReading: supportsReading ? true : nil)
    }
    func read(host: RemoteHost, token: String) async throws -> GlassesDisplaySnapshot {
        if let errorCode { throw RemoteError.server(errorCode, "Fixture service error") }
        var result = current(host); result.leaseID = nil
        let readWillFail = holdReads && failReadAfterHold
        if holdReads { await withCheckedContinuation { heldReads.append($0) } }
        if readWillFail { throw CancellationError() }
        return result
    }
    func write(_ request: GlassesDisplayRequest, host: RemoteHost, token: String) async throws -> GlassesDisplaySnapshot {
        activeWrites += 1; maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
        defer { activeWrites -= 1 }
        requests.append((host.hostID!, request))
        if let errorCode { throw RemoteError.server(errorCode, "Fixture service error") }
        if failBefore == request.operation { throw RemoteError.server(503, "Fixture before write") }
        var state = current(host)
        if ["setReading", "park", "resume"].contains(request.operation) {
            guard supportsReading else { throw RemoteError.server(422, "Unsupported operation") }
            guard state.active, state.sourceID == request.sourceID, state.leaseID == request.leaseID,
                  state.expiration.map({ $0 > Date() }) == true else { throw RemoteError.server(409, "Different lease") }
        }
        switch request.operation {
        case "claim":
            if state.active, state.sourceID != request.sourceID, request.takeover != true { throw RemoteError.server(409, "Owned") }
            state.active = true; state.sourceID = request.sourceID; state.sourceName = request.sourceName
            state.leaseID = UUID().uuidString; state.state = request.state; state.revision += 1; state.feedback = nil
            state.keepReading = supportsReading ? false : nil; state.readingOnly = supportsReading ? false : nil
            sequences[state.leaseID!] = 0
        case "update":
            guard state.active, state.readingOnly != true, state.sourceID == request.sourceID, state.leaseID == request.leaseID,
                  state.expiration.map({ $0 > Date() }) == true,
                  let sequence = request.sequence, sequence > (sequences[state.leaseID!] ?? 0) else {
                throw RemoteError.server(409, "Lease or sequence rejected")
            }
            sequences[state.leaseID!] = sequence
            if state.state != request.state { state.revision += 1; state.feedback = nil }
            state.state = request.state
            if request.state?.chatID == nil { state.keepReading = false }
        case "setReading":
            guard let enabled = request.enabled, state.state?.chatID != nil else { throw RemoteError.server(422, "Missing chat") }
            if state.readingOnly == true, !enabled {
                state = .init(version: 1, hostID: host.hostID!, active: false, revision: state.revision + 1)
            } else { state.keepReading = enabled }
        case "park":
            guard state.keepReading == true else { throw RemoteError.server(409, "Not armed") }
            if state.readingOnly != true {
                state.readingOnly = true; state.revision += 1; state.feedback = nil
                state.state?.view = .reply; state.state?.page = 0; state.state?.draft = ""
                state.state?.recording = false; state.state?.sendState = GlassesSendState.none
                state.expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            }
        case "resume":
            state.leaseID = UUID().uuidString; sequences[state.leaseID!] = 0
            state.readingOnly = false; state.revision += 1; state.feedback = nil
        case "release":
            guard state.sourceID == request.sourceID, state.leaseID == request.leaseID else { throw RemoteError.server(409, "Different lease") }
            state = .init(version: 1, hostID: host.hostID!, active: false, revision: state.revision + 1)
        default: throw RemoteError.server(422, "Unsupported operation")
        }
        state.supportsKeepReading = supportsReading ? true : nil
        if state.active && state.readingOnly != true { state.expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(45)) }
        snapshots[host.hostID!] = state
        if holdOperation == request.operation { await withCheckedContinuation { held.append($0) } }
        if failAfter == request.operation { throw RemoteError.server(503, "Fixture lost response") }
        return state
    }
    func resumeWrites() { holdOperation = nil; let pending = held; held = []; pending.forEach { $0.resume() } }
    func resumeReads() { holdReads = false; let pending = heldReads; heldReads = []; pending.forEach { $0.resume() } }
    func acknowledge(_ host: RemoteHost, pages: Int = 3, stale: Bool = false, page: Int? = nil) {
        var state = current(host)
        state.feedback = .init(revision: state.revision - (stale ? 1 : 0), pageCount: pages,
                               renderedPage: page ?? state.state?.page ?? 0, connected: true)
        snapshots[host.hostID!] = state
    }
}
