# Troubleshooting Spec: Troubleshoot Jobs (Stuck, Errored, or Slow)

## 1. Problem Statement

When IAP jobs run slower than expected, error out, or get stuck, root cause can be at any layer of the execution stack. Engineers don't know whether the bottleneck is the workflow itself (a slow adapter call), the WorkflowEngine (saturated workers), Redis (queue backlog), MongoDB (missing indexes), the host OS (CPU/memory exhaustion), a deeply nested child job that actually failed, or an unhealthy dependency (adapter/application). Without following the full causal chain — and without a historical baseline to compare against — fixes target the wrong layer.

**Goal:** Serve two related but distinct investigations:
- **Purpose A (slow job):** Follow the job execution path end-to-end — API ingress → Operations Manager → WorkflowEngine → Redis/Bull queues → MongoDB → OS resources — and additionally diff the job's task timings and concurrent load against a historical baseline run of the *same* workflow, to distinguish a task-specific regression from platform-wide contention.
- **Purpose B (stuck/errored job):** Recursively walk the full parent → child → grandchild job chain for errors, verify the job is truly stalled (not just slow), rule out (or confirm) an unhealthy adapter/application dependency, and correlate logs across IAP, IAG, MongoDB, and Redis around the incident window.

Both purposes converge on the same bottleneck-layer identification and prioritized fix recommendation.

---

## 2. High-Level Flow

```
Profile Job → OM Health → WFE Health → Redis/Bull → MongoDB (+ baseline/concurrency) → Metrics → Stuck/Error Chain → Report
     │             │            │             │                  │                       │              │              │
  Task timing,   Queue       Workers,       Queue          Job coll count,           Prometheus/    Recursive       Root cause
  slowest task,  depth,      log level,     depths,        indexes, COLLSCAN,        Grafana:       parent→child   + layer +
  child job IDs  stuck jobs  log file size  failed,        historical baseline       CPU/heap/      walk, true-    fix
                                            blocked        diff, concurrent load     event loop     stall check,
                                                            at incident window                       adapter/app
                                                                                                       health, log
                                                                                                       correlation
```

Purpose A (slow) uses the MongoDB baseline/concurrency step and Metrics phase most heavily. Purpose B (stuck/errored) uses the Stuck/Error Chain phase most heavily. Both share Phases 1–4.

---

## 3. Investigation Phases

### Phase 1: Job Profile
Fetch the specific job by ID or find recent slow/running jobs for a workflow name. Parse task timing: sort all tasks by duration, surface the slowest task(s). Identify which task accounts for the majority of job duration — that task is the primary suspect. Flag any task with no end time (still running or stuck).

### Phase 2: Operations Manager Health
Check OM application state. Get running and queued job counts. Scan running jobs for those started > 60 minutes ago and flag as stuck. High queued count means workers are saturated.

### Phase 3: WorkflowEngine Health
Check WFE application state and properties. Identify worker/concurrency setting. Check `logger.console` level — `spam` or `debug` generates massive log I/O that competes with job state writes. Check WFE log file size inside the container.

### Phase 4: Redis / Bull Queue Analysis
If Redis is accessible: PING, check memory and eviction, list all `bull:*` keys, measure wait/active/failed/delayed queue depths per queue. Flag: wait > 100 (backlog), failed growing (silent task failures), `used_memory` near `maxmemory` (eviction risk), `blocked_clients` > 0 (BLPOP stall).

### Phase 5: MongoDB Job Collection Performance (+ Historical Baseline & Concurrency — Purpose A)
If MongoDB is accessible: check current slow ops (`secs_running > 2`), run explain on `db.jobs.find({status:'running'})` to detect COLLSCAN, count the jobs collection, list indexes on jobs collection. A COLLSCAN on a million-document jobs collection is catastrophic.

For slow-job investigations, additionally: query recent completed runs of the *same* workflow name to pick a baseline job, diff task-by-task timings between the current job and the baseline to isolate whether one specific task regressed or all tasks slowed uniformly, and count how many other jobs started within a tight window (e.g., ±5 min) around both the incident job's start time and the baseline's start time — a materially higher concurrent count at the incident window points to contention rather than a workflow-specific regression.

### Phase 6: Prometheus / Grafana Metrics
If `PROMETHEUS_URL` is in `.env`: query CPU rate, heap used/total, event loop lag, GC overhead, and RSS for `iap.*` and `itential.*` job labels over the incident window. Check for firing alerts. If `GRAFANA_URL` is set: discover IAP/IAG dashboards and query panel data for the incident window.

### Phase 7: Stuck / Errored Job Investigation — Parent-Child Chain + Health Correlation (Purpose B)
Extract child job IDs from parent job task outputs, and recurse: if a child job itself spawned children, walk that chain too, down to leaf jobs — root cause is often several levels deep, not in the immediate parent. For each job in the chain, iterate the full `error` array (never just the first entry) and report status.

Because `status: running` does not necessarily mean stuck, verify a true stall by polling the job twice (e.g., 60s apart) and diffing task state/end-time — if nothing changed, the job is genuinely stalled at whichever task didn't advance; if something changed, it is progressing and should be treated as a slow-job (Purpose A) investigation instead.

Before attributing the failure to workflow logic, check `/health/adapters` and `/health/applications` for the specific adapter/app the stalled or errored task depends on — an OFFLINE adapter or a non-RUNNING application overlapping the stall/error window is a more likely root cause than the workflow itself. For deep adapter diagnosis, hand off to `/troubleshoot-adapters`.

Finally, pull a tight window of logs (e.g., ±5 min around the stall/error timestamp) from the platform, IAG/gateway, MongoDB, and Redis containers/hosts and look for overlapping error signatures across components — this is a fast first-pass correlation; full log collection across VM/Kubernetes/CloudWatch deployments is delegated to `/troubleshoot-logs`.

### Phase 8: Webserver Log
Scan `webserver.log` for slow job-related API calls (> 2000ms on `/operations-manager/jobs`). High `time_starttransfer` = server processing slow (MongoDB query or OM bottleneck).

### Phase 9: Root Cause Correlation
Match findings across layers to identify the single bottleneck layer, using the Purpose A or Purpose B decision matrix as applicable. Produce a causal timeline and decision matrix entry. Save analysis report.

---

## 4. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Follow full causal chain | All layers, stop when root cause found | Bottleneck can be at any layer; partial investigation leads to wrong fixes |
| Task timing breakdown first | Sort slowest tasks before any other check | Narrows which external system is the suspect before DB/metrics checks |
| Read-only DB queries | No MongoDB writes, no Redis writes | Investigation must not alter job state or queue behavior |
| Index recommendations are informational | Share, do not apply without consent | Index builds can be disruptive on large collections |
| Prometheus/Grafana is optional depth | Run only if URL is in `.env` | API-layer evidence is usually sufficient; metrics add confirmation |
| Child job chain is recursive | Follow until leaf | Root cause is often several levels deep |
| Two distinct purposes, one skill | Slow-job (historical comparison) vs. stuck/errored-job (chain + health + logs) share Phases 1–4 but diverge after | Symptoms differ enough to need different evidence, but the underlying execution-chain model is shared |
| Historical comparison uses same-workflow baseline, not a fixed threshold | Pull prior completed runs of the identical workflow name from MongoDB | A fixed "slow" threshold doesn't account for workflows that are inherently long-running; comparing against the workflow's own history is more reliable |
| True-stall verification via double-poll, not single snapshot | Poll twice ~60s apart and diff task state | A single snapshot cannot distinguish "stuck" from "just slow"; only observing state change over time can |
| Adapter/app health checked before blaming workflow logic | Query `/health/adapters` and `/health/applications` and cross-reference with the stalled/errored task | Avoids mis-attributing an external outage to a workflow bug |
| Cross-component log correlation is a fast first pass, not full collection | Grep a tight time window from IAP/IAG/Mongo/Redis logs inline | Deep, multi-deployment-type log collection is `/troubleshoot-logs`'s job; duplicating it here would violate skill boundaries |

---

## 5. Scope

**In scope:** Job duration profiling, task timing breakdown, OM queue depth, WFE worker health and log level, Redis Bull queue depth (wait/active/failed/delayed), MongoDB jobs collection COLLSCAN detection, index analysis, historical baseline comparison against prior runs of the same workflow, concurrent job/task load analysis at the incident window, Prometheus CPU/heap/event-loop/GC metrics, Grafana dashboard discovery, recursive parent-child job error chain traversal, true-stall verification (double-poll task state diff), adapter/application health correlation with the stalled/errored task, first-pass cross-component log correlation (IAP/IAG/MongoDB/Redis) around the incident window, webserver log slow-request analysis.

**Out of scope:** Workflow definition errors (→ `/troubleshoot-workflows`). Deep adapter root-cause diagnosis — auth, sampleProperties, debug logging (→ `/troubleshoot-adapters`). OS/container resource diagnosis (→ `/troubleshoot-infra`). Deep MongoDB/Redis internals (→ `/troubleshoot-databases`). Full multi-deployment-type log collection (→ `/troubleshoot-logs`).

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| MongoDB explain on large collection is slow | Adds latency to investigation | Use `explain('executionStats')` only — does not return documents |
| Redis KEYS command on large keyspace is slow | Blocks Redis briefly | Use sparingly; scope to `bull:*` pattern |
| Prometheus/Grafana unavailable | No process metrics | Note gap; API-layer evidence (OM queue, WFE state) is usually sufficient |
| Child job IDs not in task output | Chain incomplete | Note limitation; ask user to check UI for related jobs |
| COLLSCAN finding triggers urgency to add index | Applying index on live large collection can degrade performance | Always present as recommendation; user and DBA decide timing |
| `blocked_clients` in Redis could be normal | False positive if using BLPOP intentionally | Correlate with queue depth and WFE worker state |
| No historical baseline run exists for the workflow | Cannot diff task timings or concurrency | Note as an investigation gap; recommend establishing a baseline going forward |
| Double-poll for true-stall verification adds ~60s to investigation | Minor delay | Acceptable given it prevents misclassifying a slow job as stuck (or vice versa) |
| Cross-component log grep is a coarse first pass (5-minute window, keyword match) | May miss subtler correlations or return false positives from unrelated errors | Treat findings as a hypothesis to confirm, not a conclusion; escalate to `/troubleshoot-logs` for deeper collection if inconclusive |
| Adapter/app health check only reflects *current* state, not state at incident time (if the outage has since recovered) | May miss a since-resolved adapter outage as root cause | Cross-reference with platform/adapter logs from the incident window (Step 7e) rather than relying on live health alone |

---

## 7. Requirements

### What access is needed

| Credential / Access | Required | If Not Available |
|--------------------|----------|------------------|
| `PLATFORM_URL` + auth credentials in `.env` | Yes | Cannot proceed |
| Job ID or workflow name | Yes (one of them) | Ask the user |
| `MONGO_URL` in `.env` | No | MongoDB layer skipped; note gap |
| `REDIS_HOST` in `.env` | No | Redis layer skipped; note gap |
| `PROMETHEUS_URL` in `.env` | No | Metrics layer skipped; note gap |
| `GRAFANA_URL` in `.env` | No | Dashboard data skipped |
| Docker / kubectl / SSH | For WFE log file size and webserver.log | Skip those sub-steps if unavailable |

### What external systems are involved

| System | Purpose | Required |
|--------|---------|----------|
| IAP Operations Manager API | Job fetch, queue depth | Yes |
| IAP Health API | WFE and OM application state | Yes |
| MongoDB | jobs collection index and COLLSCAN analysis | If MONGO_URL present |
| Redis | Bull queue depth, eviction, blocked clients | If REDIS_HOST present |
| Prometheus | CPU, heap, event loop, GC metrics | If PROMETHEUS_URL present |
| Grafana | Dashboard and panel data | If GRAFANA_URL present |
| Docker / kubectl | WFE log size, webserver.log access | If container/K8s environment |

### Discovery Questions

Ask the user before investigating:

1. Do you have a specific job ID, or should I search by workflow name?
2. Is the job stuck (running but not progressing), errored, or just slow (completes but takes too long)?
3. When did this start? Was it sudden or has it been degrading gradually?
4. How many concurrent users or scheduled jobs are running in this environment?
5. Has anything changed recently — new workflow deployment, job volume spike, infrastructure change?
6. Do you have MongoDB and Redis credentials to add to `.env` for deeper analysis?
7. Is Prometheus or Grafana configured in this environment?
8. (Slow job) Do you know of a prior run of this same workflow that completed normally, to use as a baseline?
9. (Stuck/errored job) Does this job spawn child jobs? If so, do you have visibility into which task calls them?
10. Do you have Docker/SSH access to the IAG, MongoDB, and Redis hosts/containers for log correlation?

---

## 8. Acceptance Criteria

1. Job is fetched and task timing breakdown is produced (sorted slowest first)
2. OM queue depth (running, queued) is measured and stuck jobs > 60 min are flagged
3. WFE application state, worker count, and log level are reported
4. Redis Bull queue depths (wait/active/failed/delayed) are reported if Redis is accessible
5. MongoDB jobs collection index list is retrieved and COLLSCAN risk is assessed if MongoDB accessible
6. Prometheus metrics (CPU, heap, event loop, GC) are queried for the incident window if available
7. Child job IDs are extracted and the full parent-child-grandchild chain is walked recursively for status/errors (not just the immediate child)
8. Webserver log is scanned for slow job-related API calls if Docker/SSH access available
9. Root cause is attributed to a specific bottleneck layer with supporting evidence
10. Index recommendations are presented as informational only, not applied
11. A causal chain timeline and decision matrix are included in the report
12. Analysis report saved to `data/{TIMESTAMP}/job_analysis.md`
13. (Slow job) A historical baseline run of the same workflow is identified and task timings are diffed against it, isolating task-specific regression vs. uniform slowdown
14. (Slow job) Concurrent job/task load at the incident window is measured and compared against the baseline window's load
15. (Stuck/errored job) A true-stall verification (double-poll task state diff) is performed before concluding the job is stuck rather than slow
16. (Stuck/errored job) Adapter and application health are checked and cross-referenced against the stalled/errored task's dependency
17. (Stuck/errored job) A first-pass cross-component log correlation (IAP/IAG/MongoDB/Redis) is performed around the incident window, with overlapping error signatures called out
