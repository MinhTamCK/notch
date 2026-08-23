#!/usr/bin/env bash
# Notch hook for Claude Code and Codex. Registered by install.sh in
# ~/.claude/settings.json (Claude Code) and ~/.codex/hooks.json (Codex).
#   notch-hook.sh event             — fire-and-forget: report the hook event to the server
#   notch-hook.sh permission        — PreToolUse: ask the server for an allow/deny decision
#   notch-hook.sh codex-event       — same as event, tagged as a Codex session
#   notch-hook.sh codex-permission  — Codex PermissionRequest: allow/deny via the notch
#
# Fails open in every path: if the server, curl, or jq is unavailable, exit 0 with no
# output so the agent falls back to its normal (terminal) permission flow.
set -u

MODE="${1:-event}"
AGENT="claude-code"
case "$MODE" in
  codex-*) AGENT="codex"; MODE="${MODE#codex-}" ;;
esac
# Caller-provided env wins over ~/.notch/env (matches the compiled notch-hook).
_ns="${NOTCH_SERVER-}"; _nt="${NOTCH_TOKEN-}"; _nm="${NOTCH_MACHINE-}"; _nr="${NOTCH_REMOTE_APPROVE-}"
_nh="${NOTCH_GATE_HEADLESS-}"
[ -f "$HOME/.notch/env" ] && . "$HOME/.notch/env"
[ -n "$_ns" ] && NOTCH_SERVER="$_ns"
[ -n "$_nt" ] && NOTCH_TOKEN="$_nt"
[ -n "$_nm" ] && NOTCH_MACHINE="$_nm"
[ -n "$_nr" ] && NOTCH_REMOTE_APPROVE="$_nr"
[ -n "$_nh" ] && NOTCH_GATE_HEADLESS="$_nh"
NOTCH_SERVER="${NOTCH_SERVER:-http://localhost:4519}"
NOTCH_TOKEN="${NOTCH_TOKEN:-}"
NOTCH_MACHINE="${NOTCH_MACHINE:-$(hostname -s)}"
NOTCH_REMOTE_APPROVE="${NOTCH_REMOTE_APPROVE:-1}"
NOTCH_GATE_HEADLESS="${NOTCH_GATE_HEADLESS:-0}"

payload="$(cat)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

body="$(jq -cn --arg machine "$NOTCH_MACHINE" --arg agent "$AGENT" --argjson event "$payload" \
  '{machine: $machine, agent: $agent, ts: (now * 1000 | floor), event: $event}' 2>/dev/null)" || exit 0

auth=(-H "Authorization: Bearer $NOTCH_TOKEN" -H "Content-Type: application/json")

# Respect the session's permission mode: only gate tools Claude Code itself would
# prompt for. Bypass/auto/dontAsk sessions are monitor-only; acceptEdits skips
# the gate for edit tools but still gates Bash and plans. (Codex's PermissionRequest
# only fires when Codex would prompt anyway, so none of this applies there.)
if [ "$MODE" = "permission" ] && [ "$AGENT" = "claude-code" ]; then
  pm="$(jq -r '.permission_mode // "default"' <<<"$payload" 2>/dev/null)"
  tool="$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null)"
  case "$pm" in
    bypassPermissions|auto|dontAsk) MODE="event" ;;
    acceptEdits) case "$tool" in Edit|Write|MultiEdit) MODE="event" ;; esac ;;
  esac
  # Headless sessions (`claude -p`, Agent SDK) set CLAUDE_CODE_ENTRYPOINT=sdk-cli.
  # There is no terminal prompt to relocate there, and `--allowedTools` pre-approval
  # leaves permission_mode at "default" — gating would invent an approval the session
  # never had and stall it 55s per call. NOTCH_GATE_HEADLESS=1 opts back in.
  # AskUserQuestion is still gated even headless: the notch answers it via
  # updatedInput, and there is no terminal picker to fall back to.
  if [ "${CLAUDE_CODE_ENTRYPOINT-}" = "sdk-cli" ] && [ "$NOTCH_GATE_HEADLESS" != "1" ] \
    && [ "$tool" != "AskUserQuestion" ]; then
    MODE="event"
  fi
fi

if [ "$MODE" = "permission" ] && [ "$NOTCH_REMOTE_APPROVE" != "0" ]; then
  resp="$(curl -sS -m 3 "${auth[@]}" -d "$body" "$NOTCH_SERVER/api/permissions" 2>/dev/null)" || exit 0
  id="$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)"
  [ -n "$id" ] || exit 0

  dec="$(curl -sS -m 58 -H "Authorization: Bearer $NOTCH_TOKEN" \
    "$NOTCH_SERVER/api/permissions/$id/decision?wait=55" 2>/dev/null)" || exit 0
  decision="$(jq -r '.decision // empty' <<<"$dec" 2>/dev/null)"
  reason="$(jq -r '.reason // "Decided via Notch"' <<<"$dec" 2>/dev/null)"

  case "$AGENT:$decision" in
    codex:allow)
      echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ;;
    codex:deny)
      jq -cn --arg r "$reason" \
        '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny", message: $r}}}' ;;
    claude-code:allow|claude-code:deny)
      jq -cn --arg d "$decision" --arg r "$reason" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
      ;;
  esac
  exit 0
fi

curl -sS -m 2 "${auth[@]}" -d "$body" "$NOTCH_SERVER/api/events" >/dev/null 2>&1
exit 0
