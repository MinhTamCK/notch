#!/usr/bin/env bash
# Build a release Notch.app bundle (menu-bar-only) and install it
# to /Applications (or ~/Applications if not writable).
# Signs with the Developer ID identity when present in the keychain
# (override with NOTCH_SIGN_IDENTITY); falls back to ad-hoc.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/app/dist"
BUNDLE="$DIST/Notch.app"

(cd "$ROOT/app" && swift build -c release --arch arm64 --arch x86_64)
BIN="$ROOT/app/.build/apple/Products/Release/NotchApp"
mkdir -p "$DIST"

if [ ! -f "$DIST/AppIcon.icns" ]; then
  swift "$ROOT/scripts/make-icon.swift" "$DIST/AppIcon.iconset"
  iconutil -c icns "$DIST/AppIcon.iconset" -o "$DIST/AppIcon.icns"
fi

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/NotchApp"
cp "$ROOT/app/.build/apple/Products/Release/notch-hook" "$BUNDLE/Contents/Resources/notch-hook"
cp "$ROOT/app/Assets/"*.png "$BUNDLE/Contents/Resources/"
cp "$DIST/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>NotchApp</string>
  <key>CFBundleIdentifier</key><string>com.tam.notch</string>
  <key>CFBundleName</key><string>Notch</string>
  <key>CFBundleDisplayName</key><string>Notch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.2</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

IDENTITY="${NOTCH_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
  # notarization requires every Mach-O signed with hardened runtime + timestamp,
  # inner binaries first
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$BUNDLE/Contents/Resources/notch-hook"
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$BUNDLE"
  echo "signed: $IDENTITY"
else
  codesign --force -s - "$BUNDLE"
  echo "signed: ad-hoc (no Developer ID identity in keychain)"
fi

TARGET="/Applications/Notch.app"
if [ -w /Applications ]; then
  rm -rf "$TARGET"
  cp -R "$BUNDLE" "$TARGET"
else
  TARGET="$HOME/Applications/Notch.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$TARGET"
  cp -R "$BUNDLE" "$TARGET"
fi
echo "installed $TARGET"
