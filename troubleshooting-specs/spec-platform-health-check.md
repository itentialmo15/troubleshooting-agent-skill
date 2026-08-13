# Troubleshooting Spec: Platform Health Check

## 1. Problem Statement

When something goes wrong on the Itential Platform — or before a maintenance window — engineers need a fast, consistent way to answer "is the platform healthy?" Today that means manually checking the IAP UI, running individual curl commands, or relying on memory about which apps and adapters matter. The check is incomplete, inconsistent, and leaves no evidence trail.

**Goal:** Produce a single, repeatable health snapshot covering all applications, adapters, job queue state, database connectivity, and log verbosity — in under two minutes — and route to the right deep-dive skill if issues are found.

---

## 2. High-Level Flow

```
Auth       →   Apps       →   Adapters   →   Job Queue   →   DB Ping   →   Report
  │               │               │               │               │            │
  │               │               │               │               │            │
 Reuse         GET health/     GET health/     Count           Ping         Print
 .auth.json    applications    adapters        running,        MongoDB,     green/
 or login      → flag any      → flag any      queued,         Redis        yellow/
               not RUNNING     not ONLINE      stuck > 60m     if in .env   red table
```

---

## 3. Investigation Phases

### Auth
Reuse token from `.auth.json` if same platform URL and < 50 minutes old. Otherwise authenticate from `.env` (password or OAuth) and save a fresh token. Never ask the user for credentials that exist in `.env`.

### Application Health
GET `/health/applications`. Count total vs RUNNING. Flag any app not in RUNNING state — especially `WorkFlowEngine`, `OperationsManager`, and `PronghornCore`, which are critical-path. Capture `logger.console` level per app and flag any running at `spam`, `debug`, or `trace`.

### Adapter Health
GET `/health/adapters`. Count total vs ONLINE. For each adapter not ONLINE, record state (`RUNNING/OFFLINE` vs `DEAD/OFFLINE`), package ID, and host:port config. These are candidates for `/troubleshoot-adapters`.

### Job Queue
GET `/operations-manager/jobs` by status. Count running and queued. Scan running jobs for those started > 60 minutes ago — flag as potentially stuck. Count recent error jobs.

### Database Connectivity
If `MONGO_URL` is in `.env`: ping MongoDB, check connection pool utilization %, replica set member health. If `REDIS_HOST` is in `.env`: PING, check memory used vs maxmemory, evicted_keys count. If not in `.env`: note the gap.

### Report
Print a green/yellow/red summary table immediately. Save a markdown report to `data/{TIMESTAMP}/health_report.md`. Route findings to the appropriate deep-dive skill.

---

## 4. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| GET only — no writes | Read-only throughout | Health check must never alter platform state |
| Auth reuse | 50-minute TTL from `.auth.json` | Avoid redundant login calls across sequential skill runs |
| Report immediately, then save | Print table to user before writing file | Fast feedback; file is for evidence trail |
| Route findings to sub-skills | Reference `/troubleshoot-adapters`, `/troubleshoot-jobs`, etc. | Health check diagnoses breadth; sub-skills do depth |
| Missing DB credentials = noted gap, not a failure | Note and continue | Platform API health is useful even without DB access |
| Log level flagging | `spam`/`debug`/`trace` = warning | High verbosity is a performance/disk risk, not a crash |

---

## 5. Scope

**In scope:** IAP application state, adapter state, job queue depth, stuck job detection, MongoDB connectivity and connection pool, Redis connectivity and memory, WFE and app log level check, summary report with routing recommendations.

**Out of scope:** Deep workflow failure analysis (→ `/troubleshoot-workflows`). Adapter root-cause diagnosis (→ `/troubleshoot-adapters`). Slow job investigation (→ `/troubleshoot-jobs`). OS/container resource usage (→ `/troubleshoot-infra`). Deep DB query analysis (→ `/troubleshoot-databases`). Log file analysis (→ `/troubleshoot-logs`).

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Token expired mid-check | API calls return 401 | Re-authenticate silently on first 401, retry once |
| Platform unreachable | All checks fail | Report connectivity failure immediately; check network and TLS |
| MongoDB/Redis not in `.env` | Partial health picture | Note gap, complete remaining checks, list what credentials unlock |
| App DEAD but expected | False alarm | Health check reports state only; user decides if expected |
| WFE log level spam but platform stable | Warning fatigue | Flag as warning, not critical; recommend lowering when convenient |

---

## 7. Requirements

### What access is needed

| Credential / Access | Required | If Not Available |
|--------------------|----------|------------------|
| `PLATFORM_URL` + auth credentials in `.env` | Yes | Cannot proceed |
| `MONGO_URL` in `.env` | No | MongoDB check skipped; note the gap |
| `REDIS_HOST` in `.env` | No | Redis check skipped; note the gap |
| `PROMETHEUS_URL` in `.env` | No | Process metrics skipped; recommend for deeper health |

### Discovery Questions

Ask the user before running if context is unclear:

1. Is this a pre-maintenance check or incident response?
2. Are any applications expected to be DEAD in this environment (e.g., LifecycleManager, ServiceCatalog not licensed)?
3. Do you have MongoDB and Redis credentials to add to `.env` for a full check?
4. What is the approximate incident time (if investigating a past event)?

---

## 8. Acceptance Criteria

1. Auth is completed from `.env` without prompting the user for credentials
2. All IAP applications are checked and RUNNING/not-RUNNING state is reported
3. All adapters are checked and ONLINE/OFFLINE state is reported
4. Job queue depth (running, queued) and stuck jobs > 60 min are reported
5. MongoDB connectivity and connection pool % are reported if `MONGO_URL` is present
6. Redis connectivity and memory usage are reported if `REDIS_HOST` is present
7. WFE and per-app log levels are reported; `spam`/`debug` levels are flagged
8. A green/yellow/red summary table is printed to the user before the report file is written
9. A markdown report is saved to `data/{TIMESTAMP}/health_report.md`
10. Any finding includes a pointer to the correct deep-dive skill
11. Missing credentials are reported as access gaps, not errors
