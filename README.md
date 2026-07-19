# Notch

Monitor **and remotely approve** your Claude Code and Cursor sessions from your Mac's notch — across every machine you run agents on.

🌐 **[codepi.xyz/notch](https://codepi.xyz/notch)** · 🎬 **[Watch the demo](https://codepi.xyz/assets/media/notch-demo.mp4)** · 📦 **[Download](https://github.com/MinhTamCK/notch/releases/latest)**

---

## What it does

- **See every session at a glance** — live status (working · waiting · done) of all your Claude Code and Cursor agents, right in the MacBook notch.
- **Approve from the notch** — permission requests pop up with an inline diff (for edits), the command (for shell), or a Markdown plan preview. Hit **Allow** or **Deny** without leaving what you're doing.
- **Alerts that matter** — sound + auto-expand when a session needs you; opt-in "your turn" ping when a turn finishes.
- **Self-contained** — the app *is* the server. Open it and it hosts everything locally, zero config.
- **Private by design** — traffic is restricted to loopback + your Tailscale network, guarded by two-role tokens. No cloud, no telemetry.

## How it works

```
   MACHINES  (Mac · VMs · remote boxes)
   │
   │    Claude Code ─┐
   │     (hooks)     ├──►  notch-hook  —  reports events, asks for approval
   │    Cursor ──────┘
   │
   │    HTTP over Tailscale   (loopback + 100.64.0.0/10 only)
   ▼
   NOTCH.APP  (your Mac)
   │
   ├──  embedded server   —  session states + permission queue   (hosts :4519)
   │
   └──  notch UI (SwiftUI, lives in the notch)
             3 working · 1 waiting        ← live status of every session
             [ Allow ]   [ Deny ]         ← approve without leaving your work
```

A tool call that needs approval round-trips through the notch and back:

```
  Claude wants to run:  $ npm test
        │
        ▼
  notch-hook ──POST /api/permissions──► server ──► notch pops:  [Allow]  [Deny]
        ▲                                                            │
        └──────────── allow / deny  (long-poll, ≤ 55s) ─────────────┘
        │
        └─ server unreachable or you don't answer in time
              → falls back to Claude Code's normal terminal prompt (never blocks)
```

Because hooks **fail open**, Notch being down never freezes an agent — the worst case is you answer in the terminal like you always did.

## Quick start

1. **[Download the latest release](https://github.com/MinhTamCK/notch/releases/latest)**, unzip, and drag `Notch.app` into `/Applications`.
2. Clear the quarantine flag once (builds aren't notarized yet):
   ```bash
   xattr -cr /Applications/Notch.app
   ```
3. **Open it.** It hosts its own server and generates its own tokens — nothing to configure.
4. Click the **⚙️ gear** in the notch panel → **Enable Claude Code on This Mac**. New sessions now show up in your notch.
5. To watch a VM or another computer: gear → **Add Remote Machine (Copy Command)**, then paste that one line into the remote shell (needs `curl` + `jq`, and Tailscale reach to your Mac).

**Requirements:** macOS 14+ · Apple Silicon or Intel (universal) · [Tailscale](https://tailscale.com/download) for remote machines.

## Security

- The server accepts requests **only** from loopback and the Tailscale range `100.64.0.0/10` (+ its IPv6 ULA) — LAN and internet sources are rejected outright.
- **Two-role tokens:** a *machine* token can report and request approval; only the *operator* token (held on the host Mac) can list sessions and decide. A compromised remote can never approve on another machine's behalf.
- Secrets live in `~/.notch/env` (mode `0600`), never in the repo. Logs are metadata-only by default.

## Build from source

```bash
# Central server (optional headless mode) + tests
cd server && npm ci && npm test

# macOS app + unit tests
cd app && swift build && swift test

# Package a signed .app and zip a release
scripts/bundle-app.sh      # → app/dist/Notch.app
scripts/release.sh         # runs tests, builds universal, publishes
```

The app embeds the server, so `Notch.app` alone is enough to run everything. The `server/` (Node/TypeScript) directory is an optional headless deployment; the app auto-detects it and switches to a viewer.

## License

[MIT](LICENSE) © MinhTamCK
