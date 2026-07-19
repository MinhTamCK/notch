#!/usr/bin/env bash
# Install the notch server as a launchd user agent: starts at login, auto-restarts,
# logs to ~/Library/Logs/notch-server.log. Creates ~/.notch/env with a random token
# on first run. Re-running is safe (reinstalls the agent).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="$ROOT/server"
LABEL="com.tam.notch-server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/notch-server.log"
NODE_BIN="$(command -v node)" || { echo "error: node not found" >&2; exit 1; }

[ -d "$SERVER_DIR/node_modules" ] || (cd "$SERVER_DIR" && npm install --no-fund --no-audit)

mkdir -p "$HOME/.notch" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
chmod 700 "$HOME/.notch"
if [ ! -f "$HOME/.notch/env" ]; then
  # Host holds both tokens: machine (report/xin phép) and operator (list/decide).
  ( umask 077; cat > "$HOME/.notch/env" <<EOF
NOTCH_SERVER="http://localhost:4519"
NOTCH_TOKEN="$(openssl rand -hex 16)"
NOTCH_OPERATOR_TOKEN="$(openssl rand -hex 16)"
NOTCH_MACHINE="$(hostname -s)"
NOTCH_REMOTE_APPROVE=1
EOF
  )
  chmod 600 "$HOME/.notch/env"
  echo "wrote $HOME/.notch/env (new random tokens)"
else
  echo "kept existing $HOME/.notch/env"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>. "\$HOME/.notch/env"; export NOTCH_TOKEN NOTCH_OPERATOR_TOKEN NOTCH_PORT NOTCH_STALE_MINUTES NOTCH_RETAIN_HOURS NOTCH_NOTIFY_TURN_DONE; cd "$SERVER_DIR"; exec "$NODE_BIN" node_modules/.bin/tsx src/index.ts</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1  # let launchd settle; immediate re-bootstrap can fail with EIO
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

for _ in $(seq 1 20); do
  curl -s -m 1 http://localhost:4519/health | grep -q ok && { echo "server healthy under launchd ($LABEL)"; exit 0; }
  sleep 0.5
done
echo "server did not become healthy — check $LOG" >&2
exit 1
