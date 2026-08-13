# Troubleshooting Spec: Troubleshoot Databases

## 1. Problem Statement

MongoDB and Redis are critical dependencies of the Itential Platform. MongoDB stores all job state, workflow definitions, and adapter configurations. Redis backs the Bull job queue and session cache. Database-level issues — missing indexes, connection pool saturation, replica set lag, Redis eviction, Bull queue stalls — directly cause slow jobs, stuck jobs, and platform errors, but are invisible from the IAP API alone.

**Goal:** Provide deep, read-only diagnostics of MongoDB and Redis (including ElastiCache) — covering connectivity, connection pool health, slow queries, index gaps, replica set state, Bull queue depth, eviction policy, and persistence state — and deliver actionable findings with index/configuration recommendations.

---

## 2. High-Level Flow

```
MongoDB                                    Redis
  │                                          │
  ├─ Connectivity ping                       ├─ Connectivity ping
  ├─ Server status (connections, opcounters) ├─ Memory + eviction
  ├─ Replica set health                      ├─ Client stats (blocked)
  ├─ Current slow operations                 ├─ Bull queue depth (wait/active/failed)
  ├─ Collection sizes                        ├─ Replication status
  ├─ Jobs collection index analysis          ├─ Slow command log
  ├─ COLLSCAN detection on jobs queries      ├─ Persistence state (RDB/AOF)
  ├─ Slow query profiler (if enabled)        └─ Log analysis
  └─ Log analysis (mongod.log)
                          │
                          ▼
                     DB Report
```

---

## 3. Investigation Phases

### Phase 1: MongoDB Connectivity
Ping MongoDB via `db.adminCommand({ping:1})`. If this fails, check MONGO_URL format, network reachability, and auth. All subsequent phases depend on this succeeding.

### Phase 2: MongoDB Server Status
Run `db.adminCommand({serverStatus:1})`. Extract: `connections.current`, `connections.available`, connection pool utilization %. Extract `opcounters`: query, insert, update, delete rates. Extract `mem.resident`. Flag: pool > 80% used.

### Phase 3: Replica Set Health
Run `rs.status()`. For each member: name, stateStr, health, replication lag (optimeDate delta). Flag: health ≠ 1, lag > 10s, any member in RECOVERING state. Standalone MongoDB will return an error — note it and continue.

### Phase 4: Current Slow Operations
Run `db.adminCommand({currentOp: true, secs_running: {$gt: 2}})`. List any operations with `secs_running > 2`. For each: ns, op, command snippet, planSummary. If any operation has `secs_running > 30`, flag as potentially blocking other operations.

### Phase 5: Collection Sizes
Count documents in: `jobs`, `workflows`, `operations`, `adapters`, `tasks`, `users`, `sessions`, `transformations`. Flag `jobs` > 500k — high document count with no index = catastrophic scan performance.

### Phase 6: Jobs Collection Index Analysis
List all indexes on the `jobs` collection. Run `db.jobs.find({status:'running'}).explain('executionStats')`. Check `winningPlan.stage`: if `COLLSCAN`, flag as critical — every job-status query scans all documents. Report docs examined, keys examined, execution time. Suggest indexes: `{status:1}`, `{name:1, status:1}`, `{start_time:-1}` — informational only, not applied without consent.

### Phase 7: Slow Query Profile
Read `db.getProfilingStatus()`. If profiling is at level >= 1, query `system.profile` for queries with `millis > 100`, sorted by `ts` descending. Do NOT enable profiling — that is a DBA decision.

### Phase 8: Redis Connectivity
PING Redis. If unreachable, check REDIS_HOST, port, password, and network. All subsequent Redis phases depend on this.

### Phase 9: Redis Memory and Eviction
Run `INFO memory`: `used_memory_human`, `maxmemory_human`, `maxmemory_policy`, `mem_fragmentation_ratio`, `evicted_keys`. Flag: `used_memory` near `maxmemory`, `evicted_keys > 0` (queue items may have been lost), `mem_fragmentation_ratio > 1.5`.

### Phase 10: Redis Client and Replication
Run `INFO clients`: `connected_clients`, `blocked_clients`, `maxclients`. Run `INFO replication`: role, connected_slaves, replication lag. Flag: `blocked_clients > 0` (Bull worker BLPOP stall), lag > 1s.

### Phase 11: Bull Queue Depth
List all `bull:*` keys. For each queue: LLEN wait, LLEN active, ZCARD failed, ZCARD delayed. Flag: wait > 100 (backlog), failed growing (silent task failures).

### Phase 12: Redis Persistence State
Run `INFO persistence`: `rdb_last_bgsave_status`, `aof_last_write_status`, `aof_last_rewrite_time_sec`. Flag: any status = err (disk full or I/O error), AOF rewrite > 60s.

### Phase 13: Redis Slow Log
Run `SLOWLOG GET 20`. Report entries > 10ms — slow LLEN/ZADD/LRANGE on Bull queues indicates queue operation latency.

### Phase 14: Log Analysis
Collect and analyze `mongod.log` (slow queries, connection events, replication lag) and Redis log (eviction, persistence, connection storms) around the incident time window.

---

## 4. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Read-only throughout | No writes, no index creation, no configuration changes | Investigation cannot alter database state |
| Use secondary MongoDB for reads | `readPreference=secondary` in MONGO_URL | Avoids impacting the primary under load |
| Do not enable MongoDB profiling | Read `system.profile` only if already enabled | Profiling has overhead; enabling is a DBA decision |
| Index recommendations are informational | Present, do not apply | Index builds on large collections can be disruptive |
| COLLSCAN detection is highest priority | Run explain on jobs query first | COLLSCAN on jobs collection is the most common DB root cause |
| Bull queue depth is Redis-layer indicator | Check all `bull:*` keys | Tells whether the problem is queue backlog vs. Redis memory |
| ElastiCache handled via CloudWatch | AWS CLI, not direct Redis commands | ElastiCache may have auth/network restrictions; CloudWatch is always accessible with AWS credentials |

---

## 5. Scope

**In scope:** MongoDB connectivity, server status (connections, opcounters, memory), replica set health and lag, current slow operations, collection document counts, jobs collection index analysis and COLLSCAN detection, slow query profiler read (if enabled), Redis connectivity, memory and eviction, client stats, Bull queue depth, replication, slow log, persistence state, mongod.log analysis, Redis log analysis, ElastiCache CloudWatch metrics.

**Out of scope:** OS-level disk and memory diagnostics for the MongoDB/Redis hosts (→ `/troubleshoot-infra`). Bull queue depth in context of WFE performance (→ `/troubleshoot-jobs` for that correlation). Kafka diagnostics (→ `/troubleshoot-kafka`). Index creation and application (requires DBA consent and planned window).

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `explain('executionStats')` on large collection | Extra load on MongoDB | `explain` does not return documents; overhead is low |
| `KEYS "bull:*"` on large Redis keyspace | Blocks Redis briefly | Pattern-scoped KEYS is acceptable for one-time investigation; note risk |
| Slow query profiler not enabled | Cannot see historical slow queries | Note gap; do not enable — suggest DBA enables with appropriate slow threshold |
| Replica set member unreachable | `rs.status()` shows degraded cluster | Report member state; note if quorum is at risk |
| ElastiCache does not support all INFO commands | Some Redis INFO fields unavailable | Use CloudWatch as primary for ElastiCache; INFO as secondary if reachable |
| COLLSCAN finding triggers urgency | User wants to add index immediately | Always confirm maintenance window; index builds on large collections block writes |

---

## 7. Requirements

### What access is needed

| Credential / Access | Required | If Not Available |
|--------------------|----------|------------------|
| `MONGO_URL` in `.env` | For all MongoDB phases | Skip MongoDB phases; note gap |
| `REDIS_HOST` in `.env` | For all Redis phases | Skip Redis phases; note gap |
| `mongosh` installed | For MongoDB queries | Try `mongo` as fallback; note if neither available |
| `redis-cli` installed | For Redis queries | Note if unavailable |
| Docker access | For mongod.log and Redis log collection | Use SSH fallback if available |
| SSH targets (role `mongodb`, `redis`) | For VM-based log collection | Skip log analysis if unavailable |
| `AWS_ACCESS_KEY_ID` + `AWS_REGION` | For ElastiCache CloudWatch | Skip ElastiCache phase |

### What external systems are involved

| System | Purpose | Required |
|--------|---------|----------|
| MongoDB | All MongoDB diagnostic phases | If MONGO_URL present |
| Redis | All Redis diagnostic phases | If REDIS_HOST present |
| Docker / SSH | mongod.log and Redis log collection | For log analysis phases |
| AWS CloudWatch | ElastiCache cluster metrics | If AWS credentials and ElastiCache present |

### Discovery Questions

Ask the user before investigating:

1. Is the issue MongoDB-specific, Redis-specific, or both? Or is it unclear?
2. Do you have MongoDB and Redis credentials configured in `.env`?
3. Is MongoDB standalone or a replica set?
4. Is Redis standalone, Sentinel, or AWS ElastiCache?
5. Are there known slow workflows or high job volume that coincide with the issue?
6. Has there been a recent increase in job count or workflow deployment?
7. Do you know the approximate time the performance degradation started?

---

## 8. Acceptance Criteria

1. MongoDB connectivity is confirmed; failure is reported with diagnosis guidance
2. Server status (connections, connection pool %, opcounters) is extracted and flagged
3. Replica set member health and replication lag are reported; standalone MongoDB noted
4. Current slow operations (> 2s) are listed with ns, op, and planSummary
5. Key IAP collection document counts are reported; jobs > 500k is flagged
6. Jobs collection indexes are listed; COLLSCAN on `{status:'running'}` is detected and flagged critical
7. Index recommendations are presented clearly as informational — not applied
8. Slow query profiler results are read if profiling is enabled; enabling is not triggered
9. Redis connectivity is confirmed; failure is reported with diagnosis guidance
10. Redis memory, eviction (including evicted_keys > 0), and fragmentation ratio are reported
11. Bull queue depths (wait/active/failed/delayed) are reported for all `bull:*` queues
12. Redis persistence state (RDB/AOF status) is reported; errors are flagged
13. Redis slow log entries are reported
14. mongod.log and Redis log are collected and analyzed for incident window if accessible
15. Database diagnostic report saved to `data/{TIMESTAMP}/database_report.md`
