# Troubleshooting Spec: Troubleshoot Infrastructure

## 1. Problem Statement

Infrastructure failures — disk full, OOMKilled containers, CPU saturation, inter-container network partitions, EKS node pressure — manifest as IAP platform errors that look like application bugs. Engineers spend time debugging IAP when the real cause is the host. There is no consistent process for OS-level, container-level, and cloud-managed service diagnostics across Docker, VM/SSH, EKS, and ElastiCache environments.

**Goal:** Diagnose CPU, memory, disk, file descriptor, network, and container health across all IAP platform dependencies — IAP, IAG, MongoDB, Redis, Kafka, load balancers — regardless of deployment type (Docker, VM, Kubernetes, or AWS-managed).

---

## 2. High-Level Flow

```
Containers   →  Disk      →  CPU/Memory  →  File Desc  →  Network   →  SSH Hosts  →  EKS/Cloud  →  Report
    │              │              │              │              │             │              │            │
    │              │              │              │              │             │              │            │
 docker ps,     df -h,         uptime,       /proc/*/fd,   nc -zv,      Per-host      kubectl top,  Per-component
 docker stats,  docker du,     docker        FD limit      docker        OS cmd        ElastiCache   red/yellow/
 restart count  log dir size   stats,        per process   network       sweep via     CloudWatch,   green table
 OOMKilled                     top procs     utilization   inspect       SSH in        EKS node
                                                                          parallel     conditions
```

---

## 3. Investigation Phases

### Phase 1: Container Overview (Docker)
List all containers with `docker ps -a`. Identify non-running Itential containers. Take a `docker stats` snapshot: CPU%, memory used/limit%, net I/O, block I/O. Check each container for OOMKilled flag and restart count via `docker inspect`. Pull last 100 log lines from any crash-looping container and filter for fatal/error/OOM patterns.

### Phase 2: Disk Usage
Check host filesystem with `df -h`. Check Docker-specific disk with `docker system df`. Find largest directories in Itential volume mounts (`/var/log/itential`, `/data/db`). Find large log files inside the platform container. Flag: root filesystem > 85%, log directory > 1 GB, MongoDB data directory growing unusually.

### Phase 3: CPU and Load Average
Check host `uptime` for load average. Compare against `nproc` (CPU count) — load > cores = saturated. List top processes by CPU. Get per-container CPU% via `docker stats`. Inside the platform container, list Node.js processes sorted by CPU.

### Phase 4: Memory (RAM)
Check host `free -h`. List top processes by memory. Check container memory limits from `docker inspect`. Check OOMKilled flag on all Itential containers. Flag any container without a memory limit (unlimited = OOM risk).

### Phase 5: Open File Descriptors
Check current open FDs vs max limit for the IAP Node.js process and mongod process inside their containers. Check system-wide FD usage from `/proc/sys/fs/file-nr`. Flag: current FDs > 80% of limit.

### Phase 6: Network Connectivity
From inside the platform container, test TCP reachability to MongoDB, Redis, and Kafka. Inspect container network membership — verify all Itential containers are on the same Docker network. Check for containers not on the expected network. Check TLS cert validity and expiry on the IAP HTTPS endpoint.

### Phase 7: OS Diagnostics — Multi-Host SSH
Parse all `SSH_HOST_N` blocks from `.env`. Run OS diagnostics on each host in parallel: uptime/load, CPU count, free memory, disk, top processes by CPU and memory, open FDs, listening ports, OOM kernel events, systemd failed units. Save per-host output to `data/{TIMESTAMP}/os_{role}_{label}.txt`. Run role-specific checks: IAP nodes (Node.js process, Itential service, log dir size), MongoDB nodes (mongod process, data dir size, service status), Redis nodes (redis-server, memory summary), IAG nodes (iag process, logs).

### Phase 8: EKS / Kubernetes
If `KUBE_NAMESPACE` is in `.env`: get pod status for all pods in the namespace, flag non-Running pods, check `kubectl top nodes` and `kubectl top pods`, describe pods for OOMKilled/CrashLoopBackOff events, check node conditions for `MemoryPressure`, `DiskPressure`, `PIDPressure`, and recent namespace events.

### Phase 9: AWS ElastiCache
If `AWS_ACCESS_KEY_ID` is in `.env` and Redis is ElastiCache: describe cache clusters for status, query CloudWatch for FreeableMemory, Evictions, CurrConnections, CacheHits, CacheMisses over the incident window.

### Phase 10: API Performance Baseline
Time 3 samples of key IAP UI-facing endpoints. Flag any endpoint > 2s. For slow endpoints, run detailed curl timing breakdown (dns, connect, ssl, ttfb, total) to identify where latency is introduced.

---

## 4. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Read-only diagnostics | No restarts, no file deletion, no prune | Investigation must not alter infrastructure state |
| Parallel SSH for multi-host | Background jobs + wait | SSH round-trips are slow; parallelism makes fleet-scale practical |
| Role-specific SSH checks | Filter by SSH_ROLE_N | Different component types need different diagnostics |
| Docker stats snapshot (not stream) | `--no-stream` | Single point-in-time; doesn't block the terminal |
| EKS and ElastiCache as optional depth | Run only if credentials present | Handles both on-prem Docker and cloud deployments in one skill |
| Confirm before destructive suggestions | Any `prune`, `rm`, or `restart` requires user consent | Infra changes can cause outages |

---

## 5. Scope

**In scope:** Docker container status, resource usage (CPU/memory/disk/network/block I/O), OOMKilled and restart detection, disk usage (host and containers), CPU load average, memory usage (host and containers), open file descriptor limits, inter-container network connectivity, TLS cert validity, multi-host SSH OS diagnostics (parallel), EKS pod and node health, ElastiCache CloudWatch metrics, API latency baseline.

**Out of scope:** MongoDB slow query and index analysis (→ `/troubleshoot-databases`). Redis Bull queue depth analysis (→ `/troubleshoot-databases`). IAG service execution failures (→ `/troubleshoot-iag`). Log file analysis (→ `/troubleshoot-logs`). Kafka consumer lag (→ `/troubleshoot-kafka`). Adapter configuration errors (→ `/troubleshoot-adapters`).

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| SSH host unreachable | No OS data for that host | Note unreachable hosts; continue with remaining hosts |
| `docker exec` fails (container stopped) | Cannot inspect container internals | Use `docker logs` and `docker inspect` from the host instead |
| `kubectl top` requires metrics-server | Fails if metrics-server not deployed | Note gap; fall back to pod describe and events |
| FD check inside container requires process to exist | Fails if PID not found | Catch and skip; note in report |
| ElastiCache CloudWatch has data lag (1-5 min) | Metrics may not reflect real-time state | Note lag; use for trend analysis, not real-time monitoring |
| `docker system prune` suggested but user runs it prematurely | Removes valid cached layers | Never suggest `prune` in investigation; only mention with explicit consent context |

---

## 7. Requirements

### What access is needed

| Credential / Access | Required | If Not Available |
|--------------------|----------|------------------|
| `PLATFORM_URL` + auth credentials in `.env` | Yes | Cannot proceed |
| Docker socket access | For Docker-based environments | Skip Docker phases |
| `SSH_HOST_N` blocks in `.env` | For VM/bare-metal environments | Skip SSH phases |
| `KUBE_NAMESPACE` + kubectl context | For EKS/K8s environments | Skip EKS phase |
| `AWS_ACCESS_KEY_ID` + `AWS_REGION` | For ElastiCache CloudWatch | Skip ElastiCache phase |

### What external systems are involved

| System | Purpose | Required |
|--------|---------|----------|
| Docker daemon | Container status, stats, inspect, exec | For Docker environments |
| SSH target hosts | OS-level diagnostics (CPU, disk, memory, FDs) | For VM/bare-metal |
| Kubernetes API / kubectl | Pod status, node health, events | For EKS/K8s |
| AWS CloudWatch | ElastiCache metrics | For ElastiCache environments |
| OpenSSL | TLS cert validity check on IAP endpoint | Read-only |

### Discovery Questions

Ask the user before investigating:

1. What is the deployment type: Docker, VM/bare-metal, Kubernetes/EKS, or hybrid?
2. Which component is the primary suspect: IAP container, MongoDB, Redis, IAG, or the host itself?
3. What is the symptom: OOMKilled, disk full, high CPU, network unreachable, slow API, or container not starting?
4. Do you have SSH access to the VMs? Are the SSH keys configured in `.env`?
5. Is this environment on AWS (EKS, ElastiCache)? Do you have AWS CLI credentials available?
6. What is the incident time? (for filtering OOM kernel events and CloudWatch metrics)

---

## 8. Acceptance Criteria

1. All Itential Docker containers are listed with status, restart count, OOMKilled flag, and resource usage
2. Disk usage is checked at host level, Docker system level, and inside containers for log directories
3. CPU load average is compared against CPU count and flagged if saturated
4. Memory usage is checked at host and container level; OOMKilled containers are flagged
5. Open file descriptor usage vs limits is reported for IAP and MongoDB processes
6. Inter-container TCP connectivity is verified from inside the platform container
7. SSH targets from `.env` are discovered and OS diagnostics run in parallel; per-host artifacts saved
8. EKS pod status, node conditions, and events are reported if `KUBE_NAMESPACE` is present
9. ElastiCache CloudWatch metrics are retrieved if AWS credentials are present
10. API latency baseline (3-sample, 3-endpoint minimum) is measured and slow endpoints flagged
11. Per-component findings are saved to `data/{TIMESTAMP}/` with role-labeled filenames
12. A summary table with per-component status is printed before the report file is written
