#!/bin/bash
# altstore-release.sh — Build IPA, create GitHub release, update AltStore source JSON
#
# Usage:
#   ./scripts/altstore-release.sh --version 1.0 --build 1
#
# Prerequisites:
#   - macOS with Xcode 16+ and xcodegen installed
#   - gh CLI authenticated (https://cli.github.com)
#   - Valid provisioning profile for ad-hoc distribution
#   - jq installed (brew install jq)
#
# What it does:
#   1. Regenerates Xcode project (xcodegen)
#   2. Archives the app
#   3. Exports IPA with ad-hoc signing
#   4. Creates a GitHub release with the IPA attached
#   5. Updates altstore-source.json with the new version
#   6. Commits and pushes the updated JSON

set -euo pipefail

REPO="maroun2/agor-ios"
SCHEME="AgorApp"
BUNDLE_ID="com.agor.AgorApp"
MIN_OS="18.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
EXPORT_PLIST="$SCRIPT_DIR/altstore-export-options.plist"
SOURCE_JSON="$ROOT_DIR/altstore-source.json"

# --- Parse args ---
VERSION=""
BUILD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build)   BUILD="$2";   shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "Usage: $0 --version X.Y --build N"
  exit 1
fi

TAG="v${VERSION}-ios"
IPA_NAME="Agor-${VERSION}.ipa"
ARCHIVE_PATH="/tmp/AgorApp-${VERSION}.xcarchive"
EXPORT_DIR="/tmp/AgorApp-export-${VERSION}"

echo "=== Agor iOS Release ${VERSION} (build ${BUILD}) ==="

# --- Preflight checks ---
command -v xcodegen >/dev/null || { echo "ERROR: xcodegen not found"; exit 1; }
command -v xcodebuild >/dev/null || { echo "ERROR: xcodebuild not found"; exit 1; }
command -v gh >/dev/null || { echo "ERROR: gh CLI not found"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not found (brew install jq)"; exit 1; }

cd "$ROOT_DIR"

# --- Step 1: Regenerate project ---
echo "→ Regenerating Xcode project..."
xcodegen generate

# --- Step 2: Archive ---
echo "→ Archiving..."
xcodebuild archive \
  -project AgorApp.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  | tail -1

# --- Step 3: Export IPA ---
echo "→ Exporting IPA..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$EXPORT_DIR" \
  | tail -1

IPA_PATH="$EXPORT_DIR/${SCHEME}.ipa"
if [[ ! -f "$IPA_PATH" ]]; then
  echo "ERROR: IPA not found at $IPA_PATH"
  ls -la "$EXPORT_DIR"/
  exit 1
fi

cp "$IPA_PATH" "/tmp/${IPA_NAME}"
IPA_SIZE=$(stat -f%z "/tmp/${IPA_NAME}" 2>/dev/null || stat -c%s "/tmp/${IPA_NAME}")
echo "→ IPA ready: /tmp/${IPA_NAME} (${IPA_SIZE} bytes)"

# --- Step 4: Create GitHub release ---
echo "→ Creating GitHub release ${TAG}..."
gh release create "$TAG" \
  --repo "$REPO" \
  --title "Agor iOS v${VERSION}" \
  --notes "Agor iOS v${VERSION} (build ${BUILD})" \
  "/tmp/${IPA_NAME}"

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${IPA_NAME}"
echo "→ Download URL: ${DOWNLOAD_URL}"

# --- Step 5: Update altstore-source.json ---
echo "→ Updating altstore-source.json..."
TODAY=$(date -u +"%Y-%m-%d")

NEW_VERSION=$(cat <<JSONEOF
{
  "version": "${VERSION}",
  "date": "${TODAY}",
  "localizedDescription": "Agor iOS v${VERSION}",
  "downloadURL": "${DOWNLOAD_URL}",
  "size": ${IPA_SIZE},
  "minOSVersion": "${MIN_OS}"
}
JSONEOF
)

# Prepend new version to the versions array in apps[0]
jq --argjson v "$NEW_VERSION" '.apps[0].versions = [$v] + .apps[0].versions' "$SOURCE_JSON" > "${SOURCE_JSON}.tmp"
mv "${SOURCE_JSON}.tmp" "$SOURCE_JSON"

# --- Step 6: Commit and push ---
echo "→ Committing updated source JSON..."
git add "$SOURCE_JSON"
git commit -m "Release Agor iOS v${VERSION}"
git push

echo ""
echo "=== Release complete ==="
echo "  Tag:      ${TAG}"
echo "  IPA:      ${DOWNLOAD_URL}"
echo "  Source:   https://raw.githubusercontent.com/${REPO}/main/altstore-source.json"
