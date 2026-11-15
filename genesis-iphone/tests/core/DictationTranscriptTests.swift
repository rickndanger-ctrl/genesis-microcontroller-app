import Foundation

@main
struct DictationTranscriptTests {
    static func main() {
        var checks = 0
        func expect(_ result: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard result() else { fatalError("FAIL: \(message)") }
        }

        var draft = DictationTranscript()
        let first = UUID(), second = UUID()
        draft.beginSegment(first)
        expect(draft.receive("Hello", segment: first) == "Hello", "short phrase is visible")
        expect(draft.receive("", segment: first) == nil, "empty partial is ignored")
        expect(draft.receive("  \n", segment: first) == nil, "empty final cannot erase short phrase")
        expect(draft.text == "Hello", "silence preserves valid text")
        expect(draft.receive("Hello there.", segment: first) == "Hello there.", "partial correction replaces current phrase")
        expect(draft.receive("Hello there.", segment: first) == nil, "unchanged result does not rewrite draft")
        draft.endSegment(first)
        expect(draft.receive("Late callback", segment: first) == nil, "cancelled task cannot mutate reviewed text")
        expect(draft.text == "Hello there.", "cancellation preserves last valid partial")
        draft.beginSegment(second)
        expect(draft.receive("", segment: second) == nil, "new task starts without erasing completed speech")
        expect(draft.receive("After a pause", segment: second) == "Hello there. After a pause", "resumed speech appends")
        expect(draft.receive("After a pause.", segment: second) == "Hello there. After a pause.", "new chunk can correct punctuation")
        expect(draft.receive("Stale old words", segment: first) == nil, "old segment cannot overwrite new segment")

        var pauses = DictationTranscript()
        let pauseID = UUID()
        pauses.beginSegment(pauseID)
        pauses.receive("First sentence.", segment: pauseID, firstTimestamp: 0.3, lastTimestamp: 2)
        expect(pauses.receive("", segment: pauseID, firstTimestamp: 0, lastTimestamp: 0) == nil,
               "empty pause event does not erase timing or words")
        expect(pauses.receive("Second", segment: pauseID, firstTimestamp: 10, lastTimestamp: 10.5) == "First sentence. Second",
               "recognizer reset after long silence preserves first sentence")
        expect(pauses.receive("Second sentence.", segment: pauseID, firstTimestamp: 10, lastTimestamp: 12) == "First sentence. Second sentence.",
               "second utterance revisions do not duplicate words")
        pauses.receive("Third sentence.", segment: pauseID, firstTimestamp: 20, lastTimestamp: 22)
        expect(pauses.text == "First sentence. Second sentence. Third sentence.", "multiple silence resets preserve order")
        pauses.receive("First sentence! Second sentence. Third sentence.", segment: pauseID, firstTimestamp: 0.3, lastTimestamp: 22)
        expect(pauses.text == "First sentence! Second sentence. Third sentence.",
               "a cumulative final replaces task fragments without duplicating earlier sentences")
        pauses.endSegment(pauseID)
        expect(pauses.receive("Late reset", segment: pauseID, firstTimestamp: 30, lastTimestamp: 31) == nil,
               "retired result cannot change a completed recording")

        var corrections = DictationTranscript()
        let correctionID = UUID()
        corrections.beginSegment(correctionID)
        corrections.receive("Call Jon", segment: correctionID, firstTimestamp: 0, lastTimestamp: 2)
        expect(corrections.receive("Call John.", segment: correctionID, firstTimestamp: 0.1, lastTimestamp: 2.1) == "Call John.",
               "normal timestamp refinement is not mistaken for a new sentence")
        corrections.receive("Call John. Tomorrow.", segment: correctionID, firstTimestamp: 3, lastTimestamp: 4)
        expect(corrections.text == "Call John. Tomorrow.", "cumulative result remains one phrase even if timing changes")

        var zeroTimes = DictationTranscript()
        let zeroID = UUID()
        zeroTimes.beginSegment(zeroID)
        zeroTimes.receive("A word", segment: zeroID, firstTimestamp: 0, lastTimestamp: 0)
        zeroTimes.receive("A word.", segment: zeroID, firstTimestamp: 0.5, lastTimestamp: 1)
        expect(zeroTimes.text == "A word.", "unknown partial timing does not create duplicate final text")

        var repeated = DictationTranscript()
        let repeatID = UUID()
        repeated.beginSegment(repeatID)
        repeated.receive("Yes.", segment: repeatID, firstTimestamp: 0.1, lastTimestamp: 0.5)
        repeated.receive("Yes.", segment: repeatID, firstTimestamp: 4, lastTimestamp: 4.5)
        expect(repeated.text == "Yes. Yes.", "intentionally repeated phrase survives a pause")

        var longHold = DictationTranscript()
        for index in 1...100 {
            let id = UUID()
            longHold.beginSegment(id)
            longHold.receive("Part \(index)", segment: id)
            longHold.receive("Part \(index).", segment: id)
            longHold.receive("", segment: id)
            longHold.endSegment(id)
            expect(longHold.text.hasSuffix("Part \(index)."), "long recording keeps newest chunk \(index)")
        }
        expect(longHold.text == (1...100).map { "Part \($0)." }.joined(separator: " "),
               "100 task renewals preserve full dictation without resets or duplication")
        let afterError = UUID()
        longHold.beginSegment(afterError)
        longHold.endSegment(afterError)
        expect(longHold.text.hasPrefix("Part 1. Part 2."), "silent failed retry cannot erase long draft")
        expect(longHold.text.hasSuffix("Part 100."), "silent failed retry preserves final chunk")
        let finalChunk = UUID()
        longHold.beginSegment(finalChunk)
        longHold.receive("Next", segment: finalChunk, firstTimestamp: 0.2, lastTimestamp: 1)
        longHold.receive("Last", segment: finalChunk, firstTimestamp: 3, lastTimestamp: 4)
        longHold.receive("Next and last.", segment: finalChunk, firstTimestamp: 0.2, lastTimestamp: 4)
        expect(longHold.text == (1...100).map { "Part \($0)." }.joined(separator: " ") + " Next and last.",
               "cumulative final correction preserves all earlier renewed tasks")
        print("PASS: \(checks) dictation transcript checks")
    }
}
