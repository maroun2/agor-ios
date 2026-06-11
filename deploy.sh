#!/bin/bash
# Deploy Agor iOS to connected iPhone
# No Xcode GUI or account session required.
# Run once after a fresh `xcodegen generate` if project.yml changes.

set -eo pipefail

# Always run from repo root so relative paths work regardless of caller's cwd
cd "$(dirname "$0")"

# Prefer first available paired device; fall back to known iPhone UDID
DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
  | awk -F'   +' '/available \(paired\)/ {print $3; exit}')
DEVICE_ID="${DEVICE_ID:-00008120-0006024C3E50A01E}"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
APP=".build/DerivedData/Build/Products/Release-iphoneos/AgorApp.app"
ENTITLEMENTS="/tmp/agor-entitlements.plist"

TEAM_ID="L94RKR8S54"

# Find newest non-expired profile whose application-identifier matches exactly.
# Usage: find_profile <full-app-id>  -> echoes profile path, or returns 1
NOW=$(date +%s)
find_profile() {
  local want="$1" dec appid exp expepoch
  while IFS= read -r p; do
    [ -f "$p" ] || continue
    dec=$(security cms -D -i "$p" 2>/dev/null)
    appid=$(echo "$dec" | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || echo "")
    [ "$appid" = "$want" ] || continue
    exp=$(echo "$dec" | plutil -extract ExpirationDate raw -o - - 2>/dev/null || echo "")
    [ -z "$exp" ] && continue
    expepoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$exp" +%s 2>/dev/null || echo "0")
    if [ "$expepoch" -gt "$NOW" ]; then echo "$p"; return 0; fi
  done < <(ls -t "$PROFILES_DIR"/*.mobileprovision 2>/dev/null)
  return 1
}

APP_PROFILE=$(find_profile "$TEAM_ID.com.agor.AgorApp") || {
  echo "ERROR: No valid profile for com.agor.AgorApp. Open Xcode and build once with Cmd+R to renew it."; exit 1; }
WIDGET_PROFILE=$(find_profile "$TEAM_ID.com.agor.AgorApp.widgets") || {
  echo "ERROR: No valid profile for com.agor.AgorApp.widgets. Open Xcode and build once with Cmd+R to renew it."; exit 1; }

echo "App profile:    $(basename "$APP_PROFILE")"
echo "Widget profile: $(basename "$WIDGET_PROFILE")"

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
if xcodebuild \
  -project AgorApp.xcodeproj \
  -scheme AgorApp \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build 2>&1 | tee "$BUILD_LOG" \
  && grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
  echo "Build succeeded (git: $GIT_HASH)."
else
  echo "ERROR: Build failed. Not deploying."
  exit 1
fi

SIGN_ID="Apple Development: maron2@centrum.cz (95327R65BM)"
echo "Signing..."

# Sign embedded widget extension first (codesign must go inside-out)
APPEX="$APP/PlugIns/AgorWidgets.appex"
if [ -d "$APPEX" ]; then
  WIDGET_ENT="/tmp/agor-widget-entitlements.plist"
  security cms -D -i "$WIDGET_PROFILE" 2>/dev/null \
    | plutil -extract Entitlements xml1 -o "$WIDGET_ENT" -
  cp "$WIDGET_PROFILE" "$APPEX/embedded.mobileprovision"
  codesign --force --sign "$SIGN_ID" --entitlements "$WIDGET_ENT" --timestamp=none "$APPEX"
fi

# Sign main app
security cms -D -i "$APP_PROFILE" 2>/dev/null \
  | plutil -extract Entitlements xml1 -o "$ENTITLEMENTS" -
cp "$APP_PROFILE" "$APP/embedded.mobileprovision"
codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
echo "Signed."

# Install
echo "Installing on device..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

echo ""
echo "Done. Installed git:$GIT_HASH on device $DEVICE_ID."
