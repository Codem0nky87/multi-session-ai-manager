# On-Device Apple LLM Copilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an On-Device Apple LLM Copilot in MultiSessionAIManager that runs locally on iPad and iPhone using Apple Intelligence (`FoundationModels.framework`), providing a slide-out side panel on iPad and sheet on iPhone with terminal context attachment, code snippet insertion directly into the cursor, and push-to-talk voice prompting.

**Architecture:** A `@MainActor` `AppleIntelligenceEngine` handles on-device model sessions via a mockable `LanguageModelBackend` protocol. An `OnDeviceCopilotView` presents streaming chat responses, parsing fenced code blocks to provide one-tap "Insert into Terminal" actions via `onInputBytes`. The copilot extracts terminal context using `emulator.visibleText()` and integrates `VoiceDictationEngine` for voice input.

**Tech Stack:** Swift 6.0, SwiftUI, FoundationModels (`SystemLanguageModel`, `LanguageModelSession`), XcodeGen, Fastlane.

**Spec:** `docs/superpowers/specs/2026-10-29-on-device-apple-llm-copilot-design.md`

---

## Global Constraints

- Platform target: iOS 17.0+ (Universal iPad and iPhone).
- Architecture: 100% on-device execution; zero remote daemon dependencies.
- Hardware requirements: Runs Apple Intelligence on supported hardware (M-series iPads, A17 Pro / A18 iPhones); displays an informative compatibility card on unsupported devices.
- Terminal insertion behavior: Inserts code directly at the cursor without auto-executing (no trailing Enter / `\r`).
- Test suite: All 811+ existing Swift tests must remain green.

---

### Task 1: Core Engine & Backend Abstraction (`AppleIntelligenceEngine.swift`)

**Files:**
- Create: `app/MultiSessionAIManager/Core/AppleIntelligenceEngine.swift`
- Create: `app/MultiSessionAIManager/Tests/AppleIntelligenceEngineTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public protocol LanguageModelBackend: Sendable {
      func isAvailable() -> Bool
      func streamResponse(
          to prompt: String,
          context: String?,
          history: [AppleIntelligenceEngine.ChatMessage]
      ) -> AsyncThrowingStream<String, Error>
  }

  @MainActor
  @Observable
  public final class AppleIntelligenceEngine {
      public static let shared: AppleIntelligenceEngine
      public private(set) var availability: AvailabilityState
      public private(set) var messages: [ChatMessage]
      public private(set) var isGenerating: Bool
      public func checkAvailability()
      public func sendPrompt(_ text: String, terminalContext: String?) async
      public func stopGeneration()
      public func clearHistory()
  }
  ```

- [ ] **Step 1: Write unit tests in `AppleIntelligenceEngineTests.swift`**
  - Verify initial availability state and transitions.
  - Verify message appending and streaming concatenation.
  - Verify `stopGeneration()` cancels active stream.
  - Verify `clearHistory()` resets message history.
- [ ] **Step 2: Run test suite to verify test failure on Mac**
- [ ] **Step 3: Implement `AppleIntelligenceEngine.swift` with `LanguageModelBackend` protocol, `AppleFoundationModelsBackend`, and `MockLanguageModelBackend`**
- [ ] **Step 4: Run test suite on Mac to verify test passes**
- [ ] **Step 5: Commit changes**

---

### Task 2: Code Block Extractor & Formatting (`CodeBlockExtractor.swift`)

**Files:**
- Create: `app/MultiSessionAIManager/Core/CodeBlockExtractor.swift`
- Create: `app/MultiSessionAIManager/Tests/CodeBlockExtractorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ParsedMessageSegment: Equatable, Sendable {
      public enum SegmentType: Equatable, Sendable {
          case text(String)
          case codeBlock(code: String, language: String?)
      }
      public let type: SegmentType
  }

  public enum CodeBlockExtractor {
      public static func parse(markdown: String) -> [ParsedMessageSegment]
  }
  ```

- [ ] **Step 1: Write unit tests in `CodeBlockExtractorTests.swift`**
  - Verify plain text without code blocks returns single `.text` segment.
  - Verify markdown with single code block extracts language and raw code.
  - Verify multiple code blocks mixed with narrative text.
  - Verify unclosed code block during active streaming.
- [ ] **Step 2: Run test suite to verify test failure on Mac**
- [ ] **Step 3: Implement `CodeBlockExtractor.swift`**
- [ ] **Step 4: Run test suite on Mac to verify test passes**
- [ ] **Step 5: Commit changes**

---

### Task 3: Copilot Message Views & Panel UI (`OnDeviceCopilotView.swift`)

**Files:**
- Create: `app/MultiSessionAIManager/UI/Copilot/OnDeviceCopilotView.swift`
- Create: `app/MultiSessionAIManager/UI/Copilot/CopilotMessageView.swift`
- Create: `app/MultiSessionAIManager/Tests/OnDeviceCopilotViewTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct OnDeviceCopilotView: View {
      public init(
          activeTerminalText: @escaping () -> String?,
          onInsertToTerminal: @escaping (String) -> Void,
          onClose: @escaping () -> Void
      )
  }
  ```

- [ ] **Step 1: Write unit tests in `OnDeviceCopilotViewTests.swift`**
  - Verify terminal context attachment logic formats prompt correctly.
  - Verify insertion closure receives raw snippet on button action.
- [ ] **Step 2: Implement `CopilotMessageView.swift` and `OnDeviceCopilotView.swift`**
  - Message bubble list with user avatar and  AI assistant avatar.
  - Code block view with syntax badge, Copy button, and "Insert into Terminal" button.
  - Bottom input bar with text field, 🎙️ push-to-talk mic button, terminal attachment chip, and send/stop button.
  - Header with title, clear button, and close button.
- [ ] **Step 3: Run test suite on Mac to verify test passes**
- [ ] **Step 4: Commit changes**

---

### Task 4: RootView & Terminal Integration

**Files:**
- Modify: `app/MultiSessionAIManager/UI/RootView.swift`
- Modify: `app/MultiSessionAIManager/UI/Terminal/HerdrWorkspaceContainerView.swift` or header strip

**Interfaces:**
- Adds  AI Copilot toggle button to the top toolbar.
- Renders `OnDeviceCopilotView` as a 360pt trailing panel side-by-side with active terminal on iPad.
- Renders `OnDeviceCopilotView` in a `.sheet` on iPhone.
- Connects `activeTerminalText: { selectedSession?.visibleText() }` and `onInsertToTerminal: { code in selectedSession?.send(Array(code.utf8)) }`.

- [ ] **Step 1: Update `RootView.swift` with copilot presentation state and layout**
- [ ] **Step 2: Connect toolbar button and terminal byte routing**
- [ ] **Step 3: Run full Swift test suite on Mac (811+ tests passing)**
- [ ] **Step 4: Commit changes**

---

### Task 5: End-to-End Verification & TestFlight Release

**Files:**
- Fastlane TestFlight deployment.

- [ ] **Step 1: Push all commits to GitHub `origin/main`**
- [ ] **Step 2: Sync Mac build tree and run full test suite**
- [ ] **Step 3: Run `fastlane beta` on Mac**
- [ ] **Step 4: Confirm App Store Connect upload completion and clean up Mac build state**
