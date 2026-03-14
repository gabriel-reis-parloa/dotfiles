#!/bin/bash
# Patches gateway hooks on every Claude session start.
# Survives plugin cache updates by patching ALL cached versions.
# Each patch is idempotent — guarded so it only applies if not already present.

# ── Pre-refresh expired MCP tokens (avoids browser OAuth on startup) ─────────
if [ "$(cat "$HOME/.context/active" 2>/dev/null)" = "parloa" ]; then
  bash "$HOME/.context/refresh-mcp-tokens.sh" --force 2>/dev/null || true
fi

# ── session-start patches ────────────────────────────────────────────────────
while IFS= read -r HOOK_FILE; do
  CHANGED=false

  # Patch op item get calls — use -k 5 to SIGKILL if SIGTERM is ignored (WSL)
  if ! grep -q 'timeout -k' "$HOOK_FILE" && grep -q 'op item get' "$HOOK_FILE"; then
    sed -i 's/"\$(timeout 15 op item get /"\$(timeout -k 5 15 op item get /g' "$HOOK_FILE"
    sed -i 's/"\$(op item get /"\$(timeout -k 5 15 op item get /g' "$HOOK_FILE"
    CHANGED=true
  fi

  # Patch curl calls (no --max-time = hangs if OAuth endpoint is unreachable)
  if ! grep -q 'curl.*--max-time' "$HOOK_FILE" && grep -q 'curl -sf' "$HOOK_FILE"; then
    sed -i 's/curl -sf /curl -sf --max-time 15 /g' "$HOOK_FILE"
    CHANGED=true
  fi

  # Patch rustup which cargo (can hang on WSL indefinitely)
  if ! grep -q 'timeout.*rustup which cargo' "$HOOK_FILE" && grep -q 'rustup which cargo' "$HOOK_FILE"; then
    sed -i 's/\$(rustup which cargo/\$(timeout -k 5 10 rustup which cargo/g' "$HOOK_FILE"
    CHANGED=true
  fi

  # Patch: prepend ~/.context/bin to PATH so the gateway uses the fake op CLI.
  if ! grep -q 'context/bin.*PATH\|fake op CLI' "$HOOK_FILE" && grep -q 'export MCP_TRANSPORT=sse' "$HOOK_FILE"; then
    sed -i 's|  export MCP_TRANSPORT=sse|  # Prepend fake op CLI so the gateway reads/writes OAuth tokens from JSON files\n  # instead of 1Password (unavailable in WSL). See ~/.context/bin/op.\n  export PATH="$HOME/.context/bin:$PATH"\n  export MCP_TRANSPORT=sse|' "$HOOK_FILE"
    CHANGED=true
  fi

  # Patch: redirect gateway stdout/stderr to gateway.log.
  if ! grep -q 'gateway.log.*2>&1' "$HOOK_FILE" && grep -q '"$BIN_DIR/mcp-gateway" &' "$HOOK_FILE"; then
    sed -i 's|"$BIN_DIR/mcp-gateway" &|"$BIN_DIR/mcp-gateway" >> "$GATEWAY_STATE/gateway.log" 2>\&1 \&|' "$HOOK_FILE"
    CHANGED=true
  fi

  # Patch: add port-drain wait before gateway start to fix SIGTERM race.
  if ! grep -q 'Wait for port to drain' "$HOOK_FILE" && grep -q 'export MCP_TRANSPORT=sse' "$HOOK_FILE"; then
    sed -i 's|  export MCP_TRANSPORT=sse|  # Wait for port to drain before binding (SIGTERM is async; prevents bind-fail race)\n  for _i in $(seq 1 20); do is_listening "$PORT" \|\| break; sleep 0.5; done\n  export MCP_TRANSPORT=sse|' "$HOOK_FILE"
    CHANGED=true
  fi

  # Patch: register the long-lived claude ancestor instead of $PPID.
  if ! grep -q 'claude.*ancestor\|_spid.*PPID' "$HOOK_FILE" && grep -q 'touch "$SESSIONS_DIR/$PPID"' "$HOOK_FILE"; then
    python3 - "$HOOK_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()
old = 'touch "$SESSIONS_DIR/$PPID"'
new = (
    '# Walk to the long-lived claude ancestor ($PPID is an ephemeral subprocess)\n'
    '  _spid=$PPID\n'
    '  while [ "$_spid" -gt 1 ] && [ "$(cat /proc/$_spid/comm 2>/dev/null)" != "claude" ]; do\n'
    '    _spid=$(awk \'{print $4}\' /proc/$_spid/stat 2>/dev/null) || break\n'
    '  done\n'
    '  touch "$SESSIONS_DIR/$_spid"'
)
open(path, 'w').write(content.replace(old, new, 1))
PYEOF
    CHANGED=true
  fi

  # Patch: wait for remote backends to finish connecting before signalling ready.
  if ! grep -q '_prev.*_stable' "$HOOK_FILE" && grep -q 'Session start complete' "$HOOK_FILE"; then
    python3 - "$HOOK_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()
old = 'echo "$(_elapsed) Session start complete" >&2'
new = (
    '# Wait for remote backends to finish connecting (token refresh is async).\n'
    '# Watches the log for a stable tool count before allowing Claude to start.\n'
    'if is_listening "$PORT"; then\n'
    '  _prev=0 _stable=0\n'
    '  for _i in $(seq 1 30); do\n'
    '    _cur=$(tail -c 100000 "$GATEWAY_STATE/gateway.log" 2>/dev/null \\\n'
    '      | strings | grep -o \'Tool index built with [0-9]* tools\' \\\n'
    '      | tail -1 | grep -o \'[0-9]*\' | head -1 2>/dev/null || echo 0)\n'
    '    if [ "$_cur" -gt 13 ] && [ "$_cur" = "$_prev" ]; then\n'
    '      _stable=$((_stable + 1))\n'
    '      [ $_stable -ge 3 ] && break\n'
    '    else\n'
    '      _stable=0\n'
    '    fi\n'
    '    _prev=$_cur\n'
    '    sleep 1\n'
    '  done\n'
    'fi\n'
    '\n'
    'echo "$(_elapsed) Session start complete" >&2'
)
open(path, 'w').write(content.replace(old, new, 1))
PYEOF
    CHANGED=true
  fi

  if $CHANGED; then
    echo "Patched session-start hook: $HOOK_FILE"
  fi
done < <(find "$HOME/.claude/plugins/cache/claudes-kitchen/gateway" \
  -name "gateway-session-start.sh" 2>/dev/null)

# ── session-end patches ──────────────────────────────────────────────────────
while IFS= read -r HOOK_FILE; do
  CHANGED=false

  # Patch: use the same claude-ancestor walk for session deregistration.
  if ! grep -q '_spid.*PPID' "$HOOK_FILE" && grep -q 'rm -f "$SESSIONS_DIR/$PPID"' "$HOOK_FILE"; then
    python3 - "$HOOK_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()
old = 'rm -f "$SESSIONS_DIR/$PPID"'
new = (
    '# Walk to the long-lived claude ancestor (mirrors session-start registration)\n'
    '_spid=$PPID\n'
    'while [ "$_spid" -gt 1 ] && [ "$(cat /proc/$_spid/comm 2>/dev/null)" != "claude" ]; do\n'
    '  _spid=$(awk \'{print $4}\' /proc/$_spid/stat 2>/dev/null) || break\n'
    'done\n'
    'rm -f "$SESSIONS_DIR/$_spid"'
)
open(path, 'w').write(content.replace(old, new, 1))
PYEOF
    CHANGED=true
  fi

  if $CHANGED; then
    echo "Patched session-end hook: $HOOK_FILE"
  fi
done < <(find "$HOME/.claude/plugins/cache/claudes-kitchen/gateway" \
  -name "gateway-session-end.sh" 2>/dev/null)
