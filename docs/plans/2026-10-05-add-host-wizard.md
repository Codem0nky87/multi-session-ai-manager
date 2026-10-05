# Add-host wizard repair

**Goal:** Restore SSH key installation and remote folder selection, and require verified Herdr before services and the remaining wizard steps.

**Architecture:** Reuse `HostEditView` as the wizard's validated, non-saving first step. A small observable provisioning model owns the existing Herdr/updater installers and exposes readiness to the wizard. Keep one connection for setup, serialize operations, and cancel/drain work before disconnecting.

**Tech stack:** SwiftUI, Observation, Swift Testing, XCTest, existing SSH/SFTP services.

1. Add a hermetic UI regression for the missing key-install and remote-browser controls; run it against the broken wizard.
2. Add a continuation mode to `HostEditView`, retaining key generation/import/install and using `WorkdirPickerSheet` for workdir selection. Preserve the draft across Back/Next and validate before connecting or saving.
3. Add provisioning tests for absent/present/old Herdr, failed installation, service failure/approval, successful readiness, and cancellation. Reuse the existing installers; discovering Herdr is read-only, installation is explicit, and services are gated on the supported version.
4. Replace step 2's unverified success path with visible Herdr, metrics, and updater stages. Persist verified updater readiness in the saved host. Make step 3 use the existing persisted updater policy and real restore integration controls instead of nonfunctional toggles.
5. Regenerate the Xcode project, run the targeted unit and UI checks, review the diff, and document the revised flow. No real host is provisioned during verification.

## Validation

- 36 targeted Swift tests passed: wizard provisioning, Herdr installation, and updater operations.
- Both simulator wizard UI tests passed, including key-installer presentation, remote-explorer presentation, refusal to select a folder after connection failure, and draft preservation on Back.
- Review retained the established explicit updater-skip path: Herdr and metrics remain required, and skipped updater setup is saved with a warning.
- Actual remote installation was exercised through the fake SSH transport, not on a live host.

## Remote browser follow-up

- Folder selection now lists directories through bounded SSH exec, without an
  SFTP subsystem dependency. The default starting point is the remote home;
  linked directories and names containing spaces, quotes, or newlines work.
- Removed the row drag gesture that intercepted scrolling. Each successful
  directory change resets the list to the top. Failed navigation retains the
  previous path and entries together and disables selection until recovery.
- The SSH OS probe recognizes both CMD and PowerShell; drive and UNC navigation
  preserve absolute paths. Windows has unit coverage, not live host verification.
- `python3 scripts/test-workdir-browser.py 'platform=iOS Simulator,id=…'` creates
  a disposable loopback SSH server, explicitly verifies SFTP rejection, and runs
  the browser/model/provisioning tests plus wizard UI tests. Fixture credentials
  and public-key authorization remain inside the temporary directory.
- Final follow-up validation: 41 targeted Swift tests and all 3 simulator wizard
  UI tests passed, including selecting a nested linked folder on the live SSH
  fixture while its SFTP subsystem was disabled.
- TestFlight follow-up: version 1.0, build 202610051724, successfully archived,
  signed, and uploaded through the existing `fastlane beta` lane.
- App Store Connect confirmed build 202610051724 as `VALID` and
  `IN_BETA_TESTING` for internal testers.

## Service setup follow-up

- An SSH server without an SFTP subsystem rejected the metrics upload, leaving
  the wizard waiting before any updater files or logs existed. A live regression
  reproduced the stalled install and failed with a bounded timeout.
- Linux/macOS setup resources now use bounded SSH exec uploads with a 64 KiB
  resource limit, size verification, explicit completion acknowledgement, and
  atomic replacement. Permissions are applied before replacement; directory
  destinations are rejected. General file transfers and Windows uploads retain
  their existing implementation.
- Linux updater startup and verification supply missing user-bus environment
  values from the discovered UID. This supports SSH sessions without PAM when
  the user manager already exists; it does not enable linger or change sshd.
- Validation: 48 targeted Swift tests passed, including live SFTP-disabled
  metrics installation, maximum-size/binary uploads, upload failure preservation,
  executable replacements, directory rejection, and Linux service command
  verification with session variables unset. The same production upload code
  also verified both bundled assets in temporary files on the affected Linux
  host; those temporary files were removed without installing a service.
- TestFlight version 1.0, build 202610051804, uploaded successfully. App Store
  Connect confirmed `VALID` processing and `IN_BETA_TESTING` for internal testers.
