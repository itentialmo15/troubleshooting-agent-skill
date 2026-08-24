# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A Claude Code skill family for Itential Platform support engineering. There is no runnable application, no build system, and no test suite — the "code" is Claude Code skills (SKILL.md files) and supporting reference data. The primary deliverable is the `/troubleshoot` skill invoked directly in Claude Code sessions.

## Skill Architecture

One orchestrator skill delegates to a triage sub-skill (Phase 1) and six specialist diagnostic sub-skills (Phase 2). The orchestrator drives a **3-phase investigation lifecycle** (Phase 1: Ticket Understanding & Triage → Phase 2: Symptom Analysis & Routing → Phase 3: Reproduce & Workaround) followed by four closing phases (Phase 4: Diagnostic Report, Phase 5: Engineering Escalation, Phase 6: Resolution Learning, Phase 7: Manager Escalation). Sub-skills authenticate themselves from `.env` when invoked.

| Skill | Invoke | Covers |
|-------|--------|--------|
| **Orchestrator** | `/troubleshoot ISD-XXXX` | Full investigation lifecycle; delegates Phase 1 to triage sub-skill, Phase 2 to specialist sub-skills |
| **Triage** | `/troubleshoot-triage ISD-XXXX` | Phase 1 triage for ISD, IPSO, and ENG tickets — offline only. Resume check, `--list`, `--auto` mode, IPSO→ENG promotion |
| Adapters | `/troubleshoot-adapters` | Settings comparison, debug mode (auth_logging + console_level), cleanup |
| Workflows | `/troubleshoot-workflows` | Job error analysis, task failures, JST errors, import failures, childJob chains |
| Jobs | `/troubleshoot-jobs` | Stuck/errored jobs, slow-job baseline comparison, parent-child chain traversal |
| Databases | `/troubleshoot-databases` | MongoDB (slow queries, COLLSCAN, replica set), Redis (eviction, Bull queues), ElastiCache |
| Infrastructure | `/troubleshoot-infra` | CPU/memory/disk, containers (OOMKilled), EKS, SSH multi-host, network |
| Logs | `/troubleshoot-logs` | IAP/IAG/MongoDB/Redis/LB log collection and cross-component timestamp correlation |

Skills live in `.claude/skills/<skill-name>/SKILL.md`. Each SKILL.md is self-contained — it includes all curl commands, phase-by-phase instructions, gotchas, and cleanup steps.

## Investigation Data Layout

Each investigation produces per-ticket artifacts under `data/`. Multiple investigations (ISD, IPSO, ENG) can coexist simultaneously — each in its own timestamped folder:

```
data/
├── <ISO-timestamp>/
│   └── <TICKET-KEY>/           — ISD-XXXX, IPSO-XXXX, or ENG-XXXX
│       ├── ticket_context.md       — Jira ticket snapshot and symptom summary
│       ├── pre-investigation-summary.md — Triage output (Phase 1 / troubleshoot-triage)
│       ├── known_issues.md         — Matched past cases and ENG bugs
│       ├── confluence_references.md — KB articles and runbooks found
│       ├── diagnostic_report.md   — Findings, evidence, recommended actions (Phase 4)
│       ├── outage_summary_report.md — Customer/management-facing outage report (Phase 4, outage tickets only)
│       └── eng_ticket_draft.md    — ENG ticket draft saved if engineer declines immediate filing (IPSO only)
├── known-resolutions.md            — Accumulated resolution patterns (append-only)
├── product-capability-reference.md — Platform version history, open bugs, components, version behavioral notes
└── ISD-Triage-Skill-Executive-Brief.md — Business case and case studies
```

The `/troubleshoot-triage` sub-skill checks for an existing folder before creating a new one — if a prior triage exists for the same ticket key, it prompts the engineer to resume or start fresh. Use `/troubleshoot-triage --list` to see all in-flight investigations.

## Credentials and Auth

Each investigation uses a `.env` file (gitignored) in the repo root or working directory:

```
PLATFORM_URL=https://customer.itential.io
AUTH_METHOD=oauth          # oauth | basic
CLIENT_ID=...
CLIENT_SECRET=...
MONGO_URL=mongodb://...    # optional — for direct DB diagnostics
REDIS_HOST=...             # optional
SSH_HOST_1=...             # optional — multi-host SSH pattern
SSH_USER_1=...
SSH_KEY_PATH_1=...
SSH_ROLE_1=...             # label: iap | mongo | redis | gateway
JIRA_API_TOKEN=...         # for Jira MCP write operations
```

Auth tokens are cached in `.auth.json` (gitignored). The orchestrator reuses a token if it is less than 50 minutes old and `platform_url` matches; otherwise it re-authenticates silently.

## Safety Rules (Non-Negotiable)

These apply in every troubleshooting session:

- **Read-only platform API** — no PUT/POST/DELETE/PATCH without explicit engineer approval
- **Read-only MongoDB** — no writes, no `db.dropCollection()`, no index creation without approval
- **Read-only Redis** — no SET, DEL, FLUSHDB
- **Jira comments** — present the draft and wait for explicit approval before posting; all ISD comments must be internal (`commentVisibility: {"type": "role", "value": "Service Desk Team"}`)
- **ENG tickets** — present the bug report draft and wait for approval before filing
- **Adapter debug mode** — always disable `auth_logging` and reset `console_level` to `error` before ending a session; debug mode exposes credentials in logs
- **Adapter PUT** — does not support partial updates; always GET the current settings, modify in-place, then PUT the full body

## Vendor Sync

`vendor/builder-skills/` is a vendored snapshot of workflow-construction helpers from the upstream `itential/builder-skills` repo. These are used in Phase 4 (Reproduce the Issue) to construct Docker-based reproduction environments.

To refresh the vendored copy:

```bash
scripts/sync-builder-skills.sh [branch]
```

After running: review `git diff vendor/builder-skills/` and `vendor/builder-skills/SYNC_CHANGELOG.md`, then commit deliberately. The sync never auto-applies — it surfaces what changed upstream and leaves the commit to you.

## Spec → Skill Relationship

`troubleshooting-specs/spec-troubleshoot-<name>.md` files are design documents that preceded each SKILL.md. The SKILL.md is the authoritative implementation; the spec is historical context for why a phase exists or how a decision was made. When there is a conflict, the SKILL.md wins.

## HTML and PPTX Deliverables

All HTML deliverables use the Itential brand template at `~/.claude/templates/itential-html-template.html`. After editing the template (with `__ICON_B64__` and `__FULL_B64__` tokens intact), render it with:

```bash
python3 ~/.claude/templates/render-itential-html.py <template.html> docs/<output.html>
```

Rendered files go in `docs/`. The render script is stdlib-only (no venv needed).
