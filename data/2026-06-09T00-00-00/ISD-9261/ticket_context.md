---
generated: 2026-06-09
ticket: ISD-9261
---

╔══════════════════════════════════════════════════════════════╗
  TICKET CONTEXT — ISD-9261
╠══════════════════════════════════════════════════════════════╣
  TICKET
  ──────
  Ticket:        ISD-9261
  Summary:       [ Labs ] Enable query doesn't work in run childjob task.
  Priority:      Medium
  Severity:      Moderate / Limited (customfield_11500)
  SLA Status:    unknown
  Customer:      AstraZeneca (Labs environment)
  Reporter:      Sergio Valdez
  Assignee:      Nayana M P (nayana.mp@itential.com)
  Status:        Waiting for support
  Team:          Product Support

  ENVIRONMENT
  ───────────
  IAP Version:   Platform 6.4.0 ✅ CONFIRMED — GA released 2026-06-04
  IAG Version:   unknown
  Deployment:    Labs (AstraZeneca Labs environment)
  OS:            unknown
  MongoDB:       unknown
  Redis:         unknown
  Adapter(s):    none mentioned

  REPLICATION STATUS
  ──────────────────
  ✅ REPLICATED — Ahmed Al-Zubidy confirmed replication on the product support
  cloud instance (comment 2026-06-09). Two workflow JSON files attached as
  reproduction artifacts:
    - ahmed-test.json (6.2 KB)
    - ahmed-test-2.json (4.5 KB)

  PROBLEM
  ───────
  Component:     Automation Studio UI — childJob task input panel
  Symptom:       The "enable query" feature for querying input data does NOT
                 work on the childJob (workflow) task. It works on all other
                 task types. Throws a JavaScript TypeError in the UI.
  Error Message: Cannot set properties of undefined (setting 'childJobLoopIndex')
  Job ID:        none (UI-side error before job execution)
  Workflow:      any workflow containing a childJob task
  Incident Time: unknown
  Frequency:     always (consistent failure on childJob task type)
  Regression:    unknown — may be a missing feature or regression from a prior
                 version
  Steps Provided: partial — 2 screenshots attached (staging blobs, not accessible)

  ERROR ANALYSIS
  ──────────────
  TypeError: Cannot set properties of undefined (setting 'childJobLoopIndex')

  Breakdown:
  - Code is executing: someObject.childJobLoopIndex = value
  - someObject is undefined at the time of assignment
  - childJobLoopIndex is a loop-iteration property unique to childJob tasks
  - The "enable query" initialization handler touches this property during
    setup, but the childJob-specific state object has not been initialized
    before the handler runs
  - All other task types (adapter, application) don't have this property
    so they don't hit this code path — explains why enable query works
    everywhere else

  ATTACHMENTS
  ───────────
  2 screenshots (staging blob URLs — not accessible for review)
╚══════════════════════════════════════════════════════════════╝
