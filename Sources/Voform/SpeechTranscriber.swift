import AVFoundation
import Speech

enum SpeechTranscriberError: LocalizedError {
    case speechPermissionDenied
    case microphonePermissionDenied
    case recognizerUnavailable
    case audioEngineFailure(String)
    case recognitionFailed(String)
    case noAudioDetected
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied: return "Speech recognition permission is required."
        case .microphonePermissionDenied: return "Microphone permission is required."
        case .recognizerUnavailable: return "Speech recognition is currently unavailable."
        case .audioEngineFailure(let reason): return "Could not start audio capture: \(reason)"
        case .recognitionFailed(let reason): return "Speech recognition failed: \(reason)"
        case .noAudioDetected: return "No microphone input was detected. Check the selected input device and its input level."
        case .noSpeechDetected: return "Audio was captured, but no speech was recognized. Try speaking longer or check the selected language."
        }
    }
}

@MainActor
final class SpeechTranscriber {
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestTranscript = ""
    private var recognitionError: Error?
    private var recognitionFinished = false
    private var peakAudioLevel: Double = 0
    private var recognitionGeneration = 0
    private var stopContinuation: CheckedContinuation<String, Error>?
    private var stopTimeoutTask: Task<Void, Never>?
    private var isRecording = false

    func requestPermissions() async {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func start(
        language: RecognitionLanguage,
        onPartial: @escaping (String) -> Void,
        onAudioLevel: @escaping (Double) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        cancel()

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SpeechTranscriberError.speechPermissionDenied
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw SpeechTranscriberError.microphonePermissionDenied
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)), recognizer.isAvailable else {
            throw SpeechTranscriberError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        // Do not force local recognition merely because the locale advertises
        // support. It fails silently when Siri & Dictation or its local assets are
        // unavailable. Let Speech choose its working online/local implementation.
        request.requiresOnDeviceRecognition = false
        request.contextualStrings = ["Python", "JSON", "JavaScript", "TypeScript", "Swift", "macOS", "OpenAI", "API", "GitHub"]

        self.recognizer = recognizer
        recognitionRequest = request
        latestTranscript = ""
        recognitionError = nil
        recognitionFinished = false
        peakAudioLevel = 0
        isRecording = true
        recognitionGeneration &+= 1
        let generation = recognitionGeneration

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.recognitionGeneration == generation else { return }
                if let result {
                    self.latestTranscript = result.bestTranscription.formattedString
                    onPartial(self.latestTranscript)
                    if result.isFinal {
                        self.recognitionFinished = true
                        self.completeStopIfNeeded()
                    }
                }
                if let error {
                    let wrappedError = SpeechTranscriberError.recognitionFailed(error.localizedDescription)
                    self.recognitionError = wrappedError
                    self.recognitionFinished = true
                    NSLog("Voform speech recognition failed: %@", error.localizedDescription)
                    onError(wrappedError)
                    self.completeStopIfNeeded()
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cancel()
            throw SpeechTranscriberError.audioEngineFailure("No usable microphone input format is available.")
        }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            request.append(buffer)
            guard let channel = buffer.floatChannelData?.pointee else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for index in 0..<count {
                let sample = channel[index]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(count))
            let decibels = 20 * log10(max(rms, 0.000_001))
            let normalized = max(0, min(1, Double((decibels + 55) / 45)))
            DispatchQueue.main.async { [weak self] in
                self?.peakAudioLevel = max(self?.peakAudioLevel ?? 0, normalized)
                onAudioLevel(normalized)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cancel()
            throw SpeechTranscriberError.audioEngineFailure(error.localizedDescription)
        }
    }

    func stop() async throws -> String {
        guard isRecording else { return try completedResult() }
        isRecording = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()

        if recognitionFinished {
            let result = Result { try completedResult() }
            cleanUpRecognition()
            return try result.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            stopTimeoutTask?.cancel()
            stopTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.completeStopIfNeeded() }
            }
        }
    }

    func cancel() {
        recognitionGeneration &+= 1
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        cleanUpRecognition()
        isRecording = false
        if let continuation = stopContinuation {
            stopContinuation = nil
            continuation.resume(returning: latestTranscript)
        }
    }

    private func completeStopIfNeeded() {
        guard let continuation = stopContinuation else { return }
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        stopContinuation = nil
        let result = Result { try completedResult() }
        cleanUpRecognition()
        continuation.resume(with: result)
    }

    private func completedResult() throws -> String {
        if let recognitionError { throw recognitionError }
        let transcript = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            if peakAudioLevel < 0.04 { throw SpeechTranscriberError.noAudioDetected }
            throw SpeechTranscriberError.noSpeechDetected
        }
        return transcript
    }

    private func cleanUpRecognition() {
        recognitionGeneration &+= 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recognizer = nil
    }
}
