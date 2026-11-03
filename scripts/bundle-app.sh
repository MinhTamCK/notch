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
# Ask SwiftPM where the universal products went — newer toolchains moved them
# from .build/apple to .build/out, and a stale copy would get bundled silently.
BIN_DIR="$(cd "$ROOT/app" && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
BIN="$BIN_DIR/NotchApp"
mkdir -p "$DIST"

if [ ! -f "$DIST/AppIcon.icns" ]; then
  swift "$ROOT/scripts/make-icon.swift" "$DIST/AppIcon.iconset"
  iconutil -c icns "$DIST/AppIcon.iconset" -o "$DIST/AppIcon.icns"
fi

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/NotchApp"
cp "$BIN_DIR/notch-hook" "$BUNDLE/Contents/Resources/notch-hook"
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
  <key>CFBundleShortVersionString</key><string>0.9.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Client mode talks plain ws:// to the server in ~/.notch/env, usually a
       tailnet IP (100.64/10). ATS refuses that, and its LocalNetworking
       exception doesn't cover CGNAT IPs nor can exceptions name an IP.
       WireGuard (Tailscale) already encrypts the link. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
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
