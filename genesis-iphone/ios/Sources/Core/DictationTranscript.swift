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

        // Some OS versions report a fresh utterance after silence without ending
        // the recognition task. A later, nonoverlapping audio range distinguishes
        // that from normal corrections to the same partial transcription.
        let timedRange = first.flatMap { start in
            last.flatMap { end in end > start ? (start, end) : nil }
        }
        if let (first, last) = timedRange, let segmentFirstTimestamp,
           committed.count > segmentStartIndex, first <= segmentFirstTimestamp + 0.05,
           last >= (lastTimestamp ?? last) - 0.05 {
            // A later final can cover the full task again after partial results
            // briefly covered only its latest utterance. Replace that task's
            // pieces, retaining everything from earlier recognition tasks.
            committed.removeSubrange(segmentStartIndex...)
        } else if let (first, _) = timedRange, let previousFirst = firstTimestamp, let previousEnd = lastTimestamp,
           first > previousFirst + 0.05, first >= previousEnd + 0.05, !current.isEmpty,
           !value.hasPrefix(current + " ") {
            commitCurrent()
        }
        current = value
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
}
