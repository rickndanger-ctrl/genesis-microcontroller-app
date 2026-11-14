import Foundation

/// The small, deterministic safety boundary between Genesis Prompt reports and
/// Quiet Studio URLs. This type has no HID, AppKit, or microphone side effects.
struct PromptRouteGate {
    static func failedStartBelongs(to expected: Gesture, current: Gesture?) -> Bool {
        current == expected
    }

    struct Status {
        let bootID: String
        let route: String
        let leaseSession: String
        let leaseRemainingMS: Int
        let promptDown: Bool

        init?(_ values: [String: Any]) {
            guard (values["prompt_protocol"] as? Int) == 1,
                  let boot = values["boot_id"] as? String,
                  Self.validBootID(boot),
                  let route = values["prompt_route"] as? String,
                  let session = values["lease_session"] as? String,
                  let remaining = values["lease_remaining_ms"] as? Int,
                  remaining >= 0,
                  let down = values["prompt_down"] as? Bool else { return nil }
            bootID = boot.lowercased()
            self.route = route
            leaseSession = session
            leaseRemainingMS = remaining
            promptDown = down
        }

        static func validBootID(_ value: String) -> Bool {
            value.count == 32 && value.allSatisfy { $0.isHexDigit }
        }
    }

    struct Gesture: Equatable {
        let bootID: String
        let session: String
        let id: String
        let targetPID: Int

        init(bootID: String, session: String, id: String, targetPID: Int = 0) {
            self.bootID=bootID
            self.session=session
            self.id=id
            self.targetPID=targetPID
        }
    }
    enum Action: Equatable {
        case start(Gesture)
        case stop(Gesture)
        case cancel(Gesture)
    }

    private(set) var session: String
    private(set) var bootID: String?
    private(set) var leaseDeadline: TimeInterval = 0
    private(set) var active: Gesture?
    private(set) var quarantinedUntilRelease = false
    private(set) var physicalDown = false
    private var highSequence: [String: Int] = [:]
    private var tombstones: Set<String> = []
    private var ackReceivedAt: TimeInterval = 0

    init(session: String = UUID().uuidString.lowercased()) {
        self.session = session.lowercased()
    }

    var leaseIsLive: Bool { leaseDeadline > 0 }

    /// ACK expiry is anchored to the request's local send time, never its arrival.
    mutating func acceptLeaseAck(bootID: String, session: String, sentAt: TimeInterval,
                                 acceptedMS: Int, requestedMS: Int = 3_000,
                                 now: TimeInterval) -> Bool {
        guard let currentBoot = self.bootID, bootID.lowercased() == currentBoot,
              session.lowercased() == self.session, acceptedMS > 0,
              acceptedMS <= requestedMS, sentAt <= now,
              sentAt + Double(acceptedMS) / 1_000 > now else {
            return false
        }
        leaseDeadline = sentAt + Double(acceptedMS) / 1_000
        ackReceivedAt = now
        return true
    }

    /// Returns a cancellation if status indicates a reboot or loss of ownership.
    mutating func observe(_ status: Status, now: TimeInterval) -> Action? {
        if bootID == nil {
            bootID = status.bootID
            physicalDown = status.promptDown
            if status.promptDown { quarantinedUntilRelease = true }
        }
        if let oldBoot = bootID, oldBoot != status.bootID {
            let canceled = active.map(Action.cancel)
            bootID = status.bootID
            leaseDeadline = 0
            ackReceivedAt = 0
            physicalDown = status.promptDown
            quarantinedUntilRelease = status.promptDown
            active = nil
            return canceled
        }
        bootID = status.bootID
        physicalDown = status.promptDown
        if !status.promptDown { quarantinedUntilRelease = false }

        let expiryFromStatus = now + Double(status.leaseRemainingMS) / 1_000
        let statusOwner=status.leaseSession.lowercased()
        let justAcknowledged=leaseDeadline>now && now-ackReceivedAt<0.75
        let ownerMatches=statusOwner==session && status.leaseRemainingMS>0
        let statusMayPrecedeAck=justAcknowledged && (statusOwner.isEmpty || statusOwner==session)
        guard status.route == "quiet", leaseDeadline > now,
              ownerMatches || statusMayPrecedeAck else {
            let canceled = active.map(Action.cancel)
            active = nil
            leaseDeadline = 0
            if status.promptDown { quarantinedUntilRelease = true }
            return canceled
        }
        if ownerMatches { leaseDeadline = min(leaseDeadline, expiryFromStatus) }
        return nil
    }

    mutating func leaseExpired(now: TimeInterval) -> Action? {
        guard leaseDeadline > 0, leaseDeadline <= now else { return nil }
        let canceled = active.map(Action.cancel)
        active = nil
        leaseDeadline = 0
        ackReceivedAt = 0
        if physicalDown { quarantinedUntilRelease = true }
        return canceled
    }

    mutating func disconnected() -> Action? {
        let canceled = active.map(Action.cancel)
        active = nil
        leaseDeadline = 0
        ackReceivedAt = 0
        if physicalDown { quarantinedUntilRelease = true }
        bootID = nil
        session = UUID().uuidString.lowercased()
        return canceled
    }

    mutating func rotateSession() -> Action? {
        let canceled = active.map(Action.cancel)
        active = nil
        leaseDeadline = 0
        ackReceivedAt = 0
        session = UUID().uuidString.lowercased()
        if physicalDown { quarantinedUntilRelease = true }
        return canceled
    }

    mutating func cancelCurrent() -> Action? {
        guard let current = active else { return nil }
        active = nil
        quarantinedUntilRelease = physicalDown
        tombstones.insert(current.bootID + "/" + current.session + "/" + current.id)
        return .cancel(current)
    }

    @discardableResult mutating func loseLease() -> Action? {
        let canceled=active.map(Action.cancel)
        active = nil
        leaseDeadline = 0
        ackReceivedAt = 0
        if physicalDown { quarantinedUntilRelease = true }
        return canceled
    }

    mutating func modeChangedAwayFromCodex() -> Action? {
        let canceled = active.map(Action.cancel)
        active = nil
        leaseDeadline = 0
        ackReceivedAt = 0
        if physicalDown { quarantinedUntilRelease = true }
        return canceled
    }

    mutating func handle(_ message: [String: Any], targetPID: Int, now: TimeInterval) -> Action? {
        guard let bootID, leaseDeadline > now,
              let payload = message["p"] as? [String: Any],
              payload["v"] as? Int == 1,
              let eventBoot = payload["boot_id"] as? String,
              eventBoot.lowercased() == bootID,
              let eventSession = payload["session"] as? String,
              eventSession.lowercased() == session,
              let gestureID = payload["gesture"] as? String,
              gestureID.hasPrefix(bootID + ":"),
              let counter = Int(gestureID.dropFirst(bootID.count + 1)), counter > 0,
              let sequence = payload["seq"] as? Int, sequence > 0,
              let edge = payload["edge"] as? String,
              ["down", "up", "cancel"].contains(edge) else { return nil }

        let sequenceKey = bootID + "/" + session
        guard sequence > (highSequence[sequenceKey] ?? 0) else { return nil }
        highSequence[sequenceKey] = sequence
        let identity = bootID + "/" + session + "/" + gestureID

        if edge == "down" {
            physicalDown = true
            guard !quarantinedUntilRelease, active == nil,
                  !tombstones.contains(identity) else {
                quarantinedUntilRelease = true
                if let current=active {
                    active=nil
                    tombstones.insert(current.bootID + "/" + current.session + "/" + current.id)
                    return .cancel(current)
                }
                return nil
            }
            let gesture = Gesture(bootID: bootID, session: session, id: gestureID, targetPID: targetPID)
            active = gesture
            return .start(gesture)
        }

        if edge == "up" {
            physicalDown = false
            quarantinedUntilRelease = false
        } else {
            // A firmware cancellation can arrive while the physical key is
            // still held; require an observed release before another start.
            physicalDown = true
            quarantinedUntilRelease = true
        }
        guard let current = active, current.id == gestureID,
              current.bootID == bootID, current.session == session else {
            tombstones.insert(identity)
            return nil
        }
        active = nil
        tombstones.insert(identity)
        return edge == "up" ? .stop(current) : .cancel(current)
    }

}

enum PromptAppLifecyclePolicy {
    static func desiredRoute(runningPID: Int?, integrationEnabled: Bool = true,
                             currentRoute: String, promptDown: Bool) -> String? {
        guard !promptDown else { return nil }
        let desired = integrationEnabled && runningPID != nil ? "quiet" : "native"
        return currentRoute == desired ? nil : desired
    }

    static func mayDispatch(targetPID: Int?, livePID: Int?, integrationEnabled: Bool = true,
                            terminalCleanup: Bool = false) -> Bool {
        guard integrationEnabled || terminalCleanup else { return false }
        guard let targetPID, let livePID else { return false }
        return targetPID == livePID
    }

    static func mayAcceptLeaseAcknowledgment(integrationEnabled: Bool,
                                             targetPID: Int?, livePID: Int?) -> Bool {
        integrationEnabled && mayDispatch(targetPID: targetPID, livePID: livePID)
    }

    static func mayAcquireLease(runningPID: Int?, integrationEnabled: Bool = true,
                                route: String, promptDown: Bool,
                                leaseOwner: String, session: String) -> Bool {
        guard integrationEnabled, runningPID != nil, route == "quiet" else { return false }
        if promptDown { return leaseOwner == session }
        return leaseOwner.isEmpty || leaseOwner == session
    }
}

enum PromptURLCommand: String { case start = "controller-start", stop = "controller-stop", cancel = "controller-cancel", heartbeat = "controller-heartbeat" }

enum PromptURLBuilder {
    static func make(_ command: PromptURLCommand, session: String, gesture: String,
                     nowMilliseconds: Int64) -> URL? {
        guard UUID(uuidString: session) != nil, !gesture.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "quietstudio"
        components.host = command.rawValue
        var items = [URLQueryItem(name: "session", value: session),
                     URLQueryItem(name: "gesture", value: gesture)]
        if command == .start || command == .heartbeat {
            items += [URLQueryItem(name: "issued_at_ms", value: String(nowMilliseconds)),
                      URLQueryItem(name: "expires_at_ms", value: String(nowMilliseconds + 2_000))]
        }
        components.queryItems = items
        return components.url
    }
}
