# Known Resolutions Library

This file captures confirmed resolution patterns from ISD ticket investigations. Each entry includes the symptom, root cause, resolution steps, workaround, detection hints, and verification. Updated as part of Phase 7 — Resolution Learning.

---

## Resolution Entries

---

### [ISD-9288] itenProngAppDown / itenProngAppCrash SNMP traps never sent

| Field | Value |
|-------|-------|
| **Ticket** | ISD-9288 |
| **ENG Bug** | ENG-24868 |
| **Component** | Platform core — `Shutdown.js` / SNMP trap subsystem |
| **Platform Version** | 6.4.0 (confirmed via tcpdump on PE Labs) |
| **Severity** | S3 — Lab environment; SNMP monitoring non-functional for down/crash events |

**Symptom:**
SNMP trap manager receives `itenProngSystemRestart` (s=4) and `itenProngAppUp` (s=6) traps correctly on platform restart, but never receives `itenProngAppDown` (s=7) or `itenProngAppCrash` (s=8) traps when services are stopped or crash.

**Root Cause:**
The platform's internal shutdown handler (`/opt/itential/platform/server/core/startup/Shutdown.js`) has a 3-second timeout and exits after Redis cleanup — it does not emit AppDown traps for stopping services. There is no mirror logic to the AppUp emission on startup. For crashes, the systemd unit has `Restart=on-failure` but no `ExecStopPost` hook, and a dead process cannot self-report.

Confirmed by: tcpdump on UDP 162 across a full restart + stop cycle — 0 packets with s=7 or s=8.

**Detection Hints:**
- AppUp and SystemRestart traps work → SNMP is configured correctly; the deficiency is in the shutdown path
- Check `journalctl -u itential-platform` for `Shutdown.js: 'Shutdown timeout has been hit'`
- Check systemd unit for absence of `ExecStopPost`

**Workaround (immediate):**
Add `ExecStopPost` to the systemd unit to send a platform-level AppDown trap on any stop or crash:
```
sudo systemctl edit itential-platform
```
Add under `[Service]`:
```ini
ExecStopPost=/usr/bin/snmptrap -v 1 -c public <SNMP_MANAGER_IP> .1.3.6.1.4.1.47688.1.1.1.0 "" 6 7 "" .1.3.6.1.4.1.47688.1.1.1.1.1.0 s "itential-platform"
```
Prerequisite: `sudo dnf install net-snmp-utils -y`

**Limitation:** Workaround sends one platform-level AppDown trap, not per-microservice. Per-microservice granularity requires the platform fix in ENG-24868.

**Verification:**
1. Apply workaround + `systemctl daemon-reload`
2. Run `sudo tcpdump -i lo -nn udp port 162 -v &`
3. Run `systemctl stop itential-platform`
4. Confirm s=7 trap arrives at SNMP manager

---

### [ISD-9261] Enable query TypeError on looped childJob task

| Field | Value |
|-------|-------|
| **Ticket** | ISD-9261 |
| **Component** | Automation Studio UI — childJob task input panel / enable query handler |
| **Platform Version** | 6.4.0 (confirmed) |
| **Severity** | S3 — UI bug, workaround available |

**Symptom:**
User clicks the "enable query" toggle on a looped childJob task input field and receives:
```
TypeError: Cannot set properties of undefined (setting 'childJobLoopIndex')
```
The query editor does not open. The task details panel may go blank, freeze, or close. Error appears only in the browser developer console (F12 → Console) — **not** in `job.error[]`, not in platform logs.

**Pre-condition (mandatory for trigger):**
- childJob task must have `loopType` set (`parallel` or `sequential`)
- `data_array` must be configured
- The enable query toggle only appears when both conditions are met

**Root Cause:**
The Automation Studio enable query handler includes childJob-specific initialization code that sets `taskConfig.childJobLoopIndex` when the toggle is clicked. At that moment, `taskConfig` has not yet been instantiated — the assignment throws before the editor opens. This path is only reached when `loopType` is set.

**Resolution Steps:**
1. Check browser console (F12) for `TypeError: Cannot set properties of undefined (setting 'childJobLoopIndex')` — confirms this is ISD-9261
2. Confirm no platform-side issue: check `job.error[]` — will be empty; check platform logs — no errors
3. Apply workaround (see below)
4. File or reference ENG bug ticket for permanent fix

**Workaround:**
Do not use enable query on childJob task inputs. Pre-extract the array before the childJob so `data_array` references it directly.

**Option A — Pass the array as a separate flat job input:**
```json
{
  "workflow": "your-workflow",
  "options": {
    "variables": {
      "devices": [{"deviceName": "router-01", ...}]
    }
  }
}
```
Wire `data_array` to `$var.job.devices` — no enable query needed.

**Option B — Pre-process with a newVariable or merge task:**
Add a task before the childJob that builds the array from the input object:
- `newVariable` task: set `name=inventory`, `value={"devices":[...]}` (object with nested array)
- Wire `data_array` to `$var.job.devices` (the flat workaround input)

**Detection Hints:**
| Signal | Meaning |
|--------|---------|
| Browser console has `childJobLoopIndex` error | Confirmed ISD-9261 — UI bug |
| No error in `job.error[]` | Platform is unaffected — UI only |
| Adapter task panel works normally | Bug is childJob-specific |
| Error only fires when loop is enabled | Pre-condition check |
| IAP 6.4.0 | Affected version — check fix version when ENG ticket is filed |

**Verification:**
1. Apply Option A or B workaround
2. Start job with flat array variable
3. Confirm loop executes: all child jobs run in parallel, `parentStatus=success`
4. Confirm browser console has no `childJobLoopIndex` error during the run

**Demo Environment:**
- PE Labs: `https://p6.pe.itential.io:3443`
- Parent workflow ID: `cf4d44a1-2429-4a91-81a3-c633d825c8e9` ("ISD-9261 - Parent Workaround Demo")
- Child workflow ID: `a827f11d-8549-45a7-bb8a-e88ee5733c0c` ("ISD-9261 - Child Demo")
- STR: `data/2026-06-09T00-00-00/ISD-9261/steps-to-reproduce.md`

**Sample payload (workaround demo):**
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

**Intended query value** (what user would type if enable query worked):
```
[devices]
```

**Replicated by:** Ahmed Al-Zubidy (Product support cloud, 2026-06-09), Builder agent (PE Labs, 2026-06-09)

---

### [Pattern] Adapter OFFLINE — token_timeout: -1

| Field | Value |
|-------|-------|
| **Component** | IAG adapter (GatewayManager) |
| **Symptom** | Adapter authenticates on startup, goes ONLINE briefly, then drops OFFLINE after first token expires |

**Root Cause:** `token_timeout: -1` — adapter never refreshes the token after initial auth.

**Resolution:** Set `token_timeout: 3600000` (1 hour in ms) in adapter settings.

**Verification:** Adapter stays ONLINE through a full token refresh cycle.

---

### [Pattern] No config found for Adapter: X

| Field | Value |
|-------|-------|
| **Component** | Workflow Engine — adapter task routing |
| **Symptom** | `"No config found for Adapter: {name}"` at runtime on adapter tasks |

**Root Cause:** `app` field on the workflow task uses the adapter **instance name** instead of the adapter **type name**. `app` and `locationType` must be the type name from `apps.json` (e.g., `EmailOpensource`, `Servicenow`). The adapter instance name (e.g., `email`, `servicenow-prod`) belongs in `adapter_id` only.

**Resolution:** Fix `app` and `locationType` to the type name from `apps.json`. The `adapter_id` field holds the instance name.

---

### [Pattern] Job has no available transitions

| Field | Value |
|-------|-------|
| **Component** | Workflow Engine — task error handling |
| **Symptom** | Job gets stuck in `running` state after adapter or external task fails |

**Root Cause:** No `"state": "error"` transition on the failing adapter/external task. When the task errors, WFE finds no valid transition and the job stalls.

**Resolution:** Add error transition on every adapter and external task:
```json
"transitions": {
  "{taskId}": {
    "{errorHandlerTaskId}": {"type": "standard", "state": "error"}
  }
}
```

---

### [Pattern] Adapter in stub mode

| Field | Value |
|-------|-------|
| **Component** | Adapter configuration |
| **Symptom** | Adapter calls return empty/stub data; no real API calls are made |

**Root Cause:** `stub: true` in adapter settings — adapter is in stub mode and does not call the target system.

**Resolution:** Set `stub: false` in adapter settings.

---

### [Pattern] WFE log > 500MB + slow jobs

| Field | Value |
|-------|-------|
| **Component** | WorkflowEngine — logging |
| **Symptom** | Jobs noticeably slower than expected; WFE log file is very large |

**Root Cause:** `console_level: spam` in WFE settings — produces extreme I/O volume that degrades job throughput.

**Resolution:** Set `console_level: error` in WFE settings.

---

### [Pattern] Jobs COLLSCAN + slow at scale

| Field | Value |
|-------|-------|
| **Component** | MongoDB — jobs collection |
| **Symptom** | Slow job queries at high job volume; MongoDB slow query log shows COLLSCAN on jobs collection |

**Root Cause:** Missing `{status: 1}` index on the jobs collection.

**Resolution:** Add index with DBA consent:
```javascript
db.jobs.createIndex({status: 1})
```

---

### [Pattern] OOMKilled container

| Field | Value |
|-------|-------|
| **Component** | Container runtime (Docker / Kubernetes) |
| **Symptom** | Container exits unexpectedly; `docker inspect` or pod events show `OOMKilled` |

**Root Cause:** Container memory limit set too low for the workload.

**Resolution:** Increase Docker memory limit or Kubernetes resource limit for the affected container.

---

### [Pattern] ASIA* AWS key prefix + adapter OFFLINE

| Field | Value |
|-------|-------|
| **Component** | AWS adapter / IAM credentials |
| **Symptom** | Adapter using AWS credentials goes OFFLINE; key ID starts with `ASIA` |

**Root Cause:** `ASIA*` prefix indicates STS temporary credentials — they have a short TTL and expire. Long-lived IAM access keys use `AKIA` prefix.

**Resolution:** Replace temporary STS credentials with long-lived IAM access key (`AKIA` prefix).

---

### [Pattern] Workflow errors[] not empty after import

| Field | Value |
|-------|-------|
| **Component** | Automation Studio — workflow import/validation |
| **Symptom** | Workflow is in draft state after import; `errors[]` array is not empty |

**Root Cause:** Validation errors during import leave the workflow in draft state. Cannot be started until all validation errors are resolved.

**Resolution:** Check each entry in `errors[]`, fix the workflow, re-PUT. Common causes: non-hex task IDs, missing transitions, invalid `app`/`locationType` values.

---

### [Pattern] $var reference resolves to undefined

| Field | Value |
|-------|-------|
| **Component** | Workflow Engine — variable resolution |
| **Symptom** | `$var.<taskId>.<variable>` resolves to `undefined` at runtime |

**Root Cause:** Non-hex task ID on the referenced task. WFE classifies non-hex task IDs as static values and never resolves them. Task IDs must match `[0-9a-f]{1,4}`.

**Resolution:** Rename the task ID to a valid hex value (e.g., `a1b2`, `ef01`).

---

### [Pattern] childJob Cannot find workflow: X at runtime

| Field | Value |
|-------|-------|
| **Component** | Workflow Engine — childJob task |
| **Symptom** | childJob task fails with `Cannot find workflow: {name}` at runtime |

**Root Cause:** childJob references the plain workflow name (`workflow: "MyWorkflow"`) but the asset is project-scoped after being added to a project. Project-scoped workflow names are prefixed with `@{projectId}: `.

**Resolution:** Update `workflow` field to `@{projectId}: {name}` format to reference the project-scoped asset.
