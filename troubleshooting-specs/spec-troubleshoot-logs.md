# Troubleshooting Spec: Troubleshoot Logs

## 1. Problem Statement

Log evidence is essential for root-cause analysis and support escalation, but collecting it is ad hoc. Engineers SSH into multiple boxes, grep individual files, and miss correlated errors across components. IAP, IAG, MongoDB, Redis, and load balancers each log in different formats, different locations, and different deployment types (Docker, VM, K8s, CloudWatch). Time-windowing to an incident is manual and error-prone. Sensitive values (tokens, passwords) end up in shared Slack threads.

**Goal:** Collect, filter, and correlate logs from all relevant platform components around a specific incident time — across Docker, SSH/VM, Kubernetes, and CloudWatch — analyze for error patterns, mask sensitive values, and produce a structured artifact package for diagnosis or support escalation.

---

## 2. High-Level Flow

```
Triage      →  Collect       →  Filter       →  Analyze      →  Correlate   →  Report
   │               │                │               │               │              │
   │               │               │               │               │              │
What          IAP app logs,   Window to       Error           Merge all      Per-component
component?    webserver,      incident        patterns,       by timestamp,  findings,
What time?    IAG, mongod,    ±30 min,        slow request    find first     masked
What ID?      Redis, LB       filter by       analysis,       signal and     artifacts,
              logs from       incident        auth failure    propagation    escalation
              Docker/SSH/     identifiers     storms          chain          package
              K8s/CloudWatch
```

---

## 3. Investigation Phases

### Phase 1: Triage — Scope the Collection
Determine: which components are suspect (IAP, IAG, MongoDB, Redis, LB — or all), the incident datetime (date + time + timezone), and any known identifiers (job ID, workflow name, adapter name, service name, error string). Set `INCIDENT_TIME`, `INCIDENT_DATE`, and ±30-minute window. Create `data/{TIMESTAMP}/` artifact directory.

### Phase 2: IAP Application Logs
Discover log paths from `/health/applications` properties. Collect via Docker exec, SSH (all hosts with `SSH_ROLE_N=iap` in parallel), kubectl, or AWS CloudWatch. Filter to incident window and known identifiers. Extract error and warning lines. Save raw and filtered files.

### Phase 3: Webserver Access Log (IAP HTTP)
Collect `webserver.log` (IAP HTTP access log) from Docker, SSH, or kubectl. Filter to incident window. Analyze: HTTP 4xx/5xx error counts by endpoint, slowest requests by response time, top endpoints by volume, auth failure (401/403) storm detection. Flag: 5xx spike, 401 storm, response time > 5s on job endpoints, sudden drop in request count.

### Phase 4: IAG Logs
Collect IAG logs from: IAG container (`docker logs`), IAG internal log file (`/var/log/iag/iag.log`), IAG adapter log inside the IAP platform container, SSH (hosts with `SSH_ROLE_N=iag`), or kubectl. Filter for errors, service/job names, token and auth patterns.

### Phase 5: MongoDB Logs (mongod.log)
Collect `mongod.log` from Docker exec, SSH (hosts with `SSH_ROLE_N=mongodb`, one file per node), or IAP-accessible MongoDB. Discover log path from mongod process args or `/etc/mongod.conf` if standard path is empty. Filter to incident window. Analyze: SLOW_QUERY entries (extract duration, ns, planSummary), connection events (count accepted/ended), replication events (lag, PRIMARY/SECONDARY state changes), errors (severity E/W).

### Phase 6: Redis Logs
Collect Redis log from Docker exec (with docker logs stdout fallback), SSH (hosts with `SSH_ROLE_N=redis`). Analyze: memory and eviction warnings, RDB/AOF persistence events, connection events, slow log entries from `redis-cli SLOWLOG GET`.

### Phase 7: Load Balancer Logs
Detect `LB_TYPE` from `.env` (nginx, haproxy, aws_alb, f5). Collect: nginx/HAProxy via Docker or SSH (hosts with `SSH_ROLE_N=lb`), ALB via S3 download using AWS CLI. Analyze: 5xx responses (upstream IAP errors), 502/504 gateway errors, slow upstream response times, health check failure patterns.

### Phase 8: Cross-Component Correlation
Merge error lines from all collected logs. Sort by timestamp. Identify: which component first showed errors, how the error propagated (e.g., MongoDB slow → IAP slow response → LB 504 → job error), and whether the incident matches a specific request, job ID, or workflow. Build a timeline narrative.

### Phase 9: Sensitive Value Masking
Before displaying or saving any log content: replace tokens, passwords, Bearer headers, and API keys with `[MASKED]` using regex. Show first 6 + last 4 characters only for debugging reference if needed.

### Phase 10: Report and Artifact Package
Save all collected files to `data/{TIMESTAMP}/` with labeled filenames. Save analysis to `data/{TIMESTAMP}/log_report.md`. List all artifacts with file sizes for support escalation.

---

## 4. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Multi-path collection | Docker, SSH, kubectl, CloudWatch | Platform logs are in different places depending on deployment type |
| Parallel SSH collection | Background jobs + wait per role | SSH round-trips across multiple nodes are slow; parallelism is essential |
| Time window filtering | ±30 minutes around incident | Focused collection; avoids gigabytes of unrelated log data |
| Identifier filtering | Job ID, workflow name, adapter name | Narrows signal-to-noise in high-volume log environments |
| Sensitive value masking | Always applied before output | Log sharing (Slack, email, tickets) must not expose credentials |
| Per-component file artifacts | One file per component per node | Preserves ability to diff, grep, and share individual components |
| Correlation by timestamp | Merge and sort all error lines | Multi-component incidents require unified timeline, not isolated views |

---

## 5. Scope

**In scope:** IAP application log collection and error analysis, webserver access log (HTTP status, response time, auth failures), IAG container and internal log collection, mongod.log (slow queries, connection events, replication, errors), Redis log (eviction, persistence, connection), load balancer access log (nginx, HAProxy, ALB), cross-component timestamp correlation, sensitive value masking, artifact packaging for escalation. Deployment types: Docker, SSH/VM multi-host, Kubernetes/EKS, AWS CloudWatch.

**Out of scope:** Real-time log streaming (use `docker logs -f` or `stern` manually). Log rotation management. Log aggregation system configuration (Splunk, ELK, Datadog). Live debugging with gdb or node --inspect. Container image or OS-level crash dump analysis.

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Log files are very large (GB) | Collection is slow or fills local disk | Filter to incident window and line-limit collection; do not copy entire files |
| Log format varies by IAP version | Parsing fails | Detect format (JSON vs combined log) from first 3 lines; handle both |
| SSH host unreachable | No logs from that host | Note unreachable host; continue with remaining sources |
| Docker container stopped | `docker exec` fails | Fall back to `docker logs {CONTAINER}` |
| CloudWatch log group name unknown | ALB/IAP CloudWatch collection fails | Ask user for log group name; do not guess |
| Sensitive values in logs | Credential exposure if shared | Always apply masking before displaying; note masking in report |
| mongod.log path not at default location | Collection produces empty file | Discover path from mongod process args and `/etc/mongod.conf` |

---

## 7. Requirements

### What access is needed

| Credential / Access | Required | If Not Available |
|--------------------|----------|------------------|
| `PLATFORM_URL` + auth credentials in `.env` | For log path discovery | Skip path discovery; use defaults |
| Docker socket access | For Docker-based log collection | Skip Docker phases |
| `SSH_HOST_N` blocks in `.env` | For VM/bare-metal log collection | Skip SSH phases |
| `KUBE_NAMESPACE` + kubectl context | For Kubernetes log collection | Skip K8s phase |
| `AWS_ACCESS_KEY_ID` + `AWS_REGION` | For CloudWatch and ALB S3 logs | Skip AWS phases |
| `LB_S3_BUCKET` / `LB_S3_PREFIX` | For ALB access log collection | Skip ALB phase |
| `IAG_CONTAINER_NAME` or SSH_ROLE_N=iag | For IAG log collection | Skip IAG phase |

### What external systems are involved

| System | Purpose | Required |
|--------|---------|----------|
| IAP Health API | Discover log file paths from app properties | Optional — can use defaults |
| Docker daemon | IAP, IAG, MongoDB, Redis, LB log collection | For Docker environments |
| SSH target hosts | OS-based log collection per role | For VM/bare-metal environments |
| Kubernetes API / kubectl | IAP, IAG pod log collection | For EKS/K8s environments |
| AWS CloudWatch Logs | IAP log groups in CloudWatch | For AWS-managed environments |
| AWS S3 | ALB access log archive | For ALB log analysis |
| redis-cli | Redis slow log (`SLOWLOG GET`) | For Redis slow command analysis |

### Discovery Questions

Ask the user before collecting:

1. Which components are you most interested in? (IAP, IAG, MongoDB, Redis, LB — or all?)
2. What is the incident date and approximate time? Include timezone if known.
3. Do you have a specific job ID, workflow name, adapter name, or error string to filter on?
4. What is the deployment type for each component: Docker, VM/SSH, Kubernetes, or AWS-managed?
5. Do you need logs for a support escalation, or for your own diagnosis?
6. Are SSH keys and host information configured in `.env`?
7. Do you have CloudWatch access or ALB S3 log bucket details for AWS environments?

---

## 8. Acceptance Criteria

1. Incident time and ±30-minute window are established before any collection begins
2. IAP application logs are collected via Docker, SSH, kubectl, or CloudWatch based on available credentials
3. Webserver access log is collected and analyzed: 4xx/5xx counts, slowest endpoints, auth failure counts
4. IAG logs are collected from container, internal log file, and IAP-side adapter log
5. mongod.log is collected (per node for replica sets), slow queries extracted and durations parsed
6. Redis log is collected; eviction, persistence, and connection events are extracted
7. Load balancer access log is collected via appropriate method (Docker/SSH/S3); 5xx and slow response patterns identified
8. All error lines from all sources are merged and sorted by timestamp for correlation
9. A cross-component incident timeline narrative is produced
10. All output displayed to the user has sensitive values (tokens, passwords, Bearer headers) masked
11. All collected files are saved to `data/{TIMESTAMP}/` with labeled filenames
12. A log analysis report is saved to `data/{TIMESTAMP}/log_report.md` with per-component findings and an artifact table
13. Access gaps (missing credentials, unreachable hosts) are listed in the report with remediation steps
