import Foundation

/// Decides which Codex chats are working right now, from two cheap facts:
/// the newest turn has no completion time, and the chat's rollout file was
/// written recently. Pure, so the rules are tested without Codex. Nothing here
/// reads a chat's title or messages.
enum CodexActivity {
    /// A turn with no completion time only counts while its file is this fresh.
    /// Codex writes in bursts (the longest quiet gap seen during work was 33 s),
    /// and a crashed Codex must not leave a light on forever.
    static let freshness: TimeInterval = 120
    /// At most this many chats get the one extra request, newest file first.
    static let probeLimit = 8
    /// Total time the activity check may add to a chat-list read.
    static let budget: TimeInterval = 1.5
    /// A file stamped slightly in the future (clock adjustment) still counts as fresh.
    static let clockSlack: TimeInterval = 60

    static func isFresh(_ modified: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(modified)
        return age >= -clockSlack && age <= freshness
    }

    /// `newestTurn` is the first row of `thread/turns/list` (newest first).
    /// Working only when `completedAt` is present and null and the file is fresh.
    /// The turn's `status` string is ignored: it reads "interrupted" while a turn runs.
    static func isWorking(newestTurn: [String: Any]?, modified: Date?, now: Date) -> Bool {
        guard let turn = newestTurn, let modified, isFresh(modified, now: now),
              let completedAt = turn["completedAt"], completedAt is NSNull else { return false }
        return true
    }

    /// Chat ids worth asking about: fresh files only, newest first, capped.
    static func probeOrder(_ modified: [String: Date], now: Date, limit: Int = probeLimit) -> [String] {
        modified.filter { isFresh($0.value, now: now) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(max(0, limit)).map(\.key)
    }

    static func turnRequest(threadID: String) -> [String: Any] {
        ["threadId": threadID, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"]
    }

    /// Only a rollout file inside Codex's own home is ever looked at. The path
    /// comes from Codex's reply, so it is checked rather than trusted.
    static func trustedRolloutPath(_ path: String, home: String) -> Bool {
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { return false }
        let root = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(root)
    }
}
