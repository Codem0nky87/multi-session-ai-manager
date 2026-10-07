fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios build_testflight

```sh
[bundle exec] fastlane ios build_testflight
```

Archive and export a signed IPA for TestFlight without uploading

### ios upload_testflight

```sh
[bundle exec] fastlane ios upload_testflight
```

Upload the existing signed IPA and wait for TestFlight processing (internal)

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Archive and upload a build to TestFlight (internal)

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
