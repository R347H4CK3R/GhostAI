import Foundation
import Combine
@preconcurrency import AVFoundation
@preconcurrency import Speech
import UIKit

/// Bounded conversational turns; background audio requires explicit session opt-in.
enum VoicePolicy {
    static let maximumCharacters = 2_000
    static let maximumSpokenCharacters = 4_000
    static let maximumListeningSeconds: UInt64 = 45
    static let silenceSeconds: UInt64 = 2
    static let resumeAfterInterruption = false

    static func shouldListen(conversationEnabled: Bool, foreground: Bool, busy: Bool, allowsBackgroundVoice: Bool = false) -> Bool {
        conversationEnabled && (foreground || allowsBackgroundVoice) && !busy
    }

    static func mayRecognize(foreground: Bool, allowsBackgroundVoice: Bool, speechAuthorized: Bool, microphoneAuthorized: Bool) -> Bool {
        (foreground || allowsBackgroundVoice) && speechAuthorized && microphoneAuthorized
    }

    static func acceptedTranscript(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > maximumCharacters ? nil : trimmed
    }
}

@MainActor
final class VoiceController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum State: Equatable {
        case idle, requestingPermission, listening, speaking, unavailable, failed, interrupted
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var status = "Voice is off."
    @Published private(set) var transcript = ""

    /// Set only for an explicitly user-started conversation; never restore from preferences.
    @Published var allowsBackgroundVoice = false {
        didSet {
            if !allowsBackgroundVoice && UIApplication.shared.applicationState != .active {
                interrupt("Background voice turned off. Open the app to restart.")
            }
        }
    }

    private var replyWindow: UIBackgroundTaskIdentifier = .invalid
    private var replyWindowAttempted = false
    private var replyWindowGeneration = UUID()
    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var permissionTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var hasTap = false
    private var generation = UUID()
    private var onFinal: ((String) -> Void)?
    private var onSpoken: (() -> Void)?
    private var spokenUtteranceID: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.interrupt("Audio interrupted. Tap voice to restart.") }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.allowsBackgroundVoice, self.state == .listening || self.state == .speaking else { return }
                self.interrupt("Voice paused while the app is inactive. Tap voice to restart.")
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.allowsBackgroundVoice else { return }
                self.interrupt("Voice paused in the background. Tap voice to restart.")
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in self?.interrupt("Audio device disconnected. Tap voice to restart.") }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.interrupt("Audio service restarted. Tap voice to restart.") }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Only a user action or an already opted-in conversational turn may call this.
    func startListening(onFinal: @escaping (String) -> Void) {
        stop()
        transcript = ""
        let token = generation
        self.onFinal = onFinal
        let foreground = UIApplication.shared.applicationState == .active
        if VoicePolicy.mayRecognize(
            foreground: foreground, allowsBackgroundVoice: allowsBackgroundVoice,
            speechAuthorized: SFSpeechRecognizer.authorizationStatus() == .authorized,
            microphoneAuthorized: AVAudioApplication.shared.recordPermission == .granted
        ) {
            beginRecognition(token: token)
            return
        }
        guard foreground else {
            fail("Open the app and grant microphone and speech access before starting background voice.", unavailable: true)
            return
        }
        state = .requestingPermission
        status = "Checking microphone and speech permissions…"
        permissionTask = Task { [weak self] in
            guard UIApplication.shared.applicationState == .active else {
                self?.fail("Open the app to grant speech access.", unavailable: true)
                return
            }
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            guard speech == .authorized else {
                self.fail("Speech permission is required. Enable it in Settings to use voice.", unavailable: true)
                return
            }
            // Never initiate a permission prompt after the app has left the foreground.
            var microphone = AVAudioApplication.shared.recordPermission == .granted
            if !microphone {
                guard UIApplication.shared.applicationState == .active else {
                    self.fail("Open the app to grant microphone access.", unavailable: true)
                    return
                }
                microphone = await AVAudioApplication.requestRecordPermission()
            }
            guard self.generation == token, !Task.isCancelled else { return }
            guard VoicePolicy.mayRecognize(
                foreground: UIApplication.shared.applicationState == .active,
                allowsBackgroundVoice: self.allowsBackgroundVoice,
                speechAuthorized: speech == .authorized, microphoneAuthorized: microphone
            ) else {
                self.fail("Voice needs microphone access and an active app or opted-in background session.", unavailable: true)
                return
            }
            self.beginRecognition(token: token)
        }
    }

    private func beginRecognition(token: UUID) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            fail("On-device speech recognition is unavailable for this device or language. Use text instead.", unavailable: true)
            return
        }
        self.recognizer = recognizer
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true // Never fall back to Apple's server recognition.
            request.shouldReportPartialResults = true
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                fail("No microphone audio input is available.")
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            hasTap = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.state == .listening else { return }
                    if failed {
                        self.fail("Speech recognition stopped. Try again or use text.")
                        return
                    }
                    if let text {
                        guard text.count <= VoicePolicy.maximumCharacters else {
                            self.fail("That voice turn was too long. Please try a shorter message.")
                            return
                        }
                        let changed = text != self.transcript
                        self.transcript = text
                        if final { self.finishListening() }
                        else if changed { self.scheduleSilenceEnd(token: token) }
                    }
                }
            }
            state = .listening
            status = "Listening on device… Pause for two seconds to send."
            engine.prepare()
            try engine.start()
            deadlineTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: VoicePolicy.maximumListeningSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.fail("Voice turn reached 45 seconds. Please try a shorter message.")
            }
        } catch {
            fail("Could not start the microphone. Check audio access and try again.")
        }
    }

    private func scheduleSilenceEnd(token: UUID) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: VoicePolicy.silenceSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.generation == token, self.state == .listening else { return }
            self.finishListening()
        }
    }

    private func finishListening() {
        guard let text = VoicePolicy.acceptedTranscript(transcript) else {
            fail("No speech was recognized. Try again or use text.")
            return
        }
        let completion = onFinal
        beginReplyWindow()
        guard state == .listening else { return }
        reset(preservingReplyWindow: true)
        status = "Voice message captured."
        completion?(text)
    }

    /// Speech output uses the system synthesizer; long replies are clipped for a bounded turn.
    func speak(_ text: String, onFinished: @escaping () -> Void = {}) {
        reset(preservingReplyWindow: true)
        guard UIApplication.shared.applicationState == .active || allowsBackgroundVoice else {
            endReplyWindow()
            state = .interrupted
            status = "Open the app to hear the reply."
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { endReplyWindow(); onFinished(); return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let utterance = AVSpeechUtterance(string: String(trimmed.prefix(VoicePolicy.maximumSpokenCharacters)))
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            spokenUtteranceID = ObjectIdentifier(utterance)
            onSpoken = onFinished
            state = .speaking
            status = trimmed.count > VoicePolicy.maximumSpokenCharacters
                ? "Speaking the first part. Read the full reply on screen."
                : "Speaking…"
            synthesizer.speak(utterance)
        } catch {
            fail("Could not play speech. Read the reply on screen.")
        }
    }

    /// A finite allowance for the response to a captured utterance, never a keepalive.
    /// Calling repeatedly during the same reply does not renew the allowance.
    func beginReplyWindow() {
        guard allowsBackgroundVoice, !replyWindowAttempted else { return }
        replyWindowAttempted = true
        let windowToken = UUID()
        replyWindowGeneration = windowToken
        replyWindow = UIApplication.shared.beginBackgroundTask(withName: "Finish voice reply") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.replyWindowGeneration == windowToken, self.replyWindowAttempted else { return }
                self.interrupt("iOS ended the voice reply window. Open the app to restart.")
            }
        }
        if replyWindow == .invalid && UIApplication.shared.applicationState != .active {
            interrupt("iOS could not continue this voice reply. Open the app to restart.")
        }
    }

    func endReplyWindow() {
        let identifier = replyWindow
        replyWindowGeneration = UUID()
        replyWindow = .invalid
        replyWindowAttempted = false
        if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
    }

    func stop() {
        reset(preservingReplyWindow: false)
    }

    private func reset(preservingReplyWindow: Bool) {
        if !preservingReplyWindow { endReplyWindow() }
        generation = UUID()
        permissionTask?.cancel(); permissionTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        silenceTask?.cancel(); silenceTask = nil
        onFinal = nil
        onSpoken = nil
        spokenUtteranceID = nil
        if engine.isRunning { engine.stop() }
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio()
        recognitionTask?.cancel(); recognitionTask = nil
        request = nil
        recognizer = nil
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        status = "Voice is off."
    }

    private func fail(_ message: String, unavailable: Bool = false) {
        stop()
        state = unavailable ? .unavailable : .failed
        status = message
    }

    private func interrupt(_ message: String) {
        guard state == .listening || state == .speaking || state == .requestingPermission || replyWindowAttempted else { return }
        stop()
        state = .interrupted
        status = message
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.spokenUtteranceID == identity else { return }
            // Real speech playback now provides the audio activity; the finite compute window is over.
            self.endReplyWindow()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.state == .speaking, self.spokenUtteranceID == identity else { return }
            let completion = self.onSpoken
            self.stop()
            completion?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.spokenUtteranceID == identity else { return }
            self.interrupt("Speech cancelled. Tap voice to restart.")
        }
    }
}
