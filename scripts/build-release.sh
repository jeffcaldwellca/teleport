#!/usr/bin/env bash
# Build a production (Release) Teleport.app and the tport CLI from the
# current working tree.
#
# Usage:
#   scripts/build-release.sh           # build Release into ./build
#   scripts/build-release.sh --open    # build, then reveal the .app in Finder
#   scripts/build-release.sh --run     # build, then launch the .app
#   scripts/build-release.sh --clean   # wipe ./build and DerivedData first

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="Teleport"
CONFIG="Release"
BUILD_DIR="$REPO_ROOT/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
PRODUCT_DIR="$DERIVED_DATA/Build/Products/$CONFIG"
APP_PATH="$PRODUCT_DIR/$SCHEME.app"

OPEN_AFTER=0
RUN_AFTER=0
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --open) OPEN_AFTER=1 ;;
        --run)  RUN_AFTER=1 ;;
        --clean) CLEAN=1 ;;
        -h|--help)
            sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
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
        echo "error: '$1' not found in PATH" >&2
        exit 1
    }
}

require xcodebuild
require xcodegen

if [[ $CLEAN -eq 1 ]]; then
    echo "==> cleaning $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

echo "==> regenerating Teleport.xcodeproj from project.yml"
xcodegen generate --quiet

echo "==> resolving Swift package dependencies"
xcodebuild \
    -project "Teleport.xcodeproj" \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED_DATA" \
    -resolvePackageDependencies \
    >/dev/null

echo "==> building $SCHEME ($CONFIG)"
# Sign with a stable identity and apply the app's entitlements. Ad-hoc /
# linker signing produces a different signature on every build, which detaches
# previously-saved Keychain items (connection passwords) — so saved passwords
# appeared to vanish across rebuilds. A real Developer ID signature is stable,
# so the team-scoped Keychain access group ("$TEAM.com.teleport.app") persists.
# Override the identity/team via env vars on machines with a different cert.
SIGN_IDENTITY="${TELEPORT_SIGN_IDENTITY:-Developer ID Application: Jeffrey Caldwell (88ZPCYS252)}"
SIGN_TEAM="${TELEPORT_SIGN_TEAM:-88ZPCYS252}"
xcodebuild \
    -project "Teleport.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$SIGN_TEAM" \
    build

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: build succeeded but $APP_PATH was not produced" >&2
    exit 1
fi

# Xcode 26's actool thins AppIcon.icns down to ~4 sizes (max 256px), so the icon
# looks blurry at Dock/Finder sizes >256px. Rebuild the icns from the full
# appiconset with iconutil so all sizes through 1024px are present.
APPICONSET="$REPO_ROOT/Teleport/Assets.xcassets/AppIcon.appiconset"
if [[ -d "$APPICONSET" ]] && command -v iconutil >/dev/null 2>&1; then
    echo "==> rebuilding AppIcon.icns with full resolution set"
    ICNS_TMP=$(mktemp -d)
    trap 'rm -rf "$ICNS_TMP"' EXIT
    mkdir -p "$ICNS_TMP/AppIcon.iconset"
    cp "$APPICONSET"/icon_*.png "$ICNS_TMP/AppIcon.iconset/"
    iconutil -c icns "$ICNS_TMP/AppIcon.iconset" -o "$ICNS_TMP/AppIcon.icns"
    cp "$ICNS_TMP/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
    touch "$APP_PATH"
fi

FINAL_APP="$BUILD_DIR/$SCHEME.app"
echo "==> copying $SCHEME.app to $FINAL_APP"
ditto "$APP_PATH" "$FINAL_APP"

echo "==> building tport (Release)"
(cd "$REPO_ROOT/TeleportKit" && swift build -c release --product tport)
TPORT_BUILT="$REPO_ROOT/TeleportKit/.build/release/tport"
if [[ ! -f "$TPORT_BUILT" ]]; then
    echo "error: tport build succeeded but $TPORT_BUILT was not produced" >&2
    exit 1
fi
cp "$TPORT_BUILT" "$BUILD_DIR/tport"
echo "   $BUILD_DIR/tport"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$FINAL_APP/Contents/Info.plist" 2>/dev/null || echo "?")
BUILD_NO=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$FINAL_APP/Contents/Info.plist" 2>/dev/null || echo "?")

echo
echo "✅ built $SCHEME $VERSION ($BUILD_NO)"
echo "   $FINAL_APP"

if [[ $OPEN_AFTER -eq 1 ]]; then
    open -R "$FINAL_APP"
fi

if [[ $RUN_AFTER -eq 1 ]]; then
    open "$FINAL_APP"
fi
