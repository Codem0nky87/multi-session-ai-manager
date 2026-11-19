# Browser spaces

A web browser that is a space in Herdr's own layout. It is listed under
**spaces** beside the workspaces, and its page fills the pane Herdr gives it,
with the sidebar and everything else still on screen. Every page is fetched by
the SSH host, so a site that exists only on the host's network opens by its
real name.

## Opening one

- Tap **new** under Herdr's list of spaces. The app asks which kind:
  **Workspace** is Herdr's own "new", exactly as before; **Browser** opens a
  browser space.
- Or long-press the host's tab and choose **New Browser Space**.

The space is called "Browser" and is selected at once. Type an address the way
you would on the host. An address without a scheme is `http://`; type
`https://` for a site that listens only on 443.

## Using it

- It is a Herdr space: select it, switch away, split it, resize it, close it,
  all the way Herdr does those for any space. The page follows the pane.
- Switching to another space hides the browser and keeps its page. Coming back
  shows the same page where it was.
- After a reconnect or an app restart the space is still in Herdr, and what it
  had open comes back: its tabs, and the address each showed last.
- When a Herdr menu or dialog covers the pane, the browser steps aside until it
  is gone.
- Closing the space in Herdr closes the browser.

### Tabs

**+** at the right end of the browser's bar opens another page as a tab, empty
and with the address bar ready. Once a space has two tabs they are listed above
the bar by their pages' titles: tap one to show it, **×** to close it.

- Every tab is a browser of its own (`Core/BrowserSpaceTabs.swift`), so going
  back to a tab shows it as it was left, with what was typed into it.
- The tabs of one host share its cookies and sign-ins.
- A space has at most eight tabs; each is a web view that stays in memory.
- Closing the only tab leaves an empty one.
- After a restart only the tab that is shown loads its page; the others load
  when they are chosen.

### Typing

Tap the address bar or a text field of a page and the keyboard is its own. The
on-screen keyboard makes the terminal shorter, as it does when typing into the
terminal, so Herdr lays the screen out once for the space above the keyboard
and the page is fully visible there.

## Limits

- **Other terminals see a placeholder.** A desktop terminal attached to the
  same Herdr session shows that pane filled with `░` and a short marker, not
  the page.
- **No bookmarks or downloads.** A link that asks for a new window opens in
  the tab it was tapped in.
- **The keyboard goes to whatever was tapped last.** While the page has it,
  Herdr's key bindings do not reach Herdr; tap the terminal to give it back.
- **"new" is recognised by its text.** With the sidebar collapsed, or a Herdr
  that words the label differently, a tap on it goes straight to Herdr. The tab
  menu entry always works.
- **On a Windows host the pane's shell stays underneath.** See
  [On a Windows host](#on-a-windows-host).

## How it works

Herdr draws its sidebar and panes inside the terminal, so the app cannot add a
real item to Herdr's list. It does this instead:

```
 Herdr on the host                         AI Manager
 ─────────────────                         ──────────
 space "Browser"                           the terminal grid it already draws
   pane runs the placeholder   ── PTY ──▶    [[AIM-BROWSER 7f3a2c 113x39]]░░░░░
   (marker + fill, repainted                 ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    on every resize)                                │ find the marker
                                                    ▼
                                           browser laid over exactly those cells
```

1. **Opening** (`Core/BrowserSpaceCommands.swift`), over the tab's own SSH
   connection and in the tab's own Herdr session:
   `herdr workspace create --label Browser --focus`, then the placeholder is
   written to `~/.local/share/msam/browser-space.sh` and made the new pane's
   process with `herdr pane run <pane> exec sh …`. A Windows host is sent the
   same two Herdr commands and a placeholder of its own
   ([below](#on-a-windows-host)).
2. **The placeholder** (`Resources/msam-browser-space.sh`, plain `sh`) fills
   its pane with `░` and writes `[[AIM-BROWSER <id> <cols>x<rows>]]` at the top
   left: which space this is, and how big its pane is. It repaints when the
   pane is resized, ignores Ctrl-C, and ends when Herdr closes the pane.
3. **Finding it** (`Core/BrowserSpaceLocator.swift`). After every repaint the
   app looks for the marker in its grid. The pane counts only when **every**
   cell of the rectangle the marker claims is the fill. Anything else there
   (a Herdr menu over the pane, half a repaint, a pane that runs off the
   screen) and the browser is not shown, so it never covers something Herdr
   drew.
4. **Showing it** (`Core/BrowserSpaceModel.swift`, `UI/Browser/`). The browser
   is placed at `column × cell width`, `row × cell height`. A pane that moves
   is followed at once; one that disappears is dropped after 120 ms, so a
   repaint does not flicker the page. Each space keeps its tabs and their
   pages while it is off screen, and what its tabs showed last is saved per
   host (the newest twelve spaces).
5. **"new"** (`Core/TerminalNewSpaceButton.swift`). A tap is offered to the app
   before it is sent to Herdr. It is taken only when the tapped row's sidebar
   part reads `new` … `menu` and the tap is on `new`; choosing Workspace then
   sends Herdr the tap it would have had.

### On a Windows host

Herdr gives a pane a Windows pseudo-console there, and the pane's shell is
PowerShell, not `sh`. From the app a browser space is opened and used the same
way; what differs is on the host.

- **The placeholder is `Resources/msam-browser-space.ps1`**, written for
  Windows PowerShell 5.1, which every Windows has. It is sent over SFTP to
  `.local\share\msam\browser-space.ps1` under the account's profile, and it
  is sent before the space is made: a host that cannot take it is not left
  with an empty "Browser" space.
- **One line typed into the new pane starts it:**
  `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:/Users/alice/.local/share/msam/browser-space.ps1 7f3a2c`.
  The line reads the same in PowerShell 7, Windows PowerShell and cmd,
  whichever the pane runs. The path has forward slashes, and is in quotes when
  the profile's name has a space in it.
- **It fills the pane through the console's screen buffer**, the way
  `Clear-Host` clears one, so the last cell is filled without the pane
  scrolling. Windows sends no signal when a console changes size; the
  placeholder looks ten times a second and paints again when the size is
  another.
- **Ctrl-C, and anything else typed at the pane, is thrown away.** Windows has
  no `exec`, so the pane's shell waits underneath the placeholder. Both end
  when Herdr closes the pane. Were the placeholder ended on its own, the space
  would be a plain shell again, and nothing typed at the browser space
  meanwhile would be run by it.

`tests/test_msam_browser_space_windows.py` types that line into Windows
PowerShell, PowerShell 7 and cmd in a real pseudo-console and reads the screen
back the way the app does. It needs Windows, so CI runs it
(`windows-browser-space`).

### The keyboard and a change of size

The browser sits on a terminal whose size the keyboard changes, and three
things keep a page's text field usable. Each was a fault first: typing into a
page made the screen flash and the keyboard go away again.

- **The panes take no part in the terminal's layout**
  (`BrowserSpacePaneLayout`). A pane is as tall as the host last drew it. A
  pane that counted in the layout held the terminal's height up when the
  keyboard came up, so the terminal could only shrink about three rows for
  every redraw from the host: twelve sizes, and twelve Herdr layouts, over more
  than two seconds. The panes are drawn over a base that takes exactly the
  space it is given, and are cut off at its edges.
- **A pane waits for the redraw that follows a change of size.** Right after
  the terminal changes size the placeholder on screen is cut off, and it stays
  so until the host has drawn it again: 0.1 to 0.25 seconds on a local network,
  longer than the 120 ms above. Dropping the pane then took the keyboard from
  the page that had raised it; the keyboard went away, and the terminal changed
  size once more. So after a change of size a pane stays for up to 1.5 seconds
  (`BrowserSpaceModel.terminalResized`), and the wait is over as soon as the
  host has drawn it. The exception is a change of size made while the terminal
  itself has the keyboard: that follows a tap on Herdr, which may be what takes
  the space off the screen, so the browser gets out of the way as fast as ever.
- **The terminal does not take the keyboard back.** Nothing clears the
  terminal's own request for the keyboard when another field takes it. When
  the window became active again (another app, a password prompt) the terminal
  asked again and typing went to Herdr. It now leaves the keyboard with any
  field that has it (`KeyInputController.suspendForDeactivation`,
  `restoreAfterActivation`).

## How pages are fetched

Whatever is typed is fetched by the SSH host:

```
browser space  ──SOCKS5──▶ proxy on 127.0.0.1 ──direct-tcpip──▶ SSH host ──▶ name:port
   (this device)              (this device)        (the host looks the name up)
```

- **Names are looked up on the host.** The browser hands the proxy the name as
  written; the proxy passes it to the host unresolved. An address that exists
  only on the host's network works, and the page sees its own real address, so
  links, redirects, sign-ins and certificates behave as they do on the host.
- **No forward per site.** Every connection the page makes goes the same way.
- **An address without a scheme is `http://`.** A site that wants HTTPS
  redirects there; type `https://` for one that listens only on 443.

### What protects it

- **The proxy needs a password** (`HostBrowseProxyCredentials`), random for
  every browsing session and given only to the browser. It listens on this
  device's loopback, where any app could otherwise connect and reach whatever
  the host can reach. A client that offers no password, or the wrong one, is
  turned away before anything is opened.
- **It runs only while the host has a browser space to serve**: from the first
  time one is shown until the host's last tab is closed, on a port the system
  picks.
- **No fallback.** If the proxy is gone a page fails; it is never fetched
  directly from this device.
- **Each host has its own cookies and sign-ins**
  (`WKWebsiteDataStore(forIdentifier: host.id)`), apart from every other host's
  and from the rest of the app.
- **Certificates are checked as usual.** A site whose certificate this device
  does not trust (an internal authority, a self-signed one) is refused, and the
  browser says so. **Visit Anyway** accepts it for that site and port only,
  in that browser space, until its tab is closed.
- **A changed host key is never accepted from here.** The browser says to open
  the host's tab, which shows the key and asks.

### When a page does not load

The host says why, and the browser repeats it: *Forge could not open
wiki.internal:80. Name or service not known.* The reasons are SSH's own
(`Connection refused`, `Name or service not known`); a host whose SSH server
restricts forwarding (`AllowTcpForwarding`, `PermitOpen`) answers that it does
not allow connections to that address. A destination that never answers is
given up on after 20 seconds.

### Non-secure pages

iOS refuses plain `http://` to a dotted name before a request is even made
(App Transport Security). Internal sites are often exactly that, so the app
sets `NSAllowsArbitraryLoadsInWebContent`, which lifts the rule for web content
only; the app's own connections stay under the default rules.

### Shares the host's connection

The proxy uses the same SSH connection as the host's forwards
(`PortForwardingSession`), so a host with a browser space is kept alive, and
reconnected underneath, exactly as a running forward is. Before the proxy
starts, the connection is checked and made again if it no longer answers
(`ensureLink`), as it is before a forward starts.
