import Foundation

/// Keeps the whole hold-to-talk draft when Apple's recognizer completes or starts
/// a new utterance. Empty results and callbacks from retired tasks are not edits.
struct DictationTranscript {
    private(set) var text = ""
    private var committed: [String] = []
    private var current = ""
    private var segmentID: UUID?
    private var segmentStartIndex = 0
    private var segmentFirstTimestamp: TimeInterval?
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?

    mutating func beginSegment(_ id: UUID) {
        commitCurrent()
        segmentID = id
        segmentStartIndex = committed.count
        segmentFirstTimestamp = nil
    }

    @discardableResult
    mutating func receive(_ value: String, segment id: UUID,
                          firstTimestamp first: TimeInterval? = nil,
                          lastTimestamp last: TimeInterval? = nil) -> String? {
        guard id == segmentID else { return nil }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let incoming = Self.words(in: value)
        let previous = Self.words(in: current)
        guard !incoming.isEmpty else { return nil }
        let incomingKeys = incoming.map(\.key), previousKeys = previous.map(\.key)

        // Some OS versions reset their result to the latest utterance without
        // ending the recognition task. Timing helps identify distinct speech,
        // but zero/reset timestamps are not proof that earlier words vanished.
        let timedRange = first.flatMap { start in
            last.flatMap { end in start.isFinite && end.isFinite && start >= 0 && end > start ? (start, end) : nil }
        }
        let extendsCurrent = incomingKeys.count > previousKeys.count && incomingKeys.starts(with: previousKeys)
        let startsNewAudio: Bool
        if let (first, _) = timedRange, let previousFirst = firstTimestamp, let previousEnd = lastTimestamp {
            startsNewAudio = first > previousFirst + 0.05 && first >= previousEnd + 0.05 && !extendsCurrent
        } else { startsNewAudio = false }

        let taskText = (Array(committed[segmentStartIndex...]) + [current]).joined(separator: " ")
        let taskKeys = Self.words(in: taskText).map(\.key)
        let sameTaskSpan = Self.coversAudio(timedRange, startingAt: segmentFirstTimestamp, endingAt: lastTimestamp)
        let sameCurrentSpan = Self.coversAudio(timedRange, startingAt: firstTimestamp, endingAt: lastTimestamp)
        if startsNewAudio, !current.isEmpty {
            // A genuinely repeated phrase at a later audio range is new speech.
            commitCurrent()
            current = value
        } else if committed.count > segmentStartIndex,
                  Self.covers(taskKeys, with: incomingKeys)
                    || (sameTaskSpan && Self.isBoundedCorrection(taskKeys, incomingKeys, minimumWords: 4)) {
            // Collapse fragments only if the new text actually covers their
            // words in order. A broad/reset time range alone is insufficient.
            committed.removeSubrange(segmentStartIndex...)
            current = value
        } else if previousKeys == incomingKeys {
            current = value // Punctuation/case corrections are harmless.
        } else if Self.contains(incomingKeys, in: taskKeys)
                    || (incomingKeys.count < taskKeys.count && Self.covers(incomingKeys, with: taskKeys)) {
            // A shorter prefix, suffix, or middle fragment is an incomplete
            // callback, not permission to delete the rest of the held draft.
            return nil
        } else if previous.isEmpty || extendsCurrent || Self.isRevision(previousKeys, incomingKeys)
                    || (sameCurrentSpan && Self.isBoundedCorrection(previousKeys, incomingKeys, minimumWords: 2)) {
            current = value
        } else if let overlap = Self.suffixOverlap(previousKeys, incomingKeys) {
            // A reset sometimes repeats the tail before adding new words.
            // Keep the untouched prefix and replace only the shared tail.
            let prefix = current[..<previous[previous.count - overlap].start]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            current = prefix.isEmpty ? value : prefix + " " + value
        } else {
            // With absent/zero timestamps, disjoint text is safest treated as
            // new speech. Do not choose the longest result and lose short replies.
            commitCurrent()
            current = value
        }
        if let (first, last) = timedRange {
            if segmentFirstTimestamp == nil { segmentFirstTimestamp = first }
            firstTimestamp = first; lastTimestamp = last
        }
        let combined = (committed + [current]).filter { !$0.isEmpty }.joined(separator: " ")
        guard combined != text else { return nil }
        text = combined
        return combined
    }

    mutating func endSegment(_ id: UUID) {
        guard segmentID == id else { return }
        commitCurrent()
        segmentID = nil
    }

    private mutating func commitCurrent() {
        if !current.isEmpty { committed.append(current) }
        current = ""
        firstTimestamp = nil
        lastTimestamp = nil
    }

    private struct Word {
        let key: String
        let start: String.Index
    }
    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)
    private static func words(in value: String) -> [Word] {
        wordPattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            let key = value[range].lowercased().replacingOccurrences(of: "’", with: "'")
            return Word(key: key, start: range.lowerBound)
        }
    }
    private static func covers(_ previous: [String], with incoming: [String]) -> Bool {
        guard !previous.isEmpty, incoming.count >= previous.count else { return false }
        var index = 0
        for word in incoming where index < previous.count {
            if word == previous[index] { index += 1 }
        }
        return index == previous.count
    }
    private static func coversAudio(_ incoming: (TimeInterval, TimeInterval)?,
                                    startingAt start: TimeInterval?, endingAt end: TimeInterval?) -> Bool {
        guard let (first, last) = incoming, let start, let end else { return false }
        return abs(first - start) <= 0.15 && last >= end - 0.05
    }
    private static func isBoundedCorrection(_ previous: [String], _ incoming: [String], minimumWords: Int) -> Bool {
        // A real final may correct "Jon" to "John" in a committed phrase.
        // Require the same audio span, unchanged word count, and every other
        // aligned word as an anchor. Never use timing to authorize missing words.
        guard previous.count >= minimumWords, previous.count == incoming.count else { return false }
        return zip(previous, incoming).filter { $0 != $1 }.count == 1
    }
    private static func contains(_ fragment: [String], in complete: [String]) -> Bool {
        guard !fragment.isEmpty, fragment.count <= complete.count else { return false }
        return (0...(complete.count - fragment.count)).contains { offset in
            complete[offset..<(offset + fragment.count)].elementsEqual(fragment)
        }
    }
    private static func isRevision(_ previous: [String], _ incoming: [String]) -> Bool {
        // Keep ordinary partial corrections such as "Call Jon" → "Call John".
        // An unrelated phrase with just one shared word must not erase a draft.
        guard !previous.isEmpty, incoming.count >= previous.count, previous.first == incoming.first else { return false }
        let prefix = zip(previous, incoming).prefix { $0 == $1 }.count
        let suffix = zip(previous.reversed(), incoming.reversed()).prefix { $0 == $1 }.count
        return (prefix + suffix) * 2 >= previous.count
    }
    private static func suffixOverlap(_ previous: [String], _ incoming: [String]) -> Int? {
        let maximum = min(previous.count, incoming.count)
        guard maximum >= 2 else { return nil }
        for count in stride(from: maximum, through: 2, by: -1) {
            if previous.suffix(count).elementsEqual(incoming.prefix(count)) { return count }
        }
        return nil
    }
}
