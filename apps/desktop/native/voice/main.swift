import Foundation
import AVFoundation
import Speech

func emit(_ type: String, _ text: String = "") {
    let data = try! JSONSerialization.data(withJSONObject: ["type": type, "text": text])
    FileHandle.standardOutput.write(data + Data([10]))
}

final class Dictation {
    let engine = AVAudioEngine()
    var request: SFSpeechAudioBufferRecognitionRequest?
    var task: SFSpeechRecognitionTask?
    var partial = ""
    var stopping = false
    var tapped = false
    var finished = false
    var lastLevel = Date.distantPast

    func finish(_ type: String, _ text: String = "") {
        guard !finished else { return }
        finished = true
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        task?.cancel()
        emit(type, text)
        exit(type == "error" ? 1 : 0)
    }

    func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { self.finish("error", "Allow Octet in System Settings → Privacy & Security → Speech Recognition.") }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                DispatchQueue.main.async {
                    guard !self.stopping else { self.finish("final"); return }
                    guard allowed else { self.finish("error", "Allow Octet in System Settings → Privacy & Security → Microphone."); return }
                    self.begin()
                }
            }
        }
    }

    func begin() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            finish("error", "Speech recognition isn't available for your language right now."); return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { finish("error", "No microphone is available."); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
                let level = min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
                DispatchQueue.main.async {
                    if Date().timeIntervalSince(self.lastLevel) >= 0.05 {
                        self.lastLevel = Date()
                        emit("level", String(level))
                    }
                }
            }
        }
        tapped = true
        do { engine.prepare(); try engine.start() }
        catch { finish("error", "Couldn't start the microphone: \(error.localizedDescription)"); return }
        emit("listening")
        task = recognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                if let result {
                    self.partial = result.bestTranscription.formattedString
                    emit("partial", self.partial)
                    if result.isFinal { self.finish("final", self.partial); return }
                }
                if let error {
                    if self.stopping { self.finish("final", self.partial) }
                    else { self.finish("error", error.localizedDescription) }
                }
            }
        }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        guard request != nil else { return }
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.finish("final", self.partial) }
    }
}

if CommandLine.arguments.contains("--check") {
    let data = try! JSONSerialization.data(withJSONObject: [
        "speechAuthorization": SFSpeechRecognizer.authorizationStatus().rawValue,
        "microphoneAuthorization": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
        "available": SFSpeechRecognizer(locale: Locale.current)?.isAvailable ?? false
    ])
    FileHandle.standardOutput.write(data + Data([10]))
    exit(0)
}

let dictation = Dictation()
DispatchQueue.global().async {
    while let command = readLine() {
        DispatchQueue.main.async {
            if command == "stop" { dictation.stop() }
            else if command == "cancel" { dictation.finish("cancelled") }
        }
    }
    DispatchQueue.main.async { dictation.finish("cancelled") }
}
dictation.start()
RunLoop.main.run()
