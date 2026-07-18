#!/usr/bin/env bash
# Feed demo sessions from fake machines into a running server via the real hook script.
# Assumes the server is up (defaults: localhost:4519 / dev-token).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$HOME/.notch/env" ] && . "$HOME/.notch/env"
export NOTCH_SERVER="${NOTCH_SERVER:-http://localhost:4519}"
export NOTCH_TOKEN="${NOTCH_TOKEN:-dev-token}"
HOOK="$ROOT/hooks/notch-hook.sh"

send() { # send <machine> <json>
  echo "$2" | NOTCH_MACHINE="$1" "$HOOK" event
}

send vm-alpha '{"session_id":"s-a1","hook_event_name":"SessionStart","cwd":"/home/tam/api-server","source":"startup"}'
send vm-alpha '{"session_id":"s-a1","hook_event_name":"PreToolUse","cwd":"/home/tam/api-server","tool_name":"Bash","tool_input":{"command":"npm test"}}'
send vm-alpha '{"session_id":"s-a2","hook_event_name":"SessionStart","cwd":"/home/tam/webapp","source":"startup"}'
send vm-alpha '{"session_id":"s-a2","hook_event_name":"UserPromptSubmit","cwd":"/home/tam/webapp","prompt":"add dark mode to settings page"}'
send vm-beta '{"session_id":"s-b1","hook_event_name":"SessionStart","cwd":"/srv/etl-pipeline","source":"startup"}'
send macbook '{"session_id":"s-m1","hook_event_name":"SessionStart","cwd":"/Users/tam/Desktop/notch","source":"startup"}'
send macbook '{"session_id":"s-m1","hook_event_name":"Stop","cwd":"/Users/tam/Desktop/notch","stop_hook_active":false}'

sleep 2
# This one should trigger the sound + auto-expand in the app:
send vm-beta '{"session_id":"s-b1","hook_event_name":"Notification","cwd":"/srv/etl-pipeline","message":"Claude needs your permission to use Bash"}'

echo "demo events sent"
