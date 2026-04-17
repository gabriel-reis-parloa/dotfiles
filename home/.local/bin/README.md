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

## Google Workspace Access

The gateway holds a valid OAuth token for Google Workspace. Use it directly with Google REST APIs — no separate login needed.

**Token location:** `~/.cache/mcp-gateway/tokens/google_workspace.json`

**Claude: if you get a 401 or token expiry error on Google Workspace tools**, refresh the token automatically using the refresh_token in the file — do NOT ask Gabriel to run claude-status or re-auth manually:
```python
import json, subprocess, urllib.parse, time
from datetime import datetime, timezone, timedelta
d = json.load(open('/home/gabriel/.cache/mcp-gateway/tokens/google_workspace.json'))
result = subprocess.run(['curl', '-s', '-X', 'POST', d['token_url'],
    '-H', 'Content-Type: application/x-www-form-urlencoded',
    '-d', urllib.parse.urlencode({'grant_type':'refresh_token','refresh_token':d['refresh_token'],
        'client_id':d['client_id'],'client_secret':d['client_secret']})
], capture_output=True, text=True)
resp = json.loads(result.stdout)
d['access_token'] = resp['access_token']
d['expires_at'] = (datetime.now(timezone.utc) + timedelta(seconds=resp.get('expires_in',3600))).isoformat()
json.dump(d, open('/home/gabriel/.cache/mcp-gateway/tokens/google_workspace.json','w'), indent=2)
# Then restart gateway:
# kill -9 $(pgrep -f "mcp-gateway/target/release/mcp-gateway") && sleep 2 && nohup bash ~/.claude/plugins/cache/claudes-kitchen/gateway/17218ff20959/hooks/gateway-session-start.sh > /tmp/gateway-restart.log 2>&1 &
```

```bash
TOKEN=$(python3 -c "import json; print(json.load(open('/home/gabriel/.cache/mcp-gateway/tokens/google_workspace.json'))['access_token'])")
```

**Read a Google Doc:**
```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://docs.googleapis.com/v1/documents/DOCUMENT_ID" | python3 -c "
import sys, json
d = json.load(sys.stdin)
text = []
for elem in d.get('body', {}).get('content', []):
    for e in elem.get('paragraph', {}).get('elements', []):
        t = e.get('textRun', {}).get('content', '')
        if t.strip(): text.append(t)
print(''.join(text))
"
```

**Read a Google Sheet:**
```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://sheets.googleapis.com/v4/spreadsheets/SPREADSHEET_ID/values/RANGE"
```

**List Drive files:**
```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://www.googleapis.com/drive/v3/files?pageSize=20&fields=files(id,name,mimeType)"
```

**`gws` CLI (alternative):** install once with `npm install -g @googleworkspace/cli`, then use gateway token:
```bash
GOOGLE_WORKSPACE_CLI_TOKEN="$TOKEN" gws docs documents get --params '{"documentId": "ID"}'
```
Note: `gws auth login` won't work in WSL (browser auth flow). Always use the gateway token instead.

**Token expiry:** check `expires_at` in the token file. If expired, the gateway will auto-refresh on next use — restart the gateway (`claude-status`) and re-read the token.

**If Google Workspace tools stop working after an hour (gateway connects with 303 tools but tool calls return auth errors):** the gateway uses `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` env vars for token refresh and re-auth. In WSL, `op` can't resolve these from 1Password. The `patch-gateway-timeouts.sh` hook hardcodes these as a WSL fallback (credentials stored separately, not in the repo). If the GCP OAuth client is ever rotated, update the values directly in the live hook at `~/.claude/plugins/marketplaces/claudes-kitchen/plugins/gateway/hooks/gateway-session-start.sh`.

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

**Notion MCP re-auth failure:**

Root cause: the March 1 gateway binary has a bug — it hits `GET https://mcp.notion.com/register/{client_id}` after OAuth discovery. Notion returns 404; the gateway treats it as fatal. Symptom in `gateway.log`:
```
HTTP 404: Invalid OAuth error response: SyntaxError: JSON Parse error: Unexpected EOF. Raw body:
```
The permanent fix is in source commit `87edbde660a8`+ (already in kitchen cache), but rebuilding requires the Parloa cargo registry (`parloa.jfrog.io`). Kitchen update `2c24c3b93872` also has the fix but same registry requirement.

**How Notion MCP OAuth works (as of 2026-03-20):**
1. Gateway registers a dynamic client at `https://mcp.notion.com/register` → gets a short-lived `client_id`
2. Gateway redirects to `https://mcp.notion.com/authorize?client_id=...` (NOT `api.notion.com` directly)
3. Notion's server redirects to `api.notion.com/v1/oauth/authorize` using their own internal client (`1f8d872b-...`)
4. User authorizes in Notion
5. Notion's server processes the callback and redirects to `localhost:9881/callback` with a gateway-level code
6. Gateway exchanges that code for tokens

**Why the old `JpV86vmWrDK1UQPA` client_id no longer works:** it was a stale dynamically registered client. Dynamic client_ids expire/get invalidated. Using them directly on `api.notion.com` fails with "Missing or incomplete Client ID". Always register a fresh client first.

**Manual PKCE re-auth (verified working 2026-03-24):**
```bash
# Step 1: register a fresh dynamic client
CLIENT_ID=$(curl -s -X POST https://mcp.notion.com/register \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris":["http://localhost:9881/callback"],"client_name":"claude-mcp-gateway","token_endpoint_auth_method":"none"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['client_id'])")
echo "client_id: $CLIENT_ID"
```
```bash
# Step 2: generate PKCE + build auth URL (saves verifier to /tmp for later)
python3 - "$CLIENT_ID" <<'EOF'
import sys, secrets, hashlib, base64, urllib.parse
client_id = sys.argv[1]
verifier = secrets.token_urlsafe(64)
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
state = secrets.token_urlsafe(16)
with open('/tmp/notion_pkce.txt', 'w') as f:
    f.write(f"client_id={client_id}\nverifier={verifier}\nstate={state}\n")
params = urllib.parse.urlencode({"client_id":client_id,"response_type":"code","redirect_uri":"http://localhost:9881/callback","code_challenge":challenge,"code_challenge_method":"S256","state":state})
print(f"URL: https://mcp.notion.com/authorize?{params}")
EOF
```
```bash
# Step 3: open URL in Windows browser; Notion redirects to localhost:9881/callback?code=...&state=...
# The page will fail to load — copy the full URL from the address bar, then exchange:
python3 - 'CALLBACK_URL' <<'EOF'
import sys, urllib.parse, json, subprocess
callback_url = sys.argv[1]
params = urllib.parse.parse_qs(urllib.parse.urlparse(callback_url).query)
code = params['code'][0]
pkce = dict(line.split('=',1) for line in open('/tmp/notion_pkce.txt').read().strip().splitlines())
result = subprocess.run(['curl', '-s', '-X', 'POST', 'https://mcp.notion.com/token',
    '-H', 'Content-Type: application/x-www-form-urlencoded',
    '-d', urllib.parse.urlencode({'grant_type':'authorization_code','code':code,
        'redirect_uri':'http://localhost:9881/callback','client_id':pkce['client_id'],
        'code_verifier':pkce['verifier']})
], capture_output=True, text=True)
data = json.loads(result.stdout)
print(json.dumps(data, indent=2))
EOF
```
```bash
# Step 4: write tokens to file (full format required — gateway rejects minimal format)
python3 <<'EOF'
import json
from datetime import datetime, timezone, timedelta
pkce = dict(line.split('=',1) for line in open('/tmp/notion_pkce.txt').read().strip().splitlines())
# Replace access_token and refresh_token with values from step 3 output
token_data = {
    "access_token":  "ACCESS_TOKEN",
    "refresh_token": "REFRESH_TOKEN",
    "client_id":     pkce['client_id'],
    "client_secret": None,
    "auth_url":      "https://mcp.notion.com/authorize",
    "token_url":     "https://mcp.notion.com/token",
    "scopes":        [],
    "expires_at":    (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
}
json.dump(token_data, open('/home/gabriel/.cache/mcp-gateway/tokens/notion.json','w'), indent=2)
print("Written.")
EOF
```
```bash
# Step 5: restart gateway
kill -9 $(pgrep -f "mcp-gateway/target/release/mcp-gateway") 2>/dev/null
sleep 2
nohup bash ~/.claude/plugins/cache/claudes-kitchen/gateway/17218ff20959/hooks/gateway-session-start.sh > /tmp/gateway-restart.log 2>&1 &
sleep 20 && cat /tmp/gateway-restart.log
# Verify: strings ~/.cache/mcp-gateway/gateway.log | grep -i notion | tail -5
```

**Note on WSL→Windows callback:** The redirect goes to `localhost:988x` in the Windows browser, which maps to WSL localhost. The page fails to load — that's expected. Copy the full URL from the address bar and run the token exchange from WSL.

**Stale Sidecar terminal session:** After gateway restarts, terminal (Sidecar) Claude sessions do NOT auto-reconnect. Only VS Code extension sessions reconnect automatically. If MCP tools return 404 in a terminal session, restart the terminal session.

---

**Jira MCP re-auth failure (same root cause as Notion):**

Symptom: `HTTP 404: Invalid OAuth error response: SyntaxError: JSON Parse error: Unexpected EOF` on any Jira tool call, even when `kitchen-gateway-status` shows token OK. The dynamic `client_id` in `jira.json` has been invalidated by Atlassian.

Jira uses port `9879` for the callback (not 9881). Tokens last ~8 hours. Re-auth flow (verified working 2026-03-24):

```bash
# Step 1: register fresh client
CLIENT_ID=$(curl -s -X POST https://mcp.atlassian.com/v1/register \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris":["http://localhost:9879/callback"],"client_name":"claude-mcp-gateway","token_endpoint_auth_method":"none"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['client_id'])")
echo "client_id: $CLIENT_ID"
```
```bash
# Step 2: generate PKCE + build auth URL
python3 - "$CLIENT_ID" <<'EOF'
import sys, secrets, hashlib, base64, urllib.parse
client_id = sys.argv[1]
verifier = secrets.token_urlsafe(64)
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
state = secrets.token_urlsafe(16)
with open('/tmp/jira_pkce.txt', 'w') as f:
    f.write(f"client_id={client_id}\nverifier={verifier}\nstate={state}\n")
params = urllib.parse.urlencode({"client_id":client_id,"response_type":"code","redirect_uri":"http://localhost:9879/callback","code_challenge":challenge,"code_challenge_method":"S256","state":state})
print(f"URL: https://mcp.atlassian.com/v1/authorize?{params}")
EOF
```
```bash
# Step 3: open URL in Windows browser; copy callback URL from address bar, then:
python3 - 'CALLBACK_URL' <<'EOF'
import sys, urllib.parse, json, subprocess, time
callback_url = sys.argv[1]
params = urllib.parse.parse_qs(urllib.parse.urlparse(callback_url).query)
code = params['code'][0]
pkce = dict(line.split('=',1) for line in open('/tmp/jira_pkce.txt').read().strip().splitlines())
result = subprocess.run(['curl', '-s', '-X', 'POST', 'https://cf.mcp.atlassian.com/v1/token',
    '-H', 'Content-Type: application/x-www-form-urlencoded',
    '-d', urllib.parse.urlencode({'grant_type':'authorization_code','code':code,
        'redirect_uri':'http://localhost:9879/callback','client_id':pkce['client_id'],
        'code_verifier':pkce['verifier']})
], capture_output=True, text=True)
data = json.loads(result.stdout)
token_data = {"access_token":data['access_token'],"refresh_token":data.get('refresh_token',''),
    "client_id":pkce['client_id'],"client_secret":None,
    "auth_url":"https://mcp.atlassian.com/v1/authorize",
    "token_url":"https://cf.mcp.atlassian.com/v1/token",
    "scopes":[],"expires_at":int(time.time())+data.get('expires_in',3600)}
json.dump(token_data, open('/home/gabriel/.cache/mcp-gateway/tokens/jira.json','w'), indent=2)
print("Written. expires_in:", data.get('expires_in'), "seconds (~", data.get('expires_in',0)//3600, "hours)")
EOF
```
```bash
# Step 4: restart gateway (same as Notion)
kill -9 $(pgrep -f "mcp-gateway/target/release/mcp-gateway") 2>/dev/null
sleep 2
nohup bash ~/.claude/plugins/cache/claudes-kitchen/gateway/17218ff20959/hooks/gateway-session-start.sh > /tmp/gateway-restart.log 2>&1 &
sleep 20 && strings ~/.cache/mcp-gateway/gateway.log | grep -i jira | tail -5
```
