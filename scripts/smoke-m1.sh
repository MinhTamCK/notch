#!/usr/bin/env bash
# M1 smoke test: drives the real hooks/notch-hook.sh against a freshly started server
# with simulated Claude Code hook payloads, and asserts session states + remote decisions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=45190
export NOTCH_SERVER="http://127.0.0.1:$PORT"
export NOTCH_TOKEN="smoke-token"
export NOTCH_MACHINE="smoke-vm"
export NOTCH_REMOTE_APPROVE=1
HOOK="$ROOT/hooks/notch-hook.sh"
AUTH=(-H "Authorization: Bearer $NOTCH_TOKEN")
TMP="$(mktemp -d)"
PASS=0; FAIL=0

check() { # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok: $1"
  else FAIL=$((FAIL+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi
}

sessions_state() { # sessions_state <session_id>
  curl -s "${AUTH[@]}" "$NOTCH_SERVER/api/sessions" | jq -r ".sessions[] | select(.sessionId == \"$1\") | .state"
}

echo "== starting server on :$PORT"
(cd "$ROOT/server" && NOTCH_PORT=$PORT NOTCH_TOKEN=$NOTCH_TOKEN npx tsx src/index.ts) > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; rm -rf "$TMP"' EXIT

for _ in $(seq 1 50); do
  curl -s -m 1 "$NOTCH_SERVER/health" | grep -q '"ok"' && break
  sleep 0.3
done
curl -s -m 1 "$NOTCH_SERVER/health" | grep -q '"ok"' || { echo "FAIL: server never became healthy"; cat "$TMP/server.log"; exit 1; }

echo "== auth"
code=$(curl -s -o /dev/null -w '%{http_code}' "$NOTCH_SERVER/api/sessions")
check "rejects missing token" "$code" "401"

echo "== session lifecycle via hook script"
echo '{"session_id":"s1","hook_event_name":"SessionStart","cwd":"/work/proj","source":"startup"}' | "$HOOK" event
check "SessionStart -> working" "$(sessions_state s1)" "working"

echo '{"session_id":"s1","hook_event_name":"UserPromptSubmit","cwd":"/work/proj","prompt":"fix the login bug"}' | "$HOOK" event
check "UserPromptSubmit -> working" "$(sessions_state s1)" "working"

echo "== remote approve (allow)"
echo '{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/work/proj","tool_name":"Bash","tool_input":{"command":"npm test"}}' \
  | "$HOOK" permission > "$TMP/allow.out" &
HOOK_PID=$!
sleep 1
check "PreToolUse -> needs_permission" "$(sessions_state s1)" "needs_permission"
PERM_ID=$(curl -s "${AUTH[@]}" "$NOTCH_SERVER/api/permissions" | jq -r '.permissions[0].id')
PERM_TOOL=$(curl -s "${AUTH[@]}" "$NOTCH_SERVER/api/permissions" | jq -r '.permissions[0].toolName')
check "pending request records tool" "$PERM_TOOL" "Bash"
curl -s "${AUTH[@]}" -H "Content-Type: application/json" \
  -d '{"decision":"allow","reason":"looks safe"}' "$NOTCH_SERVER/api/permissions/$PERM_ID/decide" > /dev/null
wait $HOOK_PID
check "hook emits allow decision" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/allow.out")" "allow"
check "session back to working" "$(sessions_state s1)" "working"

echo "== remote approve (deny)"
echo '{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/work/proj","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
  | "$HOOK" permission > "$TMP/deny.out" &
HOOK_PID=$!
sleep 1
PERM_ID=$(curl -s "${AUTH[@]}" "$NOTCH_SERVER/api/permissions" | jq -r '.permissions[0].id')
curl -s "${AUTH[@]}" -H "Content-Type: application/json" \
  -d '{"decision":"deny","reason":"absolutely not"}' "$NOTCH_SERVER/api/permissions/$PERM_ID/decide" > /dev/null
wait $HOOK_PID
check "hook emits deny decision" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TMP/deny.out")" "deny"
check "deny reason passthrough" "$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TMP/deny.out")" "absolutely not"

echo "== monitor-only mode (NOTCH_REMOTE_APPROVE=0)"
OUT=$(echo '{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/work/proj","tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | NOTCH_REMOTE_APPROVE=0 "$HOOK" permission)
check "monitor-only emits nothing" "$OUT" ""
check "monitor-only still reports event" "$(sessions_state s1)" "working"

echo "== notification + stop"
echo '{"session_id":"s1","hook_event_name":"Notification","cwd":"/work/proj","message":"Claude needs your permission to use Bash"}' | "$HOOK" event
check "Notification -> needs_attention" "$(sessions_state s1)" "needs_attention"

echo '{"session_id":"s1","hook_event_name":"Stop","cwd":"/work/proj","stop_hook_active":false}' | "$HOOK" event
check "Stop -> done" "$(sessions_state s1)" "done"

echo "== server down fails open"
OUT=$(echo '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | NOTCH_SERVER="http://127.0.0.1:1" "$HOOK" permission)
check "unreachable server -> empty output (fall back to terminal)" "$OUT" ""

echo "== websocket snapshot"
WS_MSG=$(cd "$ROOT/server" && node -e "
  const WebSocket = require('ws');
  const ws = new WebSocket('ws://127.0.0.1:$PORT/ws?token=$NOTCH_TOKEN');
  ws.on('message', m => { console.log(m.toString()); process.exit(0); });
  setTimeout(() => process.exit(1), 3000);
")
check "snapshot delivered" "$(jq -r '.type' <<<"$WS_MSG")" "snapshot"
check "snapshot has s1" "$(jq -r '.sessions[] | select(.sessionId == "s1") | .machine' <<<"$WS_MSG")" "smoke-vm"

echo
echo "== result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
