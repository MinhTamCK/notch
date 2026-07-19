#!/usr/bin/env bash
# Install Notch hooks for Claude Code on this machine.
#
# Usage (run from the repo, or scp the hooks/ dir to the target machine first):
#   NOTCH_SERVER=http://<server>:4519 NOTCH_TOKEN=<token> [NOTCH_MACHINE=<label>] ./install.sh
set -euo pipefail

for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "error: $dep is required" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTCH_DIR="$HOME/.notch"
SETTINGS="$HOME/.claude/settings.json"
HOOK_CMD_EVENT="\"\$HOME/.notch/notch-hook.sh\" event"
HOOK_CMD_PERM="\"\$HOME/.notch/notch-hook.sh\" permission"

mkdir -p "$NOTCH_DIR" "$HOME/.claude"
chmod 700 "$NOTCH_DIR"
install -m 755 "$SCRIPT_DIR/notch-hook.sh" "$NOTCH_DIR/notch-hook.sh"

if [ ! -f "$NOTCH_DIR/env" ]; then
  # This remote machine gets only the machine token; require a real one.
  if [ -z "${NOTCH_TOKEN:-}" ]; then
    echo "error: set NOTCH_TOKEN=<host machine token> before running (see the app's Add Remote Machine)" >&2
    exit 1
  fi
  ( umask 077; cat > "$NOTCH_DIR/env" <<EOF
NOTCH_SERVER="${NOTCH_SERVER:-http://localhost:4519}"
NOTCH_TOKEN="${NOTCH_TOKEN}"
NOTCH_MACHINE="${NOTCH_MACHINE:-$(hostname -s)}"
# Set to 0 to disable remote approval (monitor-only) on this machine:
NOTCH_REMOTE_APPROVE=1
EOF
  )
  chmod 600 "$NOTCH_DIR/env"
  echo "wrote $NOTCH_DIR/env"
else
  echo "kept existing $NOTCH_DIR/env"
fi

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.notch-backup"

jq --arg ev "$HOOK_CMD_EVENT" --arg perm "$HOOK_CMD_PERM" '
  def strip: map(select(((.hooks // []) | any(.command // "" | contains("notch-hook.sh"))) | not));
  .hooks = (.hooks // {})
  | .hooks.SessionStart      = (((.hooks.SessionStart // [])      | strip) + [{hooks: [{type: "command", command: $ev}]}])
  | .hooks.UserPromptSubmit  = (((.hooks.UserPromptSubmit // [])  | strip) + [{hooks: [{type: "command", command: $ev}]}])
  | .hooks.Notification      = (((.hooks.Notification // [])      | strip) + [{hooks: [{type: "command", command: $ev}]}])
  | .hooks.PostToolUse       = (((.hooks.PostToolUse // [])       | strip) + [{hooks: [{type: "command", command: $ev}]}])
  | .hooks.Stop              = (((.hooks.Stop // [])              | strip) + [{hooks: [{type: "command", command: $ev}]}])
  | .hooks.SessionEnd        = (((.hooks.SessionEnd // [])        | strip) + [{hooks: [{type: "command", command: $ev}]}])
  | .hooks.PreToolUse        = (((.hooks.PreToolUse // [])        | strip) + [{matcher: "Bash|Write|Edit|MultiEdit|ExitPlanMode", hooks: [{type: "command", command: $perm, timeout: 60}]}, {matcher: "AskUserQuestion", hooks: [{type: "command", command: $ev}]}])
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

echo "hooks merged into $SETTINGS (backup at $SETTINGS.notch-backup)"
echo "done — new Claude Code sessions on this machine will report to \$NOTCH_SERVER"
