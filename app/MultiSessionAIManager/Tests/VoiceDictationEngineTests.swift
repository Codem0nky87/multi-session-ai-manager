import Foundation
import AVFoundation
import Speech
import Testing
import UIKit
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

    @Test func quickKeyBarPlacesVoiceSecondFromLeftAndIncludesAlt() {
        // Voice key must be at index 1 (2nd from left, right after esc) so it avoids both
        // the iPadOS bottom-left corner swipe zone and the centered iPad Home Indicator,
        // and "alt" must be present in the quick-key bar.
        #expect(TerminalQuickKeyBar.orderedKeyIdentifiers[0] == "msam.quickkey.esc")
        #expect(TerminalQuickKeyBar.orderedKeyIdentifiers[1] == "msam.quickkey.voice")
        #expect(TerminalQuickKeyBar.orderedKeyIdentifiers.contains("msam.quickkey.alt"))
    }

    @MainActor
    @Test func stickyAltKeyPrefixesEscapeAndDisarmsOnInputAndBackspace() {
        let controller = KeyInputController()
        let inputView = TerminalKeyInputView(frame: .zero)
        var capturedBytes: [[UInt8]] = []
        inputView.onInput = { capturedBytes.append($0) }
        controller.view = inputView

        #expect(controller.isAltArmed == false)
        controller.toggleAlt()
        #expect(controller.isAltArmed == true)
        #expect(inputView.altLatchArmed == true)

        // Typing "b" while Alt is armed sends ESC + "b" (backward-word in readline/shell) and disarms
        inputView.insertText("b")
        #expect(capturedBytes.last == [0x1B, UInt8(ascii: "b")])
        #expect(inputView.altLatchArmed == false)

        // Arming Alt again and pressing Backspace sends ESC + DEL (backward-kill-word) and disarms
        controller.toggleAlt()
        #expect(inputView.altLatchArmed == true)
        inputView.deleteBackward()
        #expect(capturedBytes.last == [0x1B, 0x7F])
        #expect(inputView.altLatchArmed == false)

        // A multi-byte character gets ONE ESC in front of the whole character, not one per byte.
        controller.toggleAlt()
        inputView.insertText("é")
        #expect(capturedBytes.last == [0x1B, 0xC3, 0xA9])
        #expect(inputView.altLatchArmed == false)
    }

    /// The latches are armed on the quick-key bar but the next key usually comes from a
    /// HARDWARE keyboard, which reaches the view through `pressesBegan`, never `insertText`.
    @MainActor
    @Test func stickyAltAndCtrlLatchesApplyToHardwareKeyboardKeys() {
        let controller = KeyInputController()
        let inputView = TerminalKeyInputView(frame: .zero)
        var capturedBytes: [[UInt8]] = []
        inputView.onInput = { capturedBytes.append($0) }
        controller.view = inputView

        // Alt armed on the bar, "m" on the hardware keyboard -> ESC m, and the latch disarms.
        controller.toggleAlt()
        #expect(inputView.handleHardwareKey(keyCode: .keyboardM, characters: "m", modifierFlags: []) == true)
        #expect(capturedBytes.last == [0x1B, UInt8(ascii: "m")])
        #expect(inputView.altLatchArmed == false)
        #expect(controller.isAltArmed == false)

        // The latch is one-shot: the following key is plain again.
        #expect(inputView.handleHardwareKey(keyCode: .keyboardM, characters: "m", modifierFlags: []) == true)
        #expect(capturedBytes.last == [UInt8(ascii: "m")])

        // Pressing a bare modifier (Shift going down for a capital) must not spend the latch.
        controller.toggleAlt()
        #expect(inputView.handleHardwareKey(keyCode: .keyboardLeftShift, characters: "", modifierFlags: [.shift]) == false)
        #expect(inputView.altLatchArmed == true)
        #expect(inputView.handleHardwareKey(keyCode: .keyboardM, characters: "M", modifierFlags: [.shift]) == true)
        #expect(capturedBytes.last == [0x1B, UInt8(ascii: "M")])
        #expect(inputView.altLatchArmed == false)

        // Alt + a key that is itself an escape sequence: one ESC in front of the sequence.
        controller.toggleAlt()
        #expect(inputView.handleHardwareKey(keyCode: .keyboardUpArrow, characters: "UIKeyInputUpArrow", modifierFlags: []) == true)
        #expect(capturedBytes.last == EscapeSequences.meta + EscapeSequences.up)
        #expect(controller.isAltArmed == false)

        // Alt + Return is how TUIs take a newline without submitting.
        controller.toggleAlt()
        #expect(inputView.handleHardwareKey(keyCode: .keyboardReturnOrEnter, characters: "\r", modifierFlags: []) == true)
        #expect(capturedBytes.last == EscapeSequences.meta + EscapeSequences.return)

        // Ctrl armed on the bar, "c" on the hardware keyboard -> 0x03, and the latch disarms.
        controller.toggleCtrl()
        #expect(inputView.handleHardwareKey(keyCode: .keyboardC, characters: "c", modifierFlags: []) == true)
        #expect(capturedBytes.last == [0x03])
        #expect(inputView.ctrlLatchArmed == false)
        #expect(controller.isCtrlArmed == false)

        // Ctrl has no control-code form for an arrow; the sequence must survive intact.
        controller.toggleCtrl()
        #expect(inputView.handleHardwareKey(keyCode: .keyboardUpArrow, characters: "UIKeyInputUpArrow", modifierFlags: []) == true)
        #expect(capturedBytes.last == EscapeSequences.up)
        #expect(controller.isCtrlArmed == false)

        // A physically held Option needs no latch: Option+Left is word-left.
        #expect(inputView.handleHardwareKey(keyCode: .keyboardLeftArrow, characters: "UIKeyInputLeftArrow", modifierFlags: [.alternate]) == true)
        #expect(capturedBytes.last == EscapeSequences.meta + EscapeSequences.leftMeta)

        // Cmd shortcuts stay with UIKit and leave an armed latch alone.
        controller.toggleAlt()
        #expect(inputView.handleHardwareKey(keyCode: .keyboardV, characters: "v", modifierFlags: [.command]) == false)
        #expect(inputView.altLatchArmed == true)
    }

    /// iPadOS delivers Option+M as "µ". A terminal wants Alt+M, so a held Option is
    /// read from the key itself, not from the character Option turned it into.
    @MainActor
    @Test func physicalOptionKeyActsAsAlt() {
        let inputView = TerminalKeyInputView(frame: .zero)
        var capturedBytes: [[UInt8]] = []
        inputView.onInput = { capturedBytes.append($0) }

        func press(_ keyCode: UIKeyboardHIDUsage, _ characters: String, _ unmodified: String, _ flags: UIKeyModifierFlags) -> Bool {
            inputView.handleHardwareKey(keyCode: keyCode,
                                        characters: characters,
                                        charactersIgnoringModifiers: unmodified,
                                        modifierFlags: flags)
        }

        // Option+M -> ESC m, not ESC µ.
        #expect(press(.keyboardM, "µ", "m", [.alternate]) == true)
        #expect(capturedBytes.last == [0x1B, UInt8(ascii: "m")])

        // The unmodified key is always lowercase, so Shift has to be put back: Alt+Shift+M -> ESC M.
        #expect(press(.keyboardM, "Â", "m", [.alternate, .shift]) == true)
        #expect(capturedBytes.last == [0x1B, UInt8(ascii: "M")])

        // Caps Lock capitalises a letter the same way.
        #expect(press(.keyboardM, "µ", "m", [.alternate, .alphaShift]) == true)
        #expect(capturedBytes.last == [0x1B, UInt8(ascii: "M")])

        // Alt+Shift+, is Alt+< (start of buffer in readline and less).
        #expect(press(.keyboardComma, "¯", ",", [.alternate, .shift]) == true)
        #expect(capturedBytes.last == [0x1B, UInt8(ascii: "<")])

        // Caps Lock does not shift a symbol.
        #expect(press(.keyboardComma, "≤", ",", [.alternate, .alphaShift]) == true)
        #expect(capturedBytes.last == [0x1B, UInt8(ascii: ",")])

        // Option+E is a dead key that composes nothing yet; Alt+E must still go out.
        #expect(press(.keyboardE, "", "e", [.alternate]) == true)
        #expect(capturedBytes.last == [0x1B, UInt8(ascii: "e")])

        // Ctrl+Option+C -> ESC then Ctrl-C.
        #expect(press(.keyboardC, "ç", "c", [.alternate, .control]) == true)
        #expect(capturedBytes.last == [0x1B, 0x03])

        // Option going down on its own is only a modifier.
        let sentSoFar = capturedBytes.count
        #expect(press(.keyboardLeftAlt, "", "", [.alternate]) == false)
        #expect(capturedBytes.count == sentSoFar)

        // Without Option nothing changes: the character iPadOS composed is what is sent.
        #expect(press(.keyboardM, "M", "m", [.shift]) == true)
        #expect(capturedBytes.last == [UInt8(ascii: "M")])
    }

    /// Whisper dictation is gone, so nothing it stored may outlive it on the device.
    @Test func retiredWhisperDictationLeavesNothingBehind() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msam-retired-whisper-\(UUID().uuidString)", isDirectory: true)
        let modelFile = root
            .appendingPathComponent("WhisperModels/models/argmaxinc/whisperkit-coreml/openai_whisper-small", isDirectory: true)
            .appendingPathComponent("weights.bin")
        let unrelated = root.appendingPathComponent("KnownHosts/hosts.json")
        for file in [modelFile, unrelated] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x01]).write(to: file)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "com.codem0nky87.msam.tests.retired-whisper.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("af", forKey: "voiceDictation.languageMode")
        defaults.set("openai_whisper-small", forKey: "voiceDictation.modelVariant")
        defaults.set("kept", forKey: "terminal.themeID")

        RetiredWhisperDictation.removeLeftovers(applicationSupport: root, defaults: defaults)

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("WhisperModels").path) == false)
        #expect(FileManager.default.fileExists(atPath: unrelated.path) == true)
        #expect(defaults.object(forKey: "voiceDictation.languageMode") == nil)
        #expect(defaults.object(forKey: "voiceDictation.modelVariant") == nil)
        #expect(defaults.string(forKey: "terminal.themeID") == "kept")

        // Nothing to remove is the normal case and must be a no-op.
        RetiredWhisperDictation.removeLeftovers(applicationSupport: root, defaults: defaults)
        #expect(FileManager.default.fileExists(atPath: unrelated.path) == true)
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
