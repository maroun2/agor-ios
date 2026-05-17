# AltStore Distribution

Agor iOS is distributed via [AltStore](https://altstore.io) for sideloading on non-jailbroken iPhones.

## For Users

### Add the Agor source

1. Open AltStore on your iPhone
2. Go to **Browse** → **Sources**
3. Tap **+** and paste:
   ```
   https://raw.githubusercontent.com/maroun2/agor-ios/main/altstore-source.json
   ```
4. Tap **Add Source**

### Install Agor

1. Find **Agor** in the Browse tab
2. Tap **Install**
3. AltStore will download and sign the app automatically

### Update

When a new version is released, AltStore will show an update badge. Tap **Update** to install.

> **Note:** AltStore requires refreshing apps every 7 days. Enable background refresh in AltStore settings to automate this.

## For Maintainers

### Prerequisites

- macOS with Xcode 16+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) installed
- [gh CLI](https://cli.github.com) authenticated
- [jq](https://jqlang.github.io/jq/) installed
- Valid provisioning profile for ad-hoc distribution

### Creating a release

```bash
./scripts/altstore-release.sh --version 1.1 --build 2
```

This will:
1. Regenerate the Xcode project via xcodegen
2. Archive and export an IPA with ad-hoc signing
3. Create a GitHub release with the IPA attached
4. Update `altstore-source.json` with the new version entry
5. Commit and push the updated JSON

The AltStore source URL is stable — users only need to add it once.

### Manual IPA build (without release)

```bash
# Generate project
xcodegen generate

# Archive
xcodebuild archive \
  -project AgorApp.xcodeproj \
  -scheme AgorApp \
  -configuration Release \
  -sdk iphoneos \
  -archivePath /tmp/AgorApp.xcarchive

# Export IPA
xcodebuild -exportArchive \
  -archivePath /tmp/AgorApp.xcarchive \
  -exportOptionsPlist scripts/altstore-export-options.plist \
  -exportPath /tmp/AgorApp-export
```

### Version scheme

- Version: `MAJOR.MINOR` (e.g., `1.0`, `1.1`, `2.0`)
- Build number: integer, incremented each release
- Git tag: `vX.Y-ios` (e.g., `v1.0-ios`)

## Submodule (upstream)

To add this repo as a submodule in the upstream `agor` monorepo:

```bash
git submodule add https://github.com/maroun2/agor-ios apps/agor-ios
```

> **Note:** This requires a PR to the upstream repo and is out of scope for this standalone repo.
