//
//  VoiceDictationEngine.swift
//  MultiSessionAIManager
//
//  Push-to-Talk voice dictation engine using iOS Speech.framework and AVFoundation.
//  Coordinates audio capture, speech recognition, on-device transcription, and audio
//  level metering for terminal prompt input.
//

import Foundation
import Combine
import AVFoundation
import Speech

// MARK: - State

public enum VoiceDictationState: Equatable, Sendable {
    case idle
    case requestingPermissions
    case listening(liveText: String, audioLevel: Float)
    case processing
    case error(String)
}

// MARK: - Speech Recognition Service Protocol

@MainActor
public protocol SpeechRecognitionService: AnyObject {
    var isRecording: Bool { get }
    func requestPermissions() async -> Bool
    func startRecognition(
        onDeviceOnly: Bool,
        onPartialResult: @MainActor @Sendable @escaping (String) -> Void,
        onAudioLevel: @MainActor @Sendable @escaping (Float) -> Void
    ) async throws
    func stopRecognition() async -> String?
    func cancelRecognition()
}

// MARK: - Engine

@MainActor
public final class VoiceDictationEngine: ObservableObject {
    public static let shared = VoiceDictationEngine()

    @Published public private(set) var state: VoiceDictationState = .idle

    private let service: SpeechRecognitionService
    private var currentLiveText: String = ""
    private var currentAudioLevel: Float = 0.0
    private var currentSessionID = UUID()

    public init(service: SpeechRecognitionService? = nil) {
        self.service = service ?? AppleSpeechRecognitionService()
    }

    // MARK: - Static Helpers

    public nonisolated static func cleanTranscriptionText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public nonisolated static func normalizeAudioLevel(rms: Float) -> Float {
        guard !rms.isNaN && !rms.isInfinite else { return 0.0 }
        return min(max(rms, 0.0), 1.0)
    }

    public nonisolated static func convertTextToTerminalBytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    // MARK: - Public Control API

    public func startRecording() async {
        if case .error = state {
            state = .idle
        }
        guard state == .idle else { return }

        let session = UUID()
        currentSessionID = session
        state = .requestingPermissions

        let granted = await service.requestPermissions()
        guard currentSessionID == session && state == .requestingPermissions else {
            // Superseded or cancelled while waiting for permissions
            return
        }

        guard granted else {
            state = .error("Microphone or Speech Recognition permission denied.")
            return
        }

        currentLiveText = ""
        currentAudioLevel = 0.0
        state = .listening(liveText: "", audioLevel: 0.0)

        do {
            try await service.startRecognition(
                onDeviceOnly: true,
                onPartialResult: { [weak self] partialText in
                    guard let self = self, self.currentSessionID == session else { return }
                    self.currentLiveText = partialText
                    if case .listening = self.state {
                        self.state = .listening(liveText: partialText, audioLevel: self.currentAudioLevel)
                    }
                },
                onAudioLevel: { [weak self] level in
                    guard let self = self, self.currentSessionID == session else { return }
                    let normalized = Self.normalizeAudioLevel(rms: level)
                    self.currentAudioLevel = normalized
                    if case .listening = self.state {
                        self.state = .listening(liveText: self.currentLiveText, audioLevel: normalized)
                    }
                }
            )
        } catch {
            guard currentSessionID == session else { return }
            state = .error(error.localizedDescription)
        }
    }

    public func stopRecording() async -> String? {
        guard case .listening = state else {
            cancelRecording()
            return nil
        }

        let session = currentSessionID
        state = .processing
        let finalRaw = await service.stopRecognition()
        guard currentSessionID == session else {
            return nil
        }

        let candidate = finalRaw ?? currentLiveText
        let cleaned = Self.cleanTranscriptionText(candidate)

        state = .idle
        currentLiveText = ""
        currentAudioLevel = 0.0
        return cleaned
    }

    public func cancelRecording() {
        currentSessionID = UUID()
        service.cancelRecognition()
        state = .idle
        currentLiveText = ""
        currentAudioLevel = 0.0
    }
}

// MARK: - Apple Speech Recognition Service

@MainActor
public final class AppleSpeechRecognitionService: SpeechRecognitionService {
    private var recognizer: SFSpeechRecognizer?
    private let locale: Locale
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var activeRecording = false
    private var latestTranscription: String = ""
    private var isTapInstalled = false

    public var isRecording: Bool {
        activeRecording
    }

    public init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    private func getOrCreateRecognizer() -> SFSpeechRecognizer? {
        if let r = recognizer { return r }
        let r = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.recognizer = r
        return r
    }

    // MARK: - Nonisolated Objective-C Callback Bridges
    //
    // CRITICAL (Swift 6 Strict Concurrency):
    // SFSpeechRecognizer.requestAuthorization, AVAudioSession.requestRecordPermission,
    // AVAudioNode.installTap, and SFSpeechRecognizer.recognitionTask take Objective-C
    // blocks that are NOT marked @Sendable in Apple's SDK headers, yet Apple invokes
    // them on background queues (com.apple.root.default-qos / realtime CoreAudio IO thread).
    // If those closures are formed inside a @MainActor method, Swift 6 infers @MainActor
    // isolation on the closure and injects `_swift_task_checkIsolatedSwift`
    // (`dispatch_assert_queue(main_queue)`), causing an immediate SIGTRAP crash when
    // iOS invokes the callback off the main thread.
    // Forming all Objective-C blocks inside `nonisolated static` functions prevents
    // Swift 6 from inferring @MainActor isolation on the blocks.

    public nonisolated static func makeSpeechAuthHandler(
        resuming continuation: CheckedContinuation<Bool, Never>
    ) -> (SFSpeechRecognizerAuthorizationStatus) -> Void {
        return { authStatus in
            continuation.resume(returning: authStatus == .authorized)
        }
    }

    public nonisolated static func makeAudioTapBlock(
        request: SFSpeechAudioBufferRecognitionRequest?,
        onAudioLevel: @MainActor @Sendable @escaping (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            request?.append(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var sum: Float = 0.0
            for i in 0..<frameLength {
                let sample = channelData[i]
                if !sample.isNaN && !sample.isInfinite {
                    sum += sample * sample
                }
            }
            let rms = sqrt(sum / Float(frameLength))
            if !rms.isNaN && !rms.isInfinite {
                Task { @MainActor in
                    onAudioLevel(rms * 12.0)
                }
            }
        }
    }

    public nonisolated static func makeRecognitionResultHandler(
        onResult: @MainActor @Sendable @escaping (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { result, error in
            let text = result?.bestTranscription.formattedString
            let shouldStop = (error != nil) || (result?.isFinal ?? false)
            Task { @MainActor in
                onResult(text, shouldStop)
            }
        }
    }

    private nonisolated static func requestMicrophonePermissionNonisolated() async -> Bool {
        if #available(iOS 17.0, *) {
            if AVAudioApplication.shared.recordPermission == .granted {
                return true
            }
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            if AVAudioSession.sharedInstance().recordPermission == .granted {
                return true
            }
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private nonisolated static func requestSpeechAuthorizationNonisolated() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            return true
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization(Self.makeSpeechAuthHandler(resuming: continuation))
        }
    }

    private nonisolated static func installTapNonisolated(
        on inputNode: AVAudioNode,
        request: SFSpeechAudioBufferRecognitionRequest,
        onAudioLevel: @MainActor @Sendable @escaping (Float) -> Void
    ) {
        let tapBlock = Self.makeAudioTapBlock(request: request, onAudioLevel: onAudioLevel)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: tapBlock)
    }

    private nonisolated static func startRecognitionTaskNonisolated(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onResult: @MainActor @Sendable @escaping (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        let handler = Self.makeRecognitionResultHandler(onResult: onResult)
        return recognizer.recognitionTask(with: request, resultHandler: handler)
    }

    public func requestPermissions() async -> Bool {
        let micStatus = await Self.requestMicrophonePermissionNonisolated()
        guard micStatus else { return false }
        return await Self.requestSpeechAuthorizationNonisolated()
    }

    public func startRecognition(
        onDeviceOnly: Bool,
        onPartialResult: @MainActor @Sendable @escaping (String) -> Void,
        onAudioLevel: @MainActor @Sendable @escaping (Float) -> Void
    ) async throws {
        guard let recognizer = getOrCreateRecognizer(), recognizer.isAvailable else {
            throw NSError(domain: "VoiceDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not available."])
        }

        teardownAudio()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true)

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        // Default to false so iOS prefers on-device recognition when available,
        // but gracefully falls back without crashing if local models are not yet downloaded.
        request.requiresOnDeviceRecognition = false

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            teardownAudio()
            throw NSError(
                domain: "VoiceDictation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Audio hardware is initializing. Please tap and hold again in a moment."]
            )
        }

        Self.installTapNonisolated(
            on: inputNode,
            request: request,
            onAudioLevel: onAudioLevel
        )
        self.isTapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            teardownAudio()
            throw error
        }

        self.audioEngine = engine
        self.recognitionRequest = request
        self.latestTranscription = ""
        self.activeRecording = true

        self.recognitionTask = Self.startRecognitionTaskNonisolated(
            recognizer: recognizer,
            request: request,
            onResult: { [weak self] text, shouldStop in
                guard let self = self else { return }
                if let text = text {
                    self.latestTranscription = text
                    onPartialResult(text)
                }
                if shouldStop {
                    self.activeRecording = false
                }
            }
        )
    }

    public func stopRecognition() async -> String? {
        guard activeRecording else {
            let existing = latestTranscription
            teardownAudio()
            return existing
        }

        activeRecording = false
        recognitionRequest?.endAudio()
        let capturedText = latestTranscription
        teardownAudio()
        return capturedText
    }

    public func cancelRecognition() {
        activeRecording = false
        recognitionTask?.cancel()
        teardownAudio()
    }

    private func teardownAudio() {
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            if isTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
        }
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Mock Service for Unit Testing

@MainActor
public final class MockSpeechRecognitionService: SpeechRecognitionService {
    public var isRecording = false
    public var permissionGranted = true
    public var transcribedResult: String? = "mock transcription"

    private var onPartial: (@MainActor @Sendable (String) -> Void)?
    private var onLevel: (@MainActor @Sendable (Float) -> Void)?

    public init() {}

    public func requestPermissions() async -> Bool {
        permissionGranted
    }

    public func startRecognition(
        onDeviceOnly: Bool,
        onPartialResult: @MainActor @Sendable @escaping (String) -> Void,
        onAudioLevel: @MainActor @Sendable @escaping (Float) -> Void
    ) async throws {
        isRecording = true
        self.onPartial = onPartialResult
        self.onLevel = onAudioLevel
    }

    public func stopRecognition() async -> String? {
        isRecording = false
        return transcribedResult
    }

    public func cancelRecognition() {
        isRecording = false
    }

    public func simulatePartialText(_ text: String) {
        onPartial?(text)
    }

    public func simulateAudioLevel(_ level: Float) {
        onLevel?(level)
    }
}
