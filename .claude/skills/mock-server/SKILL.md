---
name: mock-server
description: Clone, start, configure, and drive the external mock_server tool — a multi-protocol (HTTP/HTTPS/gRPC/TCP/UDP/MQTT) dependency simulator with built-in IAG/NetBox fixtures, switchable failure scenarios, request matching, response sequencing, and proxy+record live-traffic capture. Presented as an option with explicit fit criteria — never auto-invoked.
argument-hint: "[start | stop | status | configure <fixture> | record <target-url>]"
---

# Mock Server

**Owns:** Lifecycle and configuration of the external `mock_server` tool — clone-on-demand, start/stop, health check, scenario/fixture configuration, and proxy+record capture-to-mock-config generation (with mandatory credential masking).
**Use when:** A real target system is unavailable, rate-limited, or unsafe to hit repeatedly, and the engineer has decided — after reading the Decision Guidance below — that a mock stand-in is the right tool for the ticket at hand. Invoked from `/troubleshoot-adapters` (Device Simulation Option 6, auth-failure reproduction, proxy+record repro) or `/troubleshoot-ui` (backend-dependency reproduction), always as an engineer-accepted offer, never automatically.

---

## Decision Guidance — Is mock_server the Right Tool Here?

Present this list to the engineer and wait for an explicit "yes, use it" before Step 0 runs. This is a decision for the engineer to make, not a heuristic this skill applies silently on their behalf.

**Good fit:**
- The real target system is unavailable, rate-limited, or unsafe to hit repeatedly (e.g. reproducing a 429/timeout/auth-failure pattern without risking the live system).
- The ticket is REST-API-shaped against something mock_server already has a built-in fixture for (IAG v2.0, NetBox) or can import quickly (OpenAPI/Postman/HAR).
- The bug is intermittent or sequence-dependent ("fails on the Nth call", "works then suddenly fails") — response sequencing makes this deterministically reproducible, which a live retry loop against the real system usually can't.
- You want to capture real traffic *once* (proxy+record) and then replay it indefinitely without re-touching the live/customer system.

**Poor fit — use something else instead:**
- The bug is device-OS-specific (CLI/SSH parsing, real timing/quirks of an actual OS) — mock_server has no real OS backing it; see `/troubleshoot-adapters`'s Device Simulation Options 2-4 (Containerlab+XRd, CML, GNS3/EVE-NG) instead.
- The suspected root cause is inside IAP/IAG itself, not the integration target — mocking the target doesn't help diagnose a platform-side bug.
- No built-in fixture exists and the target's API is large/poorly documented enough that building a custom config would cost more engineer time than it saves.
- The engineer already has safe, reliable, low-friction access to the real system — going live directly is simpler than standing up and configuring a mock first.

---

## CRITICAL SAFETY RULES

- **Lightweight start confirmation only** — before Step 1, ask: *"Starting mock_server — local Docker container, port ${MOCK_SERVER_WEB_PORT}. Proceed?"* This is explicitly **not** the full CPU/RAM-stating gate CLAUDE.md mandates for reproduction-environment compute (EC2/EKS/DocumentDB/ElastiCache/Platform containers) — that gate is scoped to billable/compute resources, and mock_server is a single zero-dependency container with negligible footprint. A heavier gate here would add friction without matching risk.
- **Proxy+record mode must target only a system the engineer has explicit, per-capture permission to capture traffic from.** Never point it at a live customer production system without that explicit approval for that specific capture.
- **Write-time masking gate (authoritative here — other skills cross-reference this rule, never restate it):** proxy+record mode persists real captured traffic — including `Authorization`/`Cookie`/token header values — as an actual file (the recording itself, and any auto-generated config). This is a materially different risk than `/troubleshoot-logs`'s existing masking, which is *display-time only* since it never persists raw logs itself. Before any recording, history export, or generated config (`/api/config/generate-from-recording`) is written to disk, displayed, or handed to `/contribute`:
  - Recursively walk the captured JSON (headers + body). For any key matching (case-insensitive) `authorization|cookie|set-cookie|x-api-key|x-auth-token|api_key|apikey|token|password|secret|client_secret|refresh_token`, mask the value to first 6 + last 4 characters (e.g. `Bearer eyJhbG...9x3K`).
  - Also run free-text body string values through the same key-term regex, not just known header keys, to catch secrets nested under unexpected keys.
  - This runs immediately after capture, before any file write — a write-time gate, not a display-time one.
- Stopping mock_server (`docker compose down`) is always safe and requires no confirmation. Deleting persisted configs/history under `${MOCK_SERVER_DIR}/configs/` is destructive and requires explicit engineer approval, mirroring `/deploy-containers`'s `make down` vs. `make clean` distinction.

---

## Auth Reuse

mock_server itself needs no platform credentials — it's cloned over the engineer's existing GitLab SSH key (same mechanism as any other git remote), and its own admin API requires no auth by design (it's a local-only dev tool). No `.env` platform credentials are read by this skill; the only `.env` vars it reads are its own (below).

```
MOCK_SERVER_DIR=              # override ~/mock_server clone location (blank = default)
MOCK_SERVER_WEB_PORT=15000    # web UI / admin API port; maps to mock_server's own WEB_PORT
MOCK_SERVER_URL=               # derived http://localhost:${MOCK_SERVER_WEB_PORT}; override if tunneled/remote
MOCK_SERVER_GIT_REF=           # optional branch/tag/commit pin; blank = main/HEAD
```

---

## Step 0 — Clone-on-Demand

```bash
MOCK_SERVER_DIR="${MOCK_SERVER_DIR:-$HOME/mock_server}"

# Preflight: confirm the engineer's GitLab SSH key is loaded before attempting the clone
ssh -T git@gitlab.com 2>&1 | grep -qi "Welcome to GitLab" || {
  echo "⚠️  Could not authenticate to gitlab.com over SSH. Confirm your GitLab SSH key is loaded (ssh-add -l) before continuing."
}

if [ -d "${MOCK_SERVER_DIR}/.git" ]; then
  echo "Found existing mock_server at ${MOCK_SERVER_DIR} — pulling latest"
  git -C "${MOCK_SERVER_DIR}" pull origin "${MOCK_SERVER_GIT_REF:-main}"
else
  echo "Cloning mock_server to ${MOCK_SERVER_DIR}"
  git clone git@gitlab.com:itential/customersuccess/product-support-tools/mock_server.git "${MOCK_SERVER_DIR}"
  [ -n "${MOCK_SERVER_GIT_REF}" ] && git -C "${MOCK_SERVER_DIR}" checkout "${MOCK_SERVER_GIT_REF}"
fi
```

## Step 1 — Start (Lightweight Confirmation Required)

> **Confirm with the engineer: "Starting mock_server — local Docker container, port ${MOCK_SERVER_WEB_PORT}. Proceed?"**

```bash
cd "${MOCK_SERVER_DIR}"
WEB_PORT="${MOCK_SERVER_WEB_PORT:-15000}" docker compose up -d
```

## Step 2 — Health Check

Use CLAUDE.md's standard Connectivity Retry Policy (5 attempts, 5s gaps) — no new retry convention invented here.

```bash
MOCK_SERVER_URL="${MOCK_SERVER_URL:-http://localhost:${MOCK_SERVER_WEB_PORT:-15000}}"
MAX_RETRIES=5; DELAY=5
for i in $(seq 1 $MAX_RETRIES); do
  curl -sf "${MOCK_SERVER_URL}/__admin/health" > /dev/null && break
  echo "[$i/$MAX_RETRIES] mock_server not ready, retrying in ${DELAY}s"
  sleep $DELAY
done
```

## Step 3 — Configure

```bash
# Switch failure scenario: default | errors | slow | rate-limited | timeout | jittery | degrading | spike
curl -sk -X POST "${MOCK_SERVER_URL}/__admin/scenarios" \
  -H "Content-Type: application/json" -d '{"scenario": "{SCENARIO_NAME}"}'

# Load a named built-in fixture (e.g. automation-gateway-https, netbox, netbox-v33-http)
curl -sk -X POST "${MOCK_SERVER_URL}/__admin/config/load" \
  -H "Content-Type: application/json" -d '{"config": "{FIXTURE_NAME}"}'
```

## Step 4 — Proxy + Record (Requires Engineer-Named Target + Masking)

> **Confirm with the engineer: the exact target URL, and that they have explicit permission to capture traffic from it.**

```bash
# Start proxy+record mode against the engineer-named real target
curl -sk -X POST "${MOCK_SERVER_URL}/__admin/proxy/start" \
  -H "Content-Type: application/json" -d '{"target": "{REAL_TARGET_URL}", "record": true}'

# ... engineer exercises the real workflow against the target while mock_server records ...

# Stop recording and auto-generate a replayable config from the capture
curl -sk -X POST "${MOCK_SERVER_URL}/api/config/generate-from-recording" \
  -o /tmp/mock_server_generated_raw.json
```

**Masking transform (always run before the generated config is saved anywhere):**

```python
import json, re

CRED_KEY_RE = re.compile(
    r"^(authorization|cookie|set-cookie|x-api-key|x-auth-token|api_key|apikey"
    r"|token|password|secret|client_secret|refresh_token)$", re.IGNORECASE)
CRED_TERM_RE = re.compile(r"\b(token|password|secret|key)\b", re.IGNORECASE)

def mask_value(v):
    s = str(v)
    # Preserve a readable auth-scheme prefix (Bearer/Basic/Token) rather than masking it away
    m = re.match(r"^(Bearer|Basic|Token)\s+(.+)$", s, re.IGNORECASE)
    if m:
        scheme, rest = m.group(1), m.group(2)
        return f"{scheme} {rest[:6]}...{rest[-4:]}" if len(rest) > 10 else f"{scheme} {rest}"
    return s if len(s) <= 10 else f"{s[:6]}...{s[-4:]}"

def walk(node):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if CRED_KEY_RE.match(k):
                out[k] = mask_value(v)
            elif isinstance(v, str) and CRED_TERM_RE.search(k):
                out[k] = mask_value(v)
            else:
                out[k] = walk(v)
        return out
    if isinstance(node, list):
        return [walk(item) for item in node]
    return node

with open("/tmp/mock_server_generated_raw.json") as f:
    raw = json.load(f)
masked = walk(raw)

# Save location: ${MOCK_SERVER_DIR}/configs/ for reuse across tickets, or
# data/<ticket>/mock-configs/ when invoked from within a /troubleshoot investigation
with open("{SAVE_PATH}", "w") as f:
    json.dump(masked, f, indent=2)
print("Masked config saved to {SAVE_PATH} — spot-check: no raw Authorization/token/password values remain.")
```

## Step 5 — Stop / Cleanup

```bash
# Safe — preserves configs/history, no confirmation needed
cd "${MOCK_SERVER_DIR}" && docker compose down
```

> **Destructive — requires explicit engineer approval:** deleting persisted configs/history (`rm -rf "${MOCK_SERVER_DIR}/configs"`). Confirm before running; this is irreversible and removes any generated configs from prior proxy+record sessions.
