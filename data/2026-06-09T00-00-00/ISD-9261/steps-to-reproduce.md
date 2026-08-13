---
generated: 2026-06-09
ticket: ISD-9261
type: steps-to-reproduce
platform: 6.4.0
environment: PE Labs — https://p6.pe.itential.io:3443
workflows:
  - "ISD-9261 - Parent Workaround Demo"
  - "ISD-9261 - Child Demo"
---

# Steps to Reproduce — ISD-9261
**Enable query throws TypeError on childJob task when loop is enabled**

---

## Background

The "enable query" toggle on a childJob task is **only exposed in the
Automation Studio UI when the loop is enabled** (`loopType: parallel` or
`sequential` + `data_array` configured).

When the loop is enabled, the UI surfaces an "enable query" toggle next to
each input field, allowing users to write inline query expressions to
transform loop data. Clicking this toggle on a looped childJob throws:

```
TypeError: Cannot set properties of undefined (setting 'childJobLoopIndex')
```

The error fires **before the query editor opens**, regardless of what
`data_array` contains.

---

## Real-World Scenario

A user has a job variable `inventory` set to an object with a nested
`devices` array:

```json
{
  "devices": [
    {"deviceName": "router-core-01", "configKey": "ntp-server",  "configValue": "192.168.1.10"},
    {"deviceName": "router-core-02", "configKey": "ntp-server",  "configValue": "192.168.1.10"},
    {"deviceName": "switch-dist-01", "configKey": "syslog-host", "configValue": "10.0.0.5"}
  ]
}
```

They want to loop a childJob over `inventory.devices`. The natural approach:

1. Configure the childJob with `loopType: parallel`
2. Set `data_array` to `$var.job.inventory`
3. Click **enable query** on the `data_array` field
4. Type query value `[devices]` to extract the nested array inline

**Step 3 triggers ISD-9261.**

**Workaround:** Pass the `devices` array as a separate flat job input and
reference it directly via `$var.job.devices` — no enable query needed.

---

## Pre-condition

Both demo workflows are deployed on PE Labs (`https://p6.pe.itential.io:3443`):

| Workflow | ID |
|----------|----|
| ISD-9261 - Parent Workaround Demo | `cf4d44a1-2429-4a91-81a3-c633d825c8e9` |
| ISD-9261 - Child Demo | `a827f11d-8549-45a7-bb8a-e88ee5733c0c` |

The parent workflow canvas:
```
workflow_start → [newVariable: nv01] → [childJob: cj01] → [newVariable: nv02] → workflow_end
                                                         ↓ error
                                                      [newVariable: er01] → workflow_end
```

- `nv01` sets job variable `inventory` = `{"devices": [{...}, {...}, {...}]}` (object with nested devices array)
- `cj01` is configured with `loopType: parallel` — this exposes the enable query toggle
- `data_array` is wired to `$var.job.devices` (the workaround)

To reproduce on a different instance, import:
```
data/2026-06-09T00-00-00/ISD-9261/demo-parent-workflow.json
data/2026-06-09T00-00-00/ISD-9261/demo-child-workflow.json
```

---

## Steps to Reproduce the Bug

### Step 1 — Open Automation Studio

1. Log in to Itential Platform 6.4.0
2. Navigate to **Automation Studio** from the left navigation menu

---

### Step 2 — Open the parent workflow

1. Click **Open** and search for: **`ISD-9261 - Parent Workaround Demo`**
2. Open it — confirm the canvas shows `nv01 → cj01 → nv02 → workflow_end`

---

### Step 3 — Open the childJob task details panel

1. **Double-click** the childJob task `cj01`
   ("Run Child Demo — parallel loop over devices")
2. The task details panel opens
3. Confirm the loop configuration is visible:
   - **Loop Type**: `parallel`
   - **Data Array**: `$var.job.devices`
   - **Workflow**: `ISD-9261 - Child Demo`

> The `loopType` + `data_array` combination is what makes the **"enable query"**
> toggle appear on input fields. Without loop configured, the toggle is not
> visible and the bug cannot be triggered.

---

### Step 4 — Trigger the bug: click "enable query"

1. In the task details panel, locate the **Data Array** field (`$var.job.devices`)
2. Click the **"enable query"** toggle next to that field

> **What the user is trying to do:** Change `data_array` from `$var.job.devices`
> to a query expression `[devices]` that extracts the nested array from
> `$var.job.inventory` inline — so they only need the one object variable
> instead of passing the array separately.

---

### Step 5 — Observe the error

**Expected:**
The inline query editor opens and the user can type a query expression — the
same behavior seen on all other task types.

**Actual:**
The query editor does not open. Open the browser developer console
(**F12 → Console**) and observe:

```
TypeError: Cannot set properties of undefined (setting 'childJobLoopIndex')
```

The task panel may go blank, freeze, or close. The error fires before any
query expression can be entered.

---

### Step 6 — Confirm scope: no error without loop

To confirm the bug is specific to looped childJob tasks:

1. Create a new workflow with a childJob task
2. Leave `loopType` empty (no loop configured)
3. Open the task details panel
4. Observe: the "enable query" toggle is **not visible** — the bug cannot be
   triggered without loop enabled

---

## Scope Summary

| Condition | enable query visible? | Result |
|-----------|----------------------|--------|
| childJob — loop NOT enabled | No | n/a |
| childJob — loop enabled (`loopType: parallel`) | **Yes** | ❌ TypeError on click |
| Any other task type (merge, newVariable, adapter, etc.) | Yes | ✅ works |

---

## Root Cause (Hypothesis)

The Automation Studio enable query handler includes childJob-specific
initialization code that sets `taskConfig.childJobLoopIndex` when the toggle
is clicked. At that moment, `taskConfig` has not yet been instantiated —
the assignment throws:

```
TypeError: Cannot set properties of undefined (setting 'childJobLoopIndex')
```

This path is only reached when `loopType` is set (the toggle only appears then).

**Component:** Automation Studio UI — childJob task input panel / enable query  
**Not affected:** WFE, job execution, adapters, MongoDB, Redis

---

## Sample Payload

Use this to run the workaround demo — the loop executes successfully
via `$var.job.devices` without enable query:

```json
{
  "workflow": "ISD-9261 - Parent Workaround Demo",
  "options": {
    "variables": {
      "devices": [
        {"deviceName": "router-core-01", "configKey": "ntp-server",  "configValue": "192.168.1.10"},
        {"deviceName": "router-core-02", "configKey": "ntp-server",  "configValue": "192.168.1.10"},
        {"deviceName": "switch-dist-01", "configKey": "syslog-host", "configValue": "10.0.0.5"}
      ]
    }
  }
}
```

The `nv01` task creates `inventory` internally. The `devices` input is the
workaround — it's the pre-extracted array that `data_array` references directly.

**Sample query value** (what the user would type if enable query worked):

```
[devices]
```

This would extract `inventory.devices` inline, eliminating the need to pass
`devices` as a separate job variable. ISD-9261 prevents this.

---

## Workaround (Interim)

**Do not use enable query on childJob task inputs.** Pre-extract the array
before it reaches the childJob so `data_array` can reference it directly.

**Option A — Pass the array as a separate flat job input:**

```json
"variables": {
  "devices": [{"deviceName": "...", ...}]
}
```

Wire `data_array` to `$var.job.devices` — no enable query needed.

**Option B — Pre-process with a task:**

Add a `makeData` or `merge` task before the childJob to build the array,
then wire `data_array` to that task's output variable.

---

## Verified Replication

| Replicated by | Environment | Date |
|---------------|-------------|------|
| Ahmed Al-Zubidy | Product support cloud | 2026-06-09 |
| Builder agent (workflow + loop test) | PE Labs (p6.pe.itential.io:3443) | 2026-06-09 |

**Loop test confirmed:** Parent ran 3 child jobs in parallel with
`parentStatus = success`. `nv01` correctly sets `inventory` with the nested
devices object. The bug is purely in the Automation Studio UI enable query
handler — WFE loop execution is unaffected.
