import AVFoundation
import Speech

/// Speech to text for Hold Space to talk: the microphone into Apple's
/// speech recognizer, on this Mac when it can, with what's heard so far
/// shown as it comes.
@MainActor
final class VoiceInput: ObservableObject {
    static let shared = VoiceInput()

    @Published private(set) var isListening = false
    /// What's been heard so far, while listening.
    @Published private(set) var partial = ""

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var delivered: ((String) -> Void)?
    private var deadline: DispatchWorkItem?

    /// Starts listening, asking for the microphone and speech recognition
    /// the first time. `failed` says why it couldn't.
    func start(failed: @escaping (String) -> Void) {
        guard !isListening else { return }
        authorize { [weak self] problem in
            guard let self else { return }
            if let problem { return failed(problem) }
            do {
                try self.begin()
            } catch {
                self.reset()
                failed("Couldn't start listening: \(error.localizedDescription)")
            }
        }
    }

    /// Stops listening; `then` gets the final words (empty if nothing).
    func stop(then: @escaping (String) -> Void) {
        guard isListening else { return then("") }
        delivered = then
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // The last words can take a moment; don't wait on them forever.
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deliver(self.partial)
            }
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: deadline)
    }

    func cancel() {
        delivered = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        reset()
    }

    private func begin() throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw NSError(domain: "VoiceInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn't available right now"])
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Stays on this Mac where the language allows.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw NSError(domain: "VoiceInput", code: 2, userInfo: [NSLocalizedDescriptionKey: "No microphone"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()

        partial = ""
        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true || error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let text { self.partial = text }
                    if isFinal, self.delivered != nil { self.deliver(self.partial) }
                }
            }
        }
    }

    private func deliver(_ text: String) {
        deadline?.cancel()
        deadline = nil
        let then = delivered
        delivered = nil
        reset()
        then?(text)
    }

    private func reset() {
        task = nil
        request = nil
        isListening = false
        partial = ""
    }

    /// Microphone and speech recognition, asked for once; nil when both
    /// are allowed, else what to do about it.
    private func authorize(_ then: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speech in
            AVCaptureDevice.requestAccess(for: .audio) { microphone in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if speech != .authorized {
                            then("Octet isn't allowed to use speech recognition. Turn it on in System Settings › Privacy & Security › Speech Recognition.")
                        } else if !microphone {
                            then("Octet isn't allowed to use the microphone. Turn it on in System Settings › Privacy & Security › Microphone.")
                        } else {
                            then(nil)
                        }
                    }
                }
            }
        }
    }
}
