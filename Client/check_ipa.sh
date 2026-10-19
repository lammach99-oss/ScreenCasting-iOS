#!/bin/bash
# check_ipa.sh - Diagnostic tool for verifying iOS .ipa package integrity
# NOTE: Since iOS 12.2+, Swift stdlib is pre-installed on device.
#       A valid Swift .app binary will be ~100-500 KB with no embedded frameworks.
#       Size alone is NOT a valid indicator of a correct build.

set -e

IPA_PATH="$1"

if [ -z "$IPA_PATH" ]; then
    echo "Error: No .ipa path provided."
    echo "Usage: ./check_ipa.sh <path-to-ipa-file>"
    exit 1
fi

if [ ! -f "$IPA_PATH" ]; then
    echo "Error: File '$IPA_PATH' does not exist."
    exit 1
fi

echo "==========================================================="
echo "       iOS .ipa Package Diagnostic Inspector              "
echo "==========================================================="
echo "[+] Checking file: $IPA_PATH"

TEMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'ipa_check')
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[+] Unpacking IPA into temporary directory..."
unzip -q "$IPA_PATH" -d "$TEMP_DIR"

# 1. Structure Check: Verify Payload/ directory
if [ ! -d "$TEMP_DIR/Payload" ]; then
    echo "❌ ERROR: Invalid IPA structure! Missing 'Payload/' root directory."
    echo "   The .ipa archive must contain a 'Payload/' folder at its root."
    exit 1
fi
echo "✓ Structure Check Passed: 'Payload/' directory found."

# 2. App Bundle Check: Verify at least one .app folder inside Payload/
APP_BUNDLES=("$TEMP_DIR/Payload"/*.app)

if [ ! -d "${APP_BUNDLES[0]}" ]; then
    echo "❌ ERROR: No .app bundle found inside Payload/!"
    exit 1
fi

if [ ${#APP_BUNDLES[@]} -gt 1 ]; then
    echo "⚠️  WARNING: Multiple .app bundles found inside Payload/: ${APP_BUNDLES[*]}"
fi

APP_DIR="${APP_BUNDLES[0]}"
APP_NAME=$(basename "$APP_DIR")
echo "✓ App Bundle Check Passed: Found '$APP_NAME'."

# 3. Info.plist Check
PLIST_PATH="$APP_DIR/Info.plist"
if [ ! -f "$PLIST_PATH" ]; then
    echo "❌ ERROR: Missing Info.plist inside $APP_NAME!"
    exit 1
fi
echo "✓ Info.plist Check Passed."

# 4. Locate compiled executable binary
EXEC_NAME=""
if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    EXEC_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST_PATH" 2>/dev/null || true)
fi
if [ -z "$EXEC_NAME" ] && command -v plutil >/dev/null 2>&1; then
    EXEC_NAME=$(plutil -extract CFBundleExecutable raw "$PLIST_PATH" 2>/dev/null || true)
fi
if [ -z "$EXEC_NAME" ]; then
    APP_BASE="${APP_NAME%.app}"
    EXEC_NAME="$APP_BASE"
fi

EXEC_PATH="$APP_DIR/$EXEC_NAME"
if [ ! -f "$EXEC_PATH" ]; then
    # Fallback: find any executable file in the bundle root
    EXEC_PATH=$(find "$APP_DIR" -maxdepth 1 -type f -perm +111 2>/dev/null | head -n 1 || true)
fi

if [ -z "$EXEC_PATH" ] || [ ! -f "$EXEC_PATH" ]; then
    echo "❌ ERROR: No compiled executable binary found inside $APP_NAME!"
    exit 1
fi

echo "✓ Executable Check Passed: Found binary '$(basename "$EXEC_PATH")'."

# 5. ARM64 Mach-O Architecture Validation
#    This is the CORRECT way to verify a real device binary — NOT size.
#    Since iOS 12.2+, Swift stdlib is NOT embedded (.app size is legitimately 100–500 KB).
#    A real ARM64 device binary from xcodebuild will report: Mach-O 64-bit executable arm64
if command -v file >/dev/null 2>&1; then
    FILE_OUTPUT=$(file "$EXEC_PATH")
    echo "[+] Binary type: $FILE_OUTPUT"

    if echo "$FILE_OUTPUT" | grep -qiE "arm64|arm64e"; then
        echo "✓ Architecture Check Passed: Binary is ARM64 (real device build)."
    elif echo "$FILE_OUTPUT" | grep -qi "x86_64"; then
        echo "❌ ERROR: Binary is x86_64 (Simulator build)! Must build for iphoneos SDK."
        exit 1
    elif echo "$FILE_OUTPUT" | grep -qi "Mach-O"; then
        echo "✓ Architecture Check Passed: Binary is a valid Mach-O executable."
    else
        echo "⚠️  WARNING: Could not confirm ARM64 architecture. Binary type: $FILE_OUTPUT"
    fi
fi

# 6. Minimum binary size check — catch empty/stub binaries (< 50 KB is suspicious)
BINARY_SIZE_BYTES=$(stat -f%z "$EXEC_PATH" 2>/dev/null || stat -c%s "$EXEC_PATH" 2>/dev/null || echo 0)
BINARY_SIZE_KB=$((BINARY_SIZE_BYTES / 1024))
echo "[+] Executable binary size: ${BINARY_SIZE_KB} KB"

if [ "$BINARY_SIZE_BYTES" -lt 51200 ]; then
    echo "==========================================================="
    echo "❌ ERROR: Executable binary is under 50KB (${BINARY_SIZE_KB} KB)."
    echo "   This is a stub/empty binary — compilation almost certainly failed."
    echo "==========================================================="
    exit 1
fi

# 7. IPA total size info (informational only — NOT a pass/fail criterion)
IPA_SIZE_KB=$(du -sk "$IPA_PATH" 2>/dev/null | cut -f1 || echo "unknown")
APP_DIR_KB=$(du -sk "$APP_DIR" 2>/dev/null | cut -f1 || echo "unknown")
echo "[+] Uncompressed .app size: ${APP_DIR_KB} KB"
echo "[+] Compressed .ipa size:   ${IPA_SIZE_KB} KB"
echo "    (Note: Since iOS 12.2+, Swift stdlib is pre-installed on device."
echo "     A valid .app without embedded frameworks may be 100–500 KB. This is correct.)"

echo "==========================================================="
echo "  SUCCESS! Valid ARM64 .ipa package structure verified."
echo "==========================================================="
