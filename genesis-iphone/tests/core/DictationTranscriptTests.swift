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

        var shortened = DictationTranscript()
        let shortID = UUID()
        shortened.beginSegment(shortID)
        shortened.receive("Please keep the beginning of this sentence.", segment: shortID)
        shortened.receive("Please keep", segment: shortID)
        expect(shortened.text == "Please keep the beginning of this sentence.",
               "a shorter nonempty prefix cannot erase earlier recognized words")
        shortened.receive("this sentence.", segment: shortID)
        expect(shortened.text == "Please keep the beginning of this sentence.",
               "a shorter suffix callback cannot discard the beginning")

        var unknownTimes = DictationTranscript()
        let unknownID = UUID()
        unknownTimes.beginSegment(unknownID)
        unknownTimes.receive("First sentence.", segment: unknownID)
        unknownTimes.receive("Second sentence.", segment: unknownID)
        expect(unknownTimes.text == "First sentence. Second sentence.",
               "disjoint speech without timestamps appends rather than erases")
        unknownTimes.receive("Second sentence. More detail.", segment: unknownID)
        expect(unknownTimes.text == "First sentence. Second sentence. More detail.",
               "unknown-timing corrections extend their own phrase without duplication")

        var resetTimes = DictationTranscript()
        let resetID = UUID()
        resetTimes.beginSegment(resetID)
        resetTimes.receive("First sentence.", segment: resetID, firstTimestamp: 0, lastTimestamp: 0)
        resetTimes.receive("Second sentence.", segment: resetID, firstTimestamp: 0, lastTimestamp: 0)
        expect(resetTimes.text == "First sentence. Second sentence.",
               "zero-timestamp reset preserves both sentences")
        resetTimes.receive("First sentence! Second sentence.", segment: resetID, firstTimestamp: 0, lastTimestamp: 0)
        expect(resetTimes.text == "First sentence! Second sentence.",
               "textual coverage recognizes cumulative results even without timing")

        var falseCumulative = DictationTranscript()
        let falseID = UUID()
        falseCumulative.beginSegment(falseID)
        falseCumulative.receive("First sentence.", segment: falseID, firstTimestamp: 0.2, lastTimestamp: 2)
        falseCumulative.receive("Second sentence.", segment: falseID, firstTimestamp: 10, lastTimestamp: 12)
        falseCumulative.receive("Second sentence.", segment: falseID, firstTimestamp: 0, lastTimestamp: 12)
        expect(falseCumulative.text == "First sentence. Second sentence.",
               "wide/reset timestamps alone cannot erase committed words")

        var correctedCumulative = DictationTranscript()
        let correctedID = UUID()
        correctedCumulative.beginSegment(correctedID)
        correctedCumulative.receive("Call Jon.", segment: correctedID, firstTimestamp: 0.2, lastTimestamp: 2)
        correctedCumulative.receive("Ask about tomorrow.", segment: correctedID, firstTimestamp: 8, lastTimestamp: 10)
        correctedCumulative.receive("Call John. Ask about tomorrow.", segment: correctedID, firstTimestamp: 0.2, lastTimestamp: 10)
        expect(correctedCumulative.text == "Call John. Ask about tomorrow.",
               "strongly aligned cumulative name correction does not duplicate task fragments")

        var correctedFirstWord = DictationTranscript()
        let firstWordID = UUID()
        correctedFirstWord.beginSegment(firstWordID)
        correctedFirstWord.receive("Not yet", segment: firstWordID, firstTimestamp: 0.2, lastTimestamp: 1)
        correctedFirstWord.receive("Now yet", segment: firstWordID, firstTimestamp: 0.2, lastTimestamp: 1.1)
        expect(correctedFirstWord.text == "Now yet", "same-audio initial-word correction keeps its unchanged anchor")
        correctedFirstWord.receive("Not yet", segment: firstWordID, firstTimestamp: 5, lastTimestamp: 6)
        expect(correctedFirstWord.text == "Now yet Not yet", "a later audio range remains new speech despite lexical similarity")

        var earlierTask = DictationTranscript()
        let earlierID = UUID(), correctedLaterID = UUID()
        earlierTask.beginSegment(earlierID)
        earlierTask.receive("Keep the earlier recording.", segment: earlierID)
        earlierTask.endSegment(earlierID)
        earlierTask.beginSegment(correctedLaterID)
        earlierTask.receive("Call Jon.", segment: correctedLaterID, firstTimestamp: 0.2, lastTimestamp: 2)
        earlierTask.receive("Ask about tomorrow.", segment: correctedLaterID, firstTimestamp: 8, lastTimestamp: 10)
        earlierTask.receive("Call John. Ask about tomorrow.", segment: correctedLaterID, firstTimestamp: 0.2, lastTimestamp: 10)
        expect(earlierTask.text == "Keep the earlier recording. Call John. Ask about tomorrow.",
               "aligned cumulative correction cannot replace any earlier recognition task")

        var overlapping = DictationTranscript()
        let overlapID = UUID()
        overlapping.beginSegment(overlapID)
        overlapping.receive("Please open the report", segment: overlapID)
        overlapping.receive("the report and explain the changes.", segment: overlapID)
        expect(overlapping.text == "Please open the report and explain the changes.",
               "overlapping reset merges the shared words without duplication")

        var revised = DictationTranscript()
        let revisedID = UUID()
        revised.beginSegment(revisedID)
        revised.receive("Call Jon tomorrow", segment: revisedID, firstTimestamp: 0.2, lastTimestamp: 3)
        revised.receive("Call John tomorrow.", segment: revisedID, firstTimestamp: 0.2, lastTimestamp: 3.1)
        expect(revised.text == "Call John tomorrow.", "same-audio lexical correction remains possible")
        revised.receive("Call John tomorrow, please.", segment: revisedID, firstTimestamp: 0, lastTimestamp: 0)
        expect(revised.text == "Call John tomorrow, please.", "longer zero-timing partial can extend a corrected phrase")

        var missingMiddle = DictationTranscript()
        let middleID = UUID()
        missingMiddle.beginSegment(middleID)
        missingMiddle.receive("First sentence. Second sentence. Third sentence.", segment: middleID)
        missingMiddle.receive("First sentence. Third sentence.", segment: middleID)
        expect(missingMiddle.text == "First sentence. Second sentence. Third sentence.",
               "incomplete cumulative result cannot remove a recognized middle phrase")

        var shortNew = DictationTranscript()
        let shortNewID = UUID()
        shortNew.beginSegment(shortNewID)
        shortNew.receive("This first sentence is quite a bit longer.", segment: shortNewID)
        shortNew.receive("Yes.", segment: shortNewID)
        expect(shortNew.text == "This first sentence is quite a bit longer. Yes.",
               "a genuinely new short phrase is appended rather than ignored as shorter")

        var punctuation = DictationTranscript()
        let punctuationID = UUID()
        punctuation.beginSegment(punctuationID)
        punctuation.receive("Don't delete these words", segment: punctuationID)
        punctuation.receive("DON’T delete these words.", segment: punctuationID)
        expect(punctuation.text == "DON’T delete these words.", "case and apostrophe refinements do not duplicate text")
        punctuation.receive("...", segment: punctuationID)
        expect(punctuation.text == "DON’T delete these words.", "punctuation-only callbacks cannot erase words")

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
