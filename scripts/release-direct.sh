#!/usr/bin/env bash
set -euo pipefail

# Builds a Universal (arm64 + x86_64), Developer ID-signed, Apple-notarized BurnBlame.dmg
# and prints the SHA-256 ready for GitHub Releases and Homebrew Cask.
#
# Usage:
#   ./scripts/release-direct.sh                  # Full universal signed + notarized DMG
#   ./scripts/release-direct.sh --skip-notarize  # Sign & build DMG without notarizing
#   ./scripts/release-direct.sh --native-only    # Faster build for current arch only

APP_NAME="BurnBlame"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-burnblame-notary}"

SKIP_NOTARIZE=false
NATIVE_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=true ;;
        --native-only)   NATIVE_ONLY=true ;;
        *) echo "Unknown flag: $arg" >&2; exit 1 ;;
    esac
done

# Auto-detect Developer ID Application identity if not explicitly set
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "ERROR: No 'Developer ID Application' certificate found in keychain." >&2
    echo "Install one via Xcode -> Settings -> Accounts -> Manage Certificates -> '+' -> Developer ID Application," >&2
    echo "or pass SIGNING_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\"." >&2
    exit 1
fi

echo "==> Releasing $APP_NAME v$VERSION (Direct / Notarized)"
echo "    Signing Identity: $SIGNING_IDENTITY"

cd "$ROOT_DIR"
if $NATIVE_ONLY; then
    echo "==> Building native release binary..."
    swift build -c release
    BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
else
    echo "==> Building Universal release binary (arm64 + x86_64)..."
    swift build -c release --arch arm64 --arch x86_64
    BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
fi

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_STAGING="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

rm -rf "$APP_BUNDLE" "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>mx.lotus.burnblame</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 BurnBlame. All rights reserved.</string>
</dict>
</plist>
EOF

echo "==> Signing $APP_BUNDLE with Hardened Runtime..."
codesign --force --deep --options runtime --timestamp \
    --entitlements "$ROOT_DIR/entitlements/BurnBlame-Direct.entitlements" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> Creating drag-to-Applications DMG..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"

codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"

if ! $SKIP_NOTARIZE; then
    echo "==> Submitting $DMG_PATH to Apple Notary Service (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

echo ""
echo "============================================================"
echo " Release ready: $DMG_PATH"
echo " Version:       $VERSION"
echo " SHA-256:       $SHA256"
echo "============================================================"
echo ""
echo "Next steps:"
echo "  1. Upload to GitHub Releases:"
echo "     gh release create v$VERSION \"$DMG_PATH\" --title \"BurnBlame v$VERSION\" --generate-notes"
echo "  2. Update Homebrew Cask:"
echo "     ./scripts/update-homebrew-cask.sh \"$VERSION\" \"$SHA256\""
