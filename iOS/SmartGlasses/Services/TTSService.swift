import Foundation
import AVFoundation

public final class TTSService: NSObject, ObservableObject {
    public static let shared = TTSService()

    private let synthesizer = AVSpeechSynthesizer()
    @Published public var isSpeaking: Bool = false
    public var onSpeechFinished: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        // NOTE: configureAudioSession() is NOT called here on purpose.
        // It accesses JarvisVoiceService.shared.isSessionActive, which
        // causes a circular singleton deadlock when JarvisVoiceService
        // is still being initialized (its init touches TTSService.shared).
        // The session is configured lazily on the first speak() call instead.
    }

    private func configureAudioSession() {
        // If Jarvis is active, keep its .measurement / .playAndRecord session untouched
        // to avoid killing the live microphone inputNode tap!
        if JarvisVoiceService.shared.isSessionActive {
            return
        }

        let session = AVAudioSession.sharedInstance()
        var configured = false

        // Strategy 1: .playback with .allowBluetoothA2DP for high-quality audio
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            configured = true
        } catch {
            print("[TTS] Eroare setCategory(.playback): \(error)")
        }

        // Strategy 2: Fallback to .playAndRecord if the Bluetooth accessory is an HFP / SCO communication device
        if !configured {
            do {
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                configured = true
            } catch {
                print("[TTS] Eroare setCategory(.playAndRecord): \(error)")
            }
        }

        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let routeDesc = outputs.isEmpty ? "Standard (fără ieșiri active)" : outputs
        DebugLogger.shared.log("TTS Audio Route: \(routeDesc)", level: .info)
    }

    public func speak(text: String) {
        guard !text.isEmpty else { return }

        configureAudioSession()

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        // Clean markdown tokens (asterisks, hashtags, backticks) for fluid voice delivery
        let cleanText = text
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let utterance = AVSpeechUtterance(string: cleanText)
        // Natural English voice: prefer enhanced US English or system en-US
        if let enVoice = AVSpeechSynthesisVoice(identifier: "com.apple.ttsbundle.Samantha-compact")
            ?? AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = enVoice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        if !JarvisVoiceService.shared.isSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

extension TTSService: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.onSpeechFinished?()
            if !JarvisVoiceService.shared.isSessionActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.onSpeechFinished?()
            if !JarvisVoiceService.shared.isSessionActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}
