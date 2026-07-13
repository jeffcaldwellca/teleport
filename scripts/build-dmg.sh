#!/usr/bin/env bash
# Package Teleport.app into a distributable "drag to Applications" .dmg,
# using the on-theme background in scripts/dmg-assets/background.png.
#
# Usage:
#   scripts/build-dmg.sh           # build Release app (if needed) + package the .dmg
#   scripts/build-dmg.sh --rebuild # force a fresh Release build first
#   scripts/build-dmg.sh --open    # build the .dmg, then reveal it in Finder

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
APP_PATH="$BUILD_DIR/Teleport.app"
BACKGROUND="$REPO_ROOT/scripts/dmg-assets/background.png"
STAGING_DIR="$BUILD_DIR/dmg-staging"

REBUILD=0
OPEN_AFTER=0
for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=1 ;;
        --open)    OPEN_AFTER=1 ;;
        -h|--help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: '$1' not found in PATH (try: brew install $1)" >&2
        exit 1
    }
}

require create-dmg
require hdiutil

if [[ $REBUILD -eq 1 || ! -d "$APP_PATH" ]]; then
    echo "==> building Teleport.app first"
    "$REPO_ROOT/scripts/build-release.sh"
fi

if [[ ! -f "$BACKGROUND" ]]; then
    echo "error: background image not found at $BACKGROUND" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.0")
OUTPUT_DMG="$BUILD_DIR/Teleport-$VERSION.dmg"
VOLICON="$APP_PATH/Contents/Resources/AppIcon.icns"

echo "==> staging a clean folder with just Teleport.app"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/Teleport.app"

rm -f "$OUTPUT_DMG"

echo "==> building $OUTPUT_DMG"
create-dmg \
    --volname "Teleport" \
    --volicon "$VOLICON" \
    --background "$BACKGROUND" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --text-size 13 \
    --icon "Teleport.app" 180 170 \
    --hide-extension "Teleport.app" \
    --app-drop-link 480 170 \
    --no-internet-enable \
    "$OUTPUT_DMG" \
    "$STAGING_DIR"

rm -rf "$STAGING_DIR"

echo
echo "✅ built $OUTPUT_DMG"

if [[ $OPEN_AFTER -eq 1 ]]; then
    open -R "$OUTPUT_DMG"
fi
