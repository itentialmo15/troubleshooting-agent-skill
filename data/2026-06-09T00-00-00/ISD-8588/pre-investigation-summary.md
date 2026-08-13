---
generated: 2026-06-09
ticket: ISD-8588
phase: 0e
---

# Pre-Investigation Summary

**Ticket:** ISD-8588 — [ Labs ] P6 Install: Workflow Child Job Opening Behavior.
**Customer:** Internal Labs (P6 install) | **Priority:** Major | **SLA:** unknown
**Assignee:** Logan Seo

---

## What the customer reports

In Platform 6, clicking to open a child job or transformation from within
Automation Studio now opens in a **new browser window** rather than a new
tab within the same Studio window. This is a behavior regression from prior
versions. The concern is twofold: disrupted workflow management (jumping
between windows) and potential data loss from multiple unsaved workflow tabs
spread across browser windows.

---

## Initial hypothesis

This is a **UI regression in Automation Studio** introduced in Platform 6.x.
The likely root cause is a frontend navigation change — the link/click handler
for child job and transformation links was updated to use `window.open()` with
a `_blank` target (or equivalent router behavior), replacing what was previously
an in-app tab mechanism within the Studio shell. No backend, adapter, or WFE
involvement — this is purely a browser-side rendering behavior change.

---

## Known issue match

**ENG-16911 — CONFIRMED MATCH** — same title and description.
- Status: Backlog (UNRESOLVED)
- Fix Version: None assigned
- Assignee: Rowan Gibbs
- No workaround documented

This means the customer has hit a **known open Engineering bug with no patch
yet released**. The primary action is to link ISD-8588 to ENG-16911 and engage
the Engineering team for prioritization/timeline.

---

## Investigation plan

1. **Phase 0** ✅ — Ticket read, context extracted, ENG-16911 identified as direct match
2. **Phase 2** — Collect artifact checklist from customer:
   - Exact IAP version (minor + patch)
   - Browser type and version
   - Steps to reproduce (which workflow, which task type triggers the behavior)
   - Screenshots or screen recording of the behavior
   - Whether the behavior is consistent or intermittent
3. **Phase 3** — No platform sub-skills needed (UI-only issue, no job errors,
   no adapter failures, no DB/infra involvement)
4. **Phase 6** — Produce Engineering escalation pack linking ISD-8588 → ENG-16911,
   provide repro steps, request fix version prioritization

---

## Escalation risk

Low immediate risk (Labs environment, not production). However, if this behavior
is present in all P6 installs it will affect all customers upgrading to P6.
Recommend flagging ENG-16911 for prioritization before GA/production rollouts.
