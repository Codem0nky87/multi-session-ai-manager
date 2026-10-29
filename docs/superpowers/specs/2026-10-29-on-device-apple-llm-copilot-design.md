# On-Device Apple LLM Copilot Design Specification

**Date:** 2026-10-29  
**Status:** Approved  
**Platform:** iPadOS & iOS 17.0+ (Universal, with native Apple Intelligence on iOS 26+ / Apple Silicon)

---

## 1. Goal & Context

MultiSessionAIManager manages multiple remote AI agent sessions (Codex, Claude Code, Antigravity, bash) over SSH via Herdr. Because iOS/iPadOS sandboxing forbids running Unix daemons (like the Herdr server) or spawning arbitrary local shell PTYs on the device, local agents cannot run natively inside terminal sessions on iPad or iPhone.

However, Apple provides on-device foundation models through the native **`FoundationModels` framework** (Apple Intelligence), running directly on Apple Silicon Neural Engine / GPU in pure Swift without requiring any server, network connection, or background daemon.

This feature adds a native **On-Device Apple LLM Copilot** to MultiSessionAIManager:
1. **iPad Presentation:** A collapsible slide-out right-hand side panel positioned directly beside the active Herdr terminal, turning the Apple LLM into a real-time copilot.
2. **iPhone Presentation:** An interactive bottom sheet (`.sheet(isPresented:)`).
3. **Terminal Context Sharing:** A one-tap button to extract the active terminal session's recent output (`emulator.visibleText()`) and attach it to the prompt.
4. **Direct Code Injection:** An "Insert into Terminal" button on generated code blocks that types snippets directly into the active Herdr session at the cursor prompt without auto-submitting.
5. **Push-to-Talk Voice Input:** Integrated speech dictation using the app's on-device `VoiceDictationEngine`.

---

## 2. Architecture & Subsystems

```
┌────────────────────────────────────────────────────────────────────────┐
│                        RootView / Main Window                          │
├──────────────────────────────────────┬─────────────────────────────────┤
│         Active Terminal Area         │    OnDeviceCopilotView (Side)   │
│  ┌────────────────────────────────┐  │  ┌───────────────────────────┐  │
│  │   TerminalEmulatorView         │  │  │ Message Bubbles (Stream)  │  │
│  │   - Herdr PTY Session          │  │  │ [Copy] [Insert to Term]   │  │
│  │   - Auto-reflows to fit width  │  │  ├───────────────────────────┤  │
│  │   - QuickKeyBar (^/, ^c, etc.) │  │  │ Context Chip: [Term Log]  │  │
│  └────────────────────────────────┘  │  │ Prompt Input + 🎙️ Voice    │  │
│                                      │  └───────────────────────────┘  │
└──────────────────────────────────────┴─────────────────────────────────┘
                                ▲                      │
                     terminal.visibleText()    onInputBytes(code)
                                │                      ▼
               ┌────────────────┴─────────────────────────────┐
               │         AppleIntelligenceEngine              │
               │   - Protocol: LanguageModelBackendProtocol   │
               │   - Live: AppleFoundationModelsBackend       │
               │   - Mock: MockLanguageModelBackend (Tests)   │
               │   - Session: LanguageModelSession            │
               └──────────────────────────────────────────────┘
```

---

## 3. Core Engine: `AppleIntelligenceEngine.swift`

### 3.1 Backend Protocol for Testability
To allow thorough unit testing in Xcode Simulator (and graceful fallback on devices without Apple Intelligence), the engine decouples from concrete hardware via a backend protocol:

```swift
public protocol LanguageModelBackend: Sendable {
    func isAvailable() -> Bool
    func streamResponse(
        to prompt: String,
        context: String?,
        history: [AppleIntelligenceEngine.ChatMessage]
    ) -> AsyncThrowingStream<String, Error>
}
```

### 3.2 Live Backend: `AppleFoundationModelsBackend`
On supported Apple Silicon hardware running Apple Intelligence:
- Uses `SystemLanguageModel.default` from `FoundationModels.framework`.
- Checks `SystemLanguageModel.default.isAvailable`.
- Manages an active `LanguageModelSession` maintaining conversational context.
- Yields streaming tokens as they arrive.

### 3.3 Engine State & Model
```swift
@MainActor
@Observable
public final class AppleIntelligenceEngine {
    public static let shared = AppleIntelligenceEngine()

    public enum AvailabilityState: Equatable, Sendable {
        case checking
        case available
        case unsupported(reason: String)
    }

    public struct ChatMessage: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let role: Role
        public var content: String
        public let timestamp: Date
        public var attachedTerminalContext: String?
        public var isStreaming: Bool

        public enum Role: String, Sendable {
            case user
            case assistant
            case system
        }
    }

    public private(set) var availability: AvailabilityState = .checking
    public private(set) var messages: [ChatMessage] = []
    public private(set) var isGenerating: Bool = false

    public func checkAvailability()
    public func sendPrompt(_ text: String, terminalContext: String? = nil) async
    public func stopGeneration()
    public func clearHistory()
}
```

---

## 4. Terminal Integration: Context Attachment & Code Injection

### 4.1 Context Extraction
- When the user taps the **Terminal Attachment** button, the copilot captures the visible lines from the currently active terminal via `emulator.visibleText()`.
- The context is displayed as a removable pill: `📎 Terminal Output (N lines)` above the prompt box.
- When sent, the system prompt instructs the Apple Foundation Model:
  ```
  The user provided terminal output from their active session:
  ```terminal
  <terminal text>
  ```
  Answer their question or troubleshoot the output concisely.
  ```

### 4.2 Code Block Parsing & "Insert into Terminal"
- Assistant markdown responses are parsed for fenced code blocks (````lang ... ````).
- Each code block view contains:
  1. Language tag badge.
  2. **Copy Button:** Copies raw snippet to `UIPasteboard.general`.
  3. **"Insert into Terminal" Button:** Formats snippet as UTF-8 bytes and passes to `onInputBytes(Array(code.utf8))` of the active terminal session. No trailing newline or carriage return is appended, allowing the developer to review the command at the prompt before executing.

---

## 5. UI Layout: `OnDeviceCopilotView.swift`

### 5.1 iPad Side Panel
- Integrated into `RootView`'s terminal presentation area.
- Toggled via an ** AI** / Copilot button in the top navigation strip.
- When open, displays as a 360pt trailing panel with a thin divider.
- The adjacent `TerminalEmulatorView` geometry automatically scales and adjusts rows/columns via its existing `applySize(geometry.size)` handler, preventing terminal clipping.

### 5.2 iPhone Bottom Sheet
- On compact width (iPhone), the button presents `OnDeviceCopilotView` in a standard SwiftUI sheet:
  ```swift
  .sheet(isPresented: $isCopilotOpen) {
      OnDeviceCopilotView(...)
          .presentationDetents([.medium, .large])
  }
  ```

### 5.3 Prompt Input Row
- `TextField` with automatic vertical expansion.
- **🎙️ Push-to-Talk Button:** Embedded micro-button activating `VoiceDictationEngine.shared`. Hold to speak, release to append transcribed text into the prompt.
- **Terminal Context Button:** Grabs latest terminal output.
- **Send / Stop Button:** Sends prompt or cancels ongoing token stream.
- **Clear Chat Button:** In the panel header, resets the session history.

---

## 6. Testing Strategy

1. **`AppleIntelligenceEngineTests.swift`:**
   - Tests initial state and backend availability transitions.
   - Tests streaming token concatenation into assistant `ChatMessage`.
   - Tests stop generation cancellation.
   - Tests clear history.
   - Tests terminal context formatting and system prompt encapsulation.
2. **`CodeBlockExtractorTests.swift`:**
   - Tests parsing fenced code blocks from markdown text.
   - Tests extraction of clean executable snippet without markdown fences.
3. **Full Suite Regression:**
   - Confirm all 811 existing Swift tests pass on Mac simulator `iPad Pro 13-inch (M5)`.
