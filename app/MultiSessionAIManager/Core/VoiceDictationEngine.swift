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
        onPartialResult: @Sendable @escaping (String) -> Void,
        onAudioLevel: @Sendable @escaping (Float) -> Void
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

    public init(service: SpeechRecognitionService? = nil) {
        self.service = service ?? AppleSpeechRecognitionService()
    }

    // MARK: - Static Helpers

    public static func cleanTranscriptionText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func normalizeAudioLevel(rms: Float) -> Float {
        min(max(rms, 0.0), 1.0)
    }

    public static func convertTextToTerminalBytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    // MARK: - Public Control API

    public func startRecording() async {
        guard state == .idle else { return }

        state = .requestingPermissions
        let granted = await service.requestPermissions()
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
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.currentLiveText = partialText
                        if case .listening = self.state {
                            self.state = .listening(liveText: partialText, audioLevel: self.currentAudioLevel)
                        }
                    }
                },
                onAudioLevel: { [weak self] level in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let normalized = Self.normalizeAudioLevel(rms: level)
                        self.currentAudioLevel = normalized
                        if case .listening = self.state {
                            self.state = .listening(liveText: self.currentLiveText, audioLevel: normalized)
                        }
                    }
                }
            )
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    public func stopRecording() async -> String? {
        guard case .listening = state else {
            cancelRecording()
            return nil
        }

        state = .processing
        let finalRaw = await service.stopRecognition()
        let candidate = finalRaw ?? currentLiveText
        let cleaned = Self.cleanTranscriptionText(candidate)

        state = .idle
        currentLiveText = ""
        currentAudioLevel = 0.0
        return cleaned
    }

    public func cancelRecording() {
        service.cancelRecognition()
        state = .idle
        currentLiveText = ""
        currentAudioLevel = 0.0
    }
}

// MARK: - Apple Speech Recognition Service

@MainActor
public final class AppleSpeechRecognitionService: SpeechRecognitionService {
    private let recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var activeRecording = false
    private var latestTranscription: String = ""

    public var isRecording: Bool {
        activeRecording
    }

    public init(locale: Locale = Locale.current) {
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    public func requestPermissions() async -> Bool {
        let micStatus: Bool = await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard micStatus else { return false }

        let speechStatus: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                continuation.resume(returning: authStatus == .authorized)
            }
        }

        return speechStatus
    }

    public func startRecognition(
        onDeviceOnly: Bool,
        onPartialResult: @Sendable @escaping (String) -> Void,
        onAudioLevel: @Sendable @escaping (Float) -> Void
    ) async throws {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw NSError(domain: "VoiceDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not available."])
        }

        teardownAudio()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = onDeviceOnly
        }

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var sum: Float = 0.0
            for i in 0..<frameLength {
                let sample = channelData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameLength))
            onAudioLevel(rms * 12.0)
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.recognitionRequest = request
        self.latestTranscription = ""
        self.activeRecording = true

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    self.latestTranscription = text
                    onPartialResult(text)
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.activeRecording = false
                }
            }
        }
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
            engine.inputNode.removeTap(onBus: 0)
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

    private var onPartial: (@Sendable (String) -> Void)?
    private var onLevel: (@Sendable (Float) -> Void)?

    public init() {}

    public func requestPermissions() async -> Bool {
        permissionGranted
    }

    public func startRecognition(
        onDeviceOnly: Bool,
        onPartialResult: @Sendable @escaping (String) -> Void,
        onAudioLevel: @Sendable @escaping (Float) -> Void
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
