---
name: full-stack-deploy
description: Provision a complete stack on request — Itential Platform plus a gateway/orchestrator component (IAG4, IAG5, or NSO — customer's choice) plus an infrastructure substrate (AWS VMs, Docker-on-VM, local Docker, or Kubernetes — engineer's choice) plus Prometheus/Grafana monitoring with exporters on every component. Composes the existing /themis-aws-deploy, /deploy-containers, and /nso-server skills rather than reimplementing their provisioning logic.
argument-hint: "[iag4|iag5|nso] [aws|docker-vm|docker-local|k8s]"
---

# Full-Stack Deploy

**Owns:** End-to-end orchestration of a full Itential stack — gateway/orchestrator choice, infrastructure substrate choice, routing to the correct existing provisioning skill(s), and installing Prometheus/Grafana monitoring with exporters on every provisioned component.
**Use when:** An engineer needs a complete, monitored environment in one request rather than invoking `/themis-aws-deploy`, `/deploy-containers`, or `/nso-server` separately and wiring up monitoring by hand.

---

## CRITICAL SAFETY RULES

- **Gateway choice (Step 0) and infrastructure choice (Step 1) are always explicit — never assumed or defaulted.** This mirrors every other provisioning-choice convention in this repo (`/deploy-containers` Step 0, `/mock-server`'s Decision Guidance, `/nso-server`'s target/protocol prompts).
- **IAG5 + AWS VMs is an unsupported combination — stop and say so plainly, never silently substitute IAG4 or fail partway through a provision.** `/themis-aws-deploy` has no IAG5 role; this is a real, confirmed gap, not a guess.
- **This skill never bypasses or duplicates an invoked skill's own approval gates.** `/deploy-containers`' Step 3d/5c.5 CPU+memory confirmations, `/themis-aws-deploy`'s own gate, and `/nso-server`'s interactive install-package/NED/protocol prompts all run exactly as they do when invoked directly.
- **Exporter credentials are always a dedicated, read-only monitoring user — never the admin credentials already in `.env`.** `mongodb_exporter` and `redis_exporter` connect with their own minimal-privilege accounts, created fresh as part of Step 4, not reused from the platform's own admin auth.
- **Monitoring install-level specifics not confirmed in the fetched Itential docs (the Gateway/NSO process name for `process_exporter`, the `job-metrics-exporter` port, exact Grafana dashboard source) must be verified against live `docs.itential.com` content at execution time — never guessed or hardcoded as certain.**
- **The monitoring stack's resource footprint is folded into the same consolidated CPU/memory confirmation the rest of the stack already shows — not a separate, bolted-on prompt.**

---

## Step 0 — Gateway/Orchestrator Choice (customer input)

```
Which gateway/orchestrator component does the customer need?
  [1] IAG4
  [2] IAG5
  [3] NSO (Cisco Network Services Orchestrator)
```

## Step 1 — Infrastructure Substrate Choice (engineer input)

```
Where should this stack be provisioned?
  [1] AWS VMs (via /themis-aws-deploy)        — IAG4 only, see compatibility note below
  [2] Docker on a VM (via /deploy-containers)
  [3] Local Docker (via /deploy-containers)
  [4] Kubernetes (via /deploy-containers)
```

**If Step 0 = IAG5 and Step 1 = AWS VMs: stop here.** Tell the engineer plainly: *"`/themis-aws-deploy` doesn't provision IAG5 — pick Docker/K8s for IAG5, or IAG4/NSO for AWS VMs."* Do not substitute IAG4 or continue partway.

## Step 2 — Compatibility-Matrix Routing

| Gateway choice | AWS VMs | Docker-VM / Local Docker / Kubernetes |
|---|---|---|
| IAG4 | `/themis-aws-deploy` (provisions IAP+MongoDB+Redis+IAG4 as one topology) | `/deploy-containers` with `GATEWAY4_ENABLED` (Docker) or the `iag4` Helm release (K8s) |
| IAG5 | Unsupported — already stopped at Step 1 | `/deploy-containers` with `GATEWAY5_ENABLED` (Docker) or the `iag5` Helm release (K8s) |
| NSO | `/themis-aws-deploy` for IAP+MongoDB+Redis (no gateway component), **then** `/nso-server` targeting the newly-created Themis VM | `/deploy-containers` for IAP (no gateway component), **then** `/nso-server` targeting an existing host or a local install |

## Step 3 — Provision IAP + Gateway/NSO

Invoke the matched skill(s) from Step 2's table, in sequence where two are listed. Let each invoked skill run its own flow in full — including its own approval gates — rather than short-circuiting or pre-answering its prompts.

## Step 4 — Install Monitoring (Prometheus + Grafana + Exporters)

Ask the engineer where Prometheus and Grafana should run — the Platform node itself for lightweight dev/test, or a dedicated monitoring host/VM. Never assume.

**Exporters** (confirmed via `docs.itential.com/itential-platform/monitor/exporters`):

| Exporter | Port | Runs on | Notes |
|---|---|---|---|
| `node_exporter` | 9100 | Every Linux host (Platform, Gateway/NSO, MongoDB, Redis, Sentinel) | |
| `process_exporter` | 9256 | Each host | Tracks `mongod`, `redis-server`, and the `Pronghorn …` platform process groups (see Step 4a) — confirm the Gateway/NSO process name against live docs, not given in the fetched pages |
| `mongodb_exporter` | 9216 | Connects to the MongoDB replica set | Dedicated read-only monitoring user — never admin credentials |
| `redis_exporter` (data) | 9121 | Each Redis data instance | |
| `redis_exporter` (Sentinel) | 9122 | Redis Sentinel nodes | |
| `job-metrics-exporter` | Unconfirmed | Reads job/task data from MongoDB | Verify port against live docs at execution time |

Install Prometheus (scrape interval 15-30s per docs) targeting every exporter above, and Grafana with Itential's pre-built Platform/Gateway/MongoDB/Redis dashboards — fetch the live docs page during execution to confirm the exact dashboard source rather than guessing at a dashboard ID.

### Step 4a — Dashboard install is mandatory, and data must actually render

Installing Grafana without the **Itential Platform Monitoring** dashboard (uid `iap-platform-monitoring`, tabs Overview / Workflow Engine / Platform Process / Redis / MongoDB) is not a complete Step 4. Provision it as code — Grafana file provisioning for the Prometheus datasource *and* the dashboard — never a manual console import. The dashboard JSON is bundled at `references/local-docker-monitoring/dashboards/iap-platform-monitoring.json`; a ready local-Docker compose/Prometheus/process-exporter/Grafana set is in `references/local-docker-monitoring/` (copy to `~/itential-dev-stack/monitoring/`, then `docker compose -f docker-compose.yml -f monitoring/docker-compose.monitoring.yml --profile monitoring up -d --no-deps <services>`).

**Variables this step configures automatically** (the engineer is not asked to hand-edit config; show the resolved values in the Step 5 confirmation):

| Variable | Where it lands | How it is chosen |
|---|---|---|
| Host label per node (`HOST_LABEL`) | `relabel_configs` `instance` replacement for `iap_exporter`, `node_exporter`, `process_exporter` (`<label>:<port>`) | Single-host Docker: `iap-local`. VMs/K8s: each node's real hostname — one label shared by that node's platform, node and process targets. MongoDB/Redis targets get their own host labels |
| Platform scrape target + scheme/path | `iap_exporter` job (`https`, `/prometheus_metrics`, `insecure_skip_verify` only for the self-signed dev-stack cert; add `basic_auth` on secured endpoints) | From the provisioned platform host/port |
| Exporter targets | `node_exporter` 9100, `process_exporter` 9256, `mongodb_exporter` 9216, `redis_exporter` 9121, `job_metrics_exporter` 9477 | From the provisioned topology (one target per node) |
| Mongo replica set name + job-metrics URI | mongod `--replSet rs0`, `ITENTIAL_JOB_METRIC_MONGO_URI=…?replicaSet=rs0` | `rs0` default; reuse the existing name on a Themis/HA replica set |
| `MONGO_PORT` | dev-stack `.env` | Default 27017; auto-bumped to 27018 if the host port is taken (check with `lsof -nP -iTCP:27017 -sTCP:LISTEN`) |
| Grafana datasource + dashboard providers | `grafana-datasource.yml`, `grafana-dashboards.yml`, `dashboards/*.json` mounted under `/etc/grafana/provisioning/` and `/var/lib/grafana/dashboards` | Fixed; datasource is the default Prometheus |

Treat every `reference` file as a template: substitute these values rather than copying the local-Docker values verbatim onto another topology.

The dashboard's PromQL is hardcoded, so the Prometheus/exporter config must match it or every tab reads "No data":

| Dashboard expects | Config requirement |
|---|---|
| `job="iap_exporter"` / `node_exporter` / `redis_exporter` (and `process_exporter`, `mongodb_exporter` by convention) | Name the Prometheus scrape jobs exactly these — not `itential-platform`, `node`, `redis` |
| `instance=~"$node(:.*)?"` where `$node` comes from `node_cpu_seconds_total`'s instance (port stripped) | Every target on one host (platform `/prometheus_metrics`, node_exporter, process_exporter) must share the same host part of `instance`. On single-host Docker, relabel `instance` to one name (e.g. `iap-local:<port>`); on multi-node VMs use the node's real hostname for all three exporters |
| `namedprocess_namegroup_*{groupname=~"Pronghorn.* Application"}`, `"Pronghorn.* Adapter"`, `"Pronghorn.*"` | process_exporter groups named `Pronghorn Core`, `Pronghorn <name> Application`, `Pronghorn <name> Adapter` (adapters = `@itential/adapter-*` ServiceBootstrap workers, listed *before* the application rule; Core matched by `comm: Pronghorn core`, not cmdline, because cmdline matching does not match argv[0] and would also catch the tini PID 1) |
| `itential_up`, `itential_job_*`, `itential_task_*`, `itential_watcher_reconnects_total`, `itential_job_status_total` (Overview WFE/Job Error Rate/Task Throughput tiles and the Workflow Engine tab) | Itential's public **job-metrics-exporter** (`github.com/itential/job-metrics-exporter`, image `ghcr.io/itential/job-metrics-exporter:v1.0.1`, multi-arch, port **9477**, path `/metrics`; GPL-3.0). Run it with `ITENTIAL_JOB_METRIC_MONGO_URI=mongodb://<mongo>/itential?replicaSet=rs0` and `ITENTIAL_JOB_METRIC_CHANGE_STREAM_ENABLED=true`, scrape it as job `job_metrics_exporter`. Change streams need a replica set. On VMs use a dedicated read-only Mongo user (`read` on `itential`), never admin. It also needs index `{status:1,"metrics.server_id":1}` named `itential_job_metrics_exporter_task_status_server` on `tasks` (a one-time DB write — state it to the engineer) |
| `mongodb_rs_members_*` (MongoDB Overview tile, Cluster Members, Replica Set Status, Replication Lag) | MongoDB running as a replica set. On the dev-stack, override the `mongodb` service with `--replSet rs0 --bind_ip_all` and run `rs.initiate({_id:"rs0",members:[{_id:0,host:"mongodb:27017"}]})` — this restarts Mongo, so get engineer approval for an already-running stack. Data in the bind mount is preserved. A single node has no SECONDARY, so **Replication Lag stays empty by design** |
| Host port 27017 already taken (e.g. a Homebrew `mongod`) | Never kill the host process; set `MONGO_PORT=27018` in the dev-stack `.env` (container-to-container traffic is unaffected) |

**Expected-empty panels until events occur:** the `itential_task_*` counters (Task Start vs Complete, Task Distribution by Server, Total Tasks, Task Error Rate, Total Task Throughput) have no series until the first task runs after the exporter starts. Run (with engineer approval) any workflow job, or say these will populate on first job — do not report them as broken.

**Verification gate (required before Step 6):** extract every panel `expr` from the provisioned dashboard JSON, substitute `$node` with the instance host, evaluate each against Prometheus, and list any panel returning no series with its cause from the table above. Classify each remaining empty panel as *fixable*, *needs a first job event*, or *topology limit* (e.g. Replication Lag on a single node) and report plainly; do not declare the dashboard working while panels are silently empty.

**Continuity with the existing `/prometheus` query skill:** once installed, write `PROMETHEUS_HOST`/`PROMETHEUS_PORT`/`PROMETHEUS_AUTH` into `environments/<env>/CLAUDE.md` — the same location that skill already reads — so it can query the freshly-installed instance immediately with no further setup.

## Step 5 — Consolidated Confirmation

Show one consolidated summary — every component from Step 3 plus the monitoring stack's own footprint from Step 4 — and require a single explicit "yes" before anything billable/compute goes live, matching the consolidated-confirmation convention `/deploy-containers` Step 5c.5 already establishes. Do not add a second, separate prompt just for monitoring.

## Step 6 — Post-Build Summary

Reuse the existing post-build-summary convention from `/deploy-containers` (query actual installed versions, don't trust requested tags) — extended to include every exporter's actual version, Prometheus's and Grafana's actual versions, and the Grafana dashboard URL(s).
