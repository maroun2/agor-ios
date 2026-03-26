#!/bin/bash
# Deploy Agor iOS to connected iPhone
# No Xcode GUI or account session required.
# Run once after a fresh `xcodegen generate` if project.yml changes.

set -e

DEVICE_ID="00008101-001E38812660001E"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
PROFILE_UUID="57c6d436-79f9-4192-b712-440b12c9c3de"
PROFILE="$PROFILE_DIR/$PROFILE_UUID.mobileprovision"
APP=".build/DerivedData/Build/Products/Release-iphoneos/AgorApp.app"
ENTITLEMENTS="/tmp/agor-entitlements.plist"

# Verify profile exists and is not expired
if [ ! -f "$PROFILE" ]; then
  echo "ERROR: Provisioning profile not found at $PROFILE"
  echo "Open Xcode, build once with Cmd+R, then run: cp ~/Library/Developer/Xcode/UserData/Provisioning\\ Profiles/*.mobileprovision \"$PROFILE_DIR/\""
  exit 1
fi

EXPIRY=$(security cms -D -i "$PROFILE" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null || echo "unknown")
echo "Profile expires: $EXPIRY"

# Regenerate project if project.yml is newer than .xcodeproj
if [ "project.yml" -nt "AgorApp.xcodeproj/project.pbxproj" ]; then
  echo "Regenerating Xcode project..."
  xcodegen generate
fi

# Build (no signing)
echo "Building..."
xcodebuild \
  -project AgorApp.xcodeproj \
  -scheme AgorApp \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" || true

# Extract entitlements
security cms -D -i "$PROFILE" 2>/dev/null \
  | plutil -extract Entitlements xml1 -o "$ENTITLEMENTS" -

# Embed profile + sign
cp "$PROFILE" "$APP/embedded.mobileprovision"
codesign --force \
  --sign "Apple Development: maron2@centrum.cz (95327R65BM)" \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$APP"

# Install
echo "Installing on device..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

echo "Done."
