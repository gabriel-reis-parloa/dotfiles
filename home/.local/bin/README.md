# Dev Environment — Custom Tooling Reference

This file is the reference for all custom tooling — intended for both manual debugging and agent-assisted diagnosis.

---

## Context Switching

`switch-context [parloa|personal]` does the following in order:

1. **Stops the MCP gateway** (kills all `mcp-gateway` processes, waits for port 3100 to drain)
2. Swaps `~/.claude/config.json` (Claude credentials)
3. Swaps `~/.claude/settings.json` (plugins, permissions)
4. Sources `~/.context/<target>/env.sh` into the current shell
5. Updates `~/.context/active` with the current context name
6. Opens VS Code with the correct profile and project folder

**Critical:** gateway is stopped *before* credentials are swapped. Swapping credentials while the gateway holds live connections causes a race condition.

**After switching**, `Developer: Reload Window` in VS Code is required.

---

## MCP Gateway

The MCP gateway (`mcp-gateway` binary) runs on port 3100 and aggregates all MCP backends.

**Gateway state directory:** `~/.cache/mcp-gateway/`
- `gateway.pid` — PID of the running gateway
- `tokens/` — OAuth token files per backend
- `sessions/` — one file per active Claude session PID
- `gateway.log` — gateway process log

**WSL health check** (`lsof` is unreliable — use TCP probe):
```bash
(echo > /dev/tcp/127.0.0.1/3100) 2>/dev/null && echo "UP" || echo "DOWN"
```

---

## Tools

### `claude-status`
Live monitor. Auto-refreshes every 10s. Auto-restarts gateway if not responding.
```bash
claude-status           # continuous
claude-status --once    # snapshot
```

### `claude-ready`
Startup readiness poller. Runs automatically on VS Code folder open.
```bash
claude-ready
```

### `switch-context`
```bash
switch-context parloa
switch-context personal
switch-context status
```

### `kitchen-gateway-status`
Token expiry check (legacy — uses lsof).
```bash
kitchen-gateway-status
kitchen-gateway-status --json
```

---

## VS Code Tasks

| Task | Trigger | What it does |
|---|---|---|
| `Claude: Environment Ready` | `folderOpen` | Runs `claude-ready` |
| `Claude: Restart Gateway` | Manual | Kills gateway processes |

---

## Debugging Checklist

**Claude extension hanging / MCP tools unavailable:**
1. Run `claude-status` — auto-restarts broken gateway
2. If still broken: `Ctrl+Shift+P → Developer: Reload Window`
3. If gateway won't start: `tail -50 ~/.cache/mcp-gateway/gateway.log`

**After `switch-context`, Claude not working:**
1. Check `~/.context/active`
2. Check `~/.claude/config.json`: `jq -r '.primaryApiKey' ~/.claude/config.json`
3. Run `claude-status`
4. `Developer: Reload Window`

**Stuck processes:**
```bash
pgrep -a -f "gateway-session-start"   # should be empty when idle
pgrep -a -f "mcp-gateway"             # should show one process
```
