# Dev Environment — WSL2 Setup & Context Switching

This document describes Gabriel's Claude Code environment running on WSL2 (Ubuntu, `networkingMode=mirrored`), with VS Code Remote WSL. It is intended to give a new agent enough context to work here without re-discovering things from scratch.

---

## Machine Overview

- **Host:** Windows 11 + WSL2 (`~/.wslconfig`: `networkingMode=mirrored`)
- **Shell:** bash (zsh not used)
- **Editor:** VS Code Remote WSL, two profiles: `Parloa` and `Default` (personal)
- **Package manager used in projects:** pnpm 10.x
- **Custom scripts:** `~/.local/bin/` and `~/bin/` (both on PATH)
- **Script source of truth:** `~/dotfiles/` (git repo, GitHub: `gabriel-reis-parloa/dotfiles`, private)
  - Live files are **symlinks** → `~/dotfiles/home/...` so edits are instant
  - No sync step required

---

## Two Contexts: `parloa` and `personal`

Gabriel works in two completely separate contexts — work (Parloa) and personal. Each has its own:

| Item | Path |
|---|---|
| Claude credentials | `~/.context/<ctx>/claude-config.json` |
| Claude settings (plugins, permissions) | `~/.context/<ctx>/claude-settings.json` |
| Shell env vars | `~/.context/<ctx>/env.sh` |
| Active marker | `~/.context/active` (contains `parloa` or `personal`) |

These are swapped atomically by `switch-context`.

### Switching contexts

```bash
switch-context parloa       # switch to work
switch-context personal     # switch to personal
switch-context status       # show current context
```

**What `switch-context` does (in order):**
1. Kills all `mcp-gateway` processes (by PID file + `pgrep`) and waits for port 3100 to drain via TCP probe
2. Copies `~/.context/<target>/claude-config.json` → `~/.claude/config.json`
3. Copies `~/.context/<target>/claude-settings.json` → `~/.claude/settings.json`
4. Sources `~/.context/<target>/env.sh` into the current shell
5. Writes `~/.context/active`
6. Opens VS Code with the correct profile and project folder

**Critical:** gateway is stopped *before* credentials are swapped. Swapping while the gateway holds live connections causes a race condition.

**After switching:** `Ctrl+Shift+P → Developer: Reload Window` in VS Code is required.

---

## MCP Gateway

The MCP gateway (`mcp-gateway` binary, from Claude's Kitchen plugin) aggregates all MCP backends and runs on **port 3100**.

### State directory: `~/.cache/mcp-gateway/`

| Path | Purpose |
|---|---|
| `gateway.pid` | PID of the running gateway |
| `tokens/` | OAuth token files, one per backend (e.g. `jira.json`, `notion.json`) |
| `sessions/` | One file per active Claude session PID |
| `gateway.log` | Gateway process log (stdout+stderr redirected here by patch) |

### Health check (WSL-safe)

`lsof -i :3100` is **unreliable in WSL** — use TCP probe instead:
```bash
(echo > /dev/tcp/127.0.0.1/3100) 2>/dev/null && echo "UP" || echo "DOWN"
```
All scripts in this environment use this probe, not lsof.

### Token management

Tokens live in `~/.cache/mcp-gateway/tokens/*.json`. The list is dynamic — any new backend gets picked up automatically. Each file has `expires_at` and optionally `refresh_token`.

- Tokens are **pre-refreshed on every session start** by `patch-gateway-timeouts.sh` (calls `~/.context/refresh-mcp-tokens.sh --force`)
- Cron also refreshes every 20 minutes via `refresh-mcp-tokens.sh`
- Backends that need browser OAuth (no refresh token): Datadog, Notion, Jira, Miro, Google Workspace

### 1Password in WSL

**1Password CLI (`op`) does not work in WSL.** A fake `op` shim at `~/.context/bin/op` is prepended to PATH before the gateway starts (via `patch-gateway-timeouts.sh`). It reads/writes OAuth tokens from JSON files instead.

---

## Session Hooks and Patches

Claude's Kitchen plugin installs gateway hooks in:
```
~/.claude/plugins/cache/claudes-kitchen/gateway/<hash>/hooks/
  gateway-session-start.sh
  gateway-session-end.sh
```

These hooks are patched on every Claude session start by:
```
~/.claude/hooks/patch-gateway-timeouts.sh
```
This is a `SessionStart` hook (registered in `~/.claude/settings.json`).

### What the patches do

Each patch is **idempotent** (guarded by grep before applying):

| Patch | Why |
|---|---|
| `timeout -k 5 15 op item get ...` | WSL ignores SIGTERM; `-k 5` sends SIGKILL after 5s |
| `curl -sf --max-time 15 ...` | Prevents infinite hang if OAuth endpoint is unreachable |
| `timeout -k 5 10 rustup which cargo` | `rustup` can hang indefinitely in WSL |
| Prepend `~/.context/bin` to PATH | Injects fake `op` shim before gateway starts |
| Redirect gateway to `gateway.log` | `>> ~/.cache/mcp-gateway/gateway.log 2>&1` |
| Port-drain wait before bind | Avoids bind-fail race on SIGTERM (async in WSL) |
| Claude ancestor registration | `$PPID` is ephemeral subprocess — walks process tree to find long-lived `claude` ancestor for session registration |
| Backend stability wait | Watches `gateway.log` for stable tool count (`> 13`, stable for 3 consecutive checks) before allowing Claude to start |

---

## Custom Tools (all in `~/.local/bin/` or `~/bin/`)

### `claude-status`

Live terminal monitor. Refreshes every 10s. **Auto-restarts gateway if not responding.**

```bash
claude-status           # continuous monitor
claude-status --once    # snapshot
```

Shows:
- Gateway: PID, memory, port
- Tokens: per-backend expiry and refresh status
- Sessions: PID, session ID, conversation label (VSCode vs Terminal), memory, idle/active state
- Memory: WSL RAM usage

### `claude-ready`

Startup readiness poller. Polls gateway + Claude extension until both are up, then shows final status and exits. Designed as a VS Code `folderOpen` task.

```bash
claude-ready
```

- Timeout: 120s
- On READY: shows gateway PID/mem, token statuses
- On TIMEOUT: shows which component is missing

### `kitchen-gateway-status`

Legacy token expiry check. Still uses `lsof` (noted as unreliable). Prefer `claude-status` instead.

```bash
kitchen-gateway-status
kitchen-gateway-status --json
```

### `switch-context`

See above.

---

## VS Code Integration

### Tasks (`~/projects/parloa/.vscode/tasks.json`)

| Task | Trigger | What it does |
|---|---|---|
| `Claude: Environment Ready` | `folderOpen` | Runs `claude-ready` in terminal panel |
| `Claude: Restart Gateway` | Manual | Kills gateway processes |

---

## Debugging

**Claude extension hanging / MCP tools unavailable:**
1. Run `claude-status` — auto-restarts broken gateway
2. If still broken: `Ctrl+Shift+P → Developer: Reload Window`
3. If gateway won't start: `tail -50 ~/.cache/mcp-gateway/gateway.log`

**After `switch-context`, Claude not working:**
1. Check active context: `cat ~/.context/active`
2. Check credentials: `jq -r '.primaryApiKey' ~/.claude/config.json`
3. Run `claude-status`
4. `Developer: Reload Window`

**Stuck processes:**
```bash
pgrep -a -f "gateway-session-start"   # should be empty when idle
pgrep -a -f "mcp-gateway"             # should show one process
```

**Token needs manual re-auth (no refresh token):**
Run the VS Code task `Gateway: Re-auth` or manually log in via browser.

---

## File Map

| Live path | Dotfiles source |
|---|---|
| `~/.local/bin/claude-status` | `home/.local/bin/claude-status` |
| `~/.local/bin/claude-ready` | `home/.local/bin/claude-ready` |
| `~/.local/bin/kitchen-gateway-status` | `home/.local/bin/kitchen-gateway-status` |
| `~/.local/bin/README.md` | `home/.local/bin/README.md` |
| `~/bin/switch-context` | `home/bin/switch-context` |
| `~/.claude/hooks/patch-gateway-timeouts.sh` | `home/.claude/hooks/patch-gateway-timeouts.sh` |
| `~/.context/refresh-mcp-tokens.sh` | `home/.context/refresh-mcp-tokens.sh` |
| `~/projects/parloa/.vscode/tasks.json` | `vscode/tasks.json` |
