/// Shell scripts served to remote machines (Linux VMs etc.), embedded as strings
/// so the app stays a single self-contained binary.
enum EmbeddedScripts {
    /// Served at GET /install/hook — the bash hook remote machines run (needs curl + jq).
    static let hookScript = #"""
    #!/usr/bin/env bash
    # Notch hook for Claude Code (installed via the Notch app's /install endpoint).
    #   notch-hook.sh event       — fire-and-forget: report the hook event to the server
    #   notch-hook.sh permission  — PreToolUse: ask the server for an allow/deny decision
    # Fails open in every path so Claude Code falls back to its terminal flow.
    set -u

    MODE="${1:-event}"
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

    body="$(jq -cn --arg machine "$NOTCH_MACHINE" --arg agent "claude-code" --argjson event "$payload" \
      '{machine: $machine, agent: $agent, ts: (now * 1000 | floor), event: $event}' 2>/dev/null)" || exit 0

    auth=(-H "Authorization: Bearer $NOTCH_TOKEN" -H "Content-Type: application/json")

    # Statusline: report plan usage (throttled — statusline fires constantly),
    # then render: the replaced statusline if one was preserved, else a default.
    if [ "$MODE" = "statusline" ]; then
      limits="$(jq -c '.rate_limits // empty' <<<"$payload" 2>/dev/null)"
      stamp="$HOME/.notch/usage-posted"
      last="$(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp" 2>/dev/null || echo 0)"
      if [ -n "$limits" ] && [ $(( $(date +%s) - last )) -gt 60 ]; then
        touch "$stamp"
        jq -cn --arg machine "$NOTCH_MACHINE" --argjson rl "$limits" '{machine: $machine, rate_limits: $rl}' \
          | curl -sS -m 1 "${auth[@]}" -d @- "$NOTCH_SERVER/api/usage" >/dev/null 2>&1 &
      fi
      if [ -s "$HOME/.notch/statusline-orig" ]; then
        printf '%s' "$payload" | bash -c "$(cat "$HOME/.notch/statusline-orig")"
      else
        model="$(jq -r '.model.display_name // "Claude"' <<<"$payload" 2>/dev/null)"
        five="$(jq -r '.rate_limits.five_hour.used_percentage // empty | round' <<<"$payload" 2>/dev/null)"
        seven="$(jq -r '.rate_limits.seven_day.used_percentage // empty | round' <<<"$payload" 2>/dev/null)"
        line="$model"
        [ -n "$five" ] && line="$line · 5h $five%"
        [ -n "$seven" ] && line="$line · 7d $seven%"
        echo "$line"
      fi
      exit 0
    fi

    # Respect the session's permission mode: only gate tools Claude Code itself would
    # prompt for. Bypass/auto/dontAsk sessions are monitor-only; acceptEdits skips
    # the gate for edit tools but still gates Bash and plans. AskUserQuestion
    # prompts in every mode, so it's always gated.
    if [ "$MODE" = "permission" ]; then
      pm="$(jq -r '.permission_mode // "default"' <<<"$payload" 2>/dev/null)"
      tool="$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null)"
      case "$pm" in
        bypassPermissions|auto|dontAsk) [ "$tool" = "AskUserQuestion" ] || MODE="event" ;;
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

      # Answering an AskUserQuestion means allow + updatedInput carrying the
      # selections (Claude Code >= 2.1.133); an allow without answers would run
      # the tool unanswered — stay silent so the terminal picker appears.
      if [ "$tool" = "AskUserQuestion" ] && [ "$decision" = "allow" ]; then
        answers="$(jq -c '.answers // empty' <<<"$dec" 2>/dev/null)"
        { [ -n "$answers" ] && [ "$answers" != "{}" ]; } || exit 0
        jq -cn --argjson input "$(jq -c '.tool_input // {}' <<<"$payload")" --argjson ans "$answers" \
          '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: ($input + {answers: $ans})}}'
        exit 0
      fi

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
    """#

    /// Served at GET /install — self-configuring installer for a remote machine.
    /// __SERVER__ and __TOKEN__ are substituted per request.
    static let installScript = #"""
    #!/bin/bash
    # Notch remote-machine setup (generated by the Notch app)
    set -euo pipefail

    for dep in curl jq; do
      command -v "$dep" >/dev/null 2>&1 || {
        echo "error: $dep is required (install it: apt install $dep / brew install $dep)" >&2
        exit 1
      }
    done

    mkdir -p "$HOME/.notch" "$HOME/.claude"
    chmod 700 "$HOME/.notch"

    # The hook is inlined below (quoted heredoc — no expansion, no second fetch).
    cat > "$HOME/.notch/notch-hook.sh" <<'NOTCH_HOOK_EOF'
    __HOOK_SCRIPT__
    NOTCH_HOOK_EOF
    chmod 755 "$HOME/.notch/notch-hook.sh"

    if [ ! -f "$HOME/.notch/env" ]; then
      # This machine gets only the machine token — it can report and request
      # permission, but never approve on another machine's behalf.
      ( umask 077; cat > "$HOME/.notch/env" <<EOF
    NOTCH_SERVER="__SERVER__"
    NOTCH_TOKEN="__TOKEN__"
    NOTCH_MACHINE="$(hostname -s)"
    NOTCH_REMOTE_APPROVE=1
    # Set to 1 to also gate headless (`claude -p` / SDK) sessions from the notch:
    NOTCH_GATE_HEADLESS=0
    EOF
      )
      chmod 600 "$HOME/.notch/env"
      echo "wrote $HOME/.notch/env"
    else
      echo "kept existing $HOME/.notch/env"
    fi

    SETTINGS="$HOME/.claude/settings.json"
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    cp "$SETTINGS" "$SETTINGS.notch-backup"

    HOOK_CMD_EVENT='"$HOME/.notch/notch-hook.sh" event'
    HOOK_CMD_PERM='"$HOME/.notch/notch-hook.sh" permission'
    HOOK_CMD_SL='"$HOME/.notch/notch-hook.sh" statusline'

    # Keep a pre-existing statusline: ours will chain to it after reporting usage.
    orig_sl="$(jq -r '.statusLine.command // empty' "$SETTINGS")"
    case "$orig_sl" in
      ""|*notch-hook*) ;;
      *) printf '%s\n' "$orig_sl" > "$HOME/.notch/statusline-orig"
         chmod 600 "$HOME/.notch/statusline-orig" ;;
    esac

    jq --arg ev "$HOOK_CMD_EVENT" --arg perm "$HOOK_CMD_PERM" --arg sl "$HOOK_CMD_SL" '
      def strip: map(select(((.hooks // []) | any(.command // "" | contains("notch-hook"))) | not));
      .hooks = (.hooks // {})
      | .hooks.SessionStart      = (((.hooks.SessionStart // [])      | strip) + [{hooks: [{type: "command", command: $ev}]}])
      | .hooks.UserPromptSubmit  = (((.hooks.UserPromptSubmit // [])  | strip) + [{hooks: [{type: "command", command: $ev}]}])
      | .hooks.Notification      = (((.hooks.Notification // [])      | strip) + [{hooks: [{type: "command", command: $ev}]}])
      | .hooks.PostToolUse       = (((.hooks.PostToolUse // [])       | strip) + [{hooks: [{type: "command", command: $ev}]}])
      | .hooks.Stop              = (((.hooks.Stop // [])              | strip) + [{hooks: [{type: "command", command: $ev}]}])
      | .hooks.SessionEnd        = (((.hooks.SessionEnd // [])        | strip) + [{hooks: [{type: "command", command: $ev}]}])
      | .hooks.PreToolUse        = (((.hooks.PreToolUse // [])        | strip) + [{matcher: "Bash|Write|Edit|MultiEdit|ExitPlanMode|AskUserQuestion", hooks: [{type: "command", command: $perm, timeout: 60}]}])
      | .statusLine              = {type: "command", command: $sl}
    ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

    echo "done — new Claude Code sessions on this machine report to __SERVER__"
    """#
}
