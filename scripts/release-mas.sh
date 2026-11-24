#!/usr/bin/env bash
set -euo pipefail

# Builds a Sandboxed, Universal Mac App Store .pkg ready for App Store Connect / Transporter.
#
# Required certificates in Keychain:
#   - "Apple Distribution: ..." (or "3rd Party Mac Developer Application: ...")
#   - "3rd Party Mac Developer Installer: ..."
#
# Optional env vars:
#   APP_SIGNING_IDENTITY="..."
#   INSTALLER_SIGNING_IDENTITY="..."
#   PROVISIONING_PROFILE="/path/to/BurnBlame_MAS.provisionprofile"

APP_NAME="BurnBlame"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if [[ -z "${APP_SIGNING_IDENTITY:-}" ]]; then
    APP_SIGNING_IDENTITY="$(security find-identity -v -p codesigning | grep -E "Apple Distribution:|3rd Party Mac Developer Application:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
fi

if [[ -z "${INSTALLER_SIGNING_IDENTITY:-}" ]]; then
    INSTALLER_SIGNING_IDENTITY="$(security find-identity -v | grep "3rd Party Mac Developer Installer:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
fi

if [[ -z "$APP_SIGNING_IDENTITY" ]]; then
    echo "ERROR: No 'Apple Distribution' or '3rd Party Mac Developer Application' certificate found." >&2
    echo "Create one in Xcode -> Settings -> Accounts -> Manage Certificates." >&2
    exit 1
fi

if [[ -z "$INSTALLER_SIGNING_IDENTITY" ]]; then
    echo "ERROR: No '3rd Party Mac Developer Installer' certificate found." >&2
    echo "Create a 'Mac Installer Distribution' certificate in developer.apple.com and install it in Keychain." >&2
    exit 1
fi

echo "==> Building $APP_NAME v$VERSION (Mac App Store / Sandboxed)"
echo "    App Cert:       $APP_SIGNING_IDENTITY"
echo "    Installer Cert: $INSTALLER_SIGNING_IDENTITY"

cd "$ROOT_DIR"
swift build -c release --arch arm64 --arch x86_64 -Xswiftc -DAPP_STORE
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 -Xswiftc -DAPP_STORE --show-bin-path)/$APP_NAME"

OUT_DIR="$ROOT_DIR/dist/mas"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
PKG_PATH="$OUT_DIR/${APP_NAME}-${VERSION}.pkg"

rm -rf "$OUT_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

if [[ -n "${PROVISIONING_PROFILE:-}" && -f "$PROVISIONING_PROFILE" ]]; then
    cp "$PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
fi

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

echo "==> Signing sandboxed app bundle..."
codesign --force --deep --timestamp \
    --entitlements "$ROOT_DIR/entitlements/BurnBlame-MAS.entitlements" \
    --sign "$APP_SIGNING_IDENTITY" \
    "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> Packaging signed Mac App Store .pkg..."
productbuild --component "$APP_BUNDLE" /Applications \
    --sign "$INSTALLER_SIGNING_IDENTITY" \
    "$PKG_PATH"

echo ""
echo "============================================================"
echo " Mac App Store package ready: $PKG_PATH"
echo "============================================================"
echo ""
echo "Upload to App Store Connect via Transporter.app or:"
echo "  xcrun altool --upload-app -f \"$PKG_PATH\" -t macos -u YOUR_APPLE_ID -p @keychain:AC_PASSWORD"
