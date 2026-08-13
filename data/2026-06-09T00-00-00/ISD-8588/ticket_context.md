---
generated: 2026-06-09
ticket: ISD-8588
---

╔══════════════════════════════════════════════════════════════╗
  TICKET CONTEXT — ISD-8588
╠══════════════════════════════════════════════════════════════╣
  TICKET
  ──────
  Ticket:        ISD-8588
  Summary:       [ Labs ] P6 Install: Workflow Child Job Opening Behavior.
  Priority:      Major
  Severity:      unknown (not stated)
  SLA Status:    unknown (no SLA data in ticket)
  Customer:      Internal Labs (P6 install)
  Assignee:      Logan Seo (logan.seo@itential.com)
  Status:        Pending

  ENVIRONMENT
  ───────────
  IAP Version:   Platform 6.x (P6 install — exact minor version unknown)
  IAG Version:   unknown
  Deployment:    Labs (type unknown — likely Docker or VM)
  OS:            unknown
  MongoDB:       unknown
  Redis:         unknown
  Adapter(s):    none mentioned

  PROBLEM
  ───────
  Component:     Automation Studio UI (frontend)
  Symptom:       Opening a child job or transformation from within Automation
                 Studio now opens in a NEW BROWSER WINDOW instead of a new
                 tab within the same Studio window.
  Error Message: none (UI behavior change, not an error)
  Job ID:        none
  Workflow:      any workflow containing childJob tasks
  Incident Time: unknown
  Frequency:     always (consistent behavior change in P6)
  Regression:    yes — behavior changed from previous version (was opening
                 as new tab in same window)
  Steps Provided: partial (description only, no repro steps)

  ATTACHMENTS
  ───────────
  none

  BUSINESS IMPACT
  ───────────────
  - Workflow management disruption: navigating across multiple browser
    windows instead of tabs within a single Studio session
  - Potential data loss: multiple unsaved tabs across windows increases
    risk of losing unsaved workflow changes
╚══════════════════════════════════════════════════════════════╝
