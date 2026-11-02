# Mac handoff — pixel-art fleet UI in Notch.app + NUC server

You are Claude Code on Tam's Mac. Read this whole file first. Do the work in this repo (`MinhTamCK/notch`, branch `nuc-server`).

## What already exists (done on the NUC, tested)

- A **central headless server** runs on the NUC (a Linux VM on the tailnet) at `http://100.82.132.78:4519`, bound ONLY to that Tailscale IP, started by systemd user unit `notch-server`. Source: `server/` in this repo (Node/TS, Hono + ws). Added in commit `1b7274e`: `NOTCH_HOST` bind + static web dashboard.
- **Reference UI**: `server/public/index.html` is a working web dashboard (open `http://100.82.132.78:4519/dashboard/`, token = operator token). Screenshot: `docs/demo-dashboard.png`. It is the visual spec for the Swift UI — same colours, same sprite, same grouping.
- Hooks on each machine (the NUC already, panda VM + Macs next) POST to the NUC with the *machine* token. The Mac app must be a **viewer/operator** of that server, not host its own.

## Privacy model (do not weaken)

- Two roles. *machine* token: report events, open permission requests, poll own decision. *operator* token: list sessions, open `/ws`, decide permissions. A machine token gets 401 on `GET /api/sessions` — this is why panda (machine token only) cannot read fleet info.
- Server only accepts loopback + Tailscale (`100.64.0.0/10`) sources. Never bind 0.0.0.0, never add a public tunnel.
- Tokens live in `~/.notch/env` (mode 600) on the Mac. NEVER commit tokens, never print them in logs/UI, never put them in the repo or in screenshots. Tam gets them on the NUC from `~/.notch-server/env` (keys `NOTCH_TOKEN` = machine, `NOTCH_OPERATOR_TOKEN` = operator).

## Task 1 — connect Notch.app to the NUC server

The app already supports client mode: `AppModel.swift` hosts an embedded server only when `NOTCH_SERVER` is localhost; otherwise it acts as a client (WS `ws://<host>/ws?token=<operator>` — see `AppModel.swift` ~L120-160 and L274).

1. Back up `~/.notch/env`, then set on the Mac:
   ```
   NOTCH_SERVER="http://100.82.132.78:4519"
   NOTCH_TOKEN="<machine token>"
   NOTCH_OPERATOR_TOKEN="<operator token>"
   NOTCH_MACHINE="<mac-home | mac-company>"   # unique per Mac
   NOTCH_REMOTE_APPROVE=1
   ```
   (Ask Tam to paste the two tokens; do not echo them back.)
2. Relaunch Notch.app. Confirm it does NOT start the embedded server (no listener on :4519 locally) and shows sessions from the NUC. If client mode has a gap (e.g. connection status, reconnect backoff, 401 handling), fix it and add a unit test in `NotchCoreTests`.
3. Hooks on this Mac keep using the same env (machine token) so this Mac's own sessions report to the NUC.

## Task 2 — pixel-art fleet UI ("the colour is the interface")

Inspiration: https://fleet-terminal.app/ — six colours you learn once, most of the fleet is grey. Implement in `app/Sources/NotchApp/` (`NotchViews.swift` has `SessionRow` ~L943, `AgentBadge` ~L91, `CompactLeadingView`/`ExpandedView`; states are `SessionState` in `Models.swift`).

State → colour (same as the web dashboard):

| state | colour | meaning |
|---|---|---|
| working | grey `#8B93A1` | nothing needed from Tam |
| needs_permission | amber `#F5A524` | tool call awaiting Allow/Deny |
| needs_attention | violet `#A78BFA` | agent's turn / question |
| done | green `#3ECF8E` | finished |
| stale | dim `#4A5060` (55% opacity) | silent too long |
| ended | darker `#343843` (45% opacity) | session ended |

Sprite: a 16x18 grid crab-like mascot (see `sprite()` in `server/public/index.html` — body rows, eye sockets, 4 legs). Body fill = state colour. Working: legs alternate + eyes shift, 2 frames at 0.5 s. needs_permission: raised claw + `!`. needs_attention: `?` above head. done: smile + sparkles. stale/ended: x-eyes. Render it as a SwiftUI `Canvas` (or a small struct of rects) with `.interpolation(.none)` so pixels stay crisp; animate with `TimelineView(.periodic(from: .now, by: 0.5))`. Keep CPU low (no animation when the panel is hidden).

Layout to mirror: sessions grouped by machine; within a machine sort needs_permission → needs_attention → working → done → stale → ended, then by `updatedAt` desc. Each row: sprite, folder name of `cwd`, state label + age, last message / `lastTool`, agent name. Header: "N working · M need you · K sessions" + usage bars (already exist as `UsageRow`). Left border / card accent uses the state colour. Compact notch view: show a row of tiny sprites (max ~6) instead of the equalizer when sessions exist; fall back to the current look if you cannot make it clean.

Keep the existing approve/deny cards (`PermissionCard`, `QuestionCard`) working — do not regress them.

## Constraints / how to work

- Match existing Swift style; no new dependencies. Surgical changes, no refactors beyond what the task needs.
- Add unit tests for any pure logic you add (state→colour mapping, sort order, grouping) in `app/Tests/NotchCoreTests`; make sure each test would fail if the logic were wrong.
- Verify: `cd app && swift build && swift test`, then run the app, and compare visually with `docs/demo-dashboard.png` (screenshot yours and look at it).
- Test data without touching real sessions: `scripts/demo-events.sh` / `scripts/demo-permission.sh` post fake events — point them at the NUC with the machine token, use machine names like `demo-*`, and note fake sessions disappear only on server restart or after the stale window.
- Do not push to `master`. Commit on `nuc-server`; Tam decides about merge/release. No AI attribution trailers are required beyond the repo's existing convention (check `git log`).
- When done, report: what changed (files), test results, screenshot path, and anything you could not verify.
