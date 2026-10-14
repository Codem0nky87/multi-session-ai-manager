# App Store submission kit — AI Manager (v1.0)

## Metadata (already pushed via API on 14 Oct 2026)

- Name: MultiSession AI Manager (appInfo localization)
- Subtitle: SSH terminal & host control
- Category: Developer Tools
- Copyright: 2026 Iron Mentor (Pty) Ltd
- Privacy policy: https://github.com/Codem0nky87/multi-session-ai-manager/blob/main/PRIVACY.md (live, 200)
- Content rights: does not use third-party content
- Age rating: self-declared all-NONE (unrestricted web access = yes)
- Encryption: ITSAppUsesNonExemptEncryption=false (in Info.plist)
- Review contact: rufus.dupont@ironmentor.co.za, +27 82 000 0000, demo account not required
- Build attached to version: 202610140834

## What still needs the browser (no API exists)

1. App Privacy questionnaire -> "No, we do not collect data from this app"
   (Data Not Collected). Privacy policy URL already set via API.
2. Screenshots: iPad 13" (2064x2752 portrait) and iPhone 6.9" (1320x2868
   portrait) sets from build/appstore-shots/.
3. App Preview video: READY — build/appstore-shots/msam-preview-iphone-28s.mp4
   (28s, 1320x2868 portrait, 30fps, ~8 Mbps; tours tunnels -> settings ->
   open-host -> live agent terminal. Upload under iPhone 6.9" preview slot;
   Apple transcodes. Full 5m25s source kept alongside.)
4. Then: Add for Review -> submit.

## Screenshot captions (paste above each image in ASC)

iPad + iPhone, in order:
1. "Your servers, one clean list" — live status of every host you own.
2. "Everything about a host, in one place" — keys, services, port forwards.
3. "Expose any web service or VNC desktop" — SSH-hop tunnels straight to Safari.
4. "A real terminal, built for touch" — full quick-key bar, metrics always live.

## What Apple will check

- Works on a fresh install: the app must not crash without a configured host
  (empty state exists: "No hosts configured. Add one in MSAM Settings.").
- Reviewer needs no account; any public SSH server works. Note says so.
- Local network permission prompt appears on first connect (usage string set).
