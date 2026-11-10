import Foundation
import AVFoundation
import Speech
import Testing
@testable import MultiSessionAIManager

@Suite struct VoiceDictationEngineTests {

    @Test func voiceDictationStateEquality() {
        #expect(VoiceDictationState.idle == VoiceDictationState.idle)
        #expect(VoiceDictationState.requestingPermissions == VoiceDictationState.requestingPermissions)
        #expect(VoiceDictationState.processing == VoiceDictationState.processing)
        #expect(VoiceDictationState.error("denied") == VoiceDictationState.error("denied"))
        #expect(VoiceDictationState.error("denied") != VoiceDictationState.error("failed"))
        #expect(VoiceDictationState.listening(liveText: "hello", audioLevel: 0.5) ==
                VoiceDictationState.listening(liveText: "hello", audioLevel: 0.5))
        #expect(VoiceDictationState.listening(liveText: "hello", audioLevel: 0.5) !=
                VoiceDictationState.listening(liveText: "world", audioLevel: 0.5))
        #expect(VoiceDictationState.listening(liveText: "hello", audioLevel: 0.5) !=
                VoiceDictationState.listening(liveText: "hello", audioLevel: 0.8))
    }

    @Test func cleanTranscriptionTextTrimsAndRejectsEmpty() {
        #expect(VoiceDictationEngine.cleanTranscriptionText("   hello world   ") == "hello world")
        #expect(VoiceDictationEngine.cleanTranscriptionText("\n\n  \t") == nil)
        #expect(VoiceDictationEngine.cleanTranscriptionText("") == nil)
        #expect(VoiceDictationEngine.cleanTranscriptionText("ls -la") == "ls -la")
    }

    @Test func normalizeAudioLevelClampsBetweenZeroAndOne() {
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: -1.0) == 0.0)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: 0.0) == 0.0)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: 0.5) == 0.5)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: 1.0) == 1.0)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: 2.5) == 1.0)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: Float.nan) == 0.0)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: Float.infinity) == 0.0)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: -Float.infinity) == 0.0)
    }

    @Test func convertTextToTerminalBytesPreservesUTF8() {
        let text = "claude --dangerously-skip-permissions"
        let bytes = VoiceDictationEngine.convertTextToTerminalBytes(text)
        #expect(bytes == Array(text.utf8))
    }

    @MainActor
    @Test func engineStateTransitionsWithMockService() async {
        let mock = MockSpeechRecognitionService()
        mock.permissionGranted = true
        mock.transcribedResult = "git status"

        let engine = VoiceDictationEngine(service: mock)
        #expect(engine.state == .idle)

        await engine.startRecording()
        #expect(engine.state == .listening(liveText: "", audioLevel: 0.0))

        mock.simulatePartialText("git stat")
        #expect(engine.state == .listening(liveText: "git stat", audioLevel: 0.0))

        mock.simulateAudioLevel(0.75)
        #expect(engine.state == .listening(liveText: "git stat", audioLevel: 0.75))

        let result = await engine.stopRecording()
        #expect(result == "git status")
        #expect(engine.state == .idle)
    }

    @MainActor
    @Test func engineHandlesPermissionDenied() async {
        let mock = MockSpeechRecognitionService()
        mock.permissionGranted = false

        let engine = VoiceDictationEngine(service: mock)
        await engine.startRecording()

        if case .error(let message) = engine.state {
            #expect(message.contains("permission") || message.contains("Permission"))
        } else {
            Issue.record("Expected .error state when permission denied, got \(engine.state)")
        }
    }

    @MainActor
    @Test func engineHandlesCancelRecording() async {
        let mock = MockSpeechRecognitionService()
        mock.permissionGranted = true

        let engine = VoiceDictationEngine(service: mock)
        await engine.startRecording()
        #expect(mock.isRecording)

        engine.cancelRecording()
        #expect(!mock.isRecording)
        #expect(engine.state == .idle)
    }

    @MainActor
    @Test func engineCancelsDuringPermissionResolutionWithoutStartingRecognition() async {
        let mock = AsyncControllableMockSpeechRecognitionService()
        let engine = VoiceDictationEngine(service: mock)

        let startTask = Task {
            await engine.startRecording()
        }

        // Wait until mock has actually been asked for permissions
        await mock.waitForPermissionRequest()
        #expect(engine.state == .requestingPermissions)

        // User taps and releases quickly, cancelling while permissions are pending
        engine.cancelRecording()
        #expect(engine.state == .idle)

        // Allow permission request to finish
        mock.resumePermissionRequest(granted: true)
        await startTask.value

        // Must remain idle and NOT start recognition
        #expect(engine.state == .idle)
        #expect(!mock.startRecognitionCalled)
        #expect(!mock.isRecording)
    }

    @MainActor
    @Test func engineStopsDuringPermissionResolutionWithoutStartingRecognition() async {
        let mock = AsyncControllableMockSpeechRecognitionService()
        let engine = VoiceDictationEngine(service: mock)

        let startTask = Task {
            await engine.startRecording()
        }

        await mock.waitForPermissionRequest()
        #expect(engine.state == .requestingPermissions)

        // User finger lifted before permission finished
        let text = await engine.stopRecording()
        #expect(text == nil)
        #expect(engine.state == .idle)

        mock.resumePermissionRequest(granted: true)
        await startTask.value

        #expect(engine.state == .idle)
        #expect(!mock.startRecognitionCalled)
        #expect(!mock.isRecording)
    }

    @MainActor
    @Test func engineRecoversFromErrorOnSubsequentStart() async {
        let mock = MockSpeechRecognitionService()
        mock.permissionGranted = true
        let engine = VoiceDictationEngine(service: mock)

        // Force an error state
        mock.permissionGranted = false
        await engine.startRecording()
        if case .error = engine.state {
            // expected
        } else {
            Issue.record("Expected .error state")
        }

        // Subsequent start should recover from .error and succeed
        mock.permissionGranted = true
        await engine.startRecording()
        #expect(engine.state == .listening(liveText: "", audioLevel: 0.0))

        _ = await engine.stopRecording()
        #expect(engine.state == .idle)
    }

    @MainActor
    @Test func appleSpeechCallbacksExecuteSafelyOnBackgroundQueuesWithoutMainActorTrap() async {
        // 1. Speech authorization handler invoked from a background TCC queue
        let authAuthorized = await BackgroundCallbackSimulator.simulateSpeechAuthOnBackgroundQueue(status: .authorized)
        #expect(authAuthorized == true)

        let authDenied = await BackgroundCallbackSimulator.simulateSpeechAuthOnBackgroundQueue(status: .denied)
        #expect(authDenied == false)

        // 2. Audio tap block invoked from a background CoreAudio realtime thread
        let reportedLevel = await BackgroundCallbackSimulator.simulateAudioTapOnBackgroundQueue(sampleAmplitude: 0.1)
        #expect(reportedLevel > 0.0)

        // 3. Recognition result handler invoked from a background Speech queue
        let didStop = await BackgroundCallbackSimulator.simulateRecognitionErrorOnBackgroundQueue()
        #expect(didStop == true)
    }
}

// MARK: - Background Thread Objective-C Callback Simulator

enum BackgroundCallbackSimulator {
    static func simulateSpeechAuthOnBackgroundQueue(
        status: SFSpeechRecognizerAuthorizationStatus
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let handler = AppleSpeechRecognitionService.makeSpeechAuthHandler(resuming: continuation)
            nonisolated(unsafe) let unsafeHandler = handler
            DispatchQueue.global(qos: .userInteractive).async {
                unsafeHandler(status)
            }
        }
    }

    static func simulateAudioTapOnBackgroundQueue(
        sampleAmplitude: Float
    ) async -> Float {
        await withCheckedContinuation { continuation in
            let tapBlock = AppleSpeechRecognitionService.makeAudioTapBlock(
                request: nil,
                onAudioLevel: { level in
                    continuation.resume(returning: level)
                }
            )
            nonisolated(unsafe) let unsafeTapBlock = tapBlock
            DispatchQueue.global(qos: .userInteractive).async {
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
                buffer.frameLength = 1024
                if let channelData = buffer.floatChannelData?[0] {
                    for i in 0..<1024 {
                        channelData[i] = sampleAmplitude
                    }
                }
                let time = AVAudioTime(sampleTime: 0, atRate: 48_000)
                unsafeTapBlock(buffer, time)
            }
        }
    }

    static func simulateRecognitionErrorOnBackgroundQueue() async -> Bool {
        await withCheckedContinuation { continuation in
            let handler = AppleSpeechRecognitionService.makeRecognitionResultHandler { _, shouldStop in
                continuation.resume(returning: shouldStop)
            }
            nonisolated(unsafe) let unsafeHandler = handler
            DispatchQueue.global(qos: .userInteractive).async {
                let err = NSError(domain: "TestSpeechError", code: -1)
                unsafeHandler(nil, err)
            }
        }
    }
}

// MARK: - Test Helpers

@MainActor
final class AsyncControllableMockSpeechRecognitionService: SpeechRecognitionService {
    var isRecording = false
    var startRecognitionCalled = false
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    private var requestWaitContinuation: CheckedContinuation<Void, Never>?

    func waitForPermissionRequest() async {
        if permissionContinuation != nil { return }
        await withCheckedContinuation { continuation in
            requestWaitContinuation = continuation
        }
    }

    func resumePermissionRequest(granted: Bool) {
        permissionContinuation?.resume(returning: granted)
        permissionContinuation = nil
    }

    func requestPermissions() async -> Bool {
        await withCheckedContinuation { continuation in
            permissionContinuation = continuation
            requestWaitContinuation?.resume()
            requestWaitContinuation = nil
        }
    }

    func startRecognition(
        onDeviceOnly: Bool,
        onPartialResult: @MainActor @Sendable @escaping (String) -> Void,
        onAudioLevel: @MainActor @Sendable @escaping (Float) -> Void
    ) async throws {
        startRecognitionCalled = true
        isRecording = true
    }

    func stopRecognition() async -> String? {
        isRecording = false
        return "mock text"
    }

    func cancelRecognition() {
        isRecording = false
    }
}
