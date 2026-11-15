import Foundation

/// Bounded, device-local lifecycle metadata. Never pass transcript, audio, chat,
/// endpoint, or credential values here; only fixed event names and integer counts.
enum DictationDiagnostics {
    private static let queue = DispatchQueue(label: "Genesis.DictationDiagnostics", qos: .utility)
    private static var events: [[String: Any]] = []
    private static let limit = 128

    static func record(_ event: String, _ values: [String: Int] = [:]) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard !event.isEmpty, event.count <= 48, event.unicodeScalars.allSatisfy(allowed.contains),
              values.count <= 12, values.keys.allSatisfy({ !$0.isEmpty && $0.count <= 40 && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return }
        let timestamp = Date().timeIntervalSince1970
        queue.async {
            events.append(["time": timestamp, "event": event, "values": values])
            if events.count > limit { events.removeFirst(events.count - limit) }
            guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            let directory = root.appendingPathComponent("GenesisDiagnostics", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.complete])
                var data = Data()
                for entry in events {
                    data.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
                    data.append(0x0A)
                }
                try data.write(to: directory.appendingPathComponent("dictation.jsonl"), options: [.atomic, .completeFileProtection])
            } catch {
                // Diagnostics must never stop recording or expose user content.
            }
        }
    }
}
