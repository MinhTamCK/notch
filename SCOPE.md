# Notch — Remote Claude Code Monitor

A macOS notch app (Vibe Island–style) for monitoring **and remotely approving** Claude Code
sessions running on many VMs / other computers, via a central server.

## Decisions (locked)

| Decision | Choice |
|---|---|
| Interaction | Monitor + remote approve |
| Mac app form | Notch app, native Swift/SwiftUI |
| VM reporting | Claude Code hooks push events (no daemon) |
| Agents (v1) | Claude Code only (schema stays agent-agnostic for Cursor later) |
| Notch UI | [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) (MIT) — handles notch panel + non-notch Macs |
| Assets | SF Symbols for in-app icons; own app icon (SVG → iconutil); Kenney CC0 packs for 8-bit sounds |

## Architecture

```
┌─ VM 1..N / other computer ──────────┐
│ Claude Code sessions                │
│  └─ hooks (curl scripts)            │──── HTTPS/Tailscale ───┐
│     SessionStart/End  → POST event  │                        │
│     Notification      → POST event  │                        ▼
│     Stop              → POST event  │              ┌─ Central server ─────┐
│     PreToolUse        → POST + LONG-POLL for       │ Node/TS (Hono + ws)  │
│                         allow/deny decision        │ SQLite + in-memory   │
└─────────────────────────────────────┘              │ REST for hooks       │
                                                     │ WebSocket for app    │
                                                     └──────────┬───────────┘
                                                                │ WebSocket
                                                     ┌─ Mac notch app ──────┐
                                                     │ Swift/SwiftUI NSPanel│
                                                     │ session list, states │
                                                     │ approve/deny buttons │
                                                     │ plan preview, sounds │
                                                     └──────────────────────┘
```

### The remote-approve mechanism (core trick)

`PreToolUse` hooks can decide permissions. The hook script:

1. POSTs `{session, machine, tool_name, tool_input}` to `POST /api/permissions`
2. Long-polls (up to ~55s, under the hook `timeout`) for the user's decision
3. On decision → prints `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"|"deny","permissionDecisionReason":"via notch app"}}`
4. On timeout / server unreachable → prints `"permissionDecision":"ask"` (or exits 0 silently) → Claude Code falls back to the normal terminal prompt. **Sessions never get bricked by the server being down.**

Bonus: `ExitPlanMode` is also a `PreToolUse` event whose `tool_input` contains the full plan
markdown → **remote plan preview + plan approval** comes for free.

Caveats (accepted for v1):
- Hook matcher scoped to `Bash|Write|Edit|MultiEdit|ExitPlanMode` so cheap read-only tools
  don't round-trip to the server.
- Matched tools that the VM's allowlist would have auto-approved still wait on the remote
  decision (or timeout→ask). Mitigation: per-VM env toggle `NOTCH_REMOTE_APPROVE=0` to make
  the hook fire-and-forget (monitor only). Smarter allowlist passthrough is v1.1.

### Components

**1. `hooks/` — installer for VMs (shell)**
- `install.sh`: one-liner (`curl … | bash`) that drops `notch-hook.sh` into `~/.notch/` and
  merges hook config into `~/.claude/settings.json`. Config: `NOTCH_SERVER`, `NOTCH_TOKEN`,
  `NOTCH_MACHINE` (label, defaults to hostname) via `~/.notch/env`.
- `notch-hook.sh`: single script handling all hook events (reads stdin JSON, adds machine
  label + timestamp, POSTs; long-poll branch for PreToolUse). Deps: `curl`, `jq`.

**2. `server/` — central server (Node 22 + TypeScript, Hono + `ws`, SQLite via better-sqlite3)**
- `POST /api/events` — ingest hook events (bearer token auth)
- `POST /api/permissions` + `GET /api/permissions/:id/decision?wait=55` — permission long-poll
- `POST /api/permissions/:id/decide` — called by the Mac app (also over WS)
- `GET /ws` — WebSocket: pushes session list + state changes + pending permissions to app
- Session state machine per (machine, session_id): `working → needs_permission → working → idle/done`
  with `last_seen` heartbeating; sessions expire to `stale` after no events.
- Storage: in-memory state + append-only JSONL event log (zero native deps; swap to SQLite
  when history/query features land).
- Deploy: runs on the Mac itself (simplest) or any always-on box; VMs reach it over
  **Tailscale** (recommended — no TLS/cert work, works across networks).

**3. `app/` — macOS notch app (Swift 5.10+, SwiftUI, macOS 14+)**
- NSPanel positioned over the notch (non-activating, floats above menu bar); collapsed pill
  shows counts (e.g. `3 working · 1 waiting`), click/hover expands panel.
- Expanded: session rows (machine · project dir · state · elapsed), grouped by machine.
- Permission prompt UI: tool + command/diff summary, **Approve / Deny** buttons; plan
  preview rendered as Markdown.
- Alerts: sound + optional macOS notification when a session needs permission or finishes.
- Settings: server URL + token, sounds on/off, launch at login.
- Distribution: Developer ID signed + notarized `.app` (no App Store).

## Milestones (each independently verifiable)

**M1 — Event pipeline (server + hooks)**
Run server locally; install hooks on one VM; start a Claude Code session there.
✅ Done when: server log/`GET /api/sessions` shows the session appear as `working`,
flip to `needs_permission` on a Notification event, and `done` on Stop.

**M2 — Notch app, monitor only**
Swift app connects via WS, renders notch pill + expandable session list with live states,
plays a sound on `needs_permission`.
✅ Done when: watching a real remote session's state change in the notch within ~1s.

**M3 — Remote approve**
PreToolUse long-poll wired end-to-end; Approve/Deny buttons in app; plan preview.
✅ Done when: a `Bash` call on a VM is approved from the notch and executes; a deny
blocks it with the reason shown to Claude; server-down → terminal prompt fallback works.

**M4 — Polish + daily-driver hardening**
Multi-machine grouping, stale-session cleanup, reconnect logic (app↔server), launch at
login, signed build, install.sh ergonomics.
✅ Done when: running it for a real day across all VMs without restarting anything.

## Out of scope (v1)

- Cursor support (v1.1 — event schema already has an `agent` field)
- Sending new prompts / steering sessions ("full remote control")
- Web dashboard, multi-user/auth beyond a shared token, historical analytics UI
- Windows/Linux viewer app, App Store distribution
- Terminal jumping on the local Mac (Vibe Island feature — irrelevant for remote sessions;
  reconsider if local-session support is added)

## Assumptions (flag if wrong)

- VMs can reach the server over a private network (Tailscale or LAN); no public exposure.
- Single user (you); a shared bearer token is sufficient auth.
- VMs are Linux/macOS with `curl` + `jq` available; Claude Code ≥ 1.0 with hooks support.
- The Mac running the app can also run the server (or you have an always-on box).
