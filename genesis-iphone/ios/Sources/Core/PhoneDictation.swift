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
    enum State { case idle, authorizing, recording, finalizing }
    var onText: ((String) -> Void)?
    var onState: ((State) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var state: State = .idle { didSet { onState?(state) } }
    private var recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var sessionID = UUID()
    private var finalReceived = false
    private var interruptionObserver: NSObjectProtocol?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.state != .idle else { return }
                    self.cancel()
                    self.onError?("Recording was interrupted. Your partial draft is saved; nothing was sent.")
                }
            }
    }

    func start() async throws {
        guard state == .idle else { return }
        sessionID = UUID(); let active = sessionID
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
            state = .idle; throw DictationError.permissions
        }
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            state = .idle; throw DictationError.unavailable
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request; finalReceived = false
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true)
            let input = engine.inputNode, format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.unavailable }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapInstalled = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self, active == self.sessionID else { return }
                    if let result {
                        self.onText?(result.bestTranscription.formattedString)
                        if result.isFinal { self.finalReceived = true }
                    }
                    if error != nil {
                        let shouldReport = self.state == .recording
                        self.finalReceived = true
                        if shouldReport {
                            self.cancel()
                            self.onError?("Dictation stopped. Your partial draft is saved; you can edit it before sending.")
                        }
                    }
                }
            }
            engine.prepare(); try engine.start(); state = .recording
        } catch { cancel(); throw error }
    }

    func stop() async {
        if state == .authorizing { cancel(); return }
        guard state == .recording else { return }
        let active = sessionID
        state = .finalizing
        stopAudio(); request?.endAudio()
        for _ in 0..<15 {
            if finalReceived || sessionID != active { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard active == sessionID else { return }
        finish()
    }

    func cancel() {
        sessionID = UUID()
        stopAudio(); request?.endAudio(); finish()
    }
    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func finish() {
        task?.cancel(); task = nil; request = nil; recognizer = nil
        state = .idle
    }
    enum DictationError: LocalizedError {
        case permissions, unavailable
        var errorDescription: String? {
            switch self {
            case .permissions: return "Allow Microphone and Speech Recognition for Genesis in Settings, or type your prompt."
            case .unavailable: return "On-device dictation is unavailable for this language or audio input. You can type your prompt instead."
            }
        }
    }
}
