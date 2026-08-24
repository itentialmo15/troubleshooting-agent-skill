# Troubleshooting Agent — Itential Platform Support

A Claude Code skill family for Itential Platform support engineering. Invoke `/troubleshoot ISD-XXXX` to run a structured, multi-phase investigation against a live customer environment — from ticket intake through root-cause analysis, engineering escalation, and resolution capture.

---

## Quick Start

```bash
# Full investigation (orchestrator — all phases)
/troubleshoot ISD-1234

# Triage only — no platform auth needed
/troubleshoot-triage ISD-1234

# List all in-flight investigations
/troubleshoot-triage --list

# Auto-triage without human gates (for scheduled/autonomous use)
/troubleshoot-triage ISD-1234 --auto
```

**Prerequisites:** A `.env` file in the repo root (see [Credentials](#credentials)).

---

## Skill Architecture

One orchestrator delegates Phase 1 to a triage sub-skill, then routes Phase 2 to one of six specialist sub-skills based on symptom classification.

```
/troubleshoot (orchestrator)
  ├── Phase 1 → /troubleshoot-triage
  ├── Phase 2 → specialist sub-skill (auto-routed)
  │     ├── /troubleshoot-workflows   — job errors, JST, childJob chains
  │     ├── /troubleshoot-adapters    — adapter OFFLINE, auth failures
  │     ├── /troubleshoot-jobs        — slow/stuck jobs, baseline comparison
  │     ├── /troubleshoot-databases   — MongoDB, Redis, ElastiCache
  │     ├── /troubleshoot-infra       — CPU/memory/disk, containers, EKS
  │     └── /troubleshoot-logs        — log collection & cross-component correlation
  └── Phases 3–7 → Reproduce, Report, Escalate, Learn, Manager escalation
```

Skills live in `.claude/skills/<name>/SKILL.md`. Each is self-contained with all curl commands, phase instructions, and cleanup steps.

---

## Investigation Lifecycle

| Phase | Name | What happens |
|---|---|---|
| **1** | Ticket Understanding & Triage | Offline only — read ticket, check support status, mine past cases, Confluence search, priority mismatch detection, engineer question list |
| **2** | Symptom Analysis & Routing | Classify symptom → route to specialist sub-skill → inline diagnostics |
| **3** | Reproduce & Workaround | Env selection, platform authentication, builder-skills for fix construction |
| **4** | Diagnostic Report | Findings, evidence, recommended actions. For outage tickets: also produces `outage_summary_report.md` (six-section customer/management-facing report) |
| **5** | Engineering Escalation | ENG ticket draft → engineer approval → file |
| **6** | Resolution Learning | Append to `data/known-resolutions.md` and Section 7 of `product-capability-reference.md` |
| **7** | Manager Escalation | SLA breach or priority mismatch — escalation pack |

Phase 1 is entirely offline (Jira + Confluence + local reference files). No platform authentication until Phase 3.

---

## Investigation Data Layout

Each investigation writes artifacts to a per-ticket timestamped folder:

```
data/
├── <ISO-timestamp>/
│   └── <TICKET-KEY>/               — ISD-XXXX, IPSO-XXXX, or ENG-XXXX
│       ├── ticket_context.md       — ticket snapshot and version notes
│       ├── pre-investigation-summary.md
│       ├── known_issues.md         — matched past cases and ENG bugs
│       ├── confluence_references.md
│       ├── diagnostic_report.md    — Phase 4 findings
│       └── eng_ticket_draft.md     — saved ENG draft if engineer skips filing
├── known-resolutions.md            — accumulated resolution patterns (tracked)
└── product-capability-reference.md — version history, open bugs, behavioral notes (tracked)
```

> `data/<timestamp>/` folders are gitignored — they contain customer PII and log excerpts. Only the static reference files are committed.

---

## Credentials

Create a `.env` file in the repo root (gitignored):

```bash
PLATFORM_URL=https://customer.itential.io
AUTH_METHOD=oauth          # oauth | basic
CLIENT_ID=...
CLIENT_SECRET=...
MONGO_URL=mongodb://...    # optional — direct DB diagnostics
REDIS_HOST=...             # optional
SSH_HOST_1=...             # optional — multi-host SSH
SSH_USER_1=...
SSH_KEY_PATH_1=...
SSH_ROLE_1=iap             # label: iap | mongo | redis | gateway
JIRA_API_TOKEN=...         # Atlassian MCP write operations
```

Auth tokens are cached in `.auth.json` (gitignored) and reused for up to 50 minutes.

---

## IPSO & ENG Tickets

`/troubleshoot-triage` accepts any Jira project prefix:

| Prefix | Flow |
|---|---|
| `ISD-*` | Full customer triage — SLA check, customer question list, priority mismatch detection |
| `IPSO-*` | Engineering triage — reproduction steps, affected code path, affected versions. Offers ENG ticket promotion at the end |
| `ENG-*` | Engineering triage only — no SLA check, no promotion |

---

## Safety Rules

These are enforced both as behavioral rules in the skill files and as Claude Code PreToolUse hooks (`.claude/settings.json`):

- **Read-only platform API** — no PUT/POST/DELETE/PATCH without explicit engineer approval
- **Read-only MongoDB** — no writes, drops, or index creation without approval
- **Read-only Redis** — no SET, DEL, FLUSHDB
- **No restarts without consent** — `docker restart`, `systemctl restart`, `kubectl rollout restart`, `pm2 restart` are all blocked by hook until approved
- **Jira comments = internal only** — all ISD comments use `Service Desk Team` visibility
- **ENG tickets need approval** — draft is always presented before filing, even in `--auto` mode
- **Adapter debug mode** — `auth_logging` must be disabled before ending a session; leaving it on exposes credentials in every log line

---

## Reference Docs

| File | Purpose |
|---|---|
| [`docs/troubleshooting-agent-guide.html`](docs/troubleshooting-agent-guide.html) | Complete HTML guide — Overview, User Guide, Admin Guide, Sub-Skills Reference, Contribution |
| [`docs/troubleshoot-guide.md`](docs/troubleshoot-guide.md) | Markdown quick-reference |
| [`CLAUDE.md`](CLAUDE.md) | Project instructions for Claude Code (architecture, safety rules, data layout) |
| [`data/product-capability-reference.md`](data/product-capability-reference.md) | IAP version history, open bugs, Section 7 behavioral differences |
| [`data/known-resolutions.md`](data/known-resolutions.md) | Accumulated ISD resolution patterns |

---

## Contributing

At the end of each sprint or investigation cadence, open a PR that adds to one or both knowledge files:

- **`data/known-resolutions.md`** — new ISD resolution pattern (symptom → root cause → fix)
- **`data/product-capability-reference.md` Section 7** — version-specific behavioral fact

See the Contribution tab in the HTML guide for the full 10-step PR workflow.

---

## Vendored Builder Skills

The sync pulls two things from upstream:
- **Helper JSON bundles** → `vendor/builder-skills/` (importable asset bundles, create/update templates)
- **Builder skill files** → `.claude/skills/` (`/builder-agent`, `/qa-agent`, `/itential-lcm`, `/explore`, etc.)

Staleness is checked **automatically**:
- **At Phase 3 (Constructive Fix Path)** — before any builder-skill invocation, the orchestrator runs a check and prompts to sync if behind
- **At session end** — a `Stop` hook prints a staleness report if the vendor copy is out of date

To check manually (fast — no clone):
```bash
scripts/sync-builder-skills.sh --check
```

To sync both helpers and skills:
```bash
scripts/sync-builder-skills.sh [branch]
```

If the sync fails (network down, auth error), the script reports the current vendor SHA, date, and commit count before exiting.

After a successful sync: review `git diff vendor/builder-skills/ .claude/skills/` and `vendor/builder-skills/SYNC_CHANGELOG.md` before committing.
