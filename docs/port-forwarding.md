# Port forwarding

A service on the host's side of an SSH connection, used from the iPad or iPhone
without exposing that service to anything: a dev server in a browser, a
Windows desktop over RDP, a VNC session, a database.

**Manage Hosts → Edit host → Port forwarding.** Definitions are per-host,
stored on the device, and start only over an authenticated host connection: the
sheet dials SSH first and shows connection state (including a changed host key)
before it will forward anything.

## What a forward is

| Field | Meaning |
|---|---|
| Label | Display name |
| Target host / port | Where the service listens, **as seen from the SSH host** (or from the hop, when one is set) |
| Local port | A loopback port on the device; automatic (ephemeral) by default, or fixed |
| Hop | Optional second SSH hop — see below |

The app opens a `direct-tcpip` channel over the existing SSH connection and
serves it from a listener bound to `127.0.0.1` on the device. The forward
carries bytes and has no idea what protocol they are, so a definition stores no
scheme. Use a **fixed** local port when another app will remember the address,
such as an RDP client pointed at `127.0.0.1:13389`.

Nothing is published. The listener is loopback-only, and the target port is
never opened to the network — it is reached from inside the SSH connection you
already authenticated.

The equivalent of

```
ssh -N -L 13389:127.0.0.1:3389 -L 15432:127.0.0.1:5432 admin@10.0.0.20
```

is two forwards: target `127.0.0.1:3389` with fixed local port `13389`, and
target `127.0.0.1:5432` with fixed local port `15432`. They go under the host
`10.0.0.20` itself if the device can reach it, or under a host that can, with
`admin@10.0.0.20` as the hop.

## Starting, stopping and using one

The sheet has two lists.

- **Connections** are the saved forwards. Each has **Start**. A forward that
  could not start shows why on its own row and takes no slot.
- **Running** shows each started forward with the address it listens on (tap to
  copy), **Stop**, and two shortcuts: **In App** and **Safari**.

Up to **five** forwards run at once per host (`SessionWebTunnelModel.runningLimit`).
They share one SSH connection and nothing else: starting, stopping or failing
one does not touch the others. Closing the sheet stops nothing; the metrics
bar's pill lists what is running, each with its own stop, and **Stop all**.

A forward keeps listening when a connection through it fails, for example
because the target refused it: the reason is shown under the forward, and the
next connection is tried afresh. Editing a running forward stops it, so the
next Start uses the saved settings. Deleting one stops it too.

For anything that is not a web page, open the client yourself and give it the
address from the Running list. There is no hand-off to VNC or RDP apps.

iOS suspends the app soon after it leaves the screen, and a suspended app
forwards nothing. Keep AI Manager visible next to the client (Split View,
Slide Over, Stage Manager).

### Keeping a forward alive

An idle forward sends nothing, so a NAT, firewall or VPN on the path drops the
SSH connection without a word. The listeners on the device would then accept
connections that go nowhere. `PortForwardingSession.keepAlive()` prevents that
and repairs it:

- **A beat every 30 seconds** while any forward on the host is running: one
  tiny round trip (`true`) on the SSH connection, which refreshes the flow.
  Nothing is sent for a host with no forward running.
- **Reconnect underneath.** If the beat gets no answer within 10 seconds the
  SSH connection is made again. The listeners keep their ports, so the address
  in the client stays valid and the next connection simply works; no forward
  has to be stopped and started.
- **At once when it matters.** The same check runs immediately when a
  connection through a forward fails, and when the app comes back to the
  front. iOS suspends the app in the background, where nothing can be kept
  alive, so the link is usually gone on return.
- **Before every start.** Nothing is sent for a host with nothing running, so
  a connection that died meanwhile (the screen went off, iOS suspended the app)
  still reads "connected". Every Start, and opening the browser, therefore
  first makes the same round trip (`PortForwardingSession.ensureLink()`), and
  the connection is made again if it gets no answer. The forward shows
  **Starting…** while that happens. Without it the start went out on the dead
  connection and failed, and because a failed forward is not running, nothing
  checked the connection afterwards: every Start failed until the app was
  closed.
- **One check at a time.** A check that finds the connection dead replaces it.
  Two doing so at once would take each other's connection away, so a Start
  waits for a keep-alive check that is already running.
- **The hop leg** keeps itself alive too: its `ssh` runs with
  `ServerAliveInterval=30`, `ServerAliveCountMax=3`.

A start that fails because the SSH connection to the first host failed says so.
It no longer suggests checking the hop's key or password: the command never
reached the first host, so nothing was learned about the hop.

A changed host key is not reconnected automatically; that is the user's to
look at.

### http or https

Only the two browser shortcuts need a scheme, and they ask the port. Before
opening, the app sends a TLS ClientHello through the forward
(`Core/TunnelTLSProbe.swift`) and looks at the first two bytes of the answer:
a TLS handshake or alert record means `https://`; anything else, including
silence for three seconds, means `http://`. The answer is remembered until that
forward is stopped. No certificate is examined by the probe; the browser makes
its own connection afterwards.

## Second hops

When the service lives on a machine the SSH host can reach but the iPad cannot,
a tunnel can carry a **hop**: the app runs OpenSSH *on the first host* to build
the inner leg, then forwards to that.

```
iPad ──SSH──▶ host ──ssh -L──▶ hop ──▶ target:port
```

The remote command is a controlled `ssh -M -S <control-path> -f -N -L …` with
`ExitOnForwardFailure=yes`, a ready marker to detect startup, and matching stop
and cancel commands driving the same control socket. Every value derived from a
tunnel definition or a runtime credential is single-quoted for the remote shell.

### The helper on the first host

That `ssh -f` is a helper: it goes into the background on the first host,
listens on that host's loopback, and lives until it is told to exit. Stopping
the forward tells it. Closing the app, updating it, or losing the connection
does not, so a helper can be left behind. Two rules keep that from mattering:

- **The helper's port belongs to the first host.** It is picked at random
  between 20000 and 32000, and when ssh reports it taken another is tried, up
  to three times. It is not the forward's local port: that is a port of this
  device, and the same number may be in use over there. It used to be the same
  number, and a helper left behind then made every later Start fail with
  `bind [127.0.0.1]:<port>: Address already in use`.
- **Every Start first removes the helpers left behind for the same forward.**
  A helper's control path names its forward
  (`/tmp/ai-manager-web-tunnel-<forward>-<start>.sock`), and `pkill -f` matches
  the option sequence only a helper is started with, among the user's own
  processes. Helpers from builds before this rule have no forward in their
  path; those are matched by target and hop instead. Other forwards, and a
  second device forwarding from the same host, are left alone.

A helper of a forward that is never started again stays until its hop
connection ends or the host restarts. To clear every helper by hand, run
`pkill -f 'ai-manager-web-tunne[l]-'` on the first host (the brackets keep the
command from matching itself).

### Hop credentials

By default the hop uses whatever the **first host** already has — its key, its
SSH config, its agent — and runs with `BatchMode=yes`, so it either works
non-interactively or fails cleanly. The first Start of a hop forward in an app
run asks which it is: type the password, or choose **Start without a
password**. The answer is kept in memory until the app quits.

If you enter a password instead:

- it is held only in memory while AI Manager runs, and is never saved;
- it is delivered through a mode-`700` temporary `SSH_ASKPASS` helper written on
  the first host, with `SSH_ASKPASS_REQUIRE=force` and
  `NumberOfPasswordPrompts=1`;
- the helper is removed after startup, and again on stop, exit, and listener
  shutdown;
- it is reused when that forward is started again, until the app quits or the
  forward is deleted.

The web service's own login is a separate thing entirely; this password is only
for the SSH hop.

## The in-app browser

`UI/WebTunnel` opens the forwarded origin in an embedded web view. It refuses
anything that is not the loopback origin it created — the expected host must be
one of `127.0.0.1`, `::1`, or `localhost` — so a redirect cannot walk the view
off the tunnel and onto the open internet.

The browser only looks at a forward. Closing it leaves the forward running, and
a page that will not load is reported in the browser, not as a failure of the
forward: the port may simply not be a web page.

## A site that needs its own name

A forward carries one port, and the browser that opens it asks for
`127.0.0.1:<port>`, not for the site's own name. That breaks sites that depend
on their name: a reverse proxy that picks the site by host name, a certificate
issued for the name, redirects and links back to the name, cookies tied to the
domain. For those, open a **browser space** instead: its pages are fetched by
the SSH host under their real names, with no forward at all. See
[browser-space.md](browser-space.md).
