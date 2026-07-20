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

NOTES="Remote Claude Code monitor in your Mac's notch — live session status across machines, remote Approve/Deny with diff previews, plan review, sound alerts.

**Requirements:** macOS 14+, Apple Silicon or Intel (universal binary).

**Install**
1. Download \`Notch-v$VERSION.zip\`, unzip, drag \`Notch.app\` into /Applications
2. Point the app at your server: create \`~/.notch/env\` with \`NOTCH_SERVER\` and \`NOTCH_TOKEN\`
3. Server + Claude Code hooks setup: see \`scripts/install-server.sh\` and \`hooks/install.sh\` in the repo

**Menu bar icon** → Launch at Login toggle, sound alerts, reconnect."

gh release create "v$VERSION" "$ZIP" --title "Notch v$VERSION" --notes "$NOTES"
