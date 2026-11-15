import Foundation
import AVFoundation

@MainActor
private final class FakeAudioInput: DictationAudioInput {
    enum Failure: Error { case start }
    var startCount = 0
    var stopCount = 0
    var failStart = false
    private var receive: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func start(receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        startCount += 1
        self.receive = receive
        if failStart { throw Failure.start }
    }
    func stop() { stopCount += 1 }
    func emit(_ buffer: AVAudioPCMBuffer) { receive?(buffer) }
}

private final class BufferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }; count += Int(buffer.frameLength)
    }
}

@main
struct DictationAudioInputTests {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError("FAIL: \(message)") }
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
        buffer.frameLength = 32
        var sources: [FakeAudioInput] = []
        var failNextStart = false
        let lifecycle = DictationInputLifecycle {
            let source = FakeAudioInput()
            source.failStart = failNextStart; failNextStart = false
            sources.append(source)
            return source
        }
        let counter = BufferCounter()
        try lifecycle.start { counter.receive($0) }
        let first = sources[0]
        buffer.frameLength = 0
        first.emit(buffer)
        expect(counter.value == 0, "empty tap callbacks do not count as a working microphone")
        buffer.frameLength = 32
        first.emit(buffer)
        expect(counter.value == 32, "first capture delivers input")
        lifecycle.stop()
        first.emit(buffer)
        expect(counter.value == 32 && first.stopCount == 1, "release revokes late input and disposes first source")

        // Match the reported review delay rather than only testing immediate
        // restart. No microphone or speech permission is requested by this test.
        try await Task.sleep(nanoseconds: 5_000_000_000)
        try lifecycle.start { counter.receive($0) }
        let second = sources[1]
        first.emit(buffer); second.emit(buffer)
        expect(first !== second && second.startCount == 1, "second hold creates a fresh input source after five seconds")
        expect(counter.value == 64, "second hold gets fresh buffers and rejects stale first-hold buffers")
        lifecycle.stop()
        expect(second.stopCount == 1, "second release tears down its own input")

        try await Task.sleep(nanoseconds: 5_000_000_000)
        try lifecycle.start { counter.receive($0) }
        sources[2].emit(buffer)
        expect(counter.value == 96, "third hold continues receiving new audio after another review pause")
        // Defensive start while already active must also retire the old source.
        try lifecycle.start { counter.receive($0) }
        expect(sources[2].stopCount == 1 && sources.count == 4, "replacement capture stops and replaces existing input")
        sources[2].emit(buffer); sources[3].emit(buffer)
        expect(counter.value == 128, "replaced input cannot reach the new capture")
        lifecycle.stop(); lifecycle.stop()
        expect(sources[3].stopCount == 1, "duplicate release does not tear down any later source")

        failNextStart = true
        do { try lifecycle.start { counter.receive($0) }; fatalError("Failed start was accepted") }
        catch FakeAudioInput.Failure.start {}
        let failed = sources.last!
        failed.emit(buffer)
        expect(failed.stopCount == 1 && counter.value == 128, "start failure revokes callbacks and releases partial resources")

        for index in 0..<50 {
            try lifecycle.start { counter.receive($0) }
            let source = sources.last!
            source.emit(buffer)
            lifecycle.stop()
            source.emit(buffer)
            expect(source.startCount == 1 && source.stopCount == 1, "capture \(index) has one start and teardown")
            expect(counter.value == (5 + index) * 32, "capture \(index) delivers only its own fresh buffer")
        }
        for source in sources { source.emit(buffer) }
        expect(counter.value == 54 * 32, "all retired callbacks remain revoked after repeated use")
        print("PASS: \(checks) dictation input lifecycle checks; fake buffers only, no microphone capture")
    }
}
