# Browser Space Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The In App browser becomes a space in Herdr's own layout, opened from Herdr's "new" (Workspace or Browser) and from the host tab's menu, and is no longer reached through Port Forwarding.

**Architecture:** A browser space is an ordinary Herdr workspace whose pane runs a placeholder script that paints a marker carrying its id and size, plus a fill. The app finds the marker in the terminal grid it already renders and lays the existing proxied browser over exactly those cells; when the rectangle is not wholly fill (a Herdr menu over it, another space selected) the browser steps aside.

**Tech Stack:** Swift 6.0, SwiftUI, WebKit, Swift Testing (`import Testing`), POSIX `sh`, Python `unittest` (run by pytest) for the host script.

**Spec:** `docs/superpowers/specs/2026-11-18-browser-space-design.md`

## Global Constraints

- Minimum deployment target iOS 17.0, `SWIFT_VERSION` 6.0. No new packages.
- The marker is exactly `[[AIM-BROWSER <id> <cols>x<rows>]]`, the fill is `░` (U+2591), the id is six lowercase hex digits.
- The space's label is `Browser`. The placeholder is installed at `$HOME/.local/share/msam/browser-space.sh`.
- Hide grace period: 120 ms. Saved addresses: newest 12 per host, key `msam.browser-spaces.<host id lowercased>`.
- Source lives on Forge, builds run on the Mac. After editing, from the repo root:
  `rsync -a --relative <changed files> IronMentorMac:Projects/multi-session-ai-manager/` then
  `ssh IronMentorMac 'export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; cd ~/Projects/multi-session-ai-manager/app/MultiSessionAIManager && xcodegen generate >/dev/null && xcodebuild test -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager -destination "platform=iOS Simulator,name=iPad Pro 13-inch (M5)" -only-testing:MultiSessionAIManagerTests/<Suite> 2>&1 | grep -E "^(✘)|error:|\*\* TEST|Test run with" | cut -c1-300'`
  (`xcodegen generate` is needed whenever a file is added or removed.)
- A test never awaits an event without a bound: poll with a deadline and return a Bool. An unbounded wait hangs the whole run when the code under test is wrong.
- Python tests: `python3 -m pytest tests/<file> -q` on Forge.
- Throwaway probes are named `Tests/ZZ…Tests.swift`, exist only on the Mac, and are deleted (then `xcodegen generate`) before any commit.
- Herdr experiments use a throwaway session (`herdr --session msam-…`, `HERDR_*` stripped from the environment), never the default session.
- Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility |
|---|---|
| `app/MultiSessionAIManager/Resources/msam-browser-space.sh` (new) | The placeholder that runs in the pane |
| `tests/test_msam_browser_space.py` (new) | The placeholder under a real pty |
| `Core/BrowserSpaceLocator.swift` (new) | Marker format, region type, finding regions in a grid, cells → points |
| `Core/BrowserSpaceCommands.swift` (new) | The host commands and the opener that runs them |
| `Core/TerminalNewSpaceButton.swift` (new) | Hit test for Herdr's "new" |
| `Core/BrowserSpaceModel.swift` (new) | Regions shown, pages kept, addresses saved |
| `UI/Browser/HostBrowserPage.swift` (moved from `UI/WebTunnel/HostBrowserScreen.swift`) | The web view wrapper, unchanged |
| `UI/Browser/HostBrowserPane.swift` (new) | Compact browser chrome for a pane |
| `UI/Browser/BrowserSpaceOverlay.swift` (new) | Places one pane per region |
| `UI/Terminal/TerminalEmulatorView.swift`, `UI/RootView.swift`, `UI/HostTabStrip.swift`, `Core/HerdrHostSession.swift`, `UI/WebTunnel/SessionWebTunnelSheet.swift` (modified) | Wiring and removal |

All Swift paths below are under `app/MultiSessionAIManager/`.

---

### Task 1: The placeholder script

**Files:**
- Create: `app/MultiSessionAIManager/Resources/msam-browser-space.sh`
- Test: `tests/test_msam_browser_space.py`

**Interfaces:**
- Produces: a script run as `sh browser-space.sh <id>` that writes, to its terminal, `ESC[<r>;1H` + `cols` fill characters for every row and then `ESC[1;1H[[AIM-BROWSER <id> <cols>x<rows>]]`.

- [ ] **Step 1: Write the failing test**

```python
"""The browser space's placeholder, run under a real pty."""
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import termios
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'app/MultiSessionAIManager/Resources/msam-browser-space.sh'
FILL = '░'


class Placeholder:
    def __init__(self, rows, cols, ident='7f3a2c'):
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            os.execvp('sh', ['sh', str(SCRIPT), ident])
        self.resize(rows, cols)

    def resize(self, rows, cols):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    def read(self, seconds=0.6):
        data = b''
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.master], [], [], 0.05)
            if ready:
                try:
                    data += os.read(self.master, 65536)
                except OSError:
                    break
        return data.decode('utf-8', 'replace')

    def children(self):
        out = subprocess.run(['pgrep', '-P', str(self.pid)], capture_output=True, text=True).stdout.split()
        return [int(pid) for pid in out]

    def exited(self):
        try:
            return os.waitpid(self.pid, os.WNOHANG)[0] == self.pid
        except ChildProcessError:
            return True

    def close(self):
        try:
            os.close(self.master)
        except OSError:
            pass
        time.sleep(0.5)
        if not self.exited():
            os.kill(self.pid, 9)
            os.waitpid(self.pid, 0)


class PlaceholderTests(unittest.TestCase):
    def start(self, rows, cols):
        placeholder = Placeholder(rows, cols)
        self.addCleanup(placeholder.close)
        time.sleep(0.2)
        return placeholder

    def test_it_marks_its_pane_with_its_id_and_size(self):
        shown = self.start(10, 40).read()
        self.assertIn('\x1b[1;1H[[AIM-BROWSER 7f3a2c 40x10]]', shown)

    def test_it_fills_every_cell(self):
        shown = self.start(10, 40).read()
        self.assertEqual(shown.count(FILL), 40 * 10)
        for row in range(1, 11):
            self.assertIn('\x1b[%d;1H%s' % (row, FILL * 40), shown)

    def test_it_repaints_with_the_new_size_after_a_resize(self):
        placeholder = self.start(10, 40)
        placeholder.read()
        placeholder.resize(12, 50)
        shown = placeholder.read()
        self.assertIn('[[AIM-BROWSER 7f3a2c 50x12]]', shown)
        self.assertEqual(shown.count(FILL), 50 * 12)

    def test_a_pane_too_narrow_for_the_marker_shows_only_the_fill(self):
        shown = self.start(5, 12).read()
        self.assertNotIn('AIM-BROWSER', shown)
        self.assertEqual(shown.count(FILL), 12 * 5)

    def test_it_keeps_one_helper_process_however_often_it_is_resized(self):
        placeholder = self.start(10, 40)
        placeholder.read()
        for rows, cols in [(12, 50), (8, 30), (20, 60)]:
            placeholder.resize(rows, cols)
            placeholder.read(0.4)
        self.assertEqual(len(placeholder.children()), 1)

    def test_ctrl_c_does_not_close_the_space(self):
        placeholder = self.start(10, 40)
        placeholder.read()
        os.write(placeholder.master, b'\x03')
        time.sleep(0.3)
        self.assertFalse(placeholder.exited())

    def test_it_ends_with_its_helper_when_the_pane_is_closed(self):
        placeholder = self.start(10, 40)
        placeholder.read()
        children = placeholder.children()
        os.close(placeholder.master)
        time.sleep(0.6)
        self.assertTrue(placeholder.exited())
        self.assertEqual([pid for pid in children if os.path.exists('/proc/%d' % pid)], [])


if __name__ == '__main__':
    unittest.main()
```

- [ ] **Step 2: Run it to see it fail**

Run: `python3 -m pytest tests/test_msam_browser_space.py -q`
Expected: every test fails (`sh` cannot open the script).

- [ ] **Step 3: Write the script**

```sh
#!/bin/sh
# AI Manager browser space.
#
# Runs as the only process of a Herdr pane and marks that pane out: every cell
# is filled, and the top left says which browser space this is and how big the
# pane is. AI Manager finds the mark in the terminal it draws and lays its
# browser over exactly these cells. Any other terminal attached to the same
# Herdr shows this fill instead.
id=${1:-000000}
pid=

draw() {
    size=$(stty size 2>/dev/null) || return
    rows=${size% *}
    cols=${size#* }
    [ "$rows" -gt 0 ] 2>/dev/null && [ "$cols" -gt 0 ] 2>/dev/null || return
    fill=$(printf '%*s' "$cols" '' | sed 's/ /░/g')
    mark="[[AIM-BROWSER $id ${cols}x${rows}]]"
    printf '\033[?25l'
    r=1
    while [ "$r" -le "$rows" ]; do
        printf '\033[%d;1H%s' "$r" "$fill"
        r=$((r + 1))
    done
    # A mark cut short would be read as nothing at all, so leave it out.
    [ "${#mark}" -le "$cols" ] && printf '\033[1;1H%s' "$mark"
}

trap draw WINCH
# A stray Ctrl-C must not close the space. Herdr closes a pane with a hangup.
trap '' INT QUIT TSTP
trap 'kill "$pid" 2>/dev/null; exit 0' HUP TERM
stty -echo 2>/dev/null
draw
while :; do
    sleep 86400 &
    pid=$!
    wait "$pid"
    # wait came back because the pane was resized: one sleeper, not one per resize.
    kill "$pid" 2>/dev/null
done
```

- [ ] **Step 4: Run it to see it pass**

Run: `python3 -m pytest tests/test_msam_browser_space.py -q`
Expected: `7 passed`.

- [ ] **Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Resources/msam-browser-space.sh tests/test_msam_browser_space.py
git commit -m "feat(browser): a placeholder that marks out a Herdr pane for the browser"
```

---

### Task 2: Marker, region, locator and geometry

**Files:**
- Create: `Core/BrowserSpaceLocator.swift`
- Test: `Tests/BrowserSpaceLocatorTests.swift`

**Interfaces:**
- Produces:
  - `struct BrowserSpaceRegion: Equatable, Identifiable, Sendable { let id: String; let column: Int; let row: Int; let columns: Int; let rows: Int }`
  - `enum BrowserSpaceMarker { static let prefix: String; static let fill: Character; static func text(id:columns:rows:) -> String }`
  - `enum BrowserSpaceLocator { static func regions(in grid: [[Character]]) -> [BrowserSpaceRegion]; static func regions(in rows: [TerminalRenderedRow]) -> [BrowserSpaceRegion] }`
  - `enum BrowserSpaceGeometry { static func frame(of: BrowserSpaceRegion, cell: CGSize) -> CGRect }`
  - `extension TerminalRenderedRow { var cells: [Character] }`

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct BrowserSpaceLocatorTests {
    /// A screen like Herdr's: a sidebar, its border, and a pane to the right of it.
    private func screen(columns: Int = 60, rows: Int = 12,
                        pane: (column: Int, row: Int, columns: Int, rows: Int)? = (20, 1, 40, 11),
                        id: String = "7f3a2c") -> [[Character]] {
        var grid = (0..<rows).map { row -> [Character] in
            let sidebar = row == 0 ? " spaces" : (row == 5 ? " new            menu" : "")
            return Array((sidebar.padding(toLength: 19, withPad: " ", startingAt: 0) + "│")
                .padding(toLength: columns, withPad: " ", startingAt: 0))
        }
        if let pane {
            for row in pane.row..<pane.row + pane.rows {
                for column in pane.column..<pane.column + pane.columns { grid[row][column] = BrowserSpaceMarker.fill }
            }
            let marker = Array(BrowserSpaceMarker.text(id: id, columns: pane.columns, rows: pane.rows))
            grid[pane.row].replaceSubrange(pane.column..<pane.column + marker.count, with: marker)
        }
        return grid
    }

    @Test func aPaneThatIsWhollyFillIsFoundWhereItsMarkerIs() {
        #expect(BrowserSpaceLocator.regions(in: screen())
                == [BrowserSpaceRegion(id: "7f3a2c", column: 20, row: 1, columns: 40, rows: 11)])
    }

    @Test func aScreenWithoutAMarkerHasNoRegion() {
        #expect(BrowserSpaceLocator.regions(in: screen(pane: nil)).isEmpty)
    }

    @Test func somethingDrawnOverThePaneHidesIt() {
        var grid = screen()
        // A Herdr menu in the middle of the pane, nowhere near the marker.
        grid[6].replaceSubrange(30..<36, with: Array("┌────┐"))
        #expect(BrowserSpaceLocator.regions(in: grid).isEmpty)
    }

    @Test func aPaneThatRunsOffTheScreenIsNotShown() {
        var grid = screen()
        grid.removeLast(2)
        #expect(BrowserSpaceLocator.regions(in: grid).isEmpty)
    }

    @Test func aMarkerWhoseSizeIsWiderThanWhatIsFilledIsNotShown() {
        var grid = screen()
        let lying = Array(BrowserSpaceMarker.text(id: "7f3a2c", columns: 41, rows: 11))
        grid[1].replaceSubrange(20..<20 + lying.count, with: lying)
        #expect(BrowserSpaceLocator.regions(in: grid).isEmpty)
    }

    @Test func twoPanesSideBySideAreBothFound() {
        // Wide enough for both markers: a marker is 28 cells.
        var grid = screen(columns: 100, pane: (20, 1, 39, 11), id: "aaaaaa")
        for row in 1..<12 {
            for column in 60..<100 { grid[row][column] = BrowserSpaceMarker.fill }
        }
        let marker = Array(BrowserSpaceMarker.text(id: "bbbbbb", columns: 40, rows: 11))
        grid[1].replaceSubrange(60..<60 + marker.count, with: marker)
        #expect(BrowserSpaceLocator.regions(in: grid).map(\.id) == ["aaaaaa", "bbbbbb"])
    }

    @Test(arguments: [
        "[[AIM-BROWSER 7f3a2c 40x11",          // cut short
        "[[AIM-BROWSER 7f3a2c 40]]",           // no rows
        "[[AIM-BROWSER zzzzzz 40x11]]",        // not an id
        "[[AIM-BROWSER 7f3a2c 0x11]]",         // no width
        "see [[AIM-BROWSER]] in the docs",     // talked about, in a shell
    ])
    func textThatOnlyLooksLikeAMarkerIsNotOne(text: String) {
        var grid = screen()
        let cells = Array(text.padding(toLength: 40, withPad: "░", startingAt: 0))
        grid[1].replaceSubrange(20..<60, with: cells)
        #expect(BrowserSpaceLocator.regions(in: grid).isEmpty)
    }

    @Test func aRegionIsLaidOutOnItsCells() {
        let region = BrowserSpaceRegion(id: "7f3a2c", column: 26, row: 1, columns: 113, rows: 39)
        #expect(BrowserSpaceGeometry.frame(of: region, cell: CGSize(width: 8, height: 17))
                == CGRect(x: 208, y: 17, width: 904, height: 663))
    }

    @MainActor @Test func theTerminalsOwnRowsAreRead() {
        // What the placeholder writes, through the app's terminal.
        let emulator = TerminalEmulator(cols: 60, rows: 12, frameClock: TestTerminalFrameClock())
        _ = emulator.setVisibility(true, for: TerminalVisibilityOwner())
        var bytes = "\u{1b}[?1049h"
        for row in 1...10 { bytes += "\u{1b}[\(row);1H" + String(repeating: "░", count: 60) }
        bytes += "\u{1b}[1;1H" + BrowserSpaceMarker.text(id: "7f3a2c", columns: 60, rows: 10)
        emulator.feed(Data(bytes.utf8))
        emulator.tick()

        #expect(BrowserSpaceLocator.regions(in: emulator.lines)
                == [BrowserSpaceRegion(id: "7f3a2c", column: 0, row: 0, columns: 60, rows: 10)])
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run the `BrowserSpaceLocatorTests` suite (see Global Constraints). Expected: does not compile (`BrowserSpaceLocator` is not defined). Add empty stubs returning `[]` / `.zero` to see the assertions themselves fail, then continue.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics
import Foundation

/// One browser pane as the terminal shows it: where its placeholder is and how
/// big the placeholder says its pane is.
struct BrowserSpaceRegion: Equatable, Identifiable, Sendable {
    /// The id its space was opened with.
    let id: String
    /// Top left cell.
    let column: Int
    let row: Int
    /// Size in cells, as the placeholder measured its own pane.
    let columns: Int
    let rows: Int
}

/// What the placeholder paints (`Resources/msam-browser-space.sh`).
enum BrowserSpaceMarker {
    static let prefix = "[[AIM-BROWSER "
    static let fill: Character = "░"

    static func text(id: String, columns: Int, rows: Int) -> String {
        "\(prefix)\(id) \(columns)x\(rows)]]"
    }

    /// Reads a whole marker that starts at `start` of a row.
    static func parse(_ cells: [Character], at start: Int) -> (id: String, columns: Int, rows: Int, length: Int)? {
        let opening = Array(prefix)
        let bodyStart = start + opening.count
        guard start >= 0, bodyStart < cells.count, Array(cells[start..<bodyStart]) == opening else { return nil }
        // An id of at most twelve characters and two numbers of at most five digits.
        let limit = min(cells.count - 1, bodyStart + 26)
        guard bodyStart < limit,
              let close = (bodyStart..<limit).first(where: { cells[$0] == "]" && cells[$0 + 1] == "]" }) else {
            return nil
        }
        let parts = String(cells[bodyStart..<close]).split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let size = parts[1].split(separator: "x", omittingEmptySubsequences: false)
        guard !parts[0].isEmpty, parts[0].count <= 12, parts[0].allSatisfy(\.isHexDigit),
              size.count == 2, let columns = Int(size[0]), let rows = Int(size[1]),
              columns > 0, rows > 0 else { return nil }
        return (String(parts[0]), columns, rows, close + 2 - start)
    }
}

enum BrowserSpaceLocator {
    /// The browser panes that are wholly visible, in a grid of one array of
    /// cells per row.
    ///
    /// A pane counts only when every cell of the rectangle its marker claims is
    /// the fill, the marker apart. Anything else there (a Herdr menu over the
    /// pane, half of a repaint, a rectangle that runs off the screen) means the
    /// pane is not all there to be covered.
    static func regions(in grid: [[Character]]) -> [BrowserSpaceRegion] {
        let opening = Array(BrowserSpaceMarker.prefix)
        var found: [BrowserSpaceRegion] = []
        for (row, cells) in grid.enumerated() {
            var from = 0
            while let start = firstIndex(of: opening, in: cells, from: from) {
                from = start + 1
                guard let marker = BrowserSpaceMarker.parse(cells, at: start) else { continue }
                let region = BrowserSpaceRegion(id: marker.id, column: start, row: row,
                                                columns: marker.columns, rows: marker.rows)
                guard isWhollyFill(region, markerLength: marker.length, in: grid) else { continue }
                found.append(region)
                from = start + marker.columns
            }
        }
        return found
    }

    /// The same for the terminal's rendered rows. A screen without a browser
    /// costs one search per row.
    static func regions(in rows: [TerminalRenderedRow]) -> [BrowserSpaceRegion] {
        guard rows.contains(where: { $0.plainText.contains(BrowserSpaceMarker.prefix) }) else { return [] }
        return regions(in: rows.map(\.cells))
    }

    private static func firstIndex(of pattern: [Character], in cells: [Character], from: Int) -> Int? {
        guard !pattern.isEmpty, cells.count >= pattern.count, from <= cells.count - pattern.count else { return nil }
        return (from...cells.count - pattern.count).first { start in
            cells[start] == pattern[0] && Array(cells[start..<start + pattern.count]) == pattern
        }
    }

    private static func isWhollyFill(_ region: BrowserSpaceRegion, markerLength: Int, in grid: [[Character]]) -> Bool {
        guard markerLength <= region.columns, region.row + region.rows <= grid.count else { return false }
        for row in region.row..<region.row + region.rows {
            let cells = grid[row]
            guard region.column + region.columns <= cells.count else { return false }
            let first = row == region.row ? region.column + markerLength : region.column
            for column in first..<region.column + region.columns where cells[column] != BrowserSpaceMarker.fill {
                return false
            }
        }
        return true
    }
}

enum BrowserSpaceGeometry {
    /// Where a region is on screen. Herdr runs on the alternate screen, which the
    /// terminal view pins to its top left with no inset, so cells map straight
    /// to points.
    static func frame(of region: BrowserSpaceRegion, cell: CGSize) -> CGRect {
        CGRect(x: CGFloat(region.column) * cell.width, y: CGFloat(region.row) * cell.height,
               width: CGFloat(region.columns) * cell.width, height: CGFloat(region.rows) * cell.height)
    }
}

extension TerminalRenderedRow {
    /// One character per column, the way `character(atColumn:)` counts them.
    var cells: [Character] {
        var cells: [Character] = []
        for run in runs {
            let text = run.isPadding ? [] : Array(run.text.prefix(run.columns))
            cells.append(contentsOf: text)
            if text.count < run.columns {
                cells.append(contentsOf: repeatElement(" ", count: run.columns - text.count))
            }
        }
        return cells
    }
}
```

- [ ] **Step 4: Run to see them pass**

Run the `BrowserSpaceLocatorTests` suite. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core/BrowserSpaceLocator.swift app/MultiSessionAIManager/Tests/BrowserSpaceLocatorTests.swift
git commit -m "feat(browser): find a browser space's pane in the terminal grid"
```

---

### Task 3: Opening a browser space on the host

**Files:**
- Create: `Core/BrowserSpaceCommands.swift`
- Test: `Tests/BrowserSpaceCommandsTests.swift`

**Interfaces:**
- Consumes: `SSHService.run(_:timeout:outputLimit:) async throws -> SSHCommandResult` (`exitStatus`, `stdoutString`, `stderrString`), `SSHService.isWindows`, `POSIXShell.quote(_:)`, `FakeSSHTransport` (`structuredCommandResults`, `structuredCommandsRun`).
- Produces:
  - `enum BrowserSpaceCommands { static func createSpace(sessionName: String?) -> String; static func paneID(fromAnswer: String) -> String?; static func runPlaceholder(script: String, paneID: String, id: String, sessionName: String?) -> String; static func newID() -> String }`
  - `enum BrowserSpaceOpenError: Error, LocalizedError, Equatable { case windowsHost, herdr(String) }`
  - `enum BrowserSpaceOpener { static func open(using: SSHService, sessionName: String?, script: String, id: String) async throws -> String; static func bundledPlaceholder() -> String? }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct BrowserSpaceCommandsTests {
    private static let created = #"{"id":"cli:workspace:create","result":{"root_pane":{"pane_id":"w2:p1","tab_id":"w2:t1"},"type":"workspace_created","workspace":{"workspace_id":"w2"}}}"#

    @Test func theSpaceIsCreatedInTheTabsOwnSessionAndSelected() {
        #expect(BrowserSpaceCommands.createSpace(sessionName: nil)
                == "herdr workspace create --label 'Browser' --focus")
        #expect(BrowserSpaceCommands.createSpace(sessionName: "night shift")
                == "herdr --session 'night shift' workspace create --label 'Browser' --focus")
    }

    @Test func thePaneIsReadFromHerdrsAnswer() {
        #expect(BrowserSpaceCommands.paneID(fromAnswer: Self.created) == "w2:p1")
        // A login shell may print before it.
        #expect(BrowserSpaceCommands.paneID(fromAnswer: "motd\n" + Self.created + "\n") == "w2:p1")
    }

    @Test(arguments: ["", "herdr: no server running", #"{"result":{"root_pane":{"pane_id":"w2;rm -rf"}}}"#])
    func anAnswerWithoutAUsablePaneGivesNone(answer: String) {
        #expect(BrowserSpaceCommands.paneID(fromAnswer: answer) == nil)
    }

    @Test func thePlaceholderIsWrittenAndMadeThePanesProcess() {
        let command = BrowserSpaceCommands.runPlaceholder(
            script: "#!/bin/sh\necho 'it'\n", paneID: "w2:p1", id: "7f3a2c", sessionName: "work")
        let lines = command.components(separatedBy: "\n")
        #expect(lines.first == #"mkdir -p "$HOME/.local/share/msam" && cat > "$HOME/.local/share/msam/browser-space.sh" <<'AIM_BROWSER_SPACE_END'"#)
        #expect(lines.contains("echo 'it'"), "The script goes in as it is, unquoted by the here-document")
        #expect(lines.contains("AIM_BROWSER_SPACE_END"))
        #expect(lines.last == #"herdr --session 'work' pane run 'w2:p1' 'exec sh "$HOME/.local/share/msam/browser-space.sh" 7f3a2c'"#)
    }

    @Test func anIdIsSixHexDigits() {
        for _ in 0..<50 {
            let id = BrowserSpaceCommands.newID()
            #expect(id.count == 6 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(id)")
        }
    }

    private func service() async throws -> (SSHService, FakeSSHTransport) {
        let transport = FakeSSHTransport()
        let host = Host(name: "Forge", address: "192.0.2.24", port: 22, username: "alice", keyID: "test-key", defaultWorkdir: "/")
        let defaults = try #require(UserDefaults(suiteName: "browser-space-\(UUID().uuidString)"))
        let service = SSHService(host: host, transport: transport, knownHosts: KnownHostsStore(defaults: defaults))
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))) { _, _ in true }
        return (service, transport)
    }

    private func result(_ status: Int32, _ out: String = "", _ err: String = "") -> Result<SSHCommandResult, SSHCommandExecutionError> {
        .success(SSHCommandResult(exitStatus: status, stdout: Data(out.utf8), stderr: Data(err.utf8)))
    }

    @Test func openingCreatesTheSpaceThenRunsThePlaceholderInItsPane() async throws {
        let (service, transport) = try await service()
        transport.structuredCommandResults = [result(0, Self.created), result(0)]

        let id = try await BrowserSpaceOpener.open(using: service, sessionName: nil, script: "#!/bin/sh\n", id: "7f3a2c")

        #expect(id == "7f3a2c")
        let commands = transport.structuredCommandsRun.map(\.command)
        #expect(commands.count == 2)
        #expect(commands.first?.contains("workspace create --label") == true)
        #expect(commands.last?.contains("pane run") == true && commands.last?.contains("w2:p1") == true)
    }

    @Test func aHerdrThatRefusesIsQuoted() async throws {
        let (service, transport) = try await service()
        transport.structuredCommandResults = [result(1, "", "herdr: no server running\n")]

        await #expect(throws: BrowserSpaceOpenError.herdr("herdr: no server running")) {
            _ = try await BrowserSpaceOpener.open(using: service, sessionName: nil, script: "#!/bin/sh\n", id: "7f3a2c")
        }
        #expect(transport.structuredCommandsRun.count == 1, "Nothing is run in a pane that was not made")
    }

    @Test func theErrorsReadAsSentences() {
        #expect(BrowserSpaceOpenError.windowsHost.errorDescription == "Browser spaces need a Unix host.")
        #expect(BrowserSpaceOpenError.herdr("herdr: no server running").errorDescription == "herdr: no server running")
        #expect(BrowserSpaceOpenError.herdr("").errorDescription == "Herdr did not create the space.")
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run the `BrowserSpaceCommandsTests` suite. Expected: does not compile; with stubs, the assertions fail.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The host commands that open a browser space in the Herdr session a tab is
/// attached to.
enum BrowserSpaceCommands {
    static let label = "Browser"
    static let scriptPath = "$HOME/.local/share/msam/browser-space.sh"

    /// `herdr`, speaking to the tab's own session.
    private static func herdr(_ sessionName: String?) -> String {
        guard let sessionName, !sessionName.isEmpty else { return "herdr" }
        return "herdr --session \(POSIXShell.quote(sessionName))"
    }

    /// Creates the space and selects it. Herdr answers with JSON naming its pane.
    static func createSpace(sessionName: String?) -> String {
        "\(herdr(sessionName)) workspace create --label \(POSIXShell.quote(label)) --focus"
    }

    /// The pane of the space Herdr just created.
    static func paneID(fromAnswer answer: String) -> String? {
        struct Answer: Decodable {
            struct Result: Decodable {
                struct Pane: Decodable { let pane_id: String }
                let root_pane: Pane
            }
            let result: Result
        }
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let decoded = try? JSONDecoder().decode(Answer.self, from: Data(answer[start...end].utf8)) else {
            return nil
        }
        let pane = decoded.result.root_pane.pane_id
        // It goes into a command line next.
        let allowed = pane.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ":._-".contains($0)) }
        return !pane.isEmpty && allowed ? pane : nil
    }

    /// Puts this build's placeholder on the host and makes it the pane's process:
    /// with `exec`, closing the space ends the placeholder and the reverse.
    static func runPlaceholder(script: String, paneID: String, id: String, sessionName: String?) -> String {
        let run = "exec sh \"\(scriptPath)\" \(id)"
        return [
            "mkdir -p \"$HOME/.local/share/msam\" && cat > \"\(scriptPath)\" <<'AIM_BROWSER_SPACE_END'",
            script.trimmingCharacters(in: .newlines),
            "AIM_BROWSER_SPACE_END",
            "\(herdr(sessionName)) pane run \(POSIXShell.quote(paneID)) \(POSIXShell.quote(run))",
        ].joined(separator: "\n")
    }

    static func newID() -> String {
        String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
    }
}

enum BrowserSpaceOpenError: Error, LocalizedError, Equatable {
    case windowsHost
    /// Herdr's own words, when it had any.
    case herdr(String)

    var errorDescription: String? {
        switch self {
        case .windowsHost: "Browser spaces need a Unix host."
        case .herdr(let words): words.isEmpty ? "Herdr did not create the space." : words
        }
    }
}

enum BrowserSpaceOpener {
    /// Opens a browser space in the tab's Herdr session and returns its id.
    @discardableResult
    static func open(using service: SSHService, sessionName: String?, script: String,
                     id: String = BrowserSpaceCommands.newID()) async throws -> String {
        guard !service.isWindows else { throw BrowserSpaceOpenError.windowsHost }
        let created = try await service.run(BrowserSpaceCommands.createSpace(sessionName: sessionName),
                                            timeout: .seconds(20))
        guard created.exitStatus == 0,
              let pane = BrowserSpaceCommands.paneID(fromAnswer: created.stdoutString) else {
            throw BrowserSpaceOpenError.herdr(words(of: created))
        }
        let ran = try await service.run(
            BrowserSpaceCommands.runPlaceholder(script: script, paneID: pane, id: id, sessionName: sessionName),
            timeout: .seconds(20))
        guard ran.exitStatus == 0 else { throw BrowserSpaceOpenError.herdr(words(of: ran)) }
        return id
    }

    static func bundledPlaceholder() -> String? {
        Bundle.main.url(forResource: "msam-browser-space", withExtension: "sh")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static func words(of result: SSHCommandResult) -> String {
        let said = result.stderrString.isEmpty ? result.stdoutString : result.stderrString
        return String(said.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }
}
```

- [ ] **Step 4: Run to see them pass**, including a test that the script is in the bundle:

Add to the suite and run:

```swift
    @Test func thisBuildCarriesThePlaceholder() throws {
        let script = try #require(BrowserSpaceOpener.bundledPlaceholder())
        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(script.contains("[[AIM-BROWSER $id ${cols}x${rows}]]"))
    }
```

Expected: all pass. (`Resources/` is a resource folder in `project.yml`; `xcodegen generate` picks the new file up.)

- [ ] **Step 5: Check it against a real Herdr** (throwaway, nothing committed)

In a throwaway Herdr session on Forge (pattern: scratchpad `space_probe2.py`), run the exact strings `createSpace(sessionName:)` and `runPlaceholder(...)` produce through `sh -c`, then `herdr pane read <pane> --source visible` must show the marker with the pane's size. Fix the commands, not the probe, if it does not.

- [ ] **Step 6: Commit**

```bash
git add app/MultiSessionAIManager/Core/BrowserSpaceCommands.swift app/MultiSessionAIManager/Tests/BrowserSpaceCommandsTests.swift
git commit -m "feat(browser): open a browser space in the tab's Herdr session"
```

---

### Task 4: Herdr's "new", found by its text

**Files:**
- Create: `Core/TerminalNewSpaceButton.swift`
- Test: `Tests/TerminalNewSpaceButtonTests.swift`

**Interfaces:**
- Produces: `enum TerminalNewSpaceButton { static func isHit(column: Int, row: [Character]) -> Bool }`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import MultiSessionAIManager

@Suite struct TerminalNewSpaceButtonTests {
    /// Row 19 of a real Herdr 0.9.5 screen, 140 columns wide.
    private let row = Array(" new                 menu│" + String(repeating: "░", count: 114))

    @Test(arguments: [0, 1, 2, 3, 4])
    func aTapOnTheWordOrRightBesideItCounts(column: Int) {
        #expect(TerminalNewSpaceButton.isHit(column: column, row: row))
    }

    @Test(arguments: [5, 12, 21, 24, 25, 60])
    func aTapElsewhereOnTheRowDoesNot(column: Int) {
        #expect(!TerminalNewSpaceButton.isHit(column: column, row: row))
    }

    @Test(arguments: [
        " · scratchpad            │",        // a space in the list
        " new                     │",        // not Herdr's row: no "menu"
        " new project         menu│",        // three words
        " agents           grouped│",
        "new menu",                           // no sidebar border: a shell line
        "│ new                menu",          // the words are in a pane, not the sidebar
        "",
    ])
    func otherRowsAreNotTheButton(text: String) {
        #expect(!TerminalNewSpaceButton.isHit(column: 1, row: Array(text)))
        #expect(!TerminalNewSpaceButton.isHit(column: 2, row: Array(text)))
    }
}
```

- [ ] **Step 2: Run to see them fail** (`TerminalNewSpaceButtonTests`; stub returning `false` first).

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Herdr's "new" under its list of spaces.
///
/// Herdr draws its sidebar inside the terminal, so the app can only know the
/// label by what the row says: the sidebar's part of the row, up to its
/// border, reads `new` … `menu` and nothing else. When no row reads like that
/// (a collapsed sidebar, a Herdr that words it differently) nothing matches
/// and a tap goes to Herdr as it always did.
enum TerminalNewSpaceButton {
    static func isHit(column: Int, row cells: [Character]) -> Bool {
        guard let border = cells.firstIndex(of: "│") else { return false }
        let sidebar = cells[..<border]
        let words = String(sidebar).split(separator: " ")
        guard words.count == 2, words[0] == "new", words[1] == "menu",
              let start = sidebar.firstIndex(where: { $0 != " " }) else { return false }
        // The word and one cell either side: a finger is not a pointer.
        return (start - 1...start + 3).contains(column)
    }
}
```

- [ ] **Step 4: Run to see them pass.**

- [ ] **Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core/TerminalNewSpaceButton.swift app/MultiSessionAIManager/Tests/TerminalNewSpaceButtonTests.swift
git commit -m "feat(browser): recognise Herdr's \"new\" in the sidebar"
```

---

### Task 5: The model (what is shown, what is kept)

**Files:**
- Move: `UI/WebTunnel/HostBrowserScreen.swift` → `UI/Browser/HostBrowserPage.swift`, keeping only `HostBrowserPage` and `HostBrowserWebView` (drop `private` from `HostBrowserWebView`). `HostBrowserScreen` is deleted in Task 7; until then leave it in `UI/WebTunnel/HostBrowserScreen.swift`.
- Create: `Core/BrowserSpaceModel.swift`
- Modify: `Core/HerdrHostSession.swift` (add `let browserSpaces: BrowserSpaceModel`, set in `init` from `connection.host.id`)
- Test: `Tests/BrowserSpaceModelTests.swift`

**Interfaces:**
- Consumes: `BrowserSpaceRegion`, `HostBrowserPage`.
- Produces:
  - `@MainActor @Observable final class BrowserSpaceModel { init(hostID: UUID, defaults: UserDefaults = .standard, grace: Duration = .milliseconds(120)); private(set) var regions: [BrowserSpaceRegion]; func show(_ located: [BrowserSpaceRegion]); func page(for id: String) -> HostBrowserPage; func savedAddress(for id: String) -> String?; func remember(address: String, for id: String); static let savedLimit = 12 }`
  - `HerdrHostSession.browserSpaces`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct BrowserSpaceModelTests {
    private let host = UUID()
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "browser-space-model-\(UUID().uuidString)")! }
    private func region(_ id: String = "7f3a2c", column: Int = 26, columns: Int = 113) -> BrowserSpaceRegion {
        BrowserSpaceRegion(id: id, column: column, row: 1, columns: columns, rows: 39)
    }

    /// Whether `condition` came true within two seconds.
    private func soon(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    @Test func aPaneThatAppearsIsShownAtOnce() {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults())
        model.show([region()])
        #expect(model.regions == [region()])
    }

    @Test func aPaneThatMovesIsFollowedAtOnce() {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults())
        model.show([region()])
        model.show([region(column: 0, columns: 139)])
        #expect(model.regions == [region(column: 0, columns: 139)])
    }

    @Test func aPaneThatDisappearsIsDroppedAfterAMomentNotAtOnce() async {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults(), grace: .milliseconds(60))
        model.show([region()])
        model.show([])
        #expect(model.regions == [region()], "A repaint must not flicker the page")
        #expect(await soon { model.regions.isEmpty })
    }

    @Test func aPaneThatComesBackWithinTheMomentStays() async throws {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults(), grace: .milliseconds(60))
        model.show([region()])
        model.show([])
        model.show([region()])
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.regions == [region()])
    }

    @Test func aSpacesPageIsTheSameOneWhenItComesBack() async {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults(), grace: .milliseconds(10))
        let page = model.page(for: "7f3a2c")
        model.show([region()])
        model.show([])
        _ = await soon { model.regions.isEmpty }
        model.show([region()])
        #expect(model.page(for: "7f3a2c") === page)
        #expect(model.page(for: "bbbbbb") !== page)
    }

    @Test func aSpacesAddressOutlivesTheApp() {
        let store = defaults()
        BrowserSpaceModel(hostID: host, defaults: store).remember(address: "http://grafana.internal:3000/d/1", for: "7f3a2c")

        let relaunched = BrowserSpaceModel(hostID: host, defaults: store)
        #expect(relaunched.savedAddress(for: "7f3a2c") == "http://grafana.internal:3000/d/1")
        #expect(relaunched.savedAddress(for: "bbbbbb") == nil)
        #expect(BrowserSpaceModel(hostID: UUID(), defaults: store).savedAddress(for: "7f3a2c") == nil,
                "Another host's spaces are its own")
    }

    @Test func onlyTheNewestAddressesAreKept() {
        let store = defaults()
        let model = BrowserSpaceModel(hostID: host, defaults: store)
        for index in 0..<(BrowserSpaceModel.savedLimit + 3) {
            model.remember(address: "http://site\(index)/", for: String(format: "%06x", index))
        }
        model.remember(address: "http://site3/again", for: "000003")   // used again: newest

        let relaunched = BrowserSpaceModel(hostID: host, defaults: store)
        #expect(relaunched.savedAddress(for: "000000") == nil)
        #expect(relaunched.savedAddress(for: "000002") == nil)
        #expect(relaunched.savedAddress(for: "000003") == "http://site3/again")
        #expect(relaunched.savedAddress(for: "00000e") == "http://site14/")
    }
}
```

- [ ] **Step 2: Run to see them fail** (`BrowserSpaceModelTests`; stub the class with empty methods first).

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

/// The browser spaces of one host tab: which are on screen, their pages, and
/// the address each showed last.
@MainActor
@Observable
final class BrowserSpaceModel {
    static let savedLimit = 12

    /// The browser panes to draw now.
    private(set) var regions: [BrowserSpaceRegion] = []

    @ObservationIgnored private var pages: [String: HostBrowserPage] = [:]
    @ObservationIgnored private var leaving: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private let grace: Duration

    /// - Parameter grace: how long a pane that is no longer found stays drawn.
    ///   Herdr repaints in pieces; a page that vanished for one of them would
    ///   flicker. Short enough that a Herdr menu gets its space at once.
    init(hostID: UUID, defaults: UserDefaults = .standard, grace: Duration = .milliseconds(120)) {
        self.defaults = defaults
        self.key = "msam.browser-spaces.\(hostID.uuidString.lowercased())"
        self.grace = grace
    }

    /// Takes what the terminal shows now.
    func show(_ located: [BrowserSpaceRegion]) {
        for region in located {
            leaving.removeValue(forKey: region.id)?.cancel()
            if let index = regions.firstIndex(where: { $0.id == region.id }) {
                if regions[index] != region { regions[index] = region }
            } else {
                regions.append(region)
            }
        }
        let visible = Set(located.map(\.id))
        for region in regions where !visible.contains(region.id) && leaving[region.id] == nil {
            let id = region.id
            leaving[id] = Task { [weak self, grace] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled, let self else { return }
                self.leaving[id] = nil
                self.regions.removeAll { $0.id == id }
            }
        }
    }

    /// The page of a space, kept while its space is off screen.
    func page(for id: String) -> HostBrowserPage {
        if let page = pages[id] { return page }
        let page = HostBrowserPage()
        pages[id] = page
        return page
    }

    // MARK: Addresses, oldest first

    private var saved: [[String]] {
        (defaults.array(forKey: key) as? [[String]] ?? []).filter { $0.count == 2 }
    }

    func savedAddress(for id: String) -> String? {
        saved.last { $0[0] == id }?[1]
    }

    func remember(address: String, for id: String) {
        guard savedAddress(for: id) != address || saved.last?[0] != id else { return }
        var entries = saved.filter { $0[0] != id }
        entries.append([id, address])
        defaults.set(Array(entries.suffix(Self.savedLimit)), forKey: key)
    }
}
```

In `Core/HerdrHostSession.swift` add the stored property next to `terminal` and set it in `init`:

```swift
    /// The browser spaces of this tab's Herdr session. Here, not in a view: the
    /// pages must outlive SwiftUI swapping the compact and regular layouts.
    let browserSpaces: BrowserSpaceModel
    // in init, after `self.terminal = terminal`:
        self.browserSpaces = BrowserSpaceModel(hostID: connection.host.id)
```

- [ ] **Step 4: Run to see them pass** (`BrowserSpaceModelTests`, plus `RootViewModelTests` for the session change).

- [ ] **Step 5: Commit**

```bash
git add -A app/MultiSessionAIManager/UI/Browser app/MultiSessionAIManager/UI/WebTunnel/HostBrowserScreen.swift app/MultiSessionAIManager/Core/BrowserSpaceModel.swift app/MultiSessionAIManager/Core/HerdrHostSession.swift app/MultiSessionAIManager/Tests/BrowserSpaceModelTests.swift
git commit -m "feat(browser): keep each browser space's page and address"
```

---

### Task 6: The browser in a pane, laid over the terminal

**Files:**
- Create: `UI/Browser/HostBrowserPane.swift`, `UI/Browser/BrowserSpaceOverlay.swift`
- Modify: `UI/RootView.swift` (`HostTerminalView`: scan and overlay; `RootView`: stop a host's proxy with its last tab)
- Test: `Tests/BrowserSpaceOverlayTests.swift`

**Interfaces:**
- Consumes: `BrowserSpaceModel`, `BrowserSpaceLocator.regions(in: [TerminalRenderedRow])`, `BrowserSpaceGeometry.frame(of:cell:)`, `HostBrowserPage`, `HostBrowserWebView`, `HostBrowseModel` (`state`, `start()`, `stop()`), `HostBrowserAddress.url(from:)`, `PortForwardingManager.session(for:)` / `.sessions`, `session.terminal.fontMetrics.boundingBox`, `session.terminal.renderGeneration`.
- Produces: `struct HostBrowserPane: View { init(spaceID: String, page: HostBrowserPage, forwarding: PortForwardingSession, spaces: BrowserSpaceModel) }`, `struct BrowserSpaceOverlay: View { init(spaces: BrowserSpaceModel, host: Host, cell: CGSize) }`.

- [ ] **Step 1: Write the failing test** (the pane restores and records its address; drawn through a real hosting controller so `.onChange` runs)

```swift
import SwiftUI
import Testing
import UIKit
@testable import MultiSessionAIManager

@Suite(.serialized) @MainActor struct BrowserSpaceOverlayTests {
    private func forwarding() throws -> PortForwardingSession {
        let keys = KeyStore(backing: InMemoryKeychain())
        let host = Host(name: "Forge", address: "10.0.0.1", username: "alice",
                        keyID: try keys.generateEd25519(label: "browse"), defaultWorkdir: "/home/alice")
        return PortForwardingSession(
            host: host, keyStore: keys,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.overlay.\(UUID())")!),
            tunnels: [], transport: FakeSSHTransport(),
            keepAlive: .init(interval: .seconds(3600), probeTimeout: .seconds(1)))
    }

    private func soon(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func aPaneStartsBrowsingAndOpensWhatItsSpaceShowedLast() async throws {
        let session = try forwarding()
        let spaces = BrowserSpaceModel(hostID: session.host.id,
                                       defaults: UserDefaults(suiteName: "msam.overlay.\(UUID())")!)
        spaces.remember(address: "http://grafana.internal:3000/", for: "7f3a2c")
        let page = spaces.page(for: "7f3a2c")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        window.rootViewController = UIHostingController(
            rootView: HostBrowserPane(spaceID: "7f3a2c", page: page, forwarding: session, spaces: spaces))
        window.isHidden = false
        defer { window.isHidden = true }

        #expect(await soon { if case .ready = session.browse.state { true } else { false } },
                "The pane starts the host's proxy itself")
        #expect(await soon { page.webView != nil && page.isLoading || page.failure != nil || page.hasPage },
                "The saved address is opened without being typed again")
        await session.shutdown()
    }
}
```

- [ ] **Step 2: Run to see it fail** (`BrowserSpaceOverlayTests`; does not compile until `HostBrowserPane` exists).

- [ ] **Step 3: Implement `HostBrowserPane`**

```swift
import SwiftUI

/// The browser of one browser space, sized to its pane: a row of controls and
/// the page. Every request is made by the host (`HostBrowseModel`).
struct HostBrowserPane: View {
    let spaceID: String
    let page: HostBrowserPage
    let forwarding: PortForwardingSession
    let spaces: BrowserSpaceModel

    @State private var address = ""
    @FocusState private var addressFocused: Bool

    private var browse: HostBrowseModel { forwarding.browse }
    private var hostName: String { forwarding.host.name }

    private var isReady: Bool {
        if case .ready = browse.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider().overlay(Theme.hairline)
            ZStack {
                Theme.bg
                content
            }
        }
        .background(Theme.bg)
        .clipped()
        .task { await browse.start() }
        .onChange(of: browse.state, initial: true) { _, state in
            guard case .ready(let endpoint) = state else { return }
            page.attach(to: endpoint, hostID: forwarding.host.id, hostName: hostName, browse: browse)
            // After a reconnect or a relaunch the space is back but its page is not.
            if !page.hasPage, !page.isLoading, page.failure == nil,
               let saved = spaces.savedAddress(for: spaceID), let url = HostBrowserAddress.url(from: saved) {
                page.load(url)
            }
        }
        .onChange(of: page.currentAddress, initial: true) { _, current in
            guard !current.isEmpty else { return }
            // Follow the page, but never overwrite what is being typed.
            if !addressFocused { address = current }
            spaces.remember(address: current, for: spaceID)
        }
        .accessibilityIdentifier("browser-space.\(spaceID)")
    }

    private var bar: some View {
        HStack(spacing: Theme.Space.sm) {
            Button { page.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!page.canGoBack)
                .accessibilityLabel("Back")
            Button { page.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!page.canGoForward)
                .accessibilityLabel("Forward")
            Button {
                if page.isLoading { page.stopLoading() } else { page.reload() }
            } label: {
                Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
            }
            .disabled(!page.hasPage && page.failure == nil)
            .accessibilityLabel(page.isLoading ? "Stop" : "Reload")
            Image(systemName: page.currentAddress.hasPrefix("https://") ? "lock.fill" : "globe")
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
            TextField("Address, as seen from \(hostName)", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .font(Theme.mono(13))
                .onSubmit(go)
                .accessibilityIdentifier("browser-space.address")
            if page.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: 34)
    }

    @ViewBuilder
    private var content: some View {
        switch browse.state {
        case .idle, .starting:
            VStack(spacing: Theme.Space.md) {
                ProgressView()
                Text("Connecting through \(hostName)…")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            notice(icon: "exclamationmark.triangle.fill", tint: Theme.danger,
                   title: "Browsing is not available", message: message) {
                Button("Try Again") { Task { await browse.start() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        case .ready:
            if let webView = page.webView {
                HostBrowserWebView(webView: webView)
                    .opacity(page.hasPage ? 1 : 0)
                if !page.hasPage, page.failure == nil, !page.isLoading {
                    notice(icon: "globe", tint: Theme.textMuted, title: "Type an address",
                           message: "Addresses are opened by \(hostName), and names are looked up there. A site that only exists on its network works; so do its links, sign-ins and redirects.") {
                        EmptyView()
                    }
                }
                if let failure = page.failure {
                    Theme.bg.opacity(0.94)
                    notice(icon: failure.canVisitAnyway ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill",
                           tint: failure.canVisitAnyway ? Theme.warning : Theme.danger,
                           title: failure.canVisitAnyway ? "This site's certificate is not trusted" : "The page did not load",
                           message: failure.message) {
                        HStack(spacing: Theme.Space.sm) {
                            Button("Try Again") { page.reload() }
                                .buttonStyle(.bordered)
                            if failure.canVisitAnyway {
                                // An explicit choice, for this site and port only, until the app is closed.
                                Button("Visit Anyway", role: .destructive) { page.visitAnyway() }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("browser-space.visit-anyway")
                            }
                        }
                    }
                }
            }
        }
    }

    private func notice<Actions: View>(icon: String, tint: Color, title: String, message: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.title(17))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .frame(maxWidth: 440)
        .padding(Theme.Space.lg)
    }

    private func go() {
        guard isReady, let url = HostBrowserAddress.url(from: address) else { return }
        addressFocused = false
        page.load(url)
    }
}
```

- [ ] **Step 4: Implement `BrowserSpaceOverlay`**

```swift
import SwiftUI

/// The browser panes of a host tab, each over the cells of its space's pane.
/// Touches inside a pane go to its browser; everywhere else they reach the
/// terminal underneath.
struct BrowserSpaceOverlay: View {
    let spaces: BrowserSpaceModel
    let host: Host
    /// The size of one terminal cell.
    let cell: CGSize

    @Environment(\.portForwardingManager) private var portForwarding
    @State private var forwarding: PortForwardingSession?

    /// The host's forwarding session can be shut down and made again ("Stop all").
    private var current: ObjectIdentifier? {
        portForwarding?.sessions[host.id].map(ObjectIdentifier.init)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let forwarding {
                ForEach(spaces.regions) { region in
                    let frame = BrowserSpaceGeometry.frame(of: region, cell: cell)
                    HostBrowserPane(spaceID: region.id, page: spaces.page(for: region.id),
                                    forwarding: forwarding, spaces: spaces)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Not in `body`: making the session changes the manager, which a view
        // being drawn must not do.
        .task(id: current) { forwarding = portForwarding?.session(for: host) }
    }
}
```

- [ ] **Step 5: Wire it into `HostTerminalView`** (`UI/RootView.swift`)

Inside the `ZStack`, directly after the `TerminalEmulatorView(...)` `.frame(...)` and before the pictures notice:

```swift
                if session.status == .live, !session.browserSpaces.regions.isEmpty {
                    BrowserSpaceOverlay(spaces: session.browserSpaces, host: session.connection.host,
                                        cell: session.terminal.fontMetrics.boundingBox)
                }
```

On the `ZStack` (after its closing brace):

```swift
            // The browser of a browser space goes wherever Herdr put that space's pane.
            .onChange(of: session.terminal.renderGeneration, initial: true) { _, _ in
                session.browserSpaces.show(BrowserSpaceLocator.regions(in: session.terminal.lines))
            }
```

In `RootView`, add `@Environment(\.portForwardingManager) private var portForwarding` and extend the existing `.onChange(of: tabStore.tabs.map(\.id))`:

```swift
        .onChange(of: tabStore.tabs.map(\.id)) { _, _ in
            Task { await tabs.retireSessions() }
            // A host with no tab left has no browser space left to serve.
            let open = Set(tabStore.tabs.map(\.hostID))
            for (hostID, forwarding) in portForwarding?.sessions ?? [:] where !open.contains(hostID) {
                Task { await forwarding.browse.stop() }
            }
        }
```

- [ ] **Step 6: Run** `BrowserSpaceOverlayTests`, `RootViewModelTests`, `HostBrowseConnectionTests`. Expected: pass.

- [ ] **Step 7: Look at it** (throwaway `Tests/ZZBrowserSpaceLookTests.swift` on the Mac): host `HostTerminalView` for a session whose `TerminalEmulator` was fed a screen with a marker and fill (as in Task 2's last test, with a sidebar to its left), take a `drawHierarchy` snapshot, copy the PNG to Forge and read it. The browser's bar and notice must sit exactly on the fill, with the sidebar untouched. Delete the probe.

- [ ] **Step 8: Commit**

```bash
git add app/MultiSessionAIManager/UI/Browser app/MultiSessionAIManager/UI/RootView.swift app/MultiSessionAIManager/Tests/BrowserSpaceOverlayTests.swift
git commit -m "feat(browser): show the browser over its space's pane in the Herdr layout"
```

---

### Task 7: The ways in, and the old way out

**Files:**
- Modify: `UI/Terminal/TerminalEmulatorView.swift` (interception hook), `UI/RootView.swift` (choice popover, `openBrowserSpace`), `UI/HostTabStrip.swift` (menu entry), `UI/WebTunnel/SessionWebTunnelSheet.swift` (remove the browse row)
- Delete: `UI/WebTunnel/HostBrowserScreen.swift`
- Create: `docs/browser-space.md`; modify `docs/port-forwarding.md`, `README.md`
- Test: `Tests/BrowserSpaceEntryTests.swift`

**Interfaces:**
- Consumes: `TerminalNewSpaceButton.isHit(column:row:)`, `TerminalRenderedRow.cells`, `TerminalMouse.sgr(_:button:col:row:)`, `BrowserSpaceOpener.open(using:sessionName:script:id:)`, `BrowserSpaceOpener.bundledPlaceholder()`, `ToastCenter.error(_:)`.
- Produces: `TerminalEmulatorView.interceptTap: ((_ column: Int, _ row: Int) -> Bool)?`, `HostTerminalView.onNewBrowserSpace: () -> Void`, `HostTabStrip.onNewBrowserSpace: (HostTab) -> Void`.

- [ ] **Step 1: Write the failing tests** (the wiring that cannot be tapped in a unit test is pinned by reading the source, as `HostPortForwardingTests` does)

```swift
import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct BrowserSpaceEntryTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func aTapIsOfferedToTheAppBeforeItIsSentToHerdr() throws {
        let view = try source("UI/Terminal/TerminalEmulatorView.swift")
        let handler = try #require(view.range(of: "private func handleTerminalTap"))
        let body = view[handler.lowerBound...]
        let intercept = try #require(body.range(of: "interceptTap(cell.col, cell.row)"))
        let forwarded = try #require(body.range(of: "TerminalMouse.sgr(.press"))
        #expect(intercept.lowerBound < forwarded.lowerBound)
    }

    @Test func newOffersAWorkspaceOrABrowser() throws {
        let root = try source("UI/RootView.swift")
        #expect(root.contains("TerminalNewSpaceButton.isHit("))
        #expect(root.contains("Button(\"Workspace\")"))
        #expect(root.contains("Button(\"Browser\")"))
    }

    @Test func theHostTabsMenuOpensABrowserSpace() throws {
        #expect(try source("UI/HostTabStrip.swift").contains("Button(\"New Browser Space\")"))
    }

    @Test func theBrowserIsNoLongerInPortForwarding() throws {
        let sheet = try source("UI/WebTunnel/SessionWebTunnelSheet.swift")
        #expect(!sheet.contains("Browse Through"))
        #expect(!sheet.contains("HostBrowserScreen"))
    }
}
```

- [ ] **Step 2: Run to see them fail** (`BrowserSpaceEntryTests`).

- [ ] **Step 3: The hook in `TerminalEmulatorView`**

Add the parameter after `forwardsPointerClicks`:

```swift
    /// Asked before a tap is sent to the remote, with the cell that was tapped.
    /// True means the app has taken the tap and the remote must not see it.
    var interceptTap: ((_ column: Int, _ row: Int) -> Bool)? = nil
```

In `handleTerminalTap(at:)`, directly after the `if let linkURL { … return }` block:

```swift
        if let interceptTap, inputEnabled, interceptTap(cell.col, cell.row) { return }
```

- [ ] **Step 4: The choice in `HostTerminalView`** (`UI/RootView.swift`)

New members:

```swift
    /// Opens a browser space in this tab's Herdr session.
    var onNewBrowserSpace: () -> Void = {}
    /// The cell of Herdr's "new" that was tapped, while its choice is shown.
    @State private var newSpaceTap: NewSpaceTap?

    private struct NewSpaceTap: Identifiable {
        let column: Int
        let row: Int
        var id: String { "\(column),\(row)" }
    }
```

Pass the hook to `TerminalEmulatorView(...)`:

```swift
                    interceptTap: { column, row in
                        let lines = session.terminal.lines
                        guard row < lines.count,
                              TerminalNewSpaceButton.isHit(column: column, row: lines[row].cells) else { return false }
                        newSpaceTap = NewSpaceTap(column: column, row: row)
                        return true
                    },
```

On the `ZStack`, next to the `.onChange` added in Task 6:

```swift
            .popover(item: $newSpaceTap, attachmentAnchor: .rect(.rect(newSpaceAnchor)), arrowEdge: .leading) { tap in
                VStack(alignment: .leading, spacing: 0) {
                    Button("Workspace") {
                        newSpaceTap = nil
                        // Herdr's own "new": the tap it would have had.
                        session.terminal.feedInputToPTY(
                            TerminalMouse.sgr(.press, col: tap.column, row: tap.row)
                            + TerminalMouse.sgr(.release, col: tap.column, row: tap.row))
                        session.terminal.reassertFocus()
                    }
                    .accessibilityIdentifier("new-space.workspace")
                    Divider()
                    Button("Browser") {
                        newSpaceTap = nil
                        onNewBrowserSpace()
                    }
                    .accessibilityIdentifier("new-space.browser")
                }
                .buttonStyle(NewSpaceChoiceStyle())
                .frame(minWidth: 200)
                .presentationCompactAdaptation(.popover)
            }
```

with, in `HostTerminalView`:

```swift
    private var newSpaceAnchor: CGRect {
        guard let tap = newSpaceTap else { return .zero }
        let cell = session.terminal.fontMetrics.boundingBox
        return CGRect(x: CGFloat(tap.column) * cell.width, y: CGFloat(tap.row) * cell.height,
                      width: cell.width * 3, height: cell.height)
    }
```

and at file scope:

```swift
private struct NewSpaceChoiceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(16))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 12)
            .background(configuration.isPressed ? Theme.hairline : Color.clear)
            .contentShape(Rectangle())
    }
}
```

- [ ] **Step 5: `RootView.openBrowserSpace` and the tab menu**

In `RootView`, next to `openMonitorSpace()`:

```swift
    private func openBrowserSpace(in tab: HostTab) {
        let session = tabs.session(for: tab)
        guard let service = session.connection.provisioningCommandRunner else {
            toastCenter.error("SSH connection not available")
            return
        }
        guard let script = BrowserSpaceOpener.bundledPlaceholder() else {
            toastCenter.error("This build is missing the browser space helper")
            return
        }
        Task {
            do {
                try await BrowserSpaceOpener.open(using: service, sessionName: session.sessionName, script: script)
            } catch {
                toastCenter.error("Could not open a browser space: \(error.localizedDescription)")
            }
        }
    }
```

Pass `onNewBrowserSpace: { openBrowserSpace(in: tab) }` at both `HostTerminalView(` call sites, and to `HostTabStrip`:

```swift
                HostTabStrip(store: tabStore, hosts: hostStore.hosts, attention: tabs.attention,
                             onNewBrowserSpace: { openBrowserSpace(in: $0) }) { showingPicker = true }
```

In `HostTabStrip`, declare `var onNewBrowserSpace: (HostTab) -> Void = { _ in }` before `onAdd`, and in the `.contextMenu`, before `Menu("Theme")`:

```swift
                        Button("New Browser Space") {
                            store.select(tab.id)
                            onNewBrowserSpace(tab)
                        }
                        Divider()
```

- [ ] **Step 6: Remove the old entry**

In `SessionWebTunnelSheet.swift` delete `@State private var isBrowsing`, the `browseSection` line in the list, the `.fullScreenCover(isPresented: $isBrowsing) { … }` and the `browseSection` property. Delete `UI/WebTunnel/HostBrowserScreen.swift`. Run `HostPortForwardingTests` and `SessionWebTunnel*` suites; an assertion that expects the removed row is deleted with it.

- [ ] **Step 7: Run** `BrowserSpaceEntryTests`, then the whole suite (`-only-testing:MultiSessionAIManagerTests`) and `python3 -m pytest tests -q`. Expected: all pass.

- [ ] **Step 8: End to end** (throwaway, on the simulator; nothing committed)

A test SSH server on Forge (`restrict,pty,port-forwarding` key line) and a throwaway Herdr session. A `ZZ` test builds a real `HerdrHostSession` for it, hosts `HostTerminalView` in a window, calls `BrowserSpaceOpener.open`, waits (bounded) for `session.browserSpaces.regions` to hold one region, loads `http://ip6-loopback:<port>/` (a page only Forge can name, served by `python3 -m http.server`) in that space's page, and writes a `drawHierarchy` PNG. Read the PNG: the page is inside the Herdr layout, the sidebar lists "Browser". Then select another space with `herdr workspace focus` and confirm (bounded wait) the regions empty. Remove the server, the Herdr session and the probe.

- [ ] **Step 9: Docs**

Write `docs/browser-space.md` (what it is, opening one, what other terminals see, limits, how it works, with the marker format). In `docs/port-forwarding.md` replace the "Browse through this host" section's first paragraph with a pointer to it and keep the proxy's description. Add a row to the README's feature table.

- [ ] **Step 10: Commit, push, ship**

```bash
git add -A app/MultiSessionAIManager docs README.md
git commit -m "feat(browser): open the browser as a space, from Herdr's \"new\" and the tab menu"
git push origin main
```

Then the TestFlight build (`ship.sh` on the Mac) and a note of what still needs a look on the iPad: touch and keyboard inside the pane, the popover's position on "new".

---

## Self-review

- Spec 3.1 → Task 1. 3.2 → Task 3. 3.3 → Task 2. 3.4 → Tasks 5 and 6. 3.5 → Tasks 4 and 7. 3.6 → Task 7. Section 4's rows: another space selected, a menu over the pane, resize (Tasks 1, 2, 5), too small (Task 1), reconnect or restart (Tasks 5, 6), closed space (Task 5: page kept until the tab goes), another terminal (Task 1), link gone (Task 6 notices). Section 5's "bytes captured from a real Herdr session" is done as Task 7 step 8 and Task 3 step 5 rather than as a committed fixture: a capture carries the host's own screen text, which does not belong in the repository.
- Names used across tasks: `BrowserSpaceRegion`, `BrowserSpaceMarker.prefix/fill/text`, `BrowserSpaceLocator.regions(in:)`, `BrowserSpaceGeometry.frame(of:cell:)`, `TerminalRenderedRow.cells`, `BrowserSpaceCommands.createSpace/paneID/runPlaceholder/newID`, `BrowserSpaceOpener.open/bundledPlaceholder`, `BrowserSpaceOpenError`, `TerminalNewSpaceButton.isHit(column:row:)`, `BrowserSpaceModel.show/page(for:)/savedAddress(for:)/remember(address:for:)/regions/savedLimit`, `HerdrHostSession.browserSpaces`, `HostBrowserPane`, `BrowserSpaceOverlay`, `interceptTap`, `onNewBrowserSpace`.
