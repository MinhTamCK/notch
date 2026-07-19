#!/usr/bin/env bash
# Build a distributable zip of Notch.app and publish it as a GitHub release.
# Ad-hoc signed for now — release notes include the Gatekeeper bypass step.
# When the Developer ID cert lands, signing/notarization slots in before the zip.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/bundle-app.sh"

BUNDLE="$ROOT/app/dist/Notch.app"
VERSION="$(defaults read "$BUNDLE/Contents/Info" CFBundleShortVersionString)"
ZIP="$ROOT/app/dist/Notch-v$VERSION.zip"

rm -f "$ZIP"
ditto -c -k --keepParent "$BUNDLE" "$ZIP"
echo "created $ZIP ($(du -h "$ZIP" | cut -f1))"

NOTES="Remote Claude Code monitor in your Mac's notch — live session status across machines, remote Approve/Deny with diff previews, plan review, sound alerts.

**Requirements:** macOS 14+, Apple Silicon or Intel (universal binary).

**Install**
1. Download \`Notch-v$VERSION.zip\`, unzip, drag \`Notch.app\` into /Applications
2. This build is not yet notarized — clear the quarantine flag once:
   \`xattr -cr /Applications/Notch.app\`
   (or right-click → Open, then approve in System Settings → Privacy & Security)
3. Point the app at your server: create \`~/.notch/env\` with \`NOTCH_SERVER\` and \`NOTCH_TOKEN\`
4. Server + Claude Code hooks setup: see \`scripts/install-server.sh\` and \`hooks/install.sh\` in the repo

**Menu bar icon** → Launch at Login toggle, sound alerts, reconnect."

gh release create "v$VERSION" "$ZIP" --title "Notch v$VERSION" --notes "$NOTES"
