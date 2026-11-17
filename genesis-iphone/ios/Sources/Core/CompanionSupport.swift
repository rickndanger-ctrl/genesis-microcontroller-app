import Foundation

/// A companion version such as "0.6.0" or "0.5.2-preview".
struct CompanionVersion: Comparable, Equatable, CustomStringConvertible {
    /// Always padded to four components so "0.6" and "0.6.0" are the same version.
    private let core: [Int]
    private let preRelease: String?
    let description: String

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = Substring(trimmed)
        if body.hasPrefix("v") || body.hasPrefix("V") { body = body.dropFirst() }

        // Split once so a tag such as "rc-1" keeps its own dash.
        let coreText: Substring
        var tag: Substring?
        if let dash = body.firstIndex(of: "-") {
            coreText = body[..<dash]
            tag = body[body.index(after: dash)...]
            if tag!.isEmpty { return nil }
        } else {
            coreText = body
        }

        let parts = coreText.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // Int("+1") and Int("-1") parse, so insist on plain ASCII digits.
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 4 { numbers.append(0) }

        core = numbers
        preRelease = tag.map(String.init)
        description = trimmed
    }

    // Written out because the stored text differs between equal versions.
    static func == (lhs: CompanionVersion, rhs: CompanionVersion) -> Bool {
        lhs.core == rhs.core && lhs.preRelease == rhs.preRelease
    }

    static func < (lhs: CompanionVersion, rhs: CompanionVersion) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        switch (lhs.preRelease, rhs.preRelease) {
        case let (l?, r?): return l < r
        case (.some, .none): return true   // a pre-release sorts before its release
        default: return false
        }
    }
}

enum CompanionSupport {
    /// The oldest companion this app is written for.
    static let minimum = CompanionVersion("0.6.0")!

    /// True when the Mac should be updated. A companion that reports no version is older than any that does.
    static func isOutOfDate(_ reported: String?) -> Bool {
        guard let reported else { return true }
        // An unreadable version cannot be vouched for, so treat it as old.
        guard let version = CompanionVersion(reported) else { return true }
        return version < minimum
    }

    /// One sentence to show the user, or nil when the companion is current.
    static func notice(hostName: String, reported: String?) -> String? {
        guard isOutOfDate(reported) else { return nil }
        let trimmedHost = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = trimmedHost.isEmpty ? "This Mac" : trimmedHost
        let advice = "Update Agent Micro Controller on that Mac to get Muse and recent fixes."
        if let reported, CompanionVersion(reported) != nil {
            let shown = reported.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(host) is running companion \(shown). \(advice)"
        }
        return "\(host) is running an older companion. \(advice)"
    }
}

struct SelfCheckItem: Codable, Equatable, Identifiable {
    var provider: String   // "mac", "claude", "muse", "codex"
    var name: String
    var ok: Bool
    var detail: String
    var id: String { provider + "/" + name }
}

struct SelfCheckSection: Equatable, Identifiable {
    var title: String
    var items: [SelfCheckItem]
    var id: String { title }
}

struct SelfCheckReport: Codable, Equatable {
    var checkedAt: Date
    var companionVersion: String
    var summary: String
    var items: [SelfCheckItem]

    private static let knownTitles: [(provider: String, title: String)] = [
        ("mac", "This Mac"), ("claude", "Claude"), ("muse", "Muse"), ("codex", "Codex"),
    ]

    /// Items grouped by provider: mac, claude, muse, codex, then any other provider in first-seen order.
    var sections: [SelfCheckSection] {
        var order = Self.knownTitles.map(\.provider)
        var grouped: [String: [SelfCheckItem]] = [:]
        for item in items {
            if !order.contains(item.provider) { order.append(item.provider) }
            grouped[item.provider, default: []].append(item)
        }
        return order.compactMap { provider in
            guard let members = grouped[provider], !members.isEmpty else { return nil }
            return SelfCheckSection(title: Self.title(for: provider), items: members)
        }
    }

    var problemCount: Int { items.filter { !$0.ok }.count }

    private static func title(for provider: String) -> String {
        if let known = knownTitles.first(where: { $0.provider == provider }) { return known.title }
        guard let first = provider.first else { return "Other" }
        return first.uppercased() + provider.dropFirst()
    }
}

struct ActivityEntry: Codable, Equatable, Identifiable {
    var time: Date
    var provider: String
    var action: String
    var status: String     // "confirmed", "failed", "uncertain", "queued", "refused"
    var message: String
    var durationMs: Int
    /// Built from the fields that identify a command, so it stays the same across refreshes.
    var id: String { "\(time.timeIntervalSinceReferenceDate)|\(provider)|\(action)|\(durationMs)" }
    var succeeded: Bool { status == "confirmed" || status == "queued" }
}

struct ActivityReport: Codable, Equatable {
    var entries: [ActivityEntry]   // oldest first, as the Mac sends them
    var newestFirst: [ActivityEntry] { entries.reversed() }
}
