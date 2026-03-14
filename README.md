# claude-code-setup

WSL2 environment setup for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with the Claude's Kitchen MCP gateway at Parloa.

This repository contains the shell scripts, hooks, and VS Code configuration that make Claude Code production-ready in a WSL2 + VS Code Remote WSL environment — with automatic gateway management, context switching between work accounts, OAuth token refresh, and a startup readiness check.

---

## Why this exists

Running Claude Code with multiple MCP backends (Jira, Notion, Datadog, GitHub, Google Workspace, Miro) in WSL2 has several failure modes that don't exist on native Linux or macOS:

- **`lsof` is unreliable in WSL2** — it cannot detect whether a process is actually listening on a port. TCP probes (`/dev/tcp/127.0.0.1/PORT`) are used everywhere instead.
- **Claude extension auto-updates cause a port bind-fail race** — the new binary starts before the old one releases port 3100, producing a live gateway process that isn't serving. A port-drain wait patch prevents this.
- **1Password CLI (`op`) doesn't work in WSL2** — the gateway uses 1Password for all OAuth token storage. A fake `op` shim intercepts these calls and routes them to `~/.cache/mcp-gateway/tokens/*.json` instead.
- **OAuth callbacks need to reach WSL** — with `networkingMode=mirrored` in `~/.wslconfig`, WSL2 `127.0.0.1` is identical to Windows localhost, so browser OAuth flows reach the gateway directly without port forwarding.
- **Session PID registration races** — the gateway registers `$PPID` on session start, but `$PPID` in a hook is an ephemeral subprocess that exits immediately. The real Claude process is the long-lived ancestor. A process-tree walk patch fixes this.
- **Context switching races** — swapping Claude credentials while the gateway holds live connections crashes the gateway mid-session. The `switch-context` script kills the gateway first, then swaps credentials.
- **Token refresh timing** — MCP backends refresh tokens asynchronously. Without a wait, Claude starts a session seeing only the backends that connected instantly (typically just GitHub), missing Jira, Notion, Datadog, etc. A tool-count stabilisation wait is patched into the gateway startup hook.

All of these fixes are applied non-destructively via `patch-gateway-timeouts.sh`, a hook that runs on every Claude session start. This means the fixes survive plugin cache updates — when Claude's Kitchen updates its gateway, the patch hook re-applies everything automatically.

---

## System architecture

```
Windows (Chrome, Okta, OAuth browser flows)
      │
      │  networkingMode=mirrored (C:\Users\<user>\.wslconfig)
      │  WSL 127.0.0.1 == Windows 127.0.0.1
      ▼
WSL2 Ubuntu
  ├── VS Code Remote WSL
  │     ├── Claude Code extension  ←── ~/.claude/config.json (credentials)
  │     │         │                     ~/.claude/settings.json (plugins)
  │     │         │ MCP SSE
  │     │         ▼
  │     │   mcp-gateway :3100  ←── ~/.cache/mcp-gateway/tokens/*.json (OAuth)
  │     │         │
  │     │         ├── Jira (OAuth2)
  │     │         ├── Notion (OAuth2)
  │     │         ├── Datadog (OAuth2)
  │     │         ├── GitHub (token)
  │     │         ├── Google Workspace (OAuth2)
  │     │         └── Miro (OAuth2)
  │     │
  │     └── .vscode/tasks.json
  │           └── "Claude: Environment Ready" (folderOpen) → claude-ready
  │
  ├── ~/.local/bin/
  │     ├── claude-status        # live process + gateway monitor
  │     ├── claude-ready         # startup readiness poller (VS Code task)
  │     └── kitchen-gateway-status  # token expiry check
  │
  ├── ~/bin/
  │     └── switch-context       # swap parloa ↔ personal credentials
  │
  ├── ~/.context/
  │     ├── active               # current context name
  │     ├── parloa/              # parloa credentials (NOT in this repo)
  │     ├── personal/            # personal credentials (NOT in this repo)
  │     └── refresh-mcp-tokens.sh  # proactive token refresh (cron + session hook)
  │
  └── ~/.claude/hooks/
        └── patch-gateway-timeouts.sh  # WSL patches applied every session start
```

---

## What's in this repo

```
clause-code-setup/
  README.md
  install.sh                              # symlink installer
  .gitignore
  home/
    .local/bin/
      claude-status                       # live monitor
      claude-ready                        # startup readiness poller
      kitchen-gateway-status              # token status CLI
      README.md                           # full tooling reference
    bin/
      switch-context                      # context switcher
    .claude/hooks/
      patch-gateway-timeouts.sh           # WSL patch hook
    .context/
      refresh-mcp-tokens.sh               # OAuth token refresh
  vscode/
    tasks.json                            # VS Code workspace tasks
```

### `claude-status`

Live terminal monitor. Refreshes every 10 seconds.

```bash
claude-status           # continuous monitor
claude-status --once    # single snapshot
```

Shows:
- **Gateway**: TCP probe health check, PID, memory. Auto-restarts the gateway if it's not responding.
- **Tokens**: Per-backend OAuth token expiry for all files in `~/.cache/mcp-gateway/tokens/`. Generic — picks up any new backend automatically.
- **Claude processes**: All running Claude instances with session ID, conversation label (VSCode vs Terminal), memory usage, and active/idle state.
- **WSL memory**: Total, used, free, available.

### `claude-ready`

Startup readiness poller. Designed to run as a VS Code `folderOpen` task. Polls every 2 seconds until the gateway is healthy and Claude is running, then prints a READY summary and exits. Times out at 120 seconds.

```bash
claude-ready    # also runs automatically on VS Code folder open
```

Output on success:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Parloa's Claude Environment — READY  (12s to start)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✓ Kitchen's Gateway  PID=12345  mem=142MB  port=3100
  ✓ Claude             running

  Backend tokens:
  jira                ok  (45m remaining)
  notion              ready  (auto-refresh on use)
  datadog             ok  (2h 10m remaining)
  google_workspace    ok  (50m remaining)

  Ready at 09:14:32
```

### `kitchen-gateway-status`

Shows gateway service state and per-backend token expiry. Useful for manual inspection.

```bash
kitchen-gateway-status          # human-readable
kitchen-gateway-status --json   # JSON output
```

> Note: this script still uses `lsof` for gateway detection (legacy). Use `claude-status` for reliable health checks in WSL2.

### `switch-context`

Switches between Parloa and personal work contexts. Handles credential swapping, gateway lifecycle, and VS Code profile.

```bash
switch-context parloa     # switch to Parloa
switch-context personal   # switch to personal
switch-context status     # show current context
```

Operation order (critical — see [Why this exists](#why-this-exists)):
1. Kill the MCP gateway and wait for port 3100 to drain
2. Swap `~/.claude/config.json` (Claude API credentials)
3. Swap `~/.claude/settings.json` (plugins, permissions)
4. Source `~/.context/<target>/env.sh` into the current shell
5. Update `~/.context/active`
6. Open VS Code with the correct profile and project folder

After switching, `Developer: Reload Window` in VS Code is required to reload the Claude extension with the new credentials.

### `patch-gateway-timeouts.sh`

A Claude `SessionStart` hook. Runs on every session start and applies WSL-specific patches to the gateway hooks:

| Patch | Problem solved |
|---|---|
| `timeout -k 5 15` on `op item get` | 1Password CLI hangs indefinitely in WSL |
| `--max-time 15` on `curl` | OAuth endpoints unreachable → silent hang |
| `timeout -k 5 10` on `rustup which cargo` | `rustup` hangs on WSL |
| Fake `op` CLI via `PATH` prepend | 1Password unavailable → routes token ops to JSON files |
| Gateway log redirect (`>> gateway.log 2>&1`) | Log file stays empty without explicit redirect |
| Port-drain wait before gateway bind | Prevents port 3100 bind-fail race on restart |
| Claude ancestor walk for PID registration | `$PPID` in hooks is ephemeral → registers wrong PID |
| Tool-count stabilisation wait | Backends connect asynchronously → Claude starts before all tools are available |

Patches are idempotent and guarded — each one checks if it's already been applied before modifying the file. This makes the hook safe to run on every session start and resilient to gateway plugin cache updates.

### `refresh-mcp-tokens.sh`

Proactively refreshes all OAuth tokens expiring within 15 minutes. Iterates all `*.json` files in `~/.cache/mcp-gateway/tokens/` — automatically covers any new backend.

Called in two ways:
- **Session start**: via `patch-gateway-timeouts.sh` with `--force` (before the gateway starts, skips the gateway guard)
- **Cron**: every 20 minutes (set up separately)

```bash
# Add to crontab:
*/20 * * * * bash ~/.context/refresh-mcp-tokens.sh >> ~/.cache/mcp-gateway/refresh.log 2>&1
```

Only runs in `parloa` context (guarded by `~/.context/active`).

---

## Installation

```bash
git clone https://github.com/gabriel-reis-parloa/claude-code-setup.git ~/claude-code-setup
cd ~/claude-code-setup
bash install.sh
```

`install.sh` creates symlinks from the expected system paths to the repo. Editing a script in `~/claude-code-setup/home/...` immediately takes effect — no sync step.

For the VS Code tasks:
```bash
cp ~/claude-code-setup/vscode/tasks.json ~/projects/parloa/.vscode/tasks.json
```

### Prerequisites

- WSL2 with Ubuntu
- VS Code with Remote WSL extension and Claude Code extension installed
- Claude's Kitchen MCP gateway plugin installed in Claude Code
- `~/.context/` directory with `parloa/` and `personal/` credential subdirectories
- `~/.context/bin/op` — fake 1Password shim (not in this repo — contains token routing logic tied to the local setup)
- `jq`, `python3`, `curl`, `pgrep` available in WSL

### WSL networking (required for OAuth browser flows)

Add to `C:\Users\<your-user>\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

Then restart WSL:
```powershell
wsl --shutdown
```

This makes `127.0.0.1` in WSL identical to Windows localhost, so OAuth callback URLs reach the MCP gateway directly from the browser.

---

## Token storage

OAuth tokens are stored as JSON files in `~/.cache/mcp-gateway/tokens/`. Each file follows this structure:

```json
{
  "access_token": "...",
  "refresh_token": "...",
  "expires_at": "2026-03-14T10:30:00+00:00",
  "token_url": "https://...",
  "client_id": "...",
  "client_secret": "..."
}
```

All token-related tooling (`claude-status`, `claude-ready`, `refresh-mcp-tokens.sh`) reads this directory dynamically — adding a new backend requires no script changes.

**Tokens are not committed to this repo.**

---

## Debugging

**Gateway not responding:**
```bash
claude-status
(echo > /dev/tcp/127.0.0.1/3100) 2>/dev/null && echo UP || echo DOWN
tail -50 ~/.cache/mcp-gateway/gateway.log
```

**After context switch, Claude not working:**
1. Confirm `~/.context/active` has the expected context
2. Confirm credentials: `jq -r '.primaryApiKey' ~/.claude/config.json | sed 's/.\{20\}$/.../'`
3. Run `claude-status`
4. `Ctrl+Shift+P → Developer: Reload Window` in VS Code

**Stuck gateway-session-start processes:**
```bash
pgrep -a -f gateway-session-start   # should be empty when idle
pkill -f gateway-session-start       # kill if stuck
```

**Token expired, manual re-auth needed:**
```bash
kitchen-gateway-status
# Ctrl+Shift+P → Run Task → Claude: Restart Gateway
# Complete OAuth flow in browser
```
