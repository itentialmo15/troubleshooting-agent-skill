---
name: troubleshoot-adapters
description: Troubleshoot IAP adapters — gather settings, compare against sampleProperties, run debug mode (auth_logging/console_level), capture live logs, and clean up after debugging. Covers OFFLINE, wrong data, and auth failure scenarios.
argument-hint: "[adapter name]"
---

# Troubleshoot Adapters

**Owns:** Full adapter diagnostic cycle — gather (settings collection and misconfiguration analysis), debug mode (live log capture during restart), and cleanup (reverse debug settings).
**Use when:** An adapter is OFFLINE, returning wrong data, failing auth, or when a job error has `IAPerror.source: adapter`.

---

## CRITICAL SAFETY RULES

- **Gather phase: GET only** — no modifications
- **Debug phase and Cleanup: PUT/restart require explicit user consent before each action**
- **Always run Cleanup (Phase 3) after Debug (Phase 2)** — leaving `auth_logging: true` exposes credentials in logs
- **Read `.env` for credentials** — never ask the user for credentials already in `.env`

---

## Auth Reuse

Check `{project_path}/.auth.json`:
- If `platform_url` matches `PLATFORM_URL` in `.env` and `timestamp` < 50 minutes old → reuse token
- Otherwise authenticate from `.env` and save `.auth.json`

**Password auth:**
```bash
curl -sk -X POST "{PLATFORM_URL}/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "{USERNAME}", "password": "{PASSWORD}"}'
```

**OAuth:**
```bash
curl -sk -X POST "{PLATFORM_URL}/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id={CLIENT_ID}&client_secret={CLIENT_SECRET}&grant_type=client_credentials"
```

---

## Phase 1: Gather — Settings Collection & Analysis

### Step 1a — Identify Adapter

If the user hasn't specified an adapter name, list all adapters with health:

```bash
curl -sk "{PLATFORM_URL}/health/adapters?token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('results', []):
    state = a.get('state','?')
    conn  = a.get('connection',{}).get('state','?')
    pkg   = a.get('package_id','?')
    flag  = '🔴' if conn != 'ONLINE' else '✅'
    print(f'{flag} {a[\"id\"]}: {state}/{conn}  ({pkg})')
"
```

### Step 1b — Get Full Adapter Settings

```bash
ADAPTER_NAME="{ADAPTER_NAME}"

curl -sk "{PLATFORM_URL}/adapters/${ADAPTER_NAME}?token={TOKEN}" \
  -o /tmp/${ADAPTER_NAME}_settings.json

# Parse and display key fields
# Settings shape: response.data.properties.properties (double-nested)
python3 -c "
import sys, json
d = json.load(open('/tmp/{ADAPTER_NAME}_settings.json'))
data  = d.get('data', d)
props = data.get('properties',{}).get('properties',{})
auth  = props.get('authentication',{})
hc    = props.get('healthcheck',{})
ssl   = props.get('ssl',{})
log   = props.get('loggerProps',{})

print('=== Adapter Settings: {ADAPTER_NAME} ===')
print('package_id (model):', data.get('model','?'))
print('host:              ', props.get('host'))
print('port:              ', props.get('port'))
print('protocol:          ', props.get('protocol'))
print('base_path:         ', props.get('base_path'))
print('stub:              ', props.get('stub'))
print()
print('--- Auth ---')
print('auth_method:       ', auth.get('auth_method'))
print('token_timeout:     ', auth.get('token_timeout'))
print('auth_field:        ', auth.get('auth_field'))
print('auth_field_format: ', auth.get('auth_field_format'))
print('auth_logging:      ', auth.get('auth_logging'))
print()
print('--- Healthcheck ---')
print('type:              ', hc.get('type'))
print('URI_Path:          ', hc.get('URI_Path'))
print('frequency:         ', hc.get('frequency'))
print()
print('--- SSL ---')
print('ssl.enabled:       ', ssl.get('enabled'))
print('accept_invalid_cert:', ssl.get('accept_invalid_cert'))
print()
print('--- Logging ---')
print('console_level:     ', log.get('console_level'))
print('log_level:         ', log.get('log_level') or log.get('logLevel'))
"
```

### Step 1c — Fetch sampleProperties (Source of Truth)

```bash
# Derive repo name from package_id
REPO_NAME=$(python3 -c "
import json
d = json.load(open('/tmp/{ADAPTER_NAME}_settings.json'))
model = d.get('data',{}).get('model','')
print(model.split('/')[-1])
")

echo "Fetching sampleProperties for: ${REPO_NAME}"
curl -s "https://gitlab.com/itentialopensource/adapters/${REPO_NAME}/-/raw/master/sampleProperties.json" \
  -o /tmp/{ADAPTER_NAME}_sample.json 2>/dev/null

# Verify we got valid JSON (not a GitLab redirect page)
head -c 100 /tmp/{ADAPTER_NAME}_sample.json
python3 -c "
import json
try:
    json.load(open('/tmp/{ADAPTER_NAME}_sample.json'))
    print('sampleProperties: ✅ fetched')
except:
    print('sampleProperties: ⚠️ not available (private adapter or network issue)')
" 2>/dev/null
```

### Step 1d — Compare Live Settings vs sampleProperties

```bash
python3 -c "
import json

live = json.load(open('/tmp/{ADAPTER_NAME}_settings.json'))
live_p = live.get('data',{}).get('properties',{}).get('properties',{})
live_auth = live_p.get('authentication',{})

try:
    sample = json.load(open('/tmp/{ADAPTER_NAME}_sample.json'))
    sample_p = sample.get('properties',{})
    sample_auth = sample_p.get('authentication',{})
except:
    print('sampleProperties not available — manual review only')
    sample_p = {}
    sample_auth = {}

print('=== Critical Checks ===')

# Stub mode
stub = live_p.get('stub')
if stub:
    print('🔴 CRITICAL: stub=true — no real API calls are made')
else:
    print('✅ stub: false')

# Auth method
live_am = live_auth.get('auth_method')
samp_am = sample_auth.get('auth_method')
if samp_am and live_am != samp_am:
    print(f'🔴 MISMATCH auth_method: live={live_am}  expected={samp_am}')
else:
    print(f'✅ auth_method: {live_am}')

# Host
host = live_p.get('host','')
if not host or host in ('localhost','127.0.0.1',''):
    print(f'⚠️  host={repr(host)} — may not be pointed at target system')
else:
    print(f'✅ host: {host}')

# Protocol/SSL match
proto = live_p.get('protocol','')
ssl_en = live_p.get('ssl',{}).get('enabled', False)
if proto == 'https' and not ssl_en:
    print('🔴 MISMATCH: protocol=https but ssl.enabled=false — TLS errors will occur')
elif proto == 'http' and ssl_en:
    print('⚠️  protocol=http but ssl.enabled=true — verify intent')
else:
    print(f'✅ protocol={proto} ssl.enabled={ssl_en}')

# Base path
live_bp = live_p.get('base_path','')
samp_bp = sample_p.get('base_path','')
if samp_bp and live_bp != samp_bp:
    print(f'⚠️  base_path: live={repr(live_bp)}  expected={repr(samp_bp)}')

# Auth field/format
for f in ('auth_field','auth_field_format'):
    lv = live_auth.get(f)
    sv = sample_auth.get(f)
    if sv and lv != sv:
        print(f'⚠️  MISMATCH {f}: live={repr(lv)}  expected={repr(sv)}')

# Token timeout
tt = live_auth.get('token_timeout')
if str(tt) == '-1':
    print('⚠️  token_timeout=-1: No auto token refresh — adapter requires restart to re-authenticate after token expiry')
elif tt and int(tt) > 0:
    print(f'✅ token_timeout={tt}ms ({int(tt)//60000} min refresh)')

print()
print('=== AWS-Specific Checks ===')
# AWS temporary credentials
for k in ('aws_access_key','accessKeyId','access_key_id'):
    v = live_p.get(k) or live_auth.get(k,'')
    if v and v.startswith('ASIA'):
        print(f'⚠️  {k} starts with ASIA = STS temporary credentials (expire in 1-12h). Use long-lived IAM key (AKIA) or automate rotation.')
" 2>/dev/null
```

### Step 1e — Save Gather Report

Save to `{project_path}/data/{TIMESTAMP}/{ADAPTER_NAME}/gather_report.md`:

```markdown
# Adapter Gather Report: {ADAPTER_NAME}
**Generated:** {YYYY-MM-DD HH:MM:SS UTC} | **Platform:** {PLATFORM_URL}
**Status:** {STATE} / {CONNECTION} | **Package:** {package_id}

## Issues Found
- 🔴 **Critical**: {issue} — {why it matters}
- 🟡 **Warning**: {issue} — {why it matters}
- 🟢 **Info**: {note}

## Mismatched Settings
| Setting | Current | Expected | Impact |
|---------|---------|----------|--------|

## Recommendations
1. {Highest-impact fix first}
2. {If connectivity issue persists → proceed to Phase 2 Debug Mode (with user consent)}
```

If the gather report shows a clear misconfiguration (stub=true, wrong host, wrong auth_method), **present findings and ask the user if they want to fix it** before proceeding to debug mode.

---

## Phase 2: Debug Mode — Live Log Capture

**Only run this phase after Phase 1 gather if root cause is still unclear.**

Run steps in this exact order:
1. Start log watcher (Step 2a) FIRST
2. Enable debug settings (Step 2b) — requires user consent
3. Restart adapter (Step 2c) — requires user consent
4. Analyze captured logs (Step 2d)
5. Always run Phase 3 (Cleanup) when done

### Step 2a — Start Live Log Watcher (Before Restart)

**Docker:**
```bash
mkdir -p {project_path}/data/{TIMESTAMP}/{ADAPTER_NAME}/

docker logs -f platform 2>&1 \
  | grep -i "{ADAPTER_NAME}\|auth\|token\|health\|error\|ECONNREFUSED\|EHOSTUNREACH" \
  | tee {project_path}/data/{TIMESTAMP}/{ADAPTER_NAME}/live_logs.txt &

echo "Log watcher PID: $!"
echo "Now proceed to Step 2b to enable debug settings."
```

**Kubernetes** (if `KUBE_NAMESPACE` in `.env`):
```bash
mkdir -p {project_path}/data/{TIMESTAMP}/{ADAPTER_NAME}/

timeout 300 stern -n {KUBE_NAMESPACE} {KUBE_POD_PATTERN} --since 1s 2>&1 \
  | tee {project_path}/data/{TIMESTAMP}/{ADAPTER_NAME}/live_logs.txt \
  | head -1000 &

echo "Stern log watcher PID: $!"
```

### Step 2b — Enable Debug Logging (User Consent Required)

> **Confirm with user before running: "I will enable auth_logging=true and console_level=debug on {ADAPTER_NAME} and restart it. This will log credential details. Proceed?"**

**CRITICAL: PUT does NOT support partial updates — always GET → modify → PUT full body.**

```bash
# 1. Re-fetch current settings
curl -sk "{PLATFORM_URL}/adapters/{ADAPTER_NAME}?token={TOKEN}" \
  -o /tmp/{ADAPTER_NAME}_settings.json

# 2. Build PUT body — enable debug settings
# Body must be wrapped in {"properties":{...}} stripping the metadata prefix
cat /tmp/{ADAPTER_NAME}_settings.json \
  | sed 's/{"metadata".*"type":"Adapter",/{"properties":{/' \
  | sed 's/"auth_logging":false/"auth_logging":true/' \
  | sed 's/"console_level":"error"/"console_level":"debug"/' \
  | sed 's/"console_level":"warn"/"console_level":"debug"/' \
  | sed 's/"console_level":"info"/"console_level":"debug"/' \
  > /tmp/{ADAPTER_NAME}_debug_body.json

# 3. Verify body before sending
grep -o '"auth_logging":true' /tmp/{ADAPTER_NAME}_debug_body.json && echo "auth_logging ✅"
grep -o '"console_level":"debug"' /tmp/{ADAPTER_NAME}_debug_body.json && echo "console_level ✅"
head -c 60 /tmp/{ADAPTER_NAME}_debug_body.json  # must start with {"properties":

# 4. PUT the modified settings
curl -sk -X PUT "{PLATFORM_URL}/adapters/{ADAPTER_NAME}?token={TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/{ADAPTER_NAME}_debug_body.json | head -c 200
```

**Log level guide:**
| Level | Use When |
|-------|----------|
| `trace` | Maximum detail — every internal step, full request/response bodies |
| `debug` | Detailed — auth flows, API calls, responses **(default choice)** |
| `info` | Normal operation — insufficient for debugging |

### Step 2c — Restart Adapter (User Consent Required)

> **Confirm with user: "I will restart the {ADAPTER_NAME} adapter. It will be briefly unavailable. Proceed?"**

```bash
curl -sk -X PUT "{PLATFORM_URL}/adapters/{ADAPTER_NAME}/restart?token={TOKEN}"

echo "Adapter restarting. Waiting 15 seconds..."
sleep 15

# Quick health check post-restart
curl -sk "{PLATFORM_URL}/health/adapters?token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('results',[]):
    if '{ADAPTER_NAME}' in a.get('id',''):
        state = a['state']
        conn = a.get('connection',{}).get('state','?')
        flag = '✅' if conn == 'ONLINE' else '⚠️ still OFFLINE'
        print(f'{a[\"id\"]}: {state}/{conn} {flag}')
"
```

### Step 2d — Analyze Captured Logs

```bash
# All captured logs
cat {project_path}/data/{TIMESTAMP}/{ADAPTER_NAME}/live_logs.txt | head -300

# Auth-specific patterns
grep -i "auth\|token\|credential\|401\|403\|password\|login" \
  {project_path}/data/{TIMESTAMP}/{ADAPTER_NAME}/live_logs.txt | head -100

# Connectivity errors
grep -i "ECONNREFUSED\|ETIMEDOUT\|ENOTFOUND\|EHOSTUNREACH\|certificate\|ssl\|tls" \
  {project_path}/data/{TIMESTAMP}/{ADAPTER_NAME}/live_logs.txt | head -100

# General errors
grep -i "error\|Error\|ERROR" \
  {project_path}/data/{TIMESTAMP}/{ADAPTER_NAME}/live_logs.txt | head -100
```

**Key log patterns:**

| Pattern | Root Cause |
|---------|-----------|
| `401` / `Unauthorized` | Wrong credentials or expired token |
| `403` / `Forbidden` | Credentials valid but insufficient permissions |
| `ECONNREFUSED` | Target host/port not reachable (host up, port closed) |
| `EHOSTUNREACH` / `ETIMEDOUT` | No routing to host — container/VM not running or wrong IP |
| `ENOTFOUND` | DNS resolution failure — wrong hostname |
| `certificate` / `ssl` / `tls` | TLS misconfiguration |
| `stub` in log | Adapter still in stub mode |
| `getToken: success` + still OFFLINE | Auth works but healthcheck URI wrong or returning non-200 |
| `token expired` / `jwt expired` | Token refresh issue — check `token_timeout` |

Save analysis to: `{project_path}/data/{TIMESTAMP}/{ADAPTER_NAME}/log_analysis.md`

---

## Phase 3: Cleanup — Reset After Debugging

**Always run this after Phase 2.** Leaving `auth_logging: true` and debug log levels in production:
- Exposes credentials in log files (security risk)
- Generates high log volume (disk pressure)
- May trigger security alerts

> **Confirm with user: "I will reset auth_logging=false and console_level=error on {ADAPTER_NAME} and restart it. Proceed?"**

### Step 3a — Reset Adapter Settings

```bash
# 1. Get current settings (may have been modified in Phase 2)
curl -sk "{PLATFORM_URL}/adapters/{ADAPTER_NAME}?token={TOKEN}" \
  -o /tmp/{ADAPTER_NAME}_settings.json

# 2. Build PUT body — reverse debug changes
cat /tmp/{ADAPTER_NAME}_settings.json \
  | sed 's/{"metadata".*"type":"Adapter",/{"properties":{/' \
  | sed 's/"auth_logging":true/"auth_logging":false/' \
  | sed 's/"console_level":"debug"/"console_level":"error"/' \
  | sed 's/"console_level":"trace"/"console_level":"error"/' \
  > /tmp/{ADAPTER_NAME}_cleanup_body.json

# 3. Verify
grep -o '"auth_logging":false' /tmp/{ADAPTER_NAME}_cleanup_body.json && echo "auth_logging ✅"
grep -o '"console_level":"error"' /tmp/{ADAPTER_NAME}_cleanup_body.json && echo "console_level ✅"

# 4. PUT back (requires user consent)
curl -sk -X PUT "{PLATFORM_URL}/adapters/{ADAPTER_NAME}?token={TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/{ADAPTER_NAME}_cleanup_body.json | head -c 200
```

### Step 3b — Restart and Verify

```bash
curl -sk -X PUT "{PLATFORM_URL}/adapters/{ADAPTER_NAME}/restart?token={TOKEN}"
sleep 15

curl -sk "{PLATFORM_URL}/health/adapters?token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('results',[]):
    if '{ADAPTER_NAME}' in a.get('id',''):
        conn = a.get('connection',{}).get('state','?')
        flag = '✅ ONLINE' if conn == 'ONLINE' else '⚠️ still OFFLINE — root cause persists'
        print(f\"{a['id']}: {a['state']}/{conn} {flag}\")
"
```

**Cleanup verification:**
| Check | Expected |
|-------|---------|
| `auth_logging` | `false` |
| `console_level` | `error` |
| Adapter state | `RUNNING` |
| Connection state | `ONLINE` (if root cause resolved) |

If adapter is still OFFLINE after cleanup: the underlying issue (wrong host, bad credentials, target unreachable) persists. Return to gather findings and investigate the target system directly.

---

## Common Adapter Failure Patterns — Quick Reference

| Symptom | Root Cause | Step |
|---------|-----------|------|
| `RUNNING/OFFLINE` at startup | Network, wrong host/port, or auth failure | Phase 1 gather |
| `stub: true` | No real API calls — silent fake mode | Step 1d — set stub=false |
| `auth_method` mismatch | Wrong auth type fails every call | Step 1d |
| `EHOSTUNREACH` | Container/VM not running at configured IP | Check host/port config |
| `ECONNREFUSED` | Service running but wrong port or not bound | Check port config |
| `401` in debug logs | Wrong credentials | Check username/password/token fields |
| `403` in debug logs | Credentials valid, insufficient permissions | Check IAP user roles on target system |
| `certificate` error | TLS mismatch | Set `accept_invalid_cert: true` or fix cert |
| `token_timeout: -1` | No auto-refresh; goes OFFLINE after session expires | Update `token_timeout` to positive ms value |
| AWS `ASIA` key prefix | Temporary STS creds (expire 1-12h) | Use long-lived IAM key (`AKIA`) |
| `getToken: success` but OFFLINE | Healthcheck URI wrong | Correct `healthcheck.URI_Path` |
