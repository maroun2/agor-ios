# Agor iOS — Build & Deploy Guide

Based on actual build experience on macOS 15 (Sequoia).

---

## Requirements

- macOS 15 (Sequoia) or later
- Xcode 16.x (NOT 26.x — Xcode 26 requires macOS 26)
- Free Apple ID (no paid Developer Program needed for personal device)
- iPhone with iOS 18+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

---

## Xcode Setup

Xcode 16.x must be used. Download from [developer.apple.com/download/all](https://developer.apple.com/download/all).

Extract the `.xip` to a local APFS volume (not exFAT/NTFS):

```bash
mkdir -p /Volumes/YourDrive/.xip-tmp
cd /Volumes/YourDrive/.xip-tmp
xip -x /path/to/Xcode_16.x.xip
mv Xcode.app /Volumes/YourDrive/Xcode16.app
```

Point the system to it:

```bash
sudo xcode-select -s /Volumes/YourDrive/Xcode16.app/Contents/Developer
xcode-select -p  # verify
xcodebuild -version  # should print Xcode 16.x
```

Run first-launch setup (required once):

```bash
sudo xcodebuild -runFirstLaunch
```

Download the iOS SDK (8–9 GB):

```bash
xcodebuild -downloadPlatform iOS
```

---

## Signing Setup (one-time)

Open Xcode 16:

```bash
open /Volumes/YourDrive/Xcode16.app
```

1. **Xcode → Settings → Accounts → `+` → Apple ID** — sign in
2. Click your account → **Manage Certificates → `+` → Apple Development**

This creates a signing certificate in your keychain. Get your Team ID:

```bash
security find-certificate -a | grep "Apple Development"
# Look for: "alis"<blob>="Apple Development: you@email.com (TEAMID10CH)"
```

The 10-character string in parentheses is your Team ID.

---

## Generate Xcode Project

The repo uses `project.yml` (xcodegen) instead of a checked-in `.xcodeproj` structure. Set your Team ID in `project.yml`:

```yaml
settings:
  DEVELOPMENT_TEAM: "YOUR10CHARID"
```

Then generate:

```bash
cd apps/agor-ios
xcodegen generate
```

---

## Build

### Simulator

```bash
xcodebuild -project AgorApp.xcodeproj \
  -scheme AgorApp \
  -destination 'platform=iOS Simulator,id=<simulator-uuid>' \
  -derivedDataPath .build/DerivedData \
  build
```

Find simulator UUIDs:

```bash
xcrun simctl list devices available | grep iPhone
```

Boot and run:

```bash
xcrun simctl boot <simulator-uuid>
xcrun simctl install <simulator-uuid> .build/DerivedData/Build/Products/Debug-iphonesimulator/AgorApp.app
xcrun simctl launch <simulator-uuid> com.agor.AgorApp
open -a /Volumes/YourDrive/Xcode16.app/Contents/Developer/Applications/Simulator.app
```

### Real iPhone

Connect iPhone via USB. Enable **Developer Mode** on the phone:

> Settings → Privacy & Security → Developer Mode → ON (requires restart)

Pair the device:

```bash
xcrun devicectl manage pair --device <device-id>
# Find device-id with: xcrun devicectl list devices
```

Build and deploy:

```bash
xcodebuild -project AgorApp.xcodeproj \
  -scheme AgorApp \
  -destination 'platform=iOS,id=<device-udid>' \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  -derivedDataPath .build/DerivedData \
  build
```

First install requires opening in Xcode 16 GUI (File → Open → `AgorApp.xcodeproj`, select device, Cmd+R).

**Trust the certificate on iPhone:**

> Settings → General → VPN & Device Management → Apple Development: you@email.com → Trust

---

## Connecting to the Daemon

On the iOS app login screen, enter the daemon URL:

- **Local network:** `http://192.168.x.x:3030` (find your Mac's IP with `ipconfig getifaddr en0`)
- **Remote:** whatever URL you use to access the daemon in the browser

The daemon must be running (`pnpm dev` in `apps/agor-daemon`).

---

## Rebuilding After Code Changes

```bash
cd apps/agor-ios
xcodegen generate   # only needed if project.yml changed
xcodebuild -project AgorApp.xcodeproj \
  -scheme AgorApp \
  -destination 'platform=iOS,id=<device-udid>' \
  -allowProvisioningUpdates \
  -derivedDataPath .build/DerivedData \
  build
```

Then install to device:

```bash
xcrun devicectl device install app \
  --device <device-udid> \
  .build/DerivedData/Build/Products/Debug-iphoneos/AgorApp.app
```

**Note:** If `xcodebuild` fails with "No Account for Team", the Xcode session has expired.
Open Xcode 16, select the device, and press **Cmd+R** once to refresh it. CLI builds work after that.

---

## Notes

- **Xcode 26.x won't open on macOS 15** — it requires macOS 26 (Tahoe). Use Xcode 16.x.
- **iOS SDK goes to internal SSD** (`/System/Library/AssetsV2/`) — SIP prevents moving it.
- **Build artifacts** go to `.build/DerivedData/` — gitignored.
- **Free Apple ID certificates** expire after 7 days — you'll need to rebuild and re-trust.
- **Paid Apple Developer Program** ($99/yr) gives 1-year certificates and App Store distribution.
