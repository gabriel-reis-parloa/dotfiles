#!/bin/bash
# Refreshes MCP OAuth tokens expiring within 15 minutes.
# Only runs in parloa context. Pass --force to skip gateway guard.
# Called by: cron (every 20min) and patch-gateway-timeouts.sh (session start).

CONTEXT_DIR="$HOME/.context"
TOKEN_DIR="$HOME/.cache/mcp-gateway/tokens"
GATEWAY_PORT=3100
THRESHOLD_SECONDS=900
FORCE=false

for arg in "$@"; do
  [ "$arg" = "--force" ] && FORCE=true
done

active=$(cat "$CONTEXT_DIR/active" 2>/dev/null)
[ "$active" = "parloa" ] || exit 0

if [ "$FORCE" = false ] && ! ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
  exit 0
fi

python3 - "$TOKEN_DIR" "$THRESHOLD_SECONDS" << 'EOF'
import json, sys, os, datetime, subprocess

token_dir = sys.argv[1]
threshold = int(sys.argv[2])
now = datetime.datetime.now(datetime.timezone.utc)

for fname in os.listdir(token_dir):
    if not fname.endswith('.json'):
        continue
    path = os.path.join(token_dir, fname)
    svc = fname[:-5]
    try:
        d = json.load(open(path))
    except Exception:
        continue
    expires_at = d.get('expires_at')
    refresh_token = d.get('refresh_token')
    if not expires_at or not refresh_token:
        continue
    try:
        if isinstance(expires_at, (int, float)):
            exp = datetime.datetime.fromtimestamp(expires_at, tz=datetime.timezone.utc)
        else:
            exp = datetime.datetime.fromisoformat(expires_at.replace('Z', '+00:00'))
    except Exception:
        continue
    if (exp - now).total_seconds() > threshold:
        continue
    try:
        result = subprocess.run(
            ['curl', '-sf', '--max-time', '15', '-X', 'POST', d['token_url'],
             '-H', 'Content-Type: application/x-www-form-urlencoded',
             '--data-urlencode', f"grant_type=refresh_token",
             '--data-urlencode', f"refresh_token={refresh_token}",
             '--data-urlencode', f"client_id={d.get('client_id', '')}",
             '--data-urlencode', f"client_secret={d.get('client_secret', '')}"],
            capture_output=True, text=True, timeout=20
        )
        if result.returncode != 0:
            print(f'[refresh-mcp-tokens] {svc}: curl failed (exit {result.returncode})', flush=True)
            continue
        t = json.loads(result.stdout)
    except Exception as e:
        print(f'[refresh-mcp-tokens] {svc}: refresh failed: {e}', flush=True)
        continue
    d['access_token'] = t['access_token']
    if 'refresh_token' in t:
        d['refresh_token'] = t['refresh_token']
    new_exp = now + datetime.timedelta(seconds=t.get('expires_in', 3600))
    d['expires_at'] = new_exp.isoformat()
    json.dump(d, open(path, 'w'))
    print(f'[refresh-mcp-tokens] {svc}: refreshed, expires {d["expires_at"]}', flush=True)
EOF
