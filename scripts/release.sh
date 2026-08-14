#!/usr/bin/env bash
# Build a distributable zip of Notch.app and publish it as a GitHub release.
# When the bundle is Developer ID-signed, it is notarized and stapled before
# publishing; ad-hoc builds skip notarization (and need the Gatekeeper bypass).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Gate the release on tests — a build that fails tests never ships.
echo "== running tests before release"
(cd "$ROOT/server" && npm test)
(cd "$ROOT/app" && swift test)

"$ROOT/scripts/bundle-app.sh"

BUNDLE="$ROOT/app/dist/Notch.app"
VERSION="$(defaults read "$BUNDLE/Contents/Info" CFBundleShortVersionString)"
ZIP="$ROOT/app/dist/Notch-v$VERSION.zip"

rm -f "$ZIP"
ditto -c -k --keepParent "$BUNDLE" "$ZIP"
echo "created $ZIP ($(du -h "$ZIP" | cut -f1))"

# capture instead of piping into grep -q: with pipefail, grep's early exit
# can fail the pipeline and silently skip notarization
SIGNATURE="$(codesign -dvv "$BUNDLE" 2>&1)"
if [[ "$SIGNATURE" == *"Developer ID Application"* ]]; then
  echo "== notarizing (keychain profile: notch-notary)"
  xcrun notarytool submit "$ZIP" --keychain-profile notch-notary --wait
  xcrun stapler staple "$BUNDLE"
  # re-zip so the shipped archive contains the stapled ticket
  rm -f "$ZIP"
  ditto -c -k --keepParent "$BUNDLE" "$ZIP"
  echo "notarized and stapled"
fi

NOTES="Remote Claude Code monitor in your Mac's notch — live session status across machines, remote Approve/Deny with diff previews, plan review, question pickers, plan-usage bars and system stats.

**Requirements:** macOS 14+, Apple Silicon or Intel (universal binary). Signed and notarized by Apple — just drag and open.

**Install**
1. Download \`Notch-v$VERSION.zip\`, unzip, drag \`Notch.app\` into /Applications
2. Open it — the app hosts its own server, no config needed
3. Gear icon in the notch panel → **Install** under \"Claude Code on this Mac\" so local sessions show up
4. To watch a VM or another computer: gear → **Copy command** under \"Add remote machine\" (needs Tailscale), then paste that line into the remote shell

**Settings** (gear icon in the notch panel) — Launch at Login, keep awake with the lid closed, \"your turn\" alerts, reconnect. The speaker icon in the header toggles sound."

gh release create "v$VERSION" "$ZIP" --title "Notch v$VERSION" --notes "$NOTES"
