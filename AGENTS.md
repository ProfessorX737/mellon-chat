# Mellon Chat Agent Notes

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

The logs include structured events for chat startup, route handling, subchat entry/close, sends, thread hydration, and forwarded Matrix warnings/errors. When debugging subchat issues, look for `room_id`, `thread_root_event_id`, `conversation_key`, `session_id`, hydration counts, and the latest visible/display event fields.

Logging must stay non-blocking. `DevLogSink` should never throw into UI flows, and failures to post logs should not affect chat behavior.
