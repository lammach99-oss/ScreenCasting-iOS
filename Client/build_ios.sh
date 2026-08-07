#!/bin/bash
# build_ios.sh - Compiles iPadCasting Swift/Metal iOS App and packages valid .ipa

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/Client/build"
IPA_PATH="$BUILD_DIR/iPadCasting.ipa"

echo "==========================================================="
echo "       Building iPadCasting iOS App (arm64 HEVC/Metal)     "
echo "==========================================================="

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

command -v xcodebuild >/dev/null 2>&1 ||
  { echo "ERROR: xcodebuild is required." >&2; exit 1; }
PROJECT="$REPO_ROOT/Client/iPadZeroLagDisplay/iPadCasting.xcodeproj"
[ -d "$PROJECT" ] ||
  { echo "ERROR: iPadCasting.xcodeproj is missing." >&2; exit 1; }

echo "[+] Archiving via xcodebuild (Release, generic iOS device)..."
ARCHIVE_PATH="$BUILD_DIR/iPadCasting.xcarchive"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme iPadCasting \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$BUILD_DIR/xcodebuild.log"

APP_BUNDLE="$ARCHIVE_PATH/Products/Applications/iPadCasting.app"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ ERROR: Compilation failed! App bundle not generated."
    exit 1
fi

# Package into valid .ipa archive
echo "[+] Packaging into Payload/ structure..."
PAYLOAD_DIR="$BUILD_DIR/Payload"
mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_BUNDLE" "$PAYLOAD_DIR/iPadCasting.app"

cd "$BUILD_DIR"
zip -qr iPadCasting.ipa Payload/
rm -rf Payload/

echo "==========================================================="
echo "  BUILD SUCCESS! Created: $IPA_PATH"
echo "==========================================================="

# Run Diagnostic Inspector if check_ipa.sh is present
CHECK_SCRIPT="$REPO_ROOT/Client/check_ipa.sh"
if [ -f "$CHECK_SCRIPT" ]; then
    chmod +x "$CHECK_SCRIPT"
    "$CHECK_SCRIPT" "$IPA_PATH"
fi
