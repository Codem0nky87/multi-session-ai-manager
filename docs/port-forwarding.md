# Port forwarding

A dev server on the host, opened in a browser on the iPad — without exposing
that server to anything.

**⚙︎ → Port Forwarding.** Definitions are per-host, stored on the iPad, and
start only over an authenticated host connection: the sheet dials SSH first and
shows connection state (including a changed host key) before it will forward
anything.

## What a tunnel is

| Field | Meaning |
|---|---|
| Label | Display name |
| Scheme | `http` or `https` |
| Target host / port | Where the service listens, **as seen from the SSH host** |
| Local port | A loopback port on the iPad; automatic (ephemeral) by default |
| Hop | Optional second SSH hop — see below |

The app opens a `direct-tcpip` channel over the existing SSH connection and
serves it from a listener bound to `127.0.0.1` on the iPad. The in-app browser
then loads `scheme://127.0.0.1:<localPort>`.

Nothing is published. The listener is loopback-only, and the target port is
never opened to the network — it is reached from inside the SSH connection you
already authenticated.

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

### Hop credentials

By default the hop uses whatever the **first host** already has — its key, its
SSH config, its agent — and runs with `BatchMode=yes`, so it either works
non-interactively or fails cleanly.

If you enter a password instead:

- it is held only while the Port Forwarding sheet is open, and is never saved;
- it is delivered through a mode-`700` temporary `SSH_ASKPASS` helper written on
  the first host, with `SSH_ASKPASS_REQUIRE=force` and
  `NumberOfPasswordPrompts=1`;
- the helper is removed after startup, and again on stop, exit, and listener
  shutdown;
- stopping the tunnel or closing the sheet requires re-entering it.

The web service's own login is a separate thing entirely; this password is only
for the SSH hop.

## The in-app browser

`UI/WebTunnel` opens the forwarded origin in an embedded web view. It refuses
anything that is not the loopback origin it created — the expected host must be
one of `127.0.0.1`, `::1`, or `localhost` — so a redirect cannot walk the view
off the tunnel and onto the open internet.
