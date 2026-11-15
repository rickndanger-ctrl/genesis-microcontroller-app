import Foundation
import Speech
import AVFoundation

@MainActor
protocol PhoneDictationService: AnyObject {
    var onText: ((String) -> Void)? { get set }
    var onState: ((PhoneDictation.State) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var state: PhoneDictation.State { get }
    func start() async throws
    func stop() async
    func cancel()
}

@MainActor
final class PhoneDictation: PhoneDictationService {
    enum State: Int { case idle, authorizing, recording, finalizing }
    var onText: ((String) -> Void)?
    var onState: ((State) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var state: State = .idle {
        didSet {
            DictationDiagnostics.record("speech_state", ["capture": captureNumber, "state": state.rawValue])
            onState?(state)
        }
    }
    private var recognizer: SFSpeechRecognizer?
    private let inputLifecycle = DictationInputLifecycle()
    private let audioRelay = DictationAudioRelay()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var captureNumber = 0
    private var segmentNumber = 0
    private var hasResult = false
    private var sessionID = UUID()
    private var segmentID = UUID()
    private var transcript = DictationTranscript()
    private var finalReceived = false
    private var segmentStartedAt = Date()
    private var rolloverTimer: Task<Void, Never>?
    private var quietTimer: Task<Void, Never>?
    private var rolloverTask: Task<Void, Never>?
    private var inputWatchdog: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.state != .idle else { return }
                    self.cancel()
                    self.onError?("Recording was interrupted. Your partial draft is saved; nothing was sent.")
                }
            }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        rolloverTimer?.cancel()
        quietTimer?.cancel()
        rolloverTask?.cancel()
        inputWatchdog?.cancel()
    }

    func start() async throws {
        guard state == .idle else {
            DictationDiagnostics.record("speech_start_ignored", ["state": state.rawValue]); return
        }
        captureNumber += 1; segmentNumber = 0
        DictationDiagnostics.record("speech_start", ["capture": captureNumber])
        sessionID = UUID(); let active = sessionID
        transcript = DictationTranscript()
        state = .authorizing
        let speechPermission = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard active == sessionID else { return }
        let microphone = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard active == sessionID else { return }
        guard speechPermission == .authorized, microphone else {
            DictationDiagnostics.record("speech_permission_denied", ["speech": speechPermission.rawValue, "mic": microphone ? 1 : 0])
            finish(); throw DictationError.permissions
        }
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            finish(); throw DictationError.unavailable
        }
        self.recognizer = recognizer
        audioRelay.resetCounts()
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true)
            try beginRecognition(active: active)
            let relay = audioRelay, capture = captureNumber
            try inputLifecycle.start { buffer in
                let count = relay.noteInputBuffer()
                relay.append(buffer)
                if count == 1 {
                    DictationDiagnostics.record("input_first_buffer", ["capture": capture, "frames": Int(buffer.frameLength), "rate": Int(buffer.format.sampleRate)])
                }
            }
            state = .recording
            scheduleInputWatchdog(active: active)
            scheduleRollover(active: active)
        } catch {
            DictationDiagnostics.record("speech_start_error", ["capture": captureNumber, "code": (error as NSError).code])
            cancel(); throw error
        }
    }

    private func beginRecognition(active: UUID) throws {
        guard let recognizer, recognizer.isAvailable else { throw DictationError.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        segmentID = UUID(); let segment = segmentID
        transcript.beginSegment(segment)
        finalReceived = false
        hasResult = false; segmentNumber += 1
        DictationDiagnostics.record("recognition_start", ["capture": captureNumber, "segment": segmentNumber])
        segmentStartedAt = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, active == self.sessionID, segment == self.segmentID,
                      self.state != .idle else { return }
                if let result {
                    if !self.hasResult {
                        self.hasResult = true
                        DictationDiagnostics.record("recognition_first_result", ["capture": self.captureNumber, "segment": self.segmentNumber,
                            "empty": result.bestTranscription.formattedString.isEmpty ? 1 : 0])
                    }
                    let words = result.bestTranscription.segments
                    let first = words.first?.timestamp
                    let last = words.last.map { $0.timestamp + $0.duration }
                    if let text = self.transcript.receive(result.bestTranscription.formattedString,
                                                        segment: segment, firstTimestamp: first, lastTimestamp: last) {
                        self.onText?(text)
                        self.scheduleQuietRollover(active: active, segment: segment)
                    }
                    if result.isFinal {
                        self.finalReceived = true
                        DictationDiagnostics.record("recognition_final", ["capture": self.captureNumber, "segment": self.segmentNumber])
                    }
                }
                if let error {
                    self.finalReceived = true
                    DictationDiagnostics.record("recognition_error", ["capture": self.captureNumber, "segment": self.segmentNumber,
                        "code": (error as NSError).code])
                }
                guard self.state == .recording, self.rolloverTask == nil else { return }
                if result?.isFinal == true {
                    // A recognizer can finish during a long pause while the user
                    // is still holding. Keep the capture alive with a new task.
                    self.beginRollover(active: active)
                } else if error != nil {
                    // A quiet/expired task can be renewed, but immediate repeated
                    // service failures must not create a rapid restart loop.
                    if Date().timeIntervalSince(self.segmentStartedAt) >= 5 {
                        self.beginRollover(active: active)
                    } else {
                        self.cancel()
                        self.onError?("Dictation stopped. Your partial draft is saved; you can edit it before sending.")
                    }
                }
            }
        }
        guard audioRelay.attach(request) else { throw DictationError.audioBuffer }
    }

    private func scheduleInputWatchdog(active: UUID) {
        inputWatchdog?.cancel()
        inputWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, self.sessionID == active, self.state == .recording,
                  self.audioRelay.inputBufferCount == 0 else { return }
            DictationDiagnostics.record("input_no_buffers", ["capture": self.captureNumber])
            self.cancel()
            self.onError?("The microphone did not start delivering audio. Your draft is saved. Release, then hold Talk again to retry.")
        }
    }

    private func scheduleRollover(active: UUID) {
        rolloverTimer?.cancel()
        rolloverTimer = Task { [weak self] in
            // Apple's legacy Speech recognizer has a per-request duration limit.
            // Renew before a minute; buffered audio bridges the task boundary.
            do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
            guard let self, self.sessionID == active, self.state == .recording else { return }
            self.beginRollover(active: active)
        }
    }

    private func scheduleQuietRollover(active: UUID, segment: UUID) {
        quietTimer?.cancel()
        quietTimer = Task { [weak self] in
            // Close a quiet utterance before Apple's next partial result can
            // replace it. This also covers OS versions with zeroed timestamps.
            // Audio remains captured and queued while the old task finalizes.
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            guard let self, self.sessionID == active, self.segmentID == segment,
                  self.state == .recording else { return }
            self.beginRollover(active: active)
        }
    }

    private func beginRollover(active: UUID) {
        guard active == sessionID, state == .recording, rolloverTask == nil else { return }
        rolloverTimer?.cancel(); rolloverTimer = nil
        quietTimer?.cancel(); quietTimer = nil
        audioRelay.beginBuffering()
        request?.endAudio()
        rolloverTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForFinal(active: active)
            guard active == self.sessionID, !Task.isCancelled else { return }
            self.transcript.endSegment(self.segmentID)
            self.task?.cancel(); self.task = nil; self.request = nil
            do {
                // Release may happen during renewal. It first stops audio, then
                // waits here so the buffered tail still gets transcribed.
                try self.beginRecognition(active: active)
                self.rolloverTask = nil
                if self.state == .recording { self.scheduleRollover(active: active) }
            } catch {
                self.cancel()
                self.onError?("Dictation stopped. Your partial draft is saved; you can edit it before sending.")
            }
        }
    }

    func stop() async {
        if state == .authorizing { cancel(); return }
        guard state == .recording else { return }
        DictationDiagnostics.record("speech_stop", ["capture": captureNumber, "buffers": audioRelay.inputBufferCount])
        let active = sessionID
        state = .finalizing
        rolloverTimer?.cancel(); rolloverTimer = nil
        quietTimer?.cancel(); quietTimer = nil
        stopInput()
        if let rolloverTask { await rolloverTask.value }
        guard active == sessionID else { return }
        audioRelay.stop()
        request?.endAudio()
        await waitForFinal(active: active)
        guard active == sessionID else { return }
        finish()
    }

    private func waitForFinal(active: UUID) async {
        for _ in 0..<20 {
            if finalReceived || sessionID != active || Task.isCancelled { break }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
        }
    }

    func cancel() {
        DictationDiagnostics.record("speech_cancel", ["capture": captureNumber, "state": state.rawValue, "buffers": audioRelay.inputBufferCount])
        // Revoke callbacks before cancelling; Speech can deliver one more result
        // after cancellation, which must not overwrite the user's reviewed draft.
        sessionID = UUID()
        stopInput()
        audioRelay.stop()
        request?.endAudio()
        finish()
    }

    private func stopInput() {
        inputWatchdog?.cancel(); inputWatchdog = nil
        inputLifecycle.stop()
    }

    private func finish() {
        DictationDiagnostics.record("speech_finish", ["capture": captureNumber, "buffers": audioRelay.inputBufferCount, "final": finalReceived ? 1 : 0])
        sessionID = UUID()
        stopInput()
        transcript.endSegment(segmentID)
        rolloverTimer?.cancel(); rolloverTimer = nil
        quietTimer?.cancel(); quietTimer = nil
        rolloverTask?.cancel(); rolloverTask = nil
        task?.cancel(); task = nil; request = nil; recognizer = nil
        audioRelay.stop()
        // Keep the audio session active until final recognition has settled.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
    }

    enum DictationError: LocalizedError {
        case permissions, unavailable, audioBuffer
        var errorDescription: String? {
            switch self {
            case .permissions: return "Allow Microphone and Speech Recognition for Genesis in Settings, or type your prompt."
            case .unavailable: return "On-device dictation is unavailable for this language or audio input. You can type your prompt instead."
            case .audioBuffer: return "Dictation could not continue. Your partial draft is saved; you can edit it before sending."
            }
        }
    }
}

/// The audio tap is not on the main actor. Own its destination and the short
/// rollover queue under one lock so no buffer is appended after endAudio().
private final class DictationAudioRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var buffering = false
    private var buffered: [AVAudioPCMBuffer] = []
    private var bufferedDuration: TimeInterval = 0
    private var overflowed = false
    private var inputBuffers = 0

    var inputBufferCount: Int {
        lock.lock(); defer { lock.unlock() }; return inputBuffers
    }
    func resetCounts() {
        lock.lock(); defer { lock.unlock() }; inputBuffers = 0
    }
    func noteInputBuffer() -> Int {
        lock.lock(); defer { lock.unlock() }; inputBuffers += 1; return inputBuffers
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if let request { request.append(buffer); return }
        guard buffering else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard bufferedDuration + duration <= 5,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            overflowed = true; return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices {
            if let src = source[index].mData, let dst = destination[index].mData {
                memcpy(dst, src, Int(source[index].mDataByteSize))
            }
        }
        buffered.append(copy)
        bufferedDuration += duration
    }

    func beginBuffering() {
        lock.lock(); defer { lock.unlock() }
        request = nil; buffering = true
    }

    func attach(_ request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !overflowed else { return false }
        for buffer in buffered { request.append(buffer) }
        buffered.removeAll(keepingCapacity: true); bufferedDuration = 0
        buffering = false; self.request = request
        return true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        request = nil; buffering = false
        buffered.removeAll(); bufferedDuration = 0; overflowed = false
    }
}
