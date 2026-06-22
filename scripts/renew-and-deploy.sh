#!/bin/bash
# renew-and-deploy.sh — Keep the free-provisioning Agor build alive on the iPhone.
#
# Free Apple Developer ("personal team") provisioning profiles expire 7 days after
# they are issued; once expired, the installed app refuses to launch. Run periodically
# by a launchd agent, this script watches the app profile's expiry and — when it is
# within RENEW_WITHIN_DAYS of expiring (or already expired) AND the iPhone is reachable
# (USB or WiFi tunnel) — rebuilds with automatic signing, which renews the profile via
# `-allowProvisioningUpdates`, then reinstalls. Reinstalling resets the 7-day timer.
#
# Most runs are no-ops: if the profile is still valid for long enough, the script exits
# in well under a second without touching the device or running a build.
#
# One-time prerequisites:
#   1. iOS platform installed in Xcode:   xcodebuild -downloadPlatform iOS
#   2. Apple ID signed in to Xcode (Settings > Accounts). The -allowProvisioningUpdates
#      flow reuses this cached session. Apple occasionally forces a re-login (2FA); when
#      that happens this script logs an auth error and you must open Xcode once and sign
#      in again. No script can bypass that 2FA step.
#
# Manual run:   bash scripts/renew-and-deploy.sh
# Force a renew regardless of expiry:   FORCE=1 bash scripts/renew-and-deploy.sh
# Logs:         ~/Library/Logs/agor-renew.log

set -uo pipefail

REPO="/Volumes/Seagate/projects/agor-ios"
SCHEME="AgorApp"
TEAM_ID="L94RKR8S54"
APP_BUNDLE_ID="com.agor.AgorApp"
DERIVED=".build/DerivedData"
RENEW_WITHIN_DAYS="${RENEW_WITHIN_DAYS:-3}"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
XCODE_APP="/Volumes/Seagate/Xcode16.app"
LOG="$HOME/Library/Logs/agor-renew.log"
FORCE="${FORCE:-0}"

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

cd "$REPO" || { log "ERR: repo not found at $REPO"; exit 1; }

# --- 1. Days until the newest valid app profile expires ---
NOW=$(date +%s)
newest_exp=0
while IFS= read -r p; do
  [ -f "$p" ] || continue
  dec=$(security cms -D -i "$p" 2>/dev/null)
  appid=$(echo "$dec" | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || echo "")
  [ "$appid" = "$TEAM_ID.$APP_BUNDLE_ID" ] || continue
  exp=$(echo "$dec" | plutil -extract ExpirationDate raw -o - - 2>/dev/null || echo "")
  [ -z "$exp" ] && continue
  ep=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$exp" +%s 2>/dev/null || echo 0)
  [ "$ep" -gt "$newest_exp" ] && newest_exp=$ep
done < <(ls -t "$PROFILES_DIR"/*.mobileprovision 2>/dev/null)

if [ "$newest_exp" -gt 0 ]; then
  days_left=$(( (newest_exp - NOW) / 86400 ))
else
  days_left=-999   # no profile present at all
fi

if [ "$FORCE" != "1" ] && [ "$newest_exp" -gt 0 ] && [ "$days_left" -gt "$RENEW_WITHIN_DAYS" ]; then
  log "OK: app profile valid ${days_left} more days (> ${RENEW_WITHIN_DAYS}); nothing to do."
  exit 0
fi
log "Renewal due: days_left=${days_left}, threshold=${RENEW_WITHIN_DAYS}, force=${FORCE}."

# --- 2. iPhone reachable? (devicectl reports 'connected' or 'available (paired)') ---
DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
  | awk -F'   +' '/(connected|available \(paired\))/ {print $3; exit}')
if [ -z "$DEVICE_ID" ]; then
  log "iPhone not reachable (off WiFi / asleep). Will retry next run."
  exit 0
fi
log "Device reachable: $DEVICE_ID"

# --- 3. iOS build platform usable? (a real destination with no error) ---
# Note: `xcodebuild -showsdks` still lists iOS even when the platform component was
# removed, so check for a usable destination instead.
if ! DEVELOPER_DIR="$XCODE_APP/Contents/Developer" xcodebuild \
      -project AgorApp.xcodeproj -scheme "$SCHEME" -showdestinations 2>&1 \
      | grep "platform:iOS" | grep -qv "error:"; then
  log "ERR: no usable iOS build destination — the iOS platform was removed."
  log "     Fix once:  xcodebuild -downloadPlatform iOS   (or install it via Xcode)."
  exit 1
fi

# --- 4. Regenerate project + git hash, then build with automatic signing (renews profile) ---
if [ "project.yml" -nt "AgorApp.xcodeproj/project.pbxproj" ]; then
  log "Regenerating Xcode project (xcodegen)..."
  xcodegen generate >>"$LOG" 2>&1
fi
mkdir -p AgorApp/Generated
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
cat > AgorApp/Generated/GitVersion.swift <<EOF
// Auto-generated at build time — do not edit
enum GitVersion {
    static let hash = "$GIT_HASH"
}
EOF

log "Building with automatic signing + -allowProvisioningUpdates (renews profile)..."
BUILD_LOG=$(mktemp)
if DEVELOPER_DIR="$XCODE_APP/Contents/Developer" xcodebuild \
    -project AgorApp.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    build >"$BUILD_LOG" 2>&1 && grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
  log "Build + profile renewal succeeded (git: $GIT_HASH)."
else
  log "ERR: build/signing failed. Tail of build log:"
  tail -n 25 "$BUILD_LOG" | tee -a "$LOG"
  if grep -qiE "authenticat|account|sign in|session|Apple ID|no profiles for" "$BUILD_LOG"; then
    log "HINT: Apple ID auth issue — open Xcode once and sign in (Settings > Accounts), then it self-heals."
  fi
  if grep -qiE "is not installed|downloadPlatform|no destinations" "$BUILD_LOG"; then
    log "HINT: iOS platform missing — run once: xcodebuild -downloadPlatform iOS"
  fi
  exit 1
fi

# --- 5. Install (resets the 7-day timer) ---
APP="$DERIVED/Build/Products/Release-iphoneos/AgorApp.app"
log "Installing on device $DEVICE_ID..."
if xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >>"$LOG" 2>&1; then
  log "DONE: installed git:$GIT_HASH; profile renewed, 7-day timer reset."
else
  log "ERR: install failed (see log above)."
  exit 1
fi
