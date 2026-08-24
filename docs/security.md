# Security model

## What the app talks to

One thing: `sshd` on each configured host.

Herdr listens on a Unix socket (`~/.config/herdr/herdr.sock`), and the app
reaches it by running `herdr` inside an SSH PTY. **No Herdr port is exposed, on
any interface.** There is no hub, no daemon, and no bespoke wire protocol — the
remote attack surface is SSH alone.

## Secrets

| Secret | Where it lives |
|---|---|
| SSH private keys | iOS Keychain (`KeyStore` / `KeychainBacking`) |
| Host-key fingerprints | On-device known-hosts store |
| Host definitions, tabs, tunnels | `UserDefaults`, on-device |
| Install-key password | Held for one connection, never persisted |
| Hop password | Held while the sheet is open, never persisted |
| Network transport credentials | **None exist.** The app holds no VPN/WARP/tunnel token of any kind |
| App Store Connect API key | Environment only; `**/*.p8` is gitignored |

No credential is transmitted anywhere except to the host it authenticates
against.

## Host-key verification

Trust on first use, then pin. The pin is keyed by address (`[address]:port` for
a non-default port) and verified on every connection.

A mismatch is a **distinct state**, not a generic failure. The tab shows the
presented fingerprint and offers only *Trust new key & reconnect*, marked
destructive. There is no Retry, because retrying cannot resolve a mismatch — it
can only re-detect it. Verify the fingerprint out of band before accepting it;
an unexpected change is what interception looks like.

## The highest-privilege action

Installing Herdr pipes a remote script to a shell:

```sh
curl -fsSL https://herdr.dev/install.sh | sh
```

This is Herdr's documented install method and it runs as the connecting user on
a host you own — but it is still the most dangerous thing in the app. Hence:

- probe first, then confirm, never automatically;
- the command shown to you and the command sent to the host are the **same
  constant**, so the promise and the action cannot drift apart;
- every remote command the app issues is bounded by a timeout and an output
  limit, so an unresponsive host stalls nothing.

You can always copy the command and run it yourself instead.

## Installing plugins is the same class of action

The plugin manager can install any Herdr plugin by `owner/repo`, and its
discover list comes from GitHub's `herdr-plugin` topic — a **self-applied** tag
that anyone can put on their own repository. There is no review, no signing, and
no allowlist behind it.

An installed plugin runs on your host as your user, and this app's own file
bridge is itself wired through a plugin's `open` command — which is exactly how
much reach a plugin has. Read what you install; a search result is not a
registry.

## Shell safety

Values that reach a remote shell are quoted at a single choke point
(`POSIXShell.quote`), and the paths that matter most avoid shells entirely:

- **Uploads** are written over SFTP, not echoed through a shell. The file
  extension is user data, so it is lowercased, stripped to `[a-z0-9]`, capped at
  12 characters, and defaulted to `bin`.
- **Downloads** come from a queue fed by `msam-send`, which the
  `herdr-file-viewer` plugin invokes with the path as a real argv element and
  **no shell in between** — so nothing in that path has to defend against
  quoting at all.
- The `msam-send` script itself is uploaded over SFTP rather than echoed,
  keeping its own quoting off the command line.
- Tunnel commands single-quote every value derived from a tunnel definition or a
  runtime credential.

## The in-app browser

The web view accepts only the loopback origin the app created for a tunnel —
the host must be `127.0.0.1`, `::1`, or `localhost`. A redirect cannot walk it
off the tunnel and onto the open internet.

## Network transport is not the app's concern

How the iPad reaches a host — LAN, VPN, Tailscale, a Cloudflare WARP private
network — is deliberately outside the app. It opens a TCP connection and speaks
SSH; it holds no credential, token, or configuration for any transport, and it
manages no enrolment.

This is a security property, not an omission. The app cannot leak a connector
token or a service-token secret because it never has one. Whatever restricts
reachability to your hosts is enforced by your network, where it belongs, and
stays enforced regardless of what this app does.

The route test in Host Setup opens a bare TCP connection and reports whether it
completed. It proves reachability on the current network path — it does **not**
prove which transport carried the traffic, and it authenticates nothing.

## Known limitations

- Host definitions and tunnel definitions live in `UserDefaults`, not the
  Keychain. They contain no secrets, but they are readable from a device backup.
- Downloaded files are held wholly in memory (capped at 50 MB) to hand to the
  share sheet.
- The app trusts the host once its key is pinned. A compromised host runs
  arbitrary code in your terminal — that is what a terminal is.

## Reporting a vulnerability

Please open a private security advisory on the repository rather than a public
issue.
