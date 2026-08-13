---
generated: 2026-06-09
ticket: ISD-9261
---

# Known Issues — ISD-9261

## Direct ENG Bug Match

**NONE FOUND.**

Searched ENG for:
- `childJobLoopIndex` — no matching bug
- `enable query` + `childJob` — no matching bug
- `inline query` + `childJob` — no matching bug

This appears to be a **new, unreported Engineering defect** that needs to be
filed in ENG.

## Related ENG Bugs (context only)

**ENG-23222** — "[ Labs ] Sort (Array) with ChildJob is not executing properly."
- Status: In Progress (Unresolved)
- Different runtime issue (childJob not executing correctly after Sort(Array))
- Not the same component or error

**ENG-22105** — "Imported Workflow from 22.x to P6 won't open some specific tasks"
- Cancelled — root cause: missing `location` field on hand-authored tasks
- Related in that it's also an Automation Studio task panel UI issue on childJob
- Resolution from Brent Nistal: add `"location": "Application"` to task JSON,
  or run MongoDB backfill script. Platform fix: v8 migration.
- Different root cause from ISD-9261 but same UI area (task details panel)

## Related ISD Tickets (context only)

**ISD-9005** — "childJob done but parent waiting forever" — Resolved. WFE
runtime issue, not UI. Fixed via ENG-22494 in Platform-6.4.0.

**ISD-7041** — "Cannot forward message to corral:dnacenter in child job" —
Resolved. Adapter/corral message routing issue, not UI.

## Confluence KB

No relevant articles found for this specific error or feature combination.
