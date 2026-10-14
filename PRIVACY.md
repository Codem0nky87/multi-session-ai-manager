# Privacy Policy — AI Manager

**Effective: 14 October 2026**

AI Manager (com.codem0nky87.MultiSessionAIManager) is a client application. It
talks only to servers *you* choose, over SSH, from your device. It has no
backend of its own.

## What we collect

**Nothing.** The developer collects no personal data. There are no accounts,
no analytics, no advertising, no tracking, and no telemetry sent from the app.

## What is stored on your device

Everything the app needs lives locally, in your device's app container and
Secure Enclave-backed Keychain:

- **Host definitions** — names, addresses, ports, and usernames of the servers
  you add.
- **SSH keys** — generated or imported ed25519 keys, stored as private-key
  material in the iOS Keychain. Keys never leave the device.
- **Known-host fingerprints** — for verifying the servers you connect to.
- **Port-forward definitions, themes, and app settings** — local preferences.

When you connect, the app exchanges terminal data, metrics, and credentials
directly with your server. That traffic is between your device and your
server; it is not routed through, or stored by, the developer.

Hop passwords you enter for port forwarding are held in memory only while the
app is running and are never written to disk.

## Third parties

The app contains no third-party analytics or advertising SDKs.

## Children

The app is a developer tool and is not directed at children.

## Changes

If our practices change, this page will be updated and the app's build
refreshed. Continued use after an update accepts the revised policy.

## Contact

Issues and enquiries: https://github.com/Codem0nky87/multi-session-ai-manager
