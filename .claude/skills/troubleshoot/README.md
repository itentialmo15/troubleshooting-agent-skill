# Troubleshoot Skill — README

**Skill:** `/troubleshoot`  
**Role:** Senior Product Support Engineering Agent for Itential Platform  
**Scope:** Full investigation lifecycle — ISD ticket intake through resolution learning and manager escalation

---

## What It Does

The `/troubleshoot` skill acts as a senior Itential support engineer. It reads ISD Jira tickets, analyzes the problem, runs targeted platform diagnostics through specialist sub-skills, produces engineering escalation packs, and captures resolution learnings. It does not guess — it collects evidence, cross-references it, and drives to root cause.

---

## How to Invoke

```
/troubleshoot ISD-9261
/troubleshoot "jobs are stuck after last deployment"
/troubleshoot "adapter automation_gateway shows OFFLINE"
```

Provide either an ISD ticket key or a brief description. The skill reads `.env` for credentials and handles the rest.

---

## Prerequisites

Create a `.env` file in your working directory with at minimum:

```bash
# Required
PLATFORM_URL=https://your-instance.itential.io
AUTH_METHOD=oauth          # or "password"
CLIENT_ID=your-client-id
CLIENT_SECRET=your-secret

# Optional — unlocks deeper investigation
MONGO_URL=mongodb://user:pass@host:27017/itential?authSource=admin
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=

# Jira — required for ticket intake and ENG escalation
JIRA_URL=https://itential.atlassian.net
JIRA_USER=you@itential.com
JIRA_API_TOKEN=your-api-token

# Slack — required for escalation messages
SLACK_ESCALATION_CHANNEL=#support-escalations
SLACK_MANAGER=@manager-handle

# Observability
PROMETHEUS_URL=http://monitor:9090
GRAFANA_URL=http://monitor:3000
GRAFANA_API_KEY=your-key

# SSH targets (for VM deployments)
SSH_HOST_1=10.0.1.50
SSH_USER_1=ec2-user
SSH_KEY_PATH_1=~/.ssh/id_rsa
SSH_ROLE_1=iap
```

Missing groups are reported as access gaps — the skill tells you exactly which variables to add and what investigation they unlock.

---

## Investigation Lifecycle

The skill follows eight sequential phases. Each phase feeds the next.

```
Phase 0         Phase 1         Phase 2         Phase 3
Ticket Intake → Auth +       → Investigation → Platform
                Snapshot        Protocol        Investigation
                                                    │
                                            (sub-skills)

Phase 4         Phase 5         Phase 6         Phase 7         Phase 8
Reproduce    → Diagnostic   → ENG           → Resolution    → Manager
               Report          Escalation      Learning        Escalation
```

---

## Phase Reference

### Phase 0 — Ticket Intake
**Runs first, before touching the platform.**

| Step | What happens |
|------|-------------|
| **0a** | Reads the full ISD Jira ticket — summary, description, all comments, attachments, and **blueprint field** (adapter/component package versions) |
| **0b** | Extracts structured context: IAP version, deployment type, error message, job ID, frequency, regression status; adapter versions come from the blueprint field — do not ask the customer |
| **0c** | Mines ISD and ENG Jira for similar tickets — uses resolution comments as diagnostic hypotheses |
| **0d** | Searches Confluence for KB articles, runbooks, post-mortems, and known-issue pages |
| **0e** | Produces a Pre-Investigation Summary: hypothesis, known issue match, investigation plan, escalation risk |

**Priority Mismatch Detection (runs at Phase 0):**
The skill reads the ticket description and flags when a customer has filed a low-priority ticket but their words indicate a blocking or production-impacting issue. Signals checked:

| Customer says | Action |
|--------------|--------|
| "production is down", "all users affected" | Flag as S1 — escalate senior manager immediately |
| "blocking our go-live", "deadline is [date]" | Flag as time-critical — escalate immediately |
| "customer-facing", "impacting our clients" | Flag downstream customer impact |
| "entire team is blocked" | Flag broad user impact |
| "this has been broken for X weeks" | Flag long-running — SLA likely breached |
| "ASAP", "tried everything", "no workaround" | Flag customer frustration — risk of churn |

When a mismatch is detected: priority is upgraded, a triage comment is posted to the ticket, and senior management is notified — **before** investigation starts.

---

### Phase 1 — Authenticate & Platform Snapshot
- Authenticates using credentials from `.env` (OAuth or password)
- Saves token to `.auth.json`, reused across phases (< 50 min old)
- Collects: IAP version, application health, adapter health
- Lists all OFFLINE adapters immediately
- Categorizes issue as functional or performance → routes to correct sub-skill(s)

---

### Phase 2 — Investigation Protocol
Eight-section standardized questionnaire. Sections not answered in the ticket are composed into a Jira comment posted to the customer.

| Section | Content |
|---------|---------|
| 1 — Symptoms | What is happening, exact error, which component |
| 2 — Timeline | When did it start, last known good state, triggering events |
| 3 — Reproduction | Steps to reproduce, expected vs actual result |
| 4 — Who is impacted | User scope, workflow scope, environment scope |
| 5 — Business impact | What is blocked, workarounds, time sensitivity |
| 6 — Resolution *(post-resolution)* | Steps taken, order attempted, partial improvements |
| 7 — Incident end *(post-resolution)* | System evidence of recovery |
| 8 — Data collection | Artifact checklist: logs, job IDs, health snapshots, monitoring data |

---

### Phase 3 — Platform Investigation

Routes to specialist sub-skills based on symptom. Sub-skills run in parallel when the issue spans multiple components.

| Symptom | Sub-skill |
|---------|-----------|
| Workflow failing, job erroring, JST error, import failure | `/troubleshoot-workflows` |
| Adapter OFFLINE, wrong data, auth failure | `/troubleshoot-adapters` |
| Jobs stuck, errored, or slow; WFE health; Bull queues; historical/baseline comparison | `/troubleshoot-jobs` |
| MongoDB slow, Redis eviction, connection pools | `/troubleshoot-databases` |
| CPU/memory/disk/OOM/containers/EKS | `/troubleshoot-infra` |
| Collect logs from any component | `/troubleshoot-logs` |
| IAG adapter OFFLINE, GatewayManager error | `/troubleshoot-adapters` + Phase 3d inline |
| UI slow, API timeouts | Phase 3h inline |
| Kafka consumer lag | Phase 3i inline |

---

### Phase 4 — Reproduce
- Scaffolds a version-matched Docker environment matching the customer's IAP version
- Writes reproduction steps with expected/actual results
- Saves to `repro/{ISD_TICKET_KEY}/repro_steps.md`

---

### Phase 5 — Diagnostic Report
Saved to `data/{TIMESTAMP}/diagnostic_report.md`. Includes:
- Environment snapshot (IAP, adapters, MongoDB, Redis, Kafka, OS)
- Investigation checklist
- Findings with evidence
- Root cause hypotheses (ranked by likelihood)
- Recommended next steps with owners
- Access gaps table

---

### Phase 6 — Engineering Escalation Pack
Produced when the investigation confirms a platform bug.

- Bug report with: summary, affected versions, steps to reproduce, expected vs actual, root cause hypothesis, workaround, artifacts
- Creates or updates ENG Jira ticket
- Links ENG ticket to ISD ticket

---

### Phase 7 — Resolution Learning
Runs when a fix is confirmed.

- Records resolution pattern to `data/known-resolutions.md`: symptom, root cause, resolution steps, workaround, detection hints, verification
- Posts resolution comment to ISD ticket
- Transitions ISD ticket to Resolved
- Updates the known-resolution library in Phase 3 routing table

---

### Phase 8 — Manager Escalation

Two modes:

**Priority Mismatch Escalation** (proactive — triggered at Phase 0):
Used when a customer files a low-priority ticket but the description reveals a blocking or production-impacting situation. The senior manager is notified immediately — not after investigation.

Slack template:
```
⚠️ PRIORITY MISMATCH — SENIOR MANAGER REVIEW REQUIRED
Ticket: ISD-XXXX | Filed as: P3 | Should be: P1

Customer: {name}
Filed priority: P3 — but the description says:
"{exact customer quote}"

Why this needs immediate attention:
• {blocking signal}
• {business risk}
• {scope}

Action needed: Review priority upgrade, assign senior engineer, consider account team contact.
```

**Standard Escalation** (reactive — SLA breach, S1 unresolved, multi-customer):
```
🔴 ESCALATION — ISD-XXXX | P1 | S1
Customer, impact, SLA status, findings, blockers, action needed.
```

Escalation triggers:

| Trigger | Urgency |
|---------|---------|
| Priority mismatch — low ticket, blocking description | Immediate — senior manager |
| S1 with no resolution path after 2 hours | Immediate |
| S2 SLA breached | Immediate |
| S1/S2 with no engineer assigned | Immediate |
| Customer requests manager escalation | Immediate |
| Issue affects multiple customers | Immediate |
| ENG confirms bug with no fix timeline | Escalate to Product Management |
| S3/S4 SLA breached > 24 hours | Lower urgency |
| Investigation blocked > 24 hours | Escalate to unblock |

---

## Sub-Skill Reference

### `/troubleshoot-workflows`
**Covers:** Runtime job errors, task output failures, JST errors, validation errors (draft state), missing transitions, non-hex task IDs, childJob chain traversal

**Also covers — Import Failures:**

| Import type | What it checks |
|-------------|---------------|
| **Workflow** | JSON syntax, duplicate name, non-hex task IDs, wrong `app` field (instance vs type), missing error transitions, circular childJob refs, `errors[]` post-import |
| **JSON Form** | Schema structure, `form[]`-to-`schema.properties` alignment, trigger variable name matching |
| **Template (Jinja2/TextFSM)** | Local syntax validation, `<!var!>` context errors, TextFSM state/value structure |
| **Command Template** | `<!var!>` variable resolution, validation rule regex validity, analytic template mismatch |
| **Transformation (JST)** | Missing `return`, `require()` unavailable, async not supported, null input edge cases |
| **Project** | Component name conflicts, project-scoped childJob refs, post-import draft state, invalid component types, missing members |

**Jobs Stuck (workflow-level):**

| Pattern | Cause |
|---------|-------|
| Job running, no task running | Missing transition to `workflow_end` |
| Adapter task running > 60 min | Upstream API unresponsive |
| childJob running, 0 child jobs | Child workflow not found or draft |
| Eval task stuck | Duplicate JSON key on transition |
| Loop stuck | One child job errored, no error transition |
| Job `complete` but tasks skipped | Error path routed silently to `workflow_end` |

---

### `/troubleshoot-adapters`
**Covers:** OFFLINE/DEAD state, auth failures, wrong data returned, token expiry, connectivity, debug mode (auth_logging, console_level)

**Common patterns:**

| Error | Cause |
|-------|-------|
| `No config found for Adapter: X` | `app` field uses instance name, not type name |
| Adapter OFFLINE after first auth | `token_timeout: -1` — never refreshes |
| `EHOSTUNREACH` | IAP cannot reach adapter host/port |
| `stub: true` | Adapter in stub mode — no real API calls |

---

### `/troubleshoot-jobs`
**Covers:** Job duration profiling, task timing breakdown, OM queue depth, WFE worker health and log level, Redis Bull queue analysis (wait/active/failed/delayed), MongoDB COLLSCAN detection, historical baseline comparison, concurrency/contention analysis, Prometheus/Grafana metrics, full parent-child job error chain traversal, true-stall verification, adapter/application health correlation, cross-component log correlation, webserver log slow-request analysis

**Two investigation purposes:**
- **Purpose A — slow job:** compare the job's task timings against a prior healthy run of the *same* workflow (MongoDB historical baseline), and check whether concurrent job/task load was abnormally high at the time it ran (contention vs. regression)
- **Purpose B — stuck/errored job:** walk the entire parent → child → grandchild job chain for errors (not just the parent), confirm the job is truly stalled (no task progress across polls) rather than just slow, rule out an unhealthy adapter/application as the cause, and correlate logs across IAP/IAG/MongoDB/Redis around the incident window

**Bottleneck layers (investigated in order):**
1. Task timing → which specific task is slow
2. OM queue → how many running/queued
3. WFE → worker count, log level (`spam` = I/O killer)
4. Redis → Bull queue depths, eviction, blocked clients
5. MongoDB → COLLSCAN on jobs collection, missing indexes, historical baseline diff, concurrency at incident window
6. Prometheus → CPU, heap, event loop, GC overhead
7. Parent-child chain → recursive error walk, true-stall check, adapter/app health, cross-component log correlation
8. Webserver log → slow API calls on `/operations-manager/jobs`

---

### `/troubleshoot-databases`
**Covers:** MongoDB connection pools, slow queries, replica set health, index analysis; Redis eviction policy, memory, queue depth, ElastiCache

---

### `/troubleshoot-infra`
**Covers:** CPU, memory, disk, file descriptors, container crashes, OOMKilled detection, EKS pod health, network connectivity

---

### `/troubleshoot-logs`
**Covers:** Log collection from IAP, IAG, MongoDB, Redis, load balancers — Docker, SSH/VM, Kubernetes/EKS, AWS CloudWatch. Filters by incident time, reports error patterns, masks sensitive values.

---

## Known Bugs — Quick Reference

| Ticket | Error | Component | Workaround |
|--------|-------|-----------|------------|
| ISD-9261 | `TypeError: Cannot set properties of undefined (setting 'childJobLoopIndex')` in browser console when clicking "enable query" on a looped childJob task | Automation Studio UI (Platform 6.4.0) | Pass `data_array` value as a separate flat job variable; wire `data_array` directly without enable query. STR: `data/2026-06-09T00-00-00/ISD-9261/steps-to-reproduce.md` |

> **Note on ISD-9261:** Error only appears in the browser console (F12). Not in `job.error[]`, not in platform logs. No platform-side investigation needed.

---

## Known Resolution Library

| Error / Symptom | Root Cause | Resolution |
|----------------|-----------|------------|
| `token_timeout: -1` + IAG OFFLINE after first auth | Adapter never refreshes IAG token | Set `token_timeout: 3600000` in adapter settings |
| `No config found for Adapter: X` | `app` field uses instance name not type name | Fix `app` and `locationType` to type name from `apps.json` |
| `Job has no available transitions` | No error transition on adapter/external task | Add `"state": "error"` transition |
| `stub: true` | Adapter in stub mode | Set `stub: false` |
| WFE log > 500MB + slow jobs | `console_level: spam` | Set `console_level: error` in WFE settings |
| Jobs COLLSCAN + slow at scale | Missing `{status: 1}` index on jobs collection | Add index with DBA consent |
| `OOMKilled` container | Memory limit too low | Increase Docker memory limit |
| `ASIA*` AWS key prefix + OFFLINE | STS temporary credentials expired | Replace with long-lived IAM key (`AKIA` prefix) |
| Workflow `errors[]` not empty after import | Draft state — validation errors | Check each error entry, fix, re-PUT |
| `$var` reference resolves to `undefined` | Non-hex task ID on the referenced task | Rename task ID to hex (`[0-9a-f]{1,4}`) |
| childJob `Cannot find workflow: X` at runtime | childJob refs plain name but asset is project-scoped | Update `workflow` field to `@{projectId}: {name}` |

---

## Key Rules

- **Never post to ISD or file ENG tickets without engineer consent** — always present the draft and wait for explicit approval before any Jira write action (comments, new tickets, links, transitions, field updates)
- **All ISD comments must be internal** — always set `commentVisibility: {"type": "role", "value": "Service Desk Team"}` on every `addCommentToJiraIssue` call. Never post a public/customer-visible comment on ISD tickets
- **GET and read-only only** — no PUT, DELETE, PATCH, POST without explicit user consent
- **No MongoDB writes** — read-only queries only
- **No Redis writes** — no SET, DEL, FLUSHDB
- **Never restart services or containers** without explicit user consent
- **Mask credentials in logs** — show first 6 + last 4 characters only
- **Low priority ≠ low impact** — always read the description, not just the priority field. A P4 that says "entire team is blocked" is a P1. Escalate before investigating.
- **`job.error` is an array** — always iterate; don't just check the first element
- **`status: complete` doesn't mean success** — check `job.error` on complete jobs too
- **Adapter `app` ≠ adapter instance name** — `app` = type name from `apps.json`; using instance name causes `"No config found for Adapter"` at runtime
- **IAG uses `Token:` header** — not `Authorization: Bearer`
- **`token_timeout: -1` is the #1 cause of IAG OFFLINE** — check this first on every IAG OFFLINE case
- **Resolution learning is not optional** — every confirmed resolution updates the known-resolution library

---

## Output Files

| File | When created | Contents |
|------|-------------|---------|
| `data/{TIMESTAMP}/ticket_context.md` | Phase 0 | Structured ticket context |
| `data/{TIMESTAMP}/known_issues.md` | Phase 0 | ENG/ISD search results |
| `data/{TIMESTAMP}/confluence_references.md` | Phase 0 | Relevant Confluence pages |
| `data/{TIMESTAMP}/diagnostic_report.md` | Phase 5 | Full diagnostic report |
| `data/{TIMESTAMP}/eng_bug_report.md` | Phase 6 | Engineering escalation pack |
| `repro/{ISD_TICKET_KEY}/repro_steps.md` | Phase 4 | Reproduction steps and evidence |
| `data/known-resolutions.md` | Phase 7 | Cumulative resolution library |

---

## Spec Files

Detailed investigation specs for each sub-skill:

| File | Covers |
|------|--------|
| `troubleshooting-specs/spec-troubleshoot-workflows.md` | Runtime job errors, all import types, jobs stuck (workflow-level), known bugs |
| `troubleshooting-specs/spec-troubleshoot-jobs.md` | Stuck/slow jobs, WFE, Redis/Bull, MongoDB, Prometheus/Grafana |
| `troubleshooting-specs/spec-troubleshoot-adapters.md` | Adapter OFFLINE, auth, debug mode |
| `troubleshooting-specs/spec-troubleshoot-databases.md` | MongoDB, Redis, ElastiCache |
| `troubleshooting-specs/spec-troubleshoot-infra.md` | CPU, memory, disk, containers, EKS |
| `troubleshooting-specs/spec-troubleshoot-logs.md` | Log collection across all deployment types |
