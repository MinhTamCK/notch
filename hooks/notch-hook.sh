#!/usr/bin/env bash
# Notch hook for Claude Code. Registered in ~/.claude/settings.json by install.sh.
#   notch-hook.sh event       — fire-and-forget: report the hook event to the server
#   notch-hook.sh permission  — PreToolUse: ask the server for an allow/deny decision
#
# Fails open in every path: if the server, curl, or jq is unavailable, exit 0 with no
# output so Claude Code falls back to its normal (terminal) permission flow.
set -u

MODE="${1:-event}"
[ -f "$HOME/.notch/env" ] && . "$HOME/.notch/env"
NOTCH_SERVER="${NOTCH_SERVER:-http://localhost:4519}"
NOTCH_TOKEN="${NOTCH_TOKEN:-dev-token}"
NOTCH_MACHINE="${NOTCH_MACHINE:-$(hostname -s)}"
NOTCH_REMOTE_APPROVE="${NOTCH_REMOTE_APPROVE:-1}"

payload="$(cat)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

body="$(jq -cn --arg machine "$NOTCH_MACHINE" --arg agent "claude-code" --argjson event "$payload" \
  '{machine: $machine, agent: $agent, ts: (now * 1000 | floor), event: $event}' 2>/dev/null)" || exit 0

auth=(-H "Authorization: Bearer $NOTCH_TOKEN" -H "Content-Type: application/json")

# Respect the session's permission mode: only gate tools Claude Code itself would
# prompt for. Bypass/auto/dontAsk sessions are monitor-only; acceptEdits skips
# the gate for edit tools but still gates Bash and plans.
if [ "$MODE" = "permission" ]; then
  pm="$(jq -r '.permission_mode // "default"' <<<"$payload" 2>/dev/null)"
  tool="$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null)"
  case "$pm" in
    bypassPermissions|auto|dontAsk) MODE="event" ;;
    acceptEdits) case "$tool" in Edit|Write|MultiEdit) MODE="event" ;; esac ;;
  esac
fi

if [ "$MODE" = "permission" ] && [ "$NOTCH_REMOTE_APPROVE" != "0" ]; then
  resp="$(curl -sS -m 3 "${auth[@]}" -d "$body" "$NOTCH_SERVER/api/permissions" 2>/dev/null)" || exit 0
  id="$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)"
  [ -n "$id" ] || exit 0

  dec="$(curl -sS -m 58 -H "Authorization: Bearer $NOTCH_TOKEN" \
    "$NOTCH_SERVER/api/permissions/$id/decision?wait=55" 2>/dev/null)" || exit 0
  decision="$(jq -r '.decision // empty' <<<"$dec" 2>/dev/null)"
  reason="$(jq -r '.reason // "Decided via Notch"' <<<"$dec" 2>/dev/null)"

  case "$decision" in
    allow|deny)
      jq -cn --arg d "$decision" --arg r "$reason" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
      ;;
  esac
  exit 0
fi

curl -sS -m 2 "${auth[@]}" -d "$body" "$NOTCH_SERVER/api/events" >/dev/null 2>&1
exit 0
