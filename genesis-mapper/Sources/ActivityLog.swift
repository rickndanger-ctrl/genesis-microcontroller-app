import Foundation

/// One line of the activity log.
struct ActivityEntry: Codable, Equatable {
    var time: Date
    var provider: String   // "claude", "muse", "codex", "gemini"
    var action: String     // e.g. "openChat", "sendPrompt"
    var status: String     // "confirmed", "failed", "uncertain", "queued", "refused"
    var message: String    // the result message shown to the user
    var durationMs: Int
}

/// A rolling, timestamped record of the commands the companion has run, kept
/// so that "it didn't work earlier" can be diagnosed afterwards.
///
/// PRIVACY RULE: never give this log prompt or message text typed by the user.
/// Only action names, results and timings belong here. The caller enforces
/// this; the rule is recorded here so it is not forgotten.
///
/// Not thread-safe by design: use it from the main actor only.
///
/// Storage is a JSON Lines file (one JSON object per line, ISO 8601 dates).
/// Logging never throws or crashes the caller: file errors are swallowed and
/// the in-memory entries keep working.
final class ActivityLog {
    private static let maxMessageLength = 200
    private static let maxFieldLength = 40

    private let url: URL
    private let limit: Int
    private let now: () -> Date
    private var entries: [ActivityEntry] = []

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Stable key order keeps the file easy to diff and grep.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(url: URL, limit: Int = 1000, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.limit = max(limit, 0)
        self.now = now
        entries = load()
    }

    func record(provider: String, action: String, status: String, message: String, durationMs: Int) {
        // Work on scalars: Swift treats "\r\n" as one Character, which would slip past a per-Character check.
        var flattened = String.UnicodeScalarView()
        for scalar in message.unicodeScalars {
            flattened.append(scalar == "\n" || scalar == "\r" || scalar == "\t" ? " " : scalar)
        }
        entries.append(ActivityEntry(
            time: now(),
            provider: String(provider.prefix(Self.maxFieldLength)),
            action: String(action.prefix(Self.maxFieldLength)),
            status: String(status.prefix(Self.maxFieldLength)),
            message: String(String(flattened).prefix(Self.maxMessageLength)),
            durationMs: max(durationMs, 0)))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        persist()
    }

    /// The newest `count` entries, oldest first.
    func recent(_ count: Int) -> [ActivityEntry] {
        guard count > 0 else { return [] }
        return Array(entries.suffix(count))
    }

    // MARK: - Storage

    private func load() -> [ActivityEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // Decode line by line so one damaged line cannot cost the whole history.
        let loaded = data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(ActivityEntry.self, from: Data($0))
        }
        return Array(loaded.suffix(limit))
    }

    private func persist() {
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            return
        }
        // Write a private sibling file and rename it over the log, so the
        // contents are never readable by others and a crash cannot leave a
        // half-written log behind.
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp")
        try? fileManager.removeItem(at: temporary)
        guard fileManager.createFile(atPath: temporary.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, url.path) != 0 {
            try? fileManager.removeItem(at: temporary)
        }
    }
}

/// The newest activity as the companion reports it.
struct RemoteActivity: Codable {
    var entries: [ActivityEntry]
}
