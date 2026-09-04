import Foundation
import AVFoundation
import Speech
import Combine
import UIKit

/// High-performance Jarvis Voice Assistant Service.
///
/// Features:
/// 1. Hands-free background voice session ("Hey Jarvis" Call Mode):
///    - Keeps AVAudioSession (.playAndRecord, .voiceChat) active in background with Bluetooth audio.
///    - Listens through connected Bluetooth earbuds (AirPods, Galaxy Buds, etc.) or iPhone mic.
/// 2. Automatic wake word & silence detection (VAD):
///    - Detects "Hey Jarvis" / "Jarvis" wake words.
///    - Detects pauses/silence (~1.8s) to automatically finalize questions.
/// 3. Multimodal integration:
///    - When a question is finalized, requests a POV photo from the glasses (BLE 0xE1 -> 0xE3).
///    - Sends photo + spoken question to OpenRouter (GLM-5.3-flash).
///    - Speaks the Romanian response into the user's earbuds via TTSService.
/// 4. Push-to-talk / Manual mode support.
public final class JarvisVoiceService: NSObject, ObservableObject {
    public static let shared = JarvisVoiceService()

    public enum Mode: String, CaseIterable, Identifiable {
        case wakeWord = "Hey Jarvis (Continuous)"
        case pushToTalk = "Press to Talk"

        public var id: String { rawValue }
    }

    public enum VoiceState: String {
        case idle = "Idle"
        case listeningWakeWord = "Waiting for 'Hey Jarvis'..."
        case recordingQuestion = "Listening..."
        case thinking = "Processing & Photo..."
        case speaking = "Jarvis Speaking..."
    }

    // MARK: - Published State
    @Published public private(set) var isSessionActive: Bool = false
    @Published public private(set) var voiceState: VoiceState = .idle
    @Published public private(set) var liveTranscript: String = ""
    @Published public private(set) var lastAnswer: String = ""
    @Published public var currentMode: Mode = .wakeWord

    // Callback to append messages into ContentView
    public var onMessageReceived: ((_ isUser: Bool, _ text: String, _ image: UIImage?) -> Void)?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var silenceTimer: Timer?
    private var isWakeWordTriggered: Bool = false
    private var currentQuestionText: String = ""

    private var isListeningLoopActive: Bool = false
    private var isTapInstalled: Bool = false

    private let processingLock = NSLock()
    private var isProcessingQuery: Bool = false

    /// Real audio-level VAD: tracks when the microphone's RMS power drops
    /// below the speech threshold continuously. This fires the query much
    /// faster than waiting for SFSpeechRecognizer to stop sending partial
    /// results (Apple's recognizer keeps re-ranking for 1-3s after silence).
    private var lastAudioAboveSpeechThreshold: Date = Date()
    private var audioVADTimer: Timer?
    /// RMS power threshold (linear, 0-1). Typical speech is 0.02-0.15;
    /// background silence is < 0.005. 0.008 catches soft trailing syllables.
    private let vadSilenceThreshold: Float = 0.008
    /// How long the mic must stay below threshold before we finalize (seconds).
    private let vadSilenceDuration: TimeInterval = 0.55

    private override init() {
        super.init()
        TTSService.shared.onSpeechFinished = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.isSessionActive else { return }
                self.resumeListeningAfterResponse()
            }
        }
    }

    // MARK: - Permissions

    public func requestPermissions(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    let ok = (status == .authorized && granted)
                    completion(ok)
                }
            }
        }
    }

    // MARK: - Session Control (Call Mode)

    public func toggleSession() {
        if isSessionActive {
            stopVoiceSession()
        } else {
            startVoiceSession()
        }
    }

    public func startVoiceSession() {
        guard !isSessionActive else { return }

        requestPermissions { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                DebugLogger.shared.log("Permisiuni audio/recunoaștere vocală refuzate de utilizator.", level: .error)
                return
            }

            self.isSessionActive = true
            self.configureAudioSession()
            self.startListeningLoop()
            HapticFeedback.success()
            DebugLogger.shared.log("Sesiune vocală Jarvis pornită (Microfon căști/telefon activ în fundal).", level: .info)
        }
    }

    public func stopVoiceSession() {
        isSessionActive = false
        stopListeningLoop()
        voiceState = .idle
        liveTranscript = ""
        isWakeWordTriggered = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        HapticFeedback.light()
        DebugLogger.shared.log("Sesiune vocală Jarvis oprită.", level: .info)
    }

    // English wake words & common phonetic variants for "Jarvis" / "Hey Jarvis"
    private static let wakeWordTriggers: [String] = [
        "hey jarvis", "jarvis", "hi jarvis", "hello jarvis", "ok jarvis",
        "hey travis", "hey gervis", "hey jarvis,"
    ]

    // MARK: - Audio Session Configuration (Pristine ASR Audio over Bluetooth / Earbuds)

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Mode .measurement eliminates aggressive cellular telephone DSP/noise-gating
            // of .voiceChat, delivering pristine, high-fidelity uncompressed audio to SFSpeechRecognizer.
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            DebugLogger.shared.log("Eroare configurare AVAudioSession: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Speech Recognition Engine Loop

    private func startListeningLoop() {
        guard isSessionActive, !isProcessingQuery else { return }
        guard !isListeningLoopActive else { return }
        isListeningLoopActive = true

        // Clean up previous engine & tap state safely
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
        audioEngine.reset()

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioVADTimer?.invalidate()
        audioVADTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil

        // Verify audio session is active for voice recording
        configureAudioSession()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // .confirmation is optimized for short phrases / commands — Apple
        // finalizes much faster than .dictation (which waits 1-3s extra
        // hoping for continuation).
        request.taskHint = .confirmation
        // Contextual strings prime Apple's language model dictionary with specialized terms and names
        request.contextualStrings = [
            "Jarvis", "Hey Jarvis", "Hi Jarvis", "OK Jarvis",
            "glasses", "camera", "photo", "picture", "front",
            "explain", "describe", "what's in front of me", "what is in front of me",
            "what am I looking at", "look at this", "see", "read", "identify", "recognize",
            "what is this", "what's this", "tell me what"
        ]
        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Prevent SIGABRT if input format has sample rate 0 (occurs during audio route transitions)
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            DebugLogger.shared.log("Audio inputNode format not ready (rate=\(recordingFormat.sampleRate), ch=\(recordingFormat.channelCount)) — reconfiguring session...", level: .error)
            isListeningLoopActive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.isSessionActive, !self.isProcessingQuery else { return }
                self.startListeningLoop()
            }
            return
        }

        // Reset VAD tracking
        lastAudioAboveSpeechThreshold = Date()

        // Install buffer tap — feeds audio to Apple AND runs real-time VAD
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)

            // Real-time audio-level VAD: compute RMS from the PCM samples
            guard let self = self, !self.isProcessingQuery else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var sumSquares: Float = 0
            for i in 0..<frameLength {
                let sample = channelData[i]
                sumSquares += sample * sample
            }
            let rms = sqrtf(sumSquares / Float(frameLength))

            if rms > self.vadSilenceThreshold {
                self.lastAudioAboveSpeechThreshold = Date()
            }
        }
        isTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            DebugLogger.shared.log("Nu s-a putut porni AVAudioEngine: \(error.localizedDescription)", level: .error)
            if isTapInstalled {
                inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
            isListeningLoopActive = false
            return
        }

        // Start the VAD polling timer (fires every 100ms to check if silence
        // has lasted long enough to finalize). This is MUCH faster than the
        // old approach of resetting a timer on every partial transcription
        // result from Apple (which keeps re-ranking for 1-3 extra seconds).
        audioVADTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.isWakeWordTriggered, !self.isProcessingQuery else { return }
            guard !self.currentQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let silentFor = Date().timeIntervalSince(self.lastAudioAboveSpeechThreshold)
            if silentFor >= self.vadSilenceDuration {
                self.audioVADTimer?.invalidate()
                self.audioVADTimer = nil
                self.silenceTimer?.invalidate()
                self.silenceTimer = nil
                DebugLogger.shared.log("VAD: silence \(String(format: "%.2f", silentFor))s — firing query instantly.", level: .info)
                self.finalizeQuestion()
            }
        }

        DispatchQueue.main.async {
            self.voiceState = (self.currentMode == .wakeWord) ? .listeningWakeWord : .recordingQuestion
            self.liveTranscript = ""
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, self.isSessionActive else { return }

            // Ignore intentional cancellation error (Code 216)
            if let error = error as NSError?, error.domain == "kAFAssistantErrorDomain" && error.code == 216 {
                return
            }

            if let result = result {
                let transcription = result.bestTranscription.formattedString
                self.handleSpeechTranscription(transcription)
            }

            if error != nil || (result?.isFinal ?? false) {
                // If the recognition session ended naturally, restart loop if still active
                if self.isSessionActive && !self.isProcessingQuery {
                    self.isListeningLoopActive = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self = self, self.isSessionActive, !self.isProcessingQuery else { return }
                        self.startListeningLoop()
                    }
                }
            }
        }
    }

    private func stopListeningLoop() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioVADTimer?.invalidate()
        audioVADTimer = nil

        isListeningLoopActive = false

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
        audioEngine.reset()

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    // MARK: - Speech & Wake Word Analysis

    private func handleSpeechTranscription(_ text: String) {
        guard !text.isEmpty, !isProcessingQuery else { return }

        DispatchQueue.main.async {
            self.liveTranscript = text
            let lower = text.lowercased()

            if self.currentMode == .wakeWord {
                if !self.isWakeWordTriggered {
                    // Check for wake word variants (including phonetic matches)
                    if let matchedTrigger = Self.wakeWordTriggers.first(where: { lower.contains($0) }) {
                        self.isWakeWordTriggered = true
                        self.voiceState = .recordingQuestion
                        HapticFeedback.medium()

                        // Subtle chime confirmation
                        AudioServicesPlaySystemSound(1103)

                        // Extract query after the wake word if any
                        if let range = lower.range(of: matchedTrigger) {
                            let after = String(text[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,:;!?\n\t"))
                            self.currentQuestionText = after
                        }
                        self.resetSilenceTimer()
                    }
                } else {
                    // Wake word was already triggered, accumulate question
                    var query = text
                    for trigger in Self.wakeWordTriggers {
                        if let range = query.lowercased().range(of: trigger) {
                            query = String(query[range.upperBound...])
                        }
                    }
                    self.currentQuestionText = query.trimmingCharacters(in: CharacterSet(charactersIn: " ,:;!?\n\t"))
                    self.resetSilenceTimer()
                }
            } else {
                // Push-to-talk mode: all speech is the question
                self.currentQuestionText = text
                self.resetSilenceTimer()
            }
        }
    }

    private func resetSilenceTimer(duration: TimeInterval = 2.0) {
        silenceTimer?.invalidate()
        // Safety fallback only — the real-time audio-level VAD (0.55s) fires
        // first in normal operation. This timer catches edge cases where the
        // mic stays noisy (fan, traffic) but speech has stopped.
        silenceTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.finalizeQuestion()
        }
    }

    private func finalizeQuestion() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        var question = currentQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
        for trigger in Self.wakeWordTriggers {
            if let range = question.lowercased().range(of: trigger) {
                question = String(question[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,:;!?\n\t"))
            }
        }

        // If the question is empty (user just said "Hey Jarvis" and stopped), keep listening for question!
        if question.isEmpty {
            if isWakeWordTriggered {
                voiceState = .recordingQuestion
                liveTranscript = "Listening..."
                TTSService.shared.speak(text: "Yes, I'm listening.")
                resetSilenceTimer(duration: 3.5)
            }
            return
        }

        processQuestion(question)
    }

    // MARK: - Smart Intent Detection (Conversational vs Visual)

    /// Identifies if the question requires the glasses' camera (POV photo via BLE).
    /// If visual, captures the glasses' POV photo immediately.
    /// For general knowledge / conversation, skipping the photo drops latency by ~2 seconds!
    private func isVisualQuery(_ text: String) -> Bool {
        let lower = text.lowercased()
        let visualKeywords = [
            // English visual cues (Strict English assistant)
            "front of me", "in front", "looking at", "what do you see", "what can you see",
            "what is this", "what's this", "what are these", "what is that", "what's that",
            "describe", "explain what", "tell me what", "identify", "recognize",
            "read this", "read the", "read text", "read that", "read",
            "take a photo", "take a picture", "snap", "capture", "camera", "photo", "picture",
            "who is this", "who is that", "what color", "what sign", "what brand", "what logo",
            "how many", "look at", "see this", "see that", "view", "scene", "surroundings",
            "what am i holding", "what am i wearing", "inspect", "check this",
            // Romanian fallback cues (in case user switches or mixes languages)
            "vezi", "fata", "față", "scrie", "arată", "arata", "poza", "poză",
            "imagine", "cameră", "ce este asta", "ce e asta", "ce am",
            "citește", "citeste", "uită", "uita", "obiect", "culoare"
        ]
        return visualKeywords.contains { lower.contains($0) }
    }

    // MARK: - Query Execution (POV Photo + Ultra-Fast AI + Earbud TTS)

    public func processQuestion(_ query: String) {
        processingLock.lock()
        guard !isProcessingQuery else {
            processingLock.unlock()
            return
        }
        isProcessingQuery = true
        processingLock.unlock()

        stopListeningLoop()

        DispatchQueue.main.async {
            self.voiceState = .thinking
            self.liveTranscript = query
            self.onMessageReceived?(true, query, nil)
        }

        let needsVision = isVisualQuery(query)

        // Capture POV photo from glasses only if connected AND question is visual
        if needsVision {
            guard BLEManager.shared.canRequestAISnapshot else {
                DebugLogger.shared.log("Visual intent detected but glasses are NOT connected.", level: .error)
                let errorSpeech = "Your glasses are not connected. Please connect your glasses to see what's in front of you."
                DispatchQueue.main.async {
                    self.voiceState = .speaking
                    self.onMessageReceived?(false, errorSpeech, nil)
                    TTSService.shared.speak(text: errorSpeech)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        self.resumeListeningAfterResponse()
                    }
                }
                return
            }

            DebugLogger.shared.log("Visual intent detected ('\(query)') -> Capturing glasses POV snapshot...", level: .info)
            BLEManager.shared.requestAISnapshot { [weak self] image, error in
                guard let self = self else { return }

                // Check returned image or recent cache (within 5 seconds)
                var validImage = image
                if validImage == nil, let cached = GlassesPhotoStore.shared.latestPhoto,
                   let photoTime = GlassesPhotoStore.shared.lastPhotoAt,
                   Date().timeIntervalSince(photoTime) < 5.0 {
                    validImage = cached
                    DebugLogger.shared.log("Using freshly cached photo from glasses (\(String(format: "%.1f", Date().timeIntervalSince(photoTime)))s ago).", level: .info)
                }

                guard let finalImage = validImage else {
                    DebugLogger.shared.log("Failed to capture POV photo from glasses: \(error ?? "timeout/no image")", level: .error)
                    let errorSpeech = "I couldn't capture a photo from your glasses. Please make sure the glasses camera is ready and try again."
                    DispatchQueue.main.async {
                        self.voiceState = .speaking
                        self.onMessageReceived?(false, errorSpeech, nil)
                        TTSService.shared.speak(text: errorSpeech)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                            self.resumeListeningAfterResponse()
                        }
                    }
                    return
                }

                self.sendToAI(prompt: query, image: finalImage)
            }
        } else {
            // Conversational mode: zero BLE photo transfer latency (instantaneous response)
            sendToAI(prompt: query, image: nil)
        }
    }

    private func sendToAI(prompt: String, image: UIImage?) {
        OpenRouterService.shared.sendQuery(prompt: prompt, image: image) { [weak self] result in
            guard let self = self else { return }

            DispatchQueue.main.async {
                switch result {
                case .success(let answer):
                    self.lastAnswer = answer
                    self.voiceState = .speaking
                    self.onMessageReceived?(false, answer, image)

                    // Speak the response in English through the user's earbuds
                    TTSService.shared.speak(text: answer)

                    // Safety fallback timeout in case TTS finish delegate is delayed
                    let wordCount = answer.components(separatedBy: " ").count
                    let fallbackDelay = max(3.0, Double(wordCount) * 0.45)

                    DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) {
                        if self.isProcessingQuery {
                            self.resumeListeningAfterResponse()
                        }
                    }

                case .failure(let error):
                    let errMsg = "AI Error: \(error.localizedDescription)"
                    self.onMessageReceived?(false, errMsg, nil)
                    if OpenRouterService.shared.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        TTSService.shared.speak(text: "Please set your OpenRouter API key in settings.")
                    } else {
                        TTSService.shared.speak(text: "Sorry, I had trouble connecting to the assistant.")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        self.resumeListeningAfterResponse()
                    }
                }
            }
        }
    }

    private func resumeListeningAfterResponse() {
        processingLock.lock()
        guard isProcessingQuery else {
            processingLock.unlock()
            return
        }
        isProcessingQuery = false
        isWakeWordTriggered = false
        currentQuestionText = ""
        processingLock.unlock()

        if isSessionActive {
            DispatchQueue.main.async { [weak self] in
                self?.startListeningLoop()
            }
        }
    }
}
