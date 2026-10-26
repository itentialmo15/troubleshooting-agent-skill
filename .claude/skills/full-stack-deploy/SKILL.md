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
| `process_exporter` | 9256 | Each host | Tracks `mongod`, `redis-server`, `itential-platform` — confirm the Gateway/NSO process name against live docs, not given in the fetched pages |
| `mongodb_exporter` | 9216 | Connects to the MongoDB replica set | Dedicated read-only monitoring user — never admin credentials |
| `redis_exporter` (data) | 9121 | Each Redis data instance | |
| `redis_exporter` (Sentinel) | 9122 | Redis Sentinel nodes | |
| `job-metrics-exporter` | Unconfirmed | Reads job/task data from MongoDB | Verify port against live docs at execution time |

Install Prometheus (scrape interval 15-30s per docs) targeting every exporter above, and Grafana with Itential's pre-built Platform/Gateway/MongoDB/Redis dashboards — fetch the live docs page during execution to confirm the exact dashboard source rather than guessing at a dashboard ID.

**Continuity with the existing `/prometheus` query skill:** once installed, write `PROMETHEUS_HOST`/`PROMETHEUS_PORT`/`PROMETHEUS_AUTH` into `environments/<env>/CLAUDE.md` — the same location that skill already reads — so it can query the freshly-installed instance immediately with no further setup.

## Step 5 — Consolidated Confirmation

Show one consolidated summary — every component from Step 3 plus the monitoring stack's own footprint from Step 4 — and require a single explicit "yes" before anything billable/compute goes live, matching the consolidated-confirmation convention `/deploy-containers` Step 5c.5 already establishes. Do not add a second, separate prompt just for monitoring.

## Step 6 — Post-Build Summary

Reuse the existing post-build-summary convention from `/deploy-containers` (query actual installed versions, don't trust requested tags) — extended to include every exporter's actual version, Prometheus's and Grafana's actual versions, and the Grafana dashboard URL(s).
