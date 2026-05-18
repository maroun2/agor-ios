#!/bin/bash
# altstore-release.sh — Build IPA, create GitHub release, update AltStore source JSON
#
# Usage:
#   ./scripts/altstore-release.sh --version X.Y
#
# Prerequisites:
#   - macOS with Xcode 16+ and xcodegen installed
#   - gh CLI authenticated (https://cli.github.com)
#   - jq installed (brew install jq)
#
# What it does:
#   1. Regenerates Xcode project (xcodegen)
#   2. Resolves SPM package dependencies
#   3. Archives the app (unsigned — AltStore re-signs on device)
#   4. Packages .app into IPA
#   5. Creates a GitHub release with the IPA attached
#   6. Updates altstore-source.json with the new version
#   7. Commits and pushes the updated JSON

set -euo pipefail

REPO="maroun2/agor-ios"
SCHEME="AgorApp"
BUNDLE_ID="com.agor.AgorApp"
MIN_OS="18.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE_JSON="$ROOT_DIR/altstore-source.json"

# --- Parse args ---
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 --version X.Y"
  exit 1
fi

TAG="v${VERSION}-ios"
IPA_NAME="Agor-${VERSION}.ipa"
ARCHIVE_PATH="/tmp/AgorApp-${VERSION}.xcarchive"

# --- Preflight checks ---
command -v xcodegen >/dev/null || { echo "ERROR: xcodegen not found"; exit 1; }
command -v xcodebuild >/dev/null || { echo "ERROR: xcodebuild not found"; exit 1; }
command -v gh >/dev/null || { echo "ERROR: gh CLI not found"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not found (brew install jq)"; exit 1; }

cd "$ROOT_DIR"

# --- Auto-derive build number from git ---
BUILD=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse --short HEAD)

echo "=== Agor iOS Release ${VERSION} (build ${BUILD}, ${COMMIT}) ==="

# --- Step 1: Regenerate project ---
echo "→ Regenerating Xcode project..."
xcodegen generate

# --- Step 2: Resolve packages ---
echo "→ Resolving SPM dependencies..."
xcodebuild -resolvePackageDependencies \
  -project AgorApp.xcodeproj \
  -scheme "$SCHEME"

# --- Step 3: Archive (unsigned for AltStore) ---
echo "→ Archiving..."
xcodebuild archive \
  -project AgorApp.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD"

# --- Step 4: Package IPA ---
echo "→ Packaging IPA..."
APP_PATH=$(find "$ARCHIVE_PATH/Products/Applications" -name "*.app" -maxdepth 1 | head -1)
if [[ -z "$APP_PATH" ]]; then
  echo "ERROR: No .app found in archive"
  ls -laR "$ARCHIVE_PATH/Products/" 2>/dev/null || echo "Products dir missing"
  exit 1
fi

IPA_STAGING="/tmp/AgorApp-ipa-staging"
rm -rf "$IPA_STAGING"
mkdir -p "$IPA_STAGING/Payload"
cp -R "$APP_PATH" "$IPA_STAGING/Payload/"
cd "$IPA_STAGING"
zip -qr "/tmp/${IPA_NAME}" Payload
cd "$ROOT_DIR"
rm -rf "$IPA_STAGING"

IPA_SIZE=$(stat -f%z "/tmp/${IPA_NAME}" 2>/dev/null || stat -c%s "/tmp/${IPA_NAME}")
echo "→ IPA ready: /tmp/${IPA_NAME} (${IPA_SIZE} bytes)"

# --- Step 5: Create GitHub release ---
echo "→ Creating GitHub release ${TAG}..."
gh release create "$TAG" \
  --repo "$REPO" \
  --title "Agor iOS v${VERSION}" \
  --notes "Agor iOS v${VERSION} - build ${BUILD} (${COMMIT})" \
  "/tmp/${IPA_NAME}"

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${IPA_NAME}"
echo "→ Download URL: ${DOWNLOAD_URL}"

# --- Step 6: Update altstore-source.json ---
echo "→ Updating altstore-source.json..."
TODAY=$(date -u +"%Y-%m-%d")

NEW_VERSION=$(cat <<JSONEOF
{
  "version": "${VERSION}",
  "date": "${TODAY}",
  "localizedDescription": "Agor iOS v${VERSION} (${COMMIT})",
  "downloadURL": "${DOWNLOAD_URL}",
  "size": ${IPA_SIZE},
  "minOSVersion": "${MIN_OS}"
}
JSONEOF
)

# Prepend new version to the versions array in apps[0]
jq --argjson v "$NEW_VERSION" '.apps[0].versions = [$v] + .apps[0].versions' "$SOURCE_JSON" > "${SOURCE_JSON}.tmp"
mv "${SOURCE_JSON}.tmp" "$SOURCE_JSON"

# --- Step 7: Commit and push ---
echo "→ Committing updated source JSON..."
git add "$SOURCE_JSON"
git commit -m "Release Agor iOS v${VERSION}"
git push

echo ""
echo "=== Release complete ==="
echo "  Tag:      ${TAG}"
echo "  IPA:      ${DOWNLOAD_URL}"
echo "  Source:   https://raw.githubusercontent.com/${REPO}/main/altstore-source.json"
