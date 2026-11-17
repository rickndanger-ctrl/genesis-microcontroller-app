import Foundation
import CryptoKit

/// One phone or tablet allowed to control this Mac.
struct PairedDevice: Codable, Equatable, Identifiable {
    var id: String           // a UUID string
    var name: String
    var tokenHash: String    // lowercase hex SHA-256 of the device's secret. The secret itself is never stored.
    var pairedAt: Date
    var lastSeenAt: Date?
}

/// Which devices may talk to this Mac. A value type: the caller persists it.
struct DeviceRegistry: Codable, Equatable {
    static let defaultName = "iPhone or iPad"
    static let maxNameLength = 40
    /// How stale `lastSeenAt` may get before `seen` reports a change. Keeps the
    /// caller from rewriting its file on every request.
    static let seenInterval: TimeInterval = 60

    var devices: [PairedDevice] = []
    /// Whether the single shared secret used before per-device secrets is still accepted.
    var legacySecretAccepted: Bool = true

    init(devices: [PairedDevice] = [], legacySecretAccepted: Bool = true) {
        self.devices = devices
        self.legacySecretAccepted = legacySecretAccepted
    }

    enum CodingKeys: String, CodingKey { case devices, legacySecretAccepted }

    /// Older files lack one or both keys; missing keys fall back to the defaults
    /// so an upgrade never locks a user out or drops their devices.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devices = try container.decodeIfPresent([PairedDevice].self, forKey: .devices) ?? []
        legacySecretAccepted = try container.decodeIfPresent(Bool.self, forKey: .legacySecretAccepted) ?? true
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 32 cryptographically random bytes, base64-encoded.
    static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }

    /// A tidy, unique display name.
    static func cleanName(_ raw: String, existing: [String]) -> String {
        // One pass: whitespace runs become a single space, other control
        // characters vanish, and edge spaces are never emitted.
        var tidy = ""
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !tidy.isEmpty
            } else if scalar.properties.generalCategory == .control {
                continue
            } else {
                if pendingSpace { tidy.append(" "); pendingSpace = false }
                tidy.unicodeScalars.append(scalar)
            }
        }
        let base = trimmedPrefix(tidy, maxNameLength)
        let name = base.isEmpty ? defaultName : base

        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(name.lowercased()) { return name }

        var number = 2
        while true {
            let suffix = " \(number)"
            // Shorten the base, not the suffix, so the number always survives the cap.
            let candidate = trimmedPrefix(name, maxNameLength - suffix.count) + suffix
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }

    /// The first `limit` characters, without a trailing space left by the cut.
    private static func trimmedPrefix(_ text: String, _ limit: Int) -> String {
        var cut = String(text.prefix(limit))
        while cut.last == " " { cut.removeLast() }
        return cut
    }

    /// Adds a device and returns the secret to hand to it. The registry keeps only its hash.
    mutating func enroll(name: String, now: Date, id: String = UUID().uuidString, token: String = DeviceRegistry.newToken()) -> (device: PairedDevice, token: String) {
        // A repeated id would make revoke and rename act on the wrong phone.
        let uniqueID = devices.contains { $0.id == id } ? UUID().uuidString : id
        let device = PairedDevice(
            id: uniqueID,
            name: Self.cleanName(name, existing: devices.map(\.name)),
            tokenHash: Self.hash(token),
            pairedAt: now,
            lastSeenAt: nil
        )
        devices.append(device)
        return (device, token)
    }

    /// The device a presented secret belongs to, or nil.
    func device(for token: String) -> PairedDevice? {
        guard !token.isEmpty else { return nil }
        let presented = Self.hash(token)
        var match: PairedDevice?
        // Visit every device so timing does not reveal which one matched.
        for device in devices where constantTimeEquals(device.tokenHash, presented) && match == nil {
            match = device
        }
        return match
    }

    /// Records that a device was just seen. Returns true only when it changed the registry.
    mutating func seen(_ id: String, now: Date) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return false }
        if let last = devices[index].lastSeenAt, now.timeIntervalSince(last) <= Self.seenInterval {
            return false
        }
        devices[index].lastSeenAt = now
        return true
    }

    mutating func revoke(_ id: String) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return false }
        devices.remove(at: index)
        return true
    }

    mutating func rename(_ id: String, to name: String) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return false }
        let others = devices.enumerated().filter { $0.offset != index }.map(\.element.name)
        let cleaned = Self.cleanName(name, existing: others)
        guard cleaned != devices[index].name else { return false }
        devices[index].name = cleaned
        return true
    }
}

/// Short-lived, single-use codes shown in the pairing QR code. In memory only.
struct PairingCodes {
    enum Outcome: Equatable { case accepted, rejected, lockedOut(until: Date) }
    static let lifetime: TimeInterval = 600      // ten minutes
    static let maxActive = 3
    static let maxFailures = 5
    static let lockout: TimeInterval = 60

    private struct Entry { var code: String; var expires: Date }
    private var entries: [Entry] = []
    private var failures = 0
    private var lockedUntil: Date?

    init() {}

    /// A new code, valid for `lifetime`. `code` is injectable for tests.
    mutating func issue(now: Date, code: String = DeviceRegistry.newToken()) -> String {
        dropExpired(now)
        entries.append(Entry(code: code, expires: now.addingTimeInterval(Self.lifetime)))
        // Bound how many live codes exist at once; the soonest to expire go first.
        while entries.count > Self.maxActive {
            let soonest = entries.indices.min { entries[$0].expires < entries[$1].expires }!
            entries.remove(at: soonest)
        }
        return code
    }

    /// Uses a code. An accepted code cannot be used again.
    ///
    /// The right code is accepted even during a lockout. Codes are 256 random
    /// bits, so guessing is not the risk; refusing the right code would only
    /// let anyone on the network stop the owner's phone from pairing.
    mutating func redeem(_ code: String, now: Date) -> Outcome {
        dropExpired(now)

        // Check every code so timing does not reveal which one was close.
        var matched: Int?
        for index in entries.indices where constantTimeEquals(entries[index].code, code) && matched == nil {
            matched = index
        }
        if let index = matched, !code.isEmpty {
            entries.remove(at: index)
            failures = 0
            lockedUntil = nil
            return .accepted
        }

        if let until = lockedUntil {
            if now < until { return .lockedOut(until: until) }
            lockedUntil = nil
            failures = 0
        }

        failures += 1
        if failures >= Self.maxFailures {
            lockedUntil = now.addingTimeInterval(Self.lockout)
            failures = 0
        }
        return .rejected
    }

    /// How many codes are currently valid.
    func activeCount(now: Date) -> Int {
        entries.filter { $0.expires > now }.count
    }

    private mutating func dropExpired(_ now: Date) {
        entries.removeAll { $0.expires <= now }
    }
}

/// Tells a request made on this Mac from one relayed from the network.
///
/// The companion listens only on the loopback address, and other devices reach
/// it through Tailscale Serve, which adds forwarding headers to everything it
/// relays and which a remote caller cannot remove. A request without any of
/// them came from a program running on this Mac.
enum LocalCaller {
    static let relayPrefixes = ["x-forwarded-", "tailscale-"]
    static let relayHeaders: Set<String> = ["forwarded", "via", "x-real-ip"]
    static func isDirect(headers: [String: String]) -> Bool {
        !headers.keys.contains { key in
            let name = key.lowercased()
            return relayHeaders.contains(name) || relayPrefixes.contains { name.hasPrefix($0) }
        }
    }
}

/// Compares two strings without leaking, through timing, where they first differ.
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let left = Array(a.utf8)
    let right = Array(b.utf8)
    // A length mismatch is folded into the result, and the loop still covers
    // the longer input so the work does not depend on where they differ.
    var difference = UInt(left.count ^ right.count)
    for index in 0..<max(left.count, right.count) {
        let x = index < left.count ? left[index] : 0
        let y = index < right.count ? right[index] : 0
        difference |= UInt(x ^ y)
    }
    return difference == 0
}
