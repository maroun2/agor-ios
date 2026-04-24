#!/bin/bash
# Deploy Agor iOS to connected iPhone
# No Xcode GUI or account session required.
# Run once after a fresh `xcodegen generate` if project.yml changes.

set -e

DEVICE_ID="00008101-001E38812660001E"
PROFILE_UUID="8c1ea10f-7151-4056-b2fe-7497b0114623"
PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
APP=".build/DerivedData/Build/Products/Release-iphoneos/AgorApp.app"
ENTITLEMENTS="/tmp/agor-entitlements.plist"

# Verify profile exists
if [ ! -f "$PROFILE" ]; then
  echo "ERROR: Provisioning profile not found. Open Xcode and build once with Cmd+R to renew it."
  exit 1
fi

EXPIRY=$(security cms -D -i "$PROFILE" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null || echo "unknown")
echo "Profile expires: $EXPIRY"

# Regenerate project if project.yml is newer than .xcodeproj
if [ "project.yml" -nt "AgorApp.xcodeproj/project.pbxproj" ]; then
  echo "Regenerating Xcode project..."
  xcodegen generate
fi

# Generate GitVersion.swift (gitignored, required by Xcode project)
mkdir -p AgorApp/Generated
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
cat > AgorApp/Generated/GitVersion.swift << EOF
// Auto-generated at build time — do not edit
enum GitVersion {
    static let hash = "$GIT_HASH"
}
EOF

# Build (no signing)
BUILD_LOG=$(mktemp /tmp/agor-build-XXXXXX)
echo "Building... (log: $BUILD_LOG)"
xcodebuild \
  -project AgorApp.xcodeproj \
  -scheme AgorApp \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build 2>&1 | tee "$BUILD_LOG"

if grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
  echo "Build succeeded (git: $GIT_HASH)."
else
  echo "ERROR: Build failed. Not deploying."
  exit 1
fi

# Extract entitlements
echo "Signing..."
security cms -D -i "$PROFILE" 2>/dev/null \
  | plutil -extract Entitlements xml1 -o "$ENTITLEMENTS" -

# Embed profile + sign
cp "$PROFILE" "$APP/embedded.mobileprovision"
codesign --force \
  --sign "Apple Development: maron2@centrum.cz (95327R65BM)" \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$APP"
echo "Signed."

# Install
echo "Installing on device..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

echo ""
echo "Done. Installed git:$GIT_HASH on device $DEVICE_ID."
