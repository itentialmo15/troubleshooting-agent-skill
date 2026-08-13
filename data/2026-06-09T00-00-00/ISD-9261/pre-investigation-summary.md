---
generated: 2026-06-09
ticket: ISD-9261
phase: 0e
---

# Pre-Investigation Summary

**Ticket:** ISD-9261 — [ Labs ] Enable query doesn't work in run childjob task.
**Customer:** AstraZeneca (Labs) | **Reporter:** Sergio Valdez | **Priority:** Medium
**Affects Version:** Platform 6.4.0 — **GA released 2026-06-04** | **Status:** Waiting for support
**Assignee:** Nayana M P | **Replicated:** ✅ Ahmed Al-Zubidy (product support cloud)

---

## What the customer reports

In Automation Studio, the "enable query" feature (inline query on task inputs)
works on all task types except the childJob (workflow) task. When the user tries
to enable it on a childJob task, the UI throws:

> **`Cannot set properties of undefined (setting 'childJobLoopIndex')`**

The feature is broken exclusively for the childJob task type — other tasks
(adapter, application, etc.) are unaffected.

---

## Root Cause Hypothesis

This is a **frontend JavaScript TypeError** in the Automation Studio childJob
task input panel. The "enable query" initialization code tries to write to
`someTaskConfig.childJobLoopIndex` — a property specific to childJob loop
configuration — but the `someTaskConfig` object is `undefined` at the time
of the write.

**Why only childJob:**
- `childJobLoopIndex` is a loop-iteration property unique to the childJob task
  actor type. No other task types have this property.
- The "enable query" UI handler was built for the general task input model. When
  it runs on a childJob task it hits childJob-specific initialization code that
  expects the loop state object to already exist — but it hasn't been initialized
  yet at the point the query feature is toggled on.
- All other task types avoid this path entirely (they have no `childJobLoopIndex`
  to set), so enable query works for them.

**Classification:** Automation Studio UI bug — childJob task panel state
initialization order. NOT a runtime/backend/adapter/WFE issue.

---

## Known Issue Match

**None found.** No existing ENG bug matches this error or this feature+task
combination. This is a **new defect** that requires a new ENG ticket.

---

## Investigation Plan

1. **Phase 0** ✅ — Ticket read, error analyzed, no ENG match found
2. **Phase 2** — Collect from customer:
   - Exact IAP version
   - Browser + version
   - Repro steps (which specific input field on the childJob task triggers it)
   - Does it fail even without loop options configured on the childJob?
   - Accessible screenshots (staging blob links in ticket are inaccessible)
3. **Phase 3** — No platform sub-skills needed (UI error, no job execution)
4. **Phase 6** — File new ENG bug with error message, repro steps, and component
   attribution (Automation Studio / childJob task panel / enable query)

---

## Workaround for the Customer (Interim)

Until Engineering fixes the childJob task panel initialization:

1. **Do not use "enable query" on childJob tasks** — wire inputs using standard
   job variable references (`$var.job.variableName`) directly in the task input fields
2. **Pre-build the input object upstream** — use a `makeData`, `merge`, or
   `query` task before the childJob task to construct the required input
   structure, then pass it as a top-level `$var` reference to the childJob input
3. **Use a JST (Transformation)** — place a transformation task before the
   childJob to shape the data, then reference its output

---

## Engineering Escalation Pack (Phase 6 Draft)

**Bug Title:** Enable query throws TypeError on childJob task:
`Cannot set properties of undefined (setting 'childJobLoopIndex')`

**Component:** Automation Studio — childJob task input panel / enable query feature

**Severity:** Medium (Labs; workaround exists)

**Steps to Reproduce:**
1. Open a workflow in Automation Studio that contains a childJob task
2. Double-click to open the childJob task details panel
3. On any input field, click "enable query" to toggle the inline query feature
4. Observe: UI throws TypeError `Cannot set properties of undefined (setting 'childJobLoopIndex')`

**Expected:** Query editor opens for the selected input field, as it does on all
other task types

**Actual:** JavaScript TypeError, query editor does not open

**Root Cause (hypothesis):** The enable query handler calls childJob loop state
initialization code before the childJob task config object is instantiated.
The `childJobLoopIndex` property is attempted on an undefined object.

**Affected versions:** P6 Labs (exact version TBC from customer)
**Not affected:** All other task types (adapter, application, etc.)

---

*Saved to:* `data/2026-06-09T00-00-00/ISD-9261/`
