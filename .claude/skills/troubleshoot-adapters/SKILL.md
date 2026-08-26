---
name: troubleshoot-adapters
description: Troubleshoot IAP adapters — gather settings, compare against sampleProperties, run debug mode (auth_logging/console_level), capture live logs, clean up after debugging, and inspect OSS adapter source from GitLab for error code mapping, auth pattern analysis, and reproduction step construction. Covers OFFLINE, wrong data, auth failure, Kafka consumer lag, and GitLab source inspection scenarios.
argument-hint: "[adapter name]"
---

# Troubleshoot Adapters

**Owns:** Full adapter diagnostic cycle — gather (settings collection and misconfiguration analysis), debug mode (live log capture during restart), and cleanup (reverse debug settings). Also owns Kafka adapter diagnostics: broker connectivity, consumer group lag, and topic partition analysis.
**Use when:** An adapter is OFFLINE, returning wrong data, failing auth, a job error has `IAPerror.source: adapter`, or a Kafka adapter is OFFLINE / consumer lag is growing.

---

## CRITICAL SAFETY RULES

- **Gather phase: GET only** — no modifications
- **Debug phase and Cleanup: PUT/restart require explicit user consent before each action**
- **Always run Cleanup (Phase 3) after Debug (Phase 2)** — leaving `auth_logging: true` exposes credentials in logs
- **Read `.env` for credentials** — never ask the user for credentials already in `.env`
- **builder-skill invocations also use `.env`** — when invoking builder-skills for fixes or workarounds (after Phase 1 or Phase 2 confirms root cause), source `.env` before invoking so the skill targets the correct platform with the correct credentials

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

**Cloud customer check (read ticket_context.md first):** If `cloud_customer_flag: true` is set in `ticket_context.md`, the customer is on `itential-saas` — Itential-managed cloud IAP with on-premises IAG. Apply these constraints for every step in this skill:

| Scenario | Cloud customer (itential-saas) note |
|---|---|
| Adapter OFFLINE | **First check: Itential NAT IP whitelisting.** Itential NATs all adapter/integration traffic. The target system must whitelist Itential's NAT IP, not the customer's on-prem IP. Confirm current NAT IP with cloud ops before any settings changes. |
| SSH to IAP nodes | Not available — IAP is Itential-managed. Cannot run `docker logs`, `pm2 logs`, or host-level commands on IAP nodes. Request logs from Itential cloud ops. |
| SSH to IAG | Available — IAG runs on customer on-prem. SSH targets in `.env` for cloud customers are IAG hosts. |
| Adapter settings API | Available — use platform API via `*.itential.io` URL as normal. |
| sampleProperties fetch | Available — use `npm show {package_id} dist-tags.latest` + package registry as normal. |

If the adapter was ONLINE and went OFFLINE without a customer-side change → lead with NAT IP rotation as the hypothesis before investigating credentials or host/port settings.

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

> **GitLab deeper inspection available:** If `sampleProperties` is unavailable, incomplete, or the gather report leaves root cause unclear after Step 1d, run **Phase 5 (GitLab Source Inspection)** to fetch and analyze `error.json`, `package.json`, and the adapter source directly from `https://gitlab.com/itentialopensource/adapters/{REPO_NAME}`. Phase 5 produces derived findings only — no code is saved or shared.

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

**Fix path — apply corrective settings (with engineer approval):**

When root cause is identified from Phase 1 gather and the engineer approves the fix:

```bash
# Use the already-fetched settings as the base (avoid a redundant GET)
# Only modify the identified misconfigured fields — never touch other fields
python3 << 'EOF'
import json

with open('/tmp/{ADAPTER_NAME}_settings.json') as f:
    settings = json.load(f)

# Apply targeted fixes — only the fields identified in the gather report:
# Examples (uncomment the applicable one(s)):
# settings['stub'] = False                    # stub=true disabling
# settings['token_timeout'] = 3600000         # -1 means never refresh
# settings['ssl'] = {**settings.get('ssl',{}), 'enabled': True}
# settings['host'] = '{CORRECT_HOST}'
# settings['port'] = {CORRECT_PORT}

with open('/tmp/{ADAPTER_NAME}_fixed.json', 'w') as f:
    json.dump(settings, f)
print("Fixed settings written — confirm fields before PUT:")
for k in ['stub', 'host', 'port', 'ssl', 'auth_method', 'token_timeout']:
    if k in settings:
        print(f"  {k}: {settings[k]}")
EOF

# PUT the corrected settings (full replacement — confirm with engineer first)
curl -sk -X PUT "{PLATFORM_URL}/adapters/{ADAPTER_NAME}?token={TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/{ADAPTER_NAME}_fixed.json \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
status = d.get('status', d.get('data', {}).get('status', '?'))
print('Adapter status after PUT:', status)
"

# Restart adapter (requires explicit consent — prompt before running)
curl -sk -X PUT "{PLATFORM_URL}/adapter-manager/adapters/{ADAPTER_NAME}/restart?token={TOKEN}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Restart:', d.get('message','?'))"

# Verify ONLINE after restart (poll up to 30s)
for i in $(seq 1 6); do
  STATUS=$(curl -sk "{PLATFORM_URL}/adapter-manager/adapters/{ADAPTER_NAME}?token={TOKEN}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','?'))")
  echo "[$i] Adapter status: $STATUS"
  [ "$STATUS" = "ONLINE" ] && break || sleep 5
done
```

> **Safe fields to fix without extra caution:** `stub`, `token_timeout`, `ssl.enabled`, `protocol`, `base_path`
>
> **Fields requiring extra confirmation:** `host`, `port`, `auth_method`, `credentials`, `ssl.ca` — pause and confirm each before applying

**Docs reference (if not already in triage docs_references.md):**

If the adapter is an OSS adapter (`adapter-*` package other than IAG) and `docs_references.md` does not yet have an Adapters section, run a targeted lookup now:

```
WebSearch("{adapter package name} configuration site:docs.itential.com/adapters")
WebSearch("{adapter package name} authentication site:docs.itential.com/adapters")
```

For `adapter-nso` or Cisco NSO–related adapters, also check:
```
WebSearch("{symptom or config key} site:docs.itential.com/cisco-nso")
```

Append any new findings to `{project_path}/data/{TIMESTAMP}/{TICKET_KEY}/docs_references.md` under the appropriate section. Use the live documentation to validate expected authentication configuration, required properties, and known adapter-specific behaviors before comparing settings in Step 1d.

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

**Fix path — apply confirmed root cause fix before cleanup (with engineer approval):**

When log analysis confirms a specific root cause, offer to apply the fix immediately — before Phase 3 cleanup — so the adapter comes back ONLINE in the same session:

```bash
# Determine fix by log pattern:

# ── 401 / token expired ──────────────────────────────────────────────────────
# Update credentials or fix token_timeout: GET → modify → PUT
curl -sk "{PLATFORM_URL}/adapters/{ADAPTER_NAME}?token={TOKEN}" \
  | python3 -c "
import sys, json
s = json.load(sys.stdin)
# Fix: update auth credentials or set token_timeout to 3600000
s['token_timeout'] = 3600000   # or update s['credentials'] fields
print(json.dumps(s))
" | curl -sk -X PUT "{PLATFORM_URL}/adapters/{ADAPTER_NAME}?token={TOKEN}" \
  -H "Content-Type: application/json" -d @-

# ── ECONNREFUSED / EHOSTUNREACH ───────────────────────────────────────────────
# Verify host/port, update if wrong
curl -sk "{PLATFORM_URL}/adapters/{ADAPTER_NAME}?token={TOKEN}" \
  | python3 -c "
import sys, json
s = json.load(sys.stdin)
s['host'] = '{CORRECT_HOST}'
s['port'] = {CORRECT_PORT}
print(json.dumps(s))
" | curl -sk -X PUT "{PLATFORM_URL}/adapters/{ADAPTER_NAME}?token={TOKEN}" \
  -H "Content-Type: application/json" -d @-

# After fix PUT: restart adapter (with consent) and verify ONLINE
curl -sk -X PUT "{PLATFORM_URL}/adapter-manager/adapters/{ADAPTER_NAME}/restart?token={TOKEN}"
sleep 10
curl -sk "{PLATFORM_URL}/adapter-manager/adapters/{ADAPTER_NAME}?token={TOKEN}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Status:', d.get('status','?'))"
```

> Apply only the single field confirmed by the log. Then proceed to **Phase 3 Cleanup** as normal — it will reset `auth_logging` and `console_level` regardless of whether a fix was applied here.

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

## Phase 4: Kafka Adapter Diagnostics

Run this phase when the IAP Kafka adapter is OFFLINE or consumer lag is growing. Kafka adapters do not follow the settings GET → PUT debug cycle (they have no `auth_logging` or `console_level` in sampleProperties), so this phase replaces Phase 1–3 for Kafka.

**Prerequisites:** `KAFKA_BOOTSTRAP`, `KAFKA_CONSUMER_GROUP`, and `KAFKA_TOPIC` must be set in `.env` (or confirm values with the engineer if absent).

---

### Step 4a — Identify Kafka Adapter State in IAP

```bash
# Check Kafka adapter health
curl -sk "{PLATFORM_URL}/health/adapters?token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d if isinstance(d, list) else d.get('results', [])
found = False
for a in results:
    if 'kafka' in a.get('package_id','').lower() or 'kafka' in a.get('id','').lower():
        conn = a.get('connection', {}).get('state', '?')
        flag = '🔴' if conn != 'ONLINE' else '✅'
        print(f\"{flag} {a['id']}: {a['state']}/{conn}  ({a.get('package_id','?')})\")
        found = True
if not found:
    print('No Kafka adapters found in /health/adapters response')
"
```

Look for: `RUNNING/OFFLINE` (adapter process up but broker unreachable) vs `STOPPED` (adapter process not running — check IAP logs).

---

### Step 4b — Broker Connectivity

```bash
# TCP reachability to each broker in the bootstrap list
# KAFKA_BOOTSTRAP may be comma-separated: broker1:9092,broker2:9092
for broker in $(echo "${KAFKA_BOOTSTRAP}" | tr ',' '\n'); do
  host="${broker%%:*}"
  port="${broker##*:}"
  result=$(echo | timeout 5 nc -zv "${host}" "${port}" 2>&1)
  echo "${broker}: ${result}"
done
```

**What to look for:**
- `Connection refused` → Kafka broker not running at that address
- `No route to host` → network path missing (firewall, VPC, security group)
- `Connection timed out` → port blocked upstream

If broker is unreachable, the adapter will stay OFFLINE regardless of settings. Escalate to customer infra team.

---

### Step 4c — Consumer Group Lag

```bash
# Check consumer group lag — run from the Kafka host (SSH) or via docker exec
# SSH deployment
ssh "${KAFKA_SSH_USER}@${KAFKA_SSH_HOST}" \
  "kafka-consumer-groups.sh --bootstrap-server ${KAFKA_BOOTSTRAP} \
   --describe --group ${KAFKA_CONSUMER_GROUP} 2>/dev/null"

# Docker deployment
docker exec apache-kafka kafka-consumer-groups.sh \
  --bootstrap-server "${KAFKA_BOOTSTRAP}" \
  --describe --group "${KAFKA_CONSUMER_GROUP}" 2>/dev/null \
  | awk 'NR==1 || /TOPIC/' | head -30
```

**Lag thresholds:**

| LAG value | Status | Action |
|---|---|---|
| 0 | ✅ IAP keeping up | No action needed |
| Steady non-zero | ⚠️ IAP behind | Check IAP CPU/memory — may need scaling |
| Growing rapidly | 🔴 IAP not consuming | Adapter OFFLINE or consumer thread crashed |
| > 10,000 | 🔴 Critical backlog | Urgent — jobs/events are accumulating |

---

### Step 4d — Topic Partition Details

```bash
# SSH deployment
ssh "${KAFKA_SSH_USER}@${KAFKA_SSH_HOST}" \
  "kafka-topics.sh --bootstrap-server ${KAFKA_BOOTSTRAP} \
   --describe --topic ${KAFKA_TOPIC} 2>/dev/null"

# Docker deployment
docker exec apache-kafka kafka-topics.sh \
  --bootstrap-server "${KAFKA_BOOTSTRAP}" \
  --describe --topic "${KAFKA_TOPIC}" 2>/dev/null
```

Check: leader assignment (no `-1` leader → broker election in progress), replication factor, ISR count. A partition with no ISR or leader = data unavailable.

---

### Step 4e — Kafka Adapter Logs in IAP

```bash
# Pull IAP application log lines for the Kafka adapter
# Docker deployment
docker logs iap-app 2>&1 \
  | grep -i "kafka\|consumer\|broker\|lag\|connect" \
  | tail -50

# SSH deployment — adjust log path from /health/applications
grep -i "kafka\|consumer\|broker\|lag" \
  /var/log/itential/platform.log 2>/dev/null | tail -50
```

Look for: connection refused, authentication errors, SSL handshake failures, consumer group rebalance loops.

---

### Step 4f — Fix & Verify

**Adapter OFFLINE due to broker unreachable:**
- Confirm broker address/port in IAP adapter settings matches what `nc` tested
- GET adapter settings → update `host`/`bootstrap.servers`/`port` → PUT (engineer approval required) → restart adapter (engineer approval required)

**Consumer lag growing, adapter ONLINE:**
- Lag growing = IAP consuming but not fast enough → check IAP CPU/memory via `/troubleshoot-infra`
- Lag stuck (no consumption) = adapter thread issue → restart the Kafka adapter (engineer approval required)

**Restart Kafka adapter:**
```bash
# Confirm with engineer before running
curl -sk -X PUT "{PLATFORM_URL}/adapters/{ADAPTER_NAME}/restart?token={TOKEN}" | jq .

# Verify state after ~15s
curl -sk "{PLATFORM_URL}/health/adapters?token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d if isinstance(d, list) else d.get('results', [])
for a in results:
    if 'kafka' in a.get('id','').lower():
        conn = a.get('connection', {}).get('state', '?')
        flag = '✅ ONLINE' if conn == 'ONLINE' else '⚠️ still OFFLINE'
        print(f\"{a['id']}: {a['state']}/{conn} {flag}\")
"
```

**No cleanup step for Kafka** — Kafka adapters have no debug settings (`auth_logging`, `console_level`) to reverse. Once the adapter is back ONLINE and lag is draining, the investigation is complete.

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
| **Kafka OFFLINE, broker reachable** | Consumer thread crashed | Restart Kafka adapter (Phase 4f) |
| **Kafka lag growing, adapter ONLINE** | IAP CPU/memory insufficient or thread blocked | Check infra (Phase 4f) |
| **Kafka lag stuck at non-zero** | IAP consumer not pulling messages | Restart Kafka adapter (Phase 4f) |
| **Kafka broker `Connection refused`** | Broker down or wrong bootstrap address | Phase 4b — update adapter settings |
| **Unknown error code in logs** | Error not in Quick Reference | Phase 5b — fetch error.json from GitLab |
| **sampleProperties unavailable** | Private adapter or npm fetch failed | Phase 5 — fetch direct from GitLab |
| **Settings correct but OFFLINE** | Subtle code-level auth/path mismatch | Phase 5d — inspect adapter source |
| **Need repro steps for ENG ticket** | Requires min-config + trigger steps | Phase 5e — construct reproduction steps |

---

## Phase 5: GitLab Source Inspection

**When to run:**
- Phase 1 gather + sampleProperties compare did NOT resolve the root cause
- Error string in logs does not match any known pattern in the Quick Reference table
- Engineer asks to build reproduction steps or confirm expected adapter behavior
- Settings look correct but adapter is still OFFLINE or returning wrong data

**CRITICAL PRIVACY RULES — enforce for every step in this phase:**
- **Never save any code** (function bodies, imports, class definitions, file contents) to any file on disk
- **Never include code in Jira comments, engineer messages, or customer communications**
- **Never paste code excerpts into gather_report.md, diagnostic_report.md, or any output file**
- `sampleProperties.json` values (config schema, not code) **may** be saved and referenced — they are expected adapter configuration, appropriate to compare against live settings
- `error.json` error-code-to-description mappings **may** be saved (they are error catalog entries, not code)
- Everything else from adapter source files — analyze in memory only; record only the derived insight, not the source

---

### Step 5a — Resolve GitLab Repository

Derive the adapter's GitLab repo path from the package_id extracted in Step 1b:

```python
# Derive GitLab repo path from package_id
# @itentialopensource/adapter-servicenow → adapter-servicenow
import re
package_id = "{package_id}"   # e.g. @itentialopensource/adapter-servicenow
repo_name = package_id.split("/")[-1]   # adapter-servicenow
gitlab_base = f"https://gitlab.com/itentialopensource/adapters/{repo_name}"
api_base    = f"https://gitlab.com/api/v4/projects/itentialopensource%2Fadapters%2F{repo_name}"
print(f"GitLab repo: {gitlab_base}")
print(f"API base:    {api_base}")
```

Verify the repo exists:
```bash
curl -s "https://gitlab.com/api/v4/projects/itentialopensource%2Fadapters%2F{REPO_NAME}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'id' in d:
    print(f'✅ Found: {d[\"name\"]}  (id={d[\"id\"]}, default_branch={d[\"default_branch\"]})')
    print(f'   URL: {d[\"web_url\"]}')
    print(f'   Last activity: {d.get(\"last_activity_at\",\"unknown\")}')
else:
    print('❌ Repo not found — may be private or wrong package name')
    print(d)
"
```

Store the project `id` and `default_branch` for subsequent file fetches. Use `default_branch` (typically `master` or `main`) in all raw URL patterns.

---

### Step 5b — Fetch and Analyze `error.json`

`error.json` maps internal error codes to human-readable descriptions. Use it to map the customer's error string to a root cause. This file is **config/catalog data, not code** — its content may be referenced in analysis.

```bash
curl -s "https://gitlab.com/itentialopensource/adapters/{REPO_NAME}/-/raw/{DEFAULT_BRANCH}/error.json" \
  -o /tmp/{ADAPTER_NAME}_errors.json 2>/dev/null

python3 -c "
import json, sys

try:
    errors = json.load(open('/tmp/{ADAPTER_NAME}_errors.json'))
except Exception as e:
    print(f'error.json not available: {e}')
    sys.exit(0)

# Search for the customer's error term in the error catalog
search_terms = ['{ERROR_TERM}', '{SYMPTOM_KEYWORD}']   # fill from ticket_context
print(f'== error.json: {len(errors)} error codes defined ==')
matches = []
for code, entry in errors.items():
    haystack = json.dumps(entry).lower()
    if any(t.lower() in haystack for t in search_terms if t):
        matches.append((code, entry))

if matches:
    print(f'MATCHING error codes ({len(matches)} found):')
    for code, entry in matches:
        print(f'  {code}')
        print(f'    summary:     {entry.get(\"summary\",\"\")}')
        print(f'    description: {entry.get(\"description\",\"\")}')
        print(f'    category:    {entry.get(\"category\",\"\")}')
        print()
else:
    print('No matching error codes found for search terms')
    # List all category buckets to guide investigation
    cats = {}
    for code, entry in errors.items():
        c = entry.get('category','unknown')
        cats[c] = cats.get(c, 0) + 1
    print('Error categories in this adapter:', cats)
"
```

Save only the matched error-code entries (not the full file) to the gather report supplement — they are diagnostic catalog data, not code.

---

### Step 5c — Fetch and Analyze `package.json`

`package.json` reveals the adapter's declared version, Node.js engine requirement, and dependencies. Dependency versions can explain compatibility failures.

```bash
curl -s "https://gitlab.com/itentialopensource/adapters/{REPO_NAME}/-/raw/{DEFAULT_BRANCH}/package.json" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'Name:     {d.get(\"name\")}')
print(f'Version:  {d.get(\"version\")}')
print(f'Engine:   {d.get(\"engines\",{}).get(\"node\",\"any\")}')
print(f'Main:     {d.get(\"main\",\"index.js\")}')
print()
print('Key dependencies:')
for dep, ver in (d.get('dependencies') or {}).items():
    if any(k in dep for k in ('axios','got','node-fetch','request','https','tls','ssl','oauth','jwt')):
        print(f'  {dep}: {ver}')
print()
print('Adapter entry point (for Step 5d):', d.get('main','adapter.js'))
" 2>/dev/null
```

**Do not save the full package.json.** Note the entry point filename for Step 5d.

---

### Step 5d — Fetch and Inspect Adapter Source (In-Memory Only)

Fetch the main adapter source file and inspect it entirely in memory. Extract only derived facts — authentication patterns, supported auth methods, required properties, connection logic. **Never write source code to any file or output.**

```bash
ENTRY_POINT="${ADAPTER_MAIN_FILE:-adapter.js}"   # from Step 5c

curl -s "https://gitlab.com/itentialopensource/adapters/{REPO_NAME}/-/raw/{DEFAULT_BRANCH}/${ENTRY_POINT}" \
  | python3 -c "
import sys, re

src = sys.stdin.read()
lines = src.splitlines()
total = len(lines)
print(f'Source loaded: {total} lines (not saved, not recorded)')
print()

# ── 1. Auth method detection ─────────────────────────────────────────────
auth_methods = re.findall(
    r'auth_method['\''\"]\s*[=:=!]+\s*['\''\"]([\w_]+)['\''\"]\s*[|)\]}]',
    src, re.IGNORECASE)
auth_switch  = re.findall(
    r'case\s+['\''\"]([\w_]+)[''\"].*?:',
    src)
all_am = sorted(set(auth_methods + auth_switch))
print(f'Detected auth_method values: {all_am}')

# ── 2. Required property detection ───────────────────────────────────────
req = re.findall(
    r'(?:required|mandatory)\s*[=:]+\s*(?:true|\[([^\]]+)\])',
    src, re.IGNORECASE)
req_fields = re.findall(
    r'if\s*\(!\s*(?:this\.)?(?:props?\.)?([a-zA-Z_][\w.]+)\s*\)',
    src)
print(f'Likely required properties: {sorted(set(req_fields))[:20]}')

# ── 3. Base path / endpoint patterns ─────────────────────────────────────
paths = re.findall(
    r'(?:base_path|basePath|baseUrl|url)\s*[+=]+\s*['\''\"](/[^\s'\''\";]+)['\''\"']',
    src)
print(f'API path patterns detected: {sorted(set(paths))[:10]}')

# ── 4. Token refresh pattern ──────────────────────────────────────────────
has_refresh = bool(re.search(r'refresh.?token|token.?refresh|getToken|renewToken', src, re.IGNORECASE))
print(f'Token refresh logic present: {has_refresh}')

# ── 5. SSL/TLS handling ───────────────────────────────────────────────────
ssl_patterns = re.findall(
    r'(?:rejectUnauthorized|accept_invalid_cert|tlsOptions|agentOptions)\s*[=:]+\s*(\S+)',
    src)
print(f'SSL/TLS options detected: {ssl_patterns}')

# ── 6. Suspicious patterns ────────────────────────────────────────────────
hard_timeout = re.findall(r'timeout\s*[=:]+\s*(\d+)', src)
if hard_timeout:
    print(f'Hardcoded timeouts (ms): {hard_timeout[:5]}')

swallowed = len(re.findall(r'catch\s*\([^)]*\)\s*\{[^}]*\}', src))
if swallowed > 3:
    print(f'Silent catch blocks: {swallowed} — errors may be swallowed without logging')

print()
print('Code inspection complete. No source recorded.')
"
```

Capture only the printed derived findings. Do not write the source file to disk, do not pipe it to a log file, do not include raw code in any output.

---

### Step 5e — Construct Reproduction Steps

Using the derived findings from Steps 5b–5d plus the live settings from Step 1b, generate concrete reproduction steps. These steps are safe to include in investigation notes and engineer communication — they describe configuration and workflow actions, not code.

```markdown
## Adapter Reproduction Steps — {ADAPTER_NAME}
**Generated from:** GitLab source analysis (Phase 5) + live settings (Phase 1)
**Adapter version:** {package version from Step 5c}
**Auth method (source):** {detected from Step 5d}

### Minimum Configuration to Reproduce
1. Deploy IAP {IAP_VERSION} with adapter package `{package_id}` installed
2. Configure adapter with these minimum properties:
   ```json
   {
     "host": "{customer host or placeholder}",
     "port": {port},
     "authentication": {
       "auth_method": "{detected auth_method}",
       "username": "{placeholder}",
       "password": "{placeholder}"
     },
     "ssl": { "enabled": {true|false} },
     "stub": false
   }
   ```
   ← Required properties identified from source analysis: {req_fields}

### Steps to Trigger the Issue
1. Start the adapter — confirm it reaches ONLINE state
2. Run a workflow task that calls `{affected endpoint or action}`
3. Expected: {correct behavior from docs/sampleProperties}
4. Actual (per ticket): {customer's observed error}

### Validation
- Check adapter logs for: {matched error codes from Step 5b}
- Compare token_timeout: {live value} vs expected: {sample value}
- Verify auth_method: {live value} vs detected in source: {Step 5d value}
```

**Do not include** code snippets, function names, internal class names, or file paths from the adapter source in reproduction steps sent to engineering or customers.

---

### Step 5f — Update Gather Report with Source Findings

Append to `{project_path}/data/{TIMESTAMP}/{TICKET_KEY}/gather_report.md`:

```markdown
## Phase 5 — GitLab Source Analysis
**Repo:** https://gitlab.com/itentialopensource/adapters/{REPO_NAME}
**Version inspected:** {package.json version}
**Analysis timestamp:** {YYYY-MM-DD HH:MM UTC}

### Auth Method Support (from source)
Detected supported auth_method values: {list from Step 5d}
Live adapter auth_method: {from Step 1b}
→ {match / mismatch / unsupported value}

### Error Code Match (from error.json)
{Matched error code entries — icode, summary, category only}
→ Root cause signal: {derived conclusion}

### Required Properties (from source)
Identified required fields: {list from Step 5d}
Missing in live config: {cross-referenced against Step 1b settings}

### Source Flags
- Token refresh logic: {yes/no}
- Silent catch blocks: {count — if > 3, note as potential log-suppression risk}
- Hardcoded timeouts: {list, if any}
- SSL/TLS options: {detected values}

### Reproduction Steps
{Content from Step 5e — no code, configuration and actions only}
```

**Remind:** No source code is written to this file. Only the derived findings above.

