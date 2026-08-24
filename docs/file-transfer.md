# File transfer

Files move both ways, but the two directions are not symmetric — because SSH
isn't. The iPad dials the host, so the host can never push. Each direction gets
the mechanism its constraints allow.

Both directions ride the tab's **existing authenticated connection**. There is
no second dial and no second host-key decision, which is why both refuse on a
tab that is not live rather than quietly connecting behind your back.

## iPad → host

The **paperclip** button offers three sources:

- **Paste** — an image on the iPad clipboard
- **Photos** — the photo library picker
- **Files** — any file, of any type

The file is written to `~/.msam/uploads/` on the host, named for the timestamp,
and its **absolute path is typed into the pane**.

```
~/.msam/uploads/2026-08-23-160245.png
```

Two details matter:

- **No trailing newline.** The path is inserted, never submitted. You decide
  when to send it, and you can keep typing around it — which is the point, since
  usually it goes in the middle of a sentence to an agent.
- **The extension is sanitised.** It is user data: it comes from a filename you
  chose or a picker gave you. It is lowercased, stripped to `[a-z0-9]`, capped
  at 12 characters, and falls back to `bin`. The extension survives at all only
  because downstream tools dispatch on it.

Home-relative, not workspace-relative: Herdr's active workspace has a working
directory the app cannot see.

Uploads are capped at **25 MB**.

## host → iPad

There is no push channel, so the iPad watches a queue and pulls what appears.

### Setting it up

1. **Host Setup → Plugins** → install **`smarzban/herdr-file-viewer`**.
2. On its row in the installed list, tap **Send files here**.

Step 2 does what the plugin manager cannot know to do: binds the viewer to
`prefix`+`f`, and points its `open` command at `msam-send`. Both are appended
only if they are not already spoken for — an existing binding or `open` command
is reported as a conflict and left alone.

### Sending a file

In the viewer, select a file and press **`O`** — that is **capital O**, i.e.
`Shift`+`o`. Lower-case `o` does something else entirely, which is the single
most common reason "nothing happens".

Two more reasons it can appear to do nothing:

- **The viewer reads its config only at startup.** If it was already open when
  you ran *Send files here*, close it with `q` and reopen it. Otherwise `O`
  falls through to the platform default (`open` on macOS) and opens the file
  *on the host*, invisibly to you.
- **Under Herdr the config lives at `$HERDR_PLUGIN_CONFIG_DIR/config.toml`**,
  which `herdr plugin config-dir herdr-file-viewer` prints —
  `~/.config/herdr-file-viewer/config.toml` is the *standalone* fallback and is
  not read when the viewer runs under Herdr. The app writes to the right one and
  reports which.

### The seam

The `herdr-file-viewer` plugin has no IPC and no hooks. Its extension point is
its **config commands** — `open`, `editor`, `reveal` — each of which is invoked
with the selected path as a real argv element, with no shell in between.

That is the whole integration. Step 3 of Host Setup installs the plugin itself,
binds it to `prefix`+`f`, installs a small script, and points the plugin's
`open` command at that script:

```
herdr plugin install smarzban/herdr-file-viewer --yes
~/.config/herdr/config.toml                     keybind: prefix+f
~/.local/bin/msam-send                          the script
~/.config/herdr-file-viewer/config.toml         open = "msam-send"
```

The plugin and the config are installed together, and deliberately so: an
`open = "msam-send"` config pointing at a plugin that is not installed is
inert, and would fail silently at exactly the moment you tried to use it.

`msam-send` resolves each argument to an absolute path, checks it is a readable
file, and appends it to `~/.msam/outbox`. Because the plugin invokes no shell,
the path arrives as one argv element however it is spelled — nothing here has to
defend against quoting.

`~/.local/bin` is already on the PATH of every bounded command the app runs, so
the config refers to `msam-send` by name.

The installer **never overwrites an `open` key that points somewhere else**. It
reports `ADDED`, `ALREADY`, or `CONFLICT`, and a conflict is left alone — that
is a setting you chose, and silently replacing it would break whatever you wired
up. Its own stanza is marked `# Added by MSAM` so a re-run can tell its edit
from yours.

### The watch

Each live tab opens a **second** PTY channel — the Herdr PTY is carrying an
interactive program and cannot be shared — running:

```sh
mkdir -p "$HOME/.msam"; : >> "$HOME/.msam/outbox"; exec tail -n 0 -F "$HOME/.msam/outbox"
```

- **`-n 0`** is what makes this a live feed rather than a replay. Without it,
  every reconnect would re-deliver the entire history.
- **`-F`** (follow by name, with retry) survives the file being rotated or
  recreated underneath it.
- **The app never truncates the outbox.** Truncation is exactly what makes
  `tail -F` decide the file shrank and start over, re-delivering everything. The
  queue is one path per line; letting it grow costs nothing worth reclaiming.

Output arrives off the main actor in arbitrary chunks — a path *will* get split
across two reads — so a `LineAccumulator` behind a lock holds the partial tail
until its newline arrives, and only complete lines cross to the main actor.

The watch is reconciled on the same schedule as the PTY: `ensureLive()` reopens
it if it closed. Without that, a reconnect leaves the watch dead and files
silently stop arriving with nothing on screen to explain why.

A host with no outbox, or without `msam-send` installed, simply has nothing to
watch. That is not a session failure and never touches the tab's status.

### Delivery

Only the **selected** tab downloads. A background tab filling the screen with
someone's file would be a surprise.

The file is fetched over that tab's own connection and presented in a sheet —
preview, share, or save. Anything queued while a sheet is open follows
immediately after it closes. Downloads are capped at **50 MB**: the whole file
is held in memory to hand to the share sheet, and an iPad is not the place for a
multi-gigabyte log.

A path is taken off the queue before it is fetched, so a failed download is
reported out loud. Otherwise the file you sent would simply never arrive.
