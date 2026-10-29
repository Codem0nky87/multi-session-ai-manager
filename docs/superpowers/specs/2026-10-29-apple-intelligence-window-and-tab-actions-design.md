# Apple Intelligence App & Window Actions Design Specification

## 1. Overview
MultiSessionAIManager connects users on iPadOS and iOS to remote AI agent sessions running in Herdr workspaces over SSH. This feature enables Apple Intelligence (running on-device via Apple FoundationModels) to understand natural language requests to manipulate application windows and tabs, presenting an interactive, reviewable **Action Card** before executing the action.

## 2. User Experience & Goals

### 2.1 Supported Actions
1. **Host-Side Herdr Window & Tab Orchestration:**
   - **Split Pane:** Horizontal (`down`) or Vertical (`right`) split (`herdr pane split`).
   - **Close Pane:** Closes current active pane (`herdr pane close`).
   - **Zoom Pane:** Toggles zoom state of active pane (`herdr pane zoom`).
   - **Create Herdr Tab:** Opens a new tab in the current workspace with optional label (`herdr tab create --label <name> --focus`).
   - **Staged Command Execution:** When a command accompanies the window action (e.g., *"split pane down and tail logs"*), the pane is created, focused, and the command is staged into the prompt without auto-executing (no trailing `\n`).

2. **App-Side Host Tab & View Navigation:**
   - **Switch Host Tab:** Switches between open host tabs (e.g., *"switch to Foundry"*, *"go to Forge"*).
   - **Open Host Tab:** Opens a new host tab for any configured host from the host store.
   - **Open Sheets:** Opens Provider Pulse usage sheet, Hardware Metrics sheet, or Settings sheet.

### 2.2 Interaction Flow: "Review & Confirm First"
1. User enters a prompt in the Apple Intelligence chat drawer or voice PTT (e.g., *"split this pane down and run pytest"* or *"switch to Foundry"*).
2. Apple Intelligence generates natural conversational text explaining the plan, accompanied by an ````action ```` block.
3. The UI (`AppleIntelligenceMessageView`) strips the raw action block from the visible text bubble and renders a polished **Action Card** at the bottom of the assistant message.
4. The Action Card displays:
   - Action icon (SF Symbol: `rectangle.split.2x1.fill`, `macwindow.on.rectangle`, etc.)
   - Action summary title (e.g. **Split Pane Down** or **Switch to Foundry**)
   - Monospaced badge for staged command if present (`Staged: pytest`)
   - **[Apply Action]** button and **[Dismiss]** button
5. Upon tapping **[Apply Action]**:
   - The card transitions to a brief loading spinner (`Applying...`).
   - If an App-level action: `tabStore.selectedTab` changes immediately to the target host.
   - If a Herdr-level action: SSH command executes on the active host (`herdr pane split ...`), and any staged command is safely fed into the new pane without trailing newline.
   - The card changes to a green checkmark `✓ Applied` badge and disables further taps.
6. Upon tapping **[Dismiss]**:
   - The card is dismissed without executing any action.

---

## 3. Architecture & Components

```
User Prompt ("split pane down and run pytest")
  │
  ▼
AppleIntelligenceEngine (enriched with AppRuntimeContext)
  │
  ▼
Streaming LLM Output: Natural Language + ```action JSON
  │
  ▼
AppActionExtractor
  ├── cleanMessageText (raw action JSON stripped from chat bubble)
  └── extractedAction (parsed AppAction enum)
  │
  ▼
AppleIntelligenceMessageView -> AppActionCardView
  │
  ▼ User taps [Apply Action]
AppActionDispatcher
  ├── App Navigation: tabStore.selectedTab = targetTab
  └── Herdr Command: session.connection.service.run("herdr pane split ...")
        └── Staged input: session.terminal.feedInputToPTY(commandBytes)
```

### 3.1 Data Models (`AppAction.swift`)

```swift
public enum SplitDirection: String, Codable, Sendable {
    case right
    case down
}

public enum AppSheetType: String, Codable, Sendable {
    case metrics
    case pulse
    case settings
}

public enum AppAction: Equatable, Sendable {
    case splitPane(direction: SplitDirection, stagedCommand: String?)
    case closePane
    case zoomPane
    case createHerdrTab(label: String, stagedCommand: String?)
    case switchHostTab(name: String)
    case openHostTab(hostName: String)
    case openAppSheet(sheet: AppSheetType)
}
```

### 3.2 Action Extractor (`AppActionExtractor.swift`)
Extracts and validates `AppAction` definitions from model responses:
- Matches fenced code blocks: ````action\n{...}\n````
- Parses JSON payload with schema:
  ```json
  {
    "type": "split_pane" | "close_pane" | "zoom_pane" | "create_herdr_tab" | "switch_host_tab" | "open_host_tab" | "open_sheet",
    "direction": "down" | "right",
    "target": "Foundry",
    "label": "tests",
    "staged_command": "pytest",
    "sheet": "metrics" | "pulse" | "settings"
  }
  ```
- Returns a clean message text without the raw action block, along with the decoded `AppAction`.

### 3.3 Runtime Context Manifest (`AppRuntimeContext.swift`)
Provides Apple Intelligence with the necessary awareness of open tabs and environment:
```swift
public struct AppRuntimeContext: Sendable {
    public let hostTabs: [String]
    public let selectedHostTab: String?
    public let activeHostName: String?
    public let currentDirectory: String?

    public var systemPromptContext: String {
        var lines: [String] = ["Current App Runtime Context:"]
        if !hostTabs.isEmpty {
            let tabsList = hostTabs.map { $0 == selectedHostTab ? "\($0) (active)" : $0 }.joined(separator: ", ")
            lines.append("- Open Host Tabs: [\(tabsList)]")
        }
        if let currentDirectory, !currentDirectory.isEmpty {
            lines.append("- Working Directory: \(currentDirectory)")
        }
        return lines.joined(separator: "\n")
    }
}
```

### 3.4 Action Dispatcher (`AppActionDispatcher.swift`)
`@MainActor` protocol and coordinator that binds `RootView`, `HostTabStore`, and `SSHService`:
- Handles tab switching on `HostTabStore`.
- Formulates valid Herdr commands with standard `$HOME/.local/bin` PATH prefix.
- Uses `session.connection.service.run(...)` for Herdr execution.
- Injects staged commands safely using `session.terminal.feedInputToPTY(Array(stagedCommand.utf8))`.

---

## 4. UI Components

### 4.1 Action Card (`AppActionCardView.swift`)
- SwiftUI component rendered under the chat bubble.
- Styling conforms to `HerdrTheme` with custom card border and subtle background tint.
- Shows SF Symbol icon corresponding to the action:
  - `rectangle.split.2x1.fill`: Vertical split (Right)
  - `rectangle.split.1x2.fill`: Horizontal split (Down)
  - `macwindow.on.rectangle`: Tab operations
  - `arrow.up.left.and.arrow.down.right`: Zoom pane
  - `xmark.rectangle`: Close pane
- Displays monospaced preview pill for staged commands.
- Interactive states:
  - Pending: `[Apply Action]` (Accent) + `[Dismiss]` (Subtle)
  - Executing: ProgressView + `Applying...`
  - Applied: `Image(systemName: "checkmark.circle.fill")` + `Applied`
  - Error: `⚠️ Failed: <reason>` + `[Retry]`

---

## 5. Error Handling & Edge Cases
1. **Disconnected Session:** If a Herdr action is confirmed while the SSH connection is down, show a clear inline error on the card: *"Host session not connected"*.
2. **Tab Not Open:** If the model proposes switching to a host tab that was closed in the meantime, show *"Tab '<name>' is not open"*.
3. **Herdr Execution Failure:** Any error returned by `herdr` (e.g. exit code 1 or pane geometry error) is captured and surfaced on the card with a Retry button.
4. **No Auto-Enter:** Staged commands never contain trailing `\n` to prevent unintended code execution in remote shells.

---

## 6. Testing Plan
1. **Unit Tests (`AppActionExtractorTests.swift`):**
   - Extract `.splitPane` with and without staged command.
   - Extract `.switchHostTab` and `.createHerdrTab`.
   - Strip action block from message body while preserving markdown formatting.
   - Handle invalid JSON or unknown action types gracefully.
2. **Unit Tests (`AppActionDispatcherTests.swift`):**
   - Verify Herdr command strings match CLI specifications.
   - Verify host tab switching updates `tabStore.selectedTab`.
   - Verify command staging bytes contain exact string without newline.
3. **UI / Component Tests (`AppActionCardViewTests.swift`):**
   - Render in `.pending`, `.executing`, `.applied`, and `.failed` states.
