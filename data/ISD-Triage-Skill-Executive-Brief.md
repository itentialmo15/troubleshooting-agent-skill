# ISD Triage Agent — Executive Brief

**July 2026 | Itential Support Engineering**

---

## What It Is

The ISD Triage Agent is an AI-powered support engineering skill that automates the investigation lifecycle for Itential Service Desk tickets — from the moment a ticket opens to the moment the root cause is confirmed, escalated, or resolved. It operates as a senior support engineer: reading tickets, pulling platform data, cross-referencing known issues, and producing structured findings — without manual research steps.

---

## The Problem It Solves

Support engineers today spend significant time on repetitive triage work: reading tickets, searching past cases, pulling platform logs, and writing up findings. This is slow, inconsistent across engineers, and leaves institutional knowledge locked in individual heads or buried in resolved ticket comments. High-severity cases compound the problem — SLA pressure meets the highest diagnostic complexity.

---

## How It Works

An engineer types a single command — `/troubleshoot ISD-9298` — and the agent executes an eight-phase lifecycle:

| Phase | What happens | Time saved |
|-------|-------------|------------|
| **Ticket Intake** | Reads the full ISD ticket, extracts structured context (version, deployment, error, attachments, blueprint field), detects priority mismatches | 15–20 min |
| **Known Issue Mining** | Searches ISD and ENG Jira for similar past tickets; extracts root-cause comments as diagnostic hypotheses | 20–30 min |
| **Confluence Search** | Finds KB articles, runbooks, and post-mortems matching the symptom | 10–15 min |
| **Platform Investigation** | Authenticates to the customer environment; runs targeted diagnostics via specialist sub-agents (workflows, adapters, jobs, databases, infra, logs) | 30–90 min |
| **Diagnostic Report** | Produces a structured report: findings, root cause hypotheses ranked by likelihood, next steps with owners, access gaps | 30–45 min |
| **Engineering Escalation** | When a platform bug is confirmed, drafts the ENG bug report and links it to the ISD ticket — awaiting engineer approval before filing | 30–60 min |
| **Resolution Learning** | On resolution, records the symptom-to-fix pattern in a shared resolution library for future cases | 10–15 min |
| **Manager Escalation** | Detects SLA risk, priority mismatches, and S1/S2 events; drafts Slack escalation messages to management | 5–10 min |

All Jira writes (comments, ticket creation, links, transitions) require explicit engineer approval before execution. The agent collects evidence and presents drafts — the engineer decides what gets posted.

---

## What It Investigated This Week

Three ISD tickets were triaged using the agent this week, demonstrating the range of issue types it handles:

**ISD-9298 — Virgin Media O2 | IAG5 Python SSL (S3)**
Root cause identified in Phase 0 without touching the customer environment: the IAG5 runner has no dedicated CA cert field for private GitLab HTTPS access. Resolution paths documented (SSH auth, OpenShift ConfigMap + env vars, OS CA bundle). Questionnaire drafted for customer.

**ISD-9284 — FIS Global | Cloud Production Outage (S1)**
Agent surfaced that a Fortinet firewall device was producing 200MB+ payloads in MongoDB's `job_data` collection — a device type not present in the DEV environment. Fix applied: `app-templateBuilder` timeout raised to 30s; architectural recommendation issued to move Fortinet backups to IAG5 Python/Ansible outside ConfigMgr.

**ISD-9248 — Gamma Communications | IAG5 runCode Security (Critical)**
Customer demonstrated SSH private key exfiltration via `runCode`. Agent identified this as by-design behavior (per the approved engineering HLD, Section 3.6), not a platform bug. Surfaced a parallel open ticket (ISD-9305) from a second customer raising the same concern. Produced a tiered mitigation plan (immediate OS controls, container hardening, product roadmap items) for the June 30 follow-up call.

---

## Impact

| Metric | Manual | With Agent |
|--------|--------|------------|
| Time to structured ticket context | 20–30 min | < 2 min |
| Time to known-issue cross-reference | 30–60 min | < 3 min |
| Time to pre-investigation hypothesis | 60–90 min | < 10 min |
| Consistency across engineers | Variable | Standardized |
| Resolution patterns captured | Ad hoc | Persistent library |

---

## Guardrails

The agent is read-only by default. It never posts Jira comments, files ENG tickets, sends Slack messages, restarts services, or writes to MongoDB/Redis without the engineer reviewing and explicitly approving the action. Every customer-facing action is a draft first.

---

## Current State and Next Steps

The skill is in active use by the support engineering team. Immediate next investments:

- **RBAC + visibility controls** for runCode (ISD-9248/ISD-9305) — product roadmap input to be filed
- **Expanding the known-resolution library** as cases are resolved — this compounds over time, making future triage faster
- **Automated SLA monitoring** — proactive escalation before breach rather than reactive detection
