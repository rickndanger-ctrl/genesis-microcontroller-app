import Foundation
import AVFoundation

@MainActor
protocol DictationAudioInput: AnyObject {
    func start(receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// Owns one fresh input source per capture, independently of recognition task
/// renewal. Revoking a capture also revokes any late audio-tap callback.
@MainActor
final class DictationInputLifecycle {
    private let makeInput: @MainActor () -> any DictationAudioInput
    private var input: (any DictationAudioInput)?
    private let gate = InputDeliveryGate()

    init(makeInput: @escaping @MainActor () -> any DictationAudioInput = { NativeDictationAudioInput() }) {
        self.makeInput = makeInput
    }

    func start(receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stop()
        let input = makeInput(), gate = gate, capture = gate.begin()
        self.input = input
        do {
            try input.start { buffer in gate.deliver(buffer, capture: capture, receive: receive) }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        gate.end()
        input?.stop()
        input = nil
    }
}

private final class InputDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active: UUID?

    func begin() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let value = UUID(); active = value; return value
    }
    func end() {
        lock.lock(); defer { lock.unlock() }
        active = nil
    }
    func deliver(_ buffer: AVAudioPCMBuffer, capture: UUID,
                 receive: @Sendable (AVAudioPCMBuffer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard capture == active, buffer.frameLength > 0,
              buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else { return }
        receive(buffer)
    }
}

@MainActor
private final class NativeDictationAudioInput: DictationAudioInput {
    private var engine: AVAudioEngine?
    private var tapInstalled = false

    func start(receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stop()
        // The session has been activated before creating its input node. Reusing
        // a graph across deactivation can retain a stale hardware input route.
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw PhoneDictation.DictationError.unavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in receive(buffer) }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        guard let engine else { return }
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.reset()
        self.engine = nil
    }
}
