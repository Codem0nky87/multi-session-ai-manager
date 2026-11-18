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
- After a reconnect or an app restart the space is still in Herdr, and the
  address it showed last is opened again.
- When a Herdr menu or dialog covers the pane, the browser steps aside until it
  is gone.
- Closing the space in Herdr closes the browser.

## Limits

- **Other terminals see a placeholder.** A desktop terminal attached to the
  same Herdr session shows that pane filled with `░` and a short marker, not
  the page.
- **One page per space.** No tabs, bookmarks or downloads. A link that asks for
  a new window opens in the same page.
- **The keyboard goes to whatever was tapped last.** While the page has it,
  Herdr's key bindings do not reach Herdr; tap the terminal to give it back.
- **"new" is recognised by its text.** With the sidebar collapsed, or a Herdr
  that words the label differently, a tap on it goes straight to Herdr. The tab
  menu entry always works.
- **Unix hosts only.**

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
   process with `herdr pane run <pane> exec sh …`.
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
   repaint does not flicker the page. Each space keeps its page while it is
   off screen, and its last address is saved per host (the newest twelve).
5. **"new"** (`Core/TerminalNewSpaceButton.swift`). A tap is offered to the app
   before it is sent to Herdr. It is taken only when the tapped row's sidebar
   part reads `new` … `menu` and the tap is on `new`; choosing Workspace then
   sends Herdr the tap it would have had.

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
