# Mellon Chat Agent Notes

## Note Hygiene

Keep `AGENTS.md` lean. Add only durable rules or facts that are likely to help
future sessions, prefer short entries, and avoid archiving transient debugging
details once the issue is resolved.

## Build And Release

Use the repo-local FVM Flutter first:

```sh
export PATH="$PWD/.fvm/flutter_sdk/bin:$PATH"
flutter --version
```

The repo's `.fvm/flutter_sdk` points at `/Users/xavier/fvm/versions/3.41.1`.
`/Users/xavier/fvm` is a symlink to the external SSD at
`/Volumes/MacMiniSSD - Data/OffloadedFromInternal/xavier/home/fvm`, so the SSD
must be mounted before building.

Do not reuse App Store Connect build numbers. Build `0.1.0 (3)` was used on
May 20, 2026, so future uploads should use a higher build number unless App
Store Connect says otherwise.

### iOS

There are repo scripts:

- `scripts/build-ios.sh`: legacy helper that ends with `flutter build ipa --release`.
- `scripts/release-ios-testflight.sh`: mutates dependencies/pods and then runs
  Fastlane. It previously reached the Apple ID prompt, so prefer Transporter
  unless the user explicitly wants Fastlane auth.

Known-good manual build:

```sh
export PATH="$PWD/.fvm/flutter_sdk/bin:$PATH"
flutter clean
flutter pub get
flutter build ipa --release --build-name=0.1.0 --build-number=<next_build_number>
```

Output:

```sh
build/ios/ipa/Mellon Chat.ipa
```

Upload path: open the IPA in Transporter and deliver it from there. Do not store
Apple ID credentials in repo notes.

### Android

Use the repo-local FVM Flutter and the local Android SDK:

```sh
export PATH="$PWD/.fvm/flutter_sdk/bin:$HOME/Library/Android/sdk/cmdline-tools/latest/bin:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
flutter doctor -v
```

The local Android SDK was set up on June 5, 2026. A healthy setup had Android
SDK 36, Java 17, accepted Android licenses, and these on-demand packages already
installed/cached by the first release build: platform/build-tools 36, platform
35/34/33/31, build-tools 35, NDK 28.2.13676358, NDK 27.0.12077973, and CMake
3.22.1. If another first-build-style setup error appears, install the missing
package with `sdkmanager --sdk_root="$HOME/Library/Android/sdk" ...` and rerun
`flutter doctor -v`.

For the fastest normal rebuild, do not run `flutter clean` unless there is a
real cache/signing problem. Keep Gradle, Dart, and native-library caches warm,
and run `flutter pub get` only when dependencies changed.

Known-good Play Store app bundle build:

```sh
flutter build appbundle --release --target-platform android-arm,android-arm64 \
  --build-name=2.4.0 --build-number=<next_build_number>
```

Prefer passing `--build-name` and `--build-number` explicitly so `pubspec.yaml`
does not need to be mutated for a release. Internal testing had latest release
`3546 (2.4.0)` before the June 5, 2026 Android upload, and `3547 (2.4.0)` was
used for that upload. Use a higher version code next time.

Output:

```sh
build/app/outputs/bundle/release/app-release.aab
```

The release signing config reads `android/key.properties`, which should stay
untracked. The keystore lives at `android/app/mellon-release.keystore`.

There are existing Android/Fastlane scripts, but do not use them by default:
`scripts/prepare-android-release.sh` installs/runs Fastlane and mutates
`pubspec.yaml` after querying Google Play, and `android/fastlane/keys.json` is
not present locally. The manual `flutter build appbundle ...` plus Play Console
upload path is currently the lower-risk release path.

For Google Play internal testing, use the Play Console developer/app URL:

```sh
https://play.google.com/console/u/0/developers/8695014147651820678/app/4974249455423960822/app-dashboard
```

Use the Chrome profile signed in as `xavier@habitedge.app`; the personal
`xavierpoon737@gmail.com` profile redirects to Play Console signup and cannot
access the app.

Upload path: go to Test and release > Testing > Internal testing, create a new
release, upload `build/app/outputs/bundle/release/app-release.aab`, continue to
Preview and confirm, then use `Save and publish` for internal testing only after
the user confirms. On the June 5, 2026 upload, Play showed no device support
losses for version `3547 (2.4.0)`.

### macOS

`scripts/build-macos.sh` exists, but it only runs `flutter build macos --release`
and still prints the old `FluffyChat.app` name. For a local unsigned-ish release
app, this worked:

```sh
export PATH="$PWD/.fvm/flutter_sdk/bin:$PATH"
flutter build macos --release --build-name=0.1.0 --build-number=<next_build_number>
```

Local app output:

```sh
build/macos/Build/Products/Release/Mellon Chat.app
```

For an App Store Connect/Transporter package, use an Xcode archive/export flow.
Automatic signing worked; forcing `CODE_SIGN_IDENTITY=Apple Distribution`
caused CocoaPods signing conflicts.

```sh
export PATH="$PWD/.fvm/flutter_sdk/bin:$PATH"
rm -rf build/macos/archive build/macos/export

xcodebuild \
  -workspace macos/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$PWD/build/macos/archive/Runner.xcarchive" \
  archive \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=2C95M5M4MV \
  FLUTTER_BUILD_NAME=0.1.0 \
  FLUTTER_BUILD_NUMBER=<next_build_number>

cat > /tmp/mellon-macos-export.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>teamID</key>
  <string>2C95M5M4MV</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$PWD/build/macos/archive/Runner.xcarchive" \
  -exportPath "$PWD/build/macos/export" \
  -exportOptionsPlist /tmp/mellon-macos-export.plist \
  -allowProvisioningUpdates
```

Package output:

```sh
build/macos/export/Mellon Chat.pkg
```

Open it in Transporter:

```sh
open -a Transporter "build/macos/export/Mellon Chat.pkg"
```

Only click Deliver after the user confirms the upload.

### Cleanup And Space Notes

Safe generated cleanup after a release:

```sh
rm -rf .dart_tool build/macos/archive build/web build/native_assets
```

Keep `build/macos/export/Mellon Chat.pkg` if the macOS package still needs to be
uploaded. The iOS/macOS build process can also refill simulator caches. If disk
space gets tight, inspect first with `du -sh`, then ask before deleting or
moving anything non-generated.

## Debug Logs

Mellon Chat has a lightweight web debug-log loop for reproductions on the deployed app.

- Client logger: `lib/utils/dev_log_sink.dart`
- Receiver/server: `deploy/dev-log-server.mjs`
- Browser endpoint: `POST /__mellon_debug_logs`
- Local log file: `/tmp/mellon-chat/subchat-routing.jsonl`
- Human view: `https://chat.mellon.chat/__mellon_debug_logs`
- JSON view: `https://chat.mellon.chat/__mellon_debug_logs?format=json`

Useful local commands:

```sh
tail -n 200 /tmp/mellon-chat/subchat-routing.jsonl
curl -fsS 'http://127.0.0.1:8092/?format=json'
```

Default deployed logging is intentionally allowlisted so normal use is not too
noisy. For a deep reproduction, open the app with `?debug_logs=verbose` to
include startup, route, timeline, and per-candidate hydration logs.

When debugging subchat load performance, remember that repeat opens use a
session-only hydration cache in `lib/pages/chat/chat.dart`. Start with
`hydration_cache_restore`, `open_initial_hydrate_skip_cache`,
`thread_hydrate_end`, and `edit_hydrate_done`; compare `room_id`,
`thread_root_event_id`, `conversation_key`, `session_id`, hydration counts, and
latest visible/display event fields.

Logging must stay non-blocking. `DevLogSink` should never throw into UI flows, and failures to post logs should not affect chat behavior.
