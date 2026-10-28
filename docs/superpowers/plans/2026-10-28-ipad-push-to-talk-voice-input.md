# iPad Push-to-Talk Voice Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-device Push-to-Talk (PTT) voice input feature to MultiSessionAIManager on iPadOS (and iOS) that transcribes spoken user prompts in real time and types them directly into the active Herdr terminal session at the cursor without auto-submitting.

**Architecture:** A `@MainActor` `VoiceDictationEngine` coordinates `AVAudioEngine`, `AVAudioSession`, and `SFSpeechRecognizer` with on-device dictation enabled. A sleek floating `VoiceTranscriptionHUD` hovers over the bottom `TerminalQuickKeyBar`, displaying an audio level waveform and live transcribed words while the user holds the 🎙️ key. Releasing the key stops recording and passes the UTF-8 text to `onInputBytes` in the active terminal session.

**Tech Stack:** Swift 6.0, SwiftUI, Speech.framework (`SFSpeechRecognizer`), AVFoundation (`AVAudioEngine`, `AVAudioSession`), XcodeGen, Fastlane.

**Spec:** `docs/superpowers/specs/2026-10-28-ipad-push-to-talk-voice-input-design.md`

## Global Constraints

- Platform target: iOS 17.0+ (Universal iPad and iPhone).
- Architecture: Works for all AI agents (Codex, Claude Code, Antigravity, Hermes, bash) running in Herdr without remote host dependencies.
- Audio privacy: Strictly require explicit user consent via `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
- On-device speech recognition: Prioritize on-device speech processing (`requiresOnDeviceRecognition = true`) on Apple Silicon.
- Insertion behavior: Insert only (no auto-submit / Enter key appended).
- Test suite: All 789+ existing Swift tests must remain green.

---

### Task 1: Permissions & Project Configuration (`project.yml`)

**Files:**
- Modify: `app/MultiSessionAIManager/project.yml:50-58`

**Interfaces:**
- Produces: `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` in generated `Info.plist`.

- [x] **Step 1: Add privacy usage descriptions to `project.yml`**
- [x] **Step 2: Regenerate Xcode project on Mac**
- [x] **Step 3: Commit changes**

---

### Task 2: Core Voice Dictation Engine (`VoiceDictationEngine.swift`)

**Files:**
- Create: `app/MultiSessionAIManager/Core/VoiceDictationEngine.swift`
- Create: `app/MultiSessionAIManager/Tests/VoiceDictationEngineTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum VoiceDictationState: Equatable, Sendable {
      case idle
      case requestingPermissions
      case listening(liveText: String, audioLevel: Float)
      case processing
      case error(String)
  }

  @MainActor
  public final class VoiceDictationEngine: ObservableObject {
      public static let shared: VoiceDictationEngine
      @Published public private(set) var state: VoiceDictationState
      public func startRecording() async
      public func stopRecording() async -> String?
      public func cancelRecording()
  }
  ```

- [x] **Step 1: Write unit tests for `VoiceDictationState` and engine lifecycle**
- [x] **Step 2: Run Swift tests on Mac to verify test fails**
- [x] **Step 3: Implement `VoiceDictationEngine.swift`**
- [x] **Step 4: Run Swift tests on Mac to verify PASS**
- [x] **Step 5: Commit changes**

---

### Task 3: Live Voice Transcription HUD (`VoiceTranscriptionHUD.swift`)

**Files:**
- Create: `app/MultiSessionAIManager/UI/Terminal/VoiceTranscriptionHUD.swift`
- Create: `app/MultiSessionAIManager/Tests/VoiceTranscriptionHUDTests.swift`

**Interfaces:**
- Consumes: `VoiceDictationState`
- Produces: `VoiceTranscriptionHUD` SwiftUI view.

- [x] **Step 1: Write unit tests for `VoiceTranscriptionHUD`**
- [x] **Step 2: Implement `VoiceTranscriptionHUD.swift`**
- [x] **Step 3: Run Swift tests on Mac to verify PASS**
- [x] **Step 4: Commit changes**

---

### Task 4: Push-to-Talk Integration in `TerminalQuickKeyBar.swift` & `RootView.swift`

**Files:**
- Modify: `app/MultiSessionAIManager/UI/Terminal/TerminalQuickKeyBar.swift:55-75`
- Modify: `app/MultiSessionAIManager/UI/RootView.swift:650-670`
- Modify: `app/MultiSessionAIManager/Tests/HostSoftwareTests.swift` or `RootViewModelTests.swift`

**Interfaces:**
- Connects Push-to-Talk button to `VoiceDictationEngine.shared` and routes transcribed text to `onInputBytes`.

- [x] **Step 1: Update `TerminalQuickKeyBar.swift`**
- [x] **Step 2: Run full Swift test suite on Mac**
- [x] **Step 3: Commit changes**

---

### Task 5: End-to-End Verification & TestFlight Delivery

**Files:**
- Fastlane deployment to TestFlight.

- [ ] **Step 1: Push commits to GitHub `origin/main`**
- [ ] **Step 2: Run `fastlane beta` on Mac**
- [ ] **Step 3: Confirm TestFlight build processing on App Store Connect**
- [ ] **Step 4: Clean up any Mac build observers and release machine**
