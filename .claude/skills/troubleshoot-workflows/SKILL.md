---
name: troubleshoot-workflows
description: Troubleshoot workflow failures, job errors, JST errors, import failures, and validation errors in Itential Platform. Analyzes job error arrays, task outputs, and transition gaps.
argument-hint: "[workflow name or job ID]"
---

# Troubleshoot Workflows

**Owns:** Workflow and job failure diagnosis — job errors, task-level failures, JST (JavaScript Transformation) errors, workflow import failures, validation errors, and childJob wiring issues.
**Use when:** A workflow job errored or is stuck, a workflow won't import, a JST script is failing, or a workflow is producing wrong output.

---

## CRITICAL SAFETY RULES

- **GET requests only** — no PUT, PATCH, POST, DELETE
- **Read `.env` for credentials** — never ask the user for credentials already in `.env`
- **Never modify workflow definitions** without explicit user consent

---

## Auth Reuse

Check `{project_path}/.auth.json`:
- If `platform_url` matches `PLATFORM_URL` in `.env` and `timestamp` < 50 minutes old → reuse token
- Otherwise authenticate from `.env` and save `.auth.json`

**Password auth:**
```bash
curl -sk -X POST "{PLATFORM_URL}/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "{USERNAME}", "password": "{PASSWORD}"}'
```

**OAuth:**
```bash
curl -sk -X POST "{PLATFORM_URL}/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id={CLIENT_ID}&client_secret={CLIENT_SECRET}&grant_type=client_credentials"
```

---

## Phase 1: Triage

Ask the user (or infer from context):
- **Workflow/job name** — which workflow is failing?
- **Job ID** — if the user has a specific job ID
- **Error message** — copy/paste from UI or logs
- **When did it start failing** — was it working before?
- **Type of failure:**
  - Job errored during execution
  - Workflow won't import (validation error)
  - JST script error
  - ChildJob not completing
  - Specific task failing

---

## Phase 2: Job Error Analysis

### Step 2a — Fetch the Failing Job

If the user has a job ID:
```bash
curl -sk "{PLATFORM_URL}/operations-manager/jobs/{JOB_ID}?token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
j = d if d.get('_id') else d.get('job', d)
print('Job ID:   ', j.get('_id'))
print('Workflow: ', j.get('name'))
print('Status:   ', j.get('status'))
print('Start:    ', j.get('start_time') or j.get('startTime'))
print('End:      ', j.get('end_time') or j.get('endTime') or '(still running)')
print()

# Print job.error array
errors = j.get('error', [])
if isinstance(errors, list):
    print(f'Errors ({len(errors)}):')
    for e in errors:
        if isinstance(e, dict):
            iap = e.get('IAPerror', e)
            print('  source:      ', iap.get('source','?'))
            print('  displayString:', iap.get('displayString','?'))
            print('  raw:         ', str(e)[:200])
            print()
elif errors:
    print('Error:', errors)
else:
    print('No errors in job.error array')
"
```

If no job ID, search recent jobs:
```bash
curl -sk "{PLATFORM_URL}/operations-manager/jobs?name={WORKFLOW_NAME}&status=error&limit=5&token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
jobs = d.get('jobs', d.get('results', []))
print(f'Found {len(jobs)} recent error jobs:')
for j in jobs:
    print(f'  {j.get(\"_id\",\"?\")}  {j.get(\"name\",\"?\")}  {j.get(\"start_time\",\"?\")[:19]}')
"
```

### Step 2b — Analyze Failing Task

```bash
curl -sk "{PLATFORM_URL}/operations-manager/jobs/{JOB_ID}?token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
j = d if d.get('_id') else d.get('job', d)
tasks = j.get('tasks', {})
print(f'Tasks ({len(tasks)}):')
for tid, t in tasks.items():
    if not isinstance(t, dict): continue
    status = t.get('status','?')
    name   = t.get('name', tid)
    flag   = '🔴' if status == 'error' else ('⚠️' if status == 'incomplete' else '')
    print(f'  {flag} [{status}] {name}  (id: {tid})')
    if status == 'error':
        output = t.get('output', {})
        print(f'    output: {str(output)[:300]}')
        err = t.get('error')
        if err:
            print(f'    error: {str(err)[:300]}')
"
```

### Step 2c — Error Source Routing

| `IAPerror.source` | Likely Cause | Next Step |
|-------------------|-------------|-----------|
| `adapter` | Adapter misconfiguration or connectivity | Run `/troubleshoot-adapters {adapter_name}` |
| `automation-studio` | Workflow validation error or missing task | Check workflow definition (Step 3) |
| `operations-manager` | Worker crash or job timeout | Run `/troubleshoot-jobs` |
| `WorkFlowEngine` | WFE execution error | Run `/troubleshoot-jobs` |
| `[task name]` | Task-specific error | Check task output (Step 2b) |
| `jst` | JavaScript Transformation error | See Phase 4 (JST errors) |

---

## Phase 3: Workflow Definition Analysis

### Step 3a — Get Workflow

```bash
# By name
curl -sk "{PLATFORM_URL}/automation-studio/workflows?name={WORKFLOW_NAME}&token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('items', d.get('results', []))
print(f'Found {len(items)} workflow(s):')
for w in items:
    print(f'  {w.get(\"_id\",\"?\")}  {w.get(\"name\",\"?\")}  v{w.get(\"version\",\"?\")}  {\"VALID\" if not w.get(\"errors\") else \"HAS ERRORS\"} ')
    errs = w.get('errors', [])
    if errs:
        print('  Validation errors:')
        for e in errs[:5]:
            print(f'    - {e}')
"
```

### Step 3b — Check Workflow Validation Errors

A workflow with validation errors is in **draft** state — it cannot be started.

```bash
curl -sk "{PLATFORM_URL}/automation-studio/workflows/{WORKFLOW_ID}?token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
w = d.get('data', d)
errors = w.get('errors', [])
if errors:
    print(f'🔴 Workflow has {len(errors)} validation error(s):')
    for e in errors:
        print(f'  - {e}')
    print()
    print('This workflow is in DRAFT state and cannot be started until errors are resolved.')
else:
    print('✅ No validation errors — workflow is valid')

# Check for missing task transitions
tasks = w.get('tasks', {})
print(f'Tasks: {len(tasks)}')
for tid, t in tasks.items():
    if not isinstance(t, dict): continue
    trans = t.get('transitions', {})
    if not trans and tid not in ('workflow_start', 'workflow_end'):
        print(f'  ⚠️ Task {t.get(\"name\",tid)}: no outgoing transitions')
    # Check for error transition on adapter/external tasks
    actor = t.get('actor', {})
    if actor.get('type') in ('adapter', 'application') and 'error' not in trans:
        print(f'  ⚠️ Task {t.get(\"name\",tid)}: no error transition (job will get stuck on task failure)')
"
```

### Step 3c — Common Validation Error Patterns

| Error | Root Cause | Fix |
|-------|-----------|-----|
| `Task {name} not found in catalog` | Task name typo or wrong app | Verify task name via `/workflow_builder/tasks/list` |
| `Missing required field: {field}` | Task input not wired | Check task schema, wire the field |
| `Circular reference detected` | childJob referencing itself | Trace childJob chain |
| `No config found for Adapter: {name}` | `app` field set to instance name (not type name) | Set `app` = adapter type from `apps.json`, not instance name |
| `$var reference unresolvable` | Variable name not defined in upstream task | Check source task output schema and variable name |
| `Task ID contains non-hex characters` | Task ID like `apush` instead of hex | Regenerate task with valid hex ID |

---

## Phase 4: JST (JavaScript Transformation) Errors

### Step 4a — Get the JST

```bash
# List JSTs
curl -sk "{PLATFORM_URL}/transformations?name={JST_NAME}&token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('items', d.get('results', []))
for t in items:
    print(t.get('_id','?'), t.get('name','?'))
"

# Get specific JST by ID
curl -sk "{PLATFORM_URL}/transformations/{JST_ID}?token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
t = d.get('data', d)
print('Name:', t.get('name'))
print()
print('=== incoming_script ===')
print(t.get('incoming_script','(none)'))
print()
print('=== outgoing_script ===')
print(t.get('outgoing_script','(none)'))
"
```

### Step 4b — Common JST Failure Patterns

JST scripts run in a sandboxed Node.js context. Common issues:

| Issue | Symptom | Fix |
|-------|---------|-----|
| No `return` statement | Script runs but output is `null` | Add `return result;` at end |
| Async code | `Promise {}` in output | JST context is synchronous — remove async/await |
| `undefined` variable | `TypeError: Cannot read property of undefined` | Check that incoming data has the expected shape |
| JSON parse of string | `SyntaxError: Unexpected token` | Use `JSON.parse()` on string fields from task output |
| Access to `require` | `require is not defined` | JST sandbox has no `require` — use built-in JS only |

### Step 4c — Test the JST Script Locally

If the task's input data is available from the job output, test the script manually:

```bash
node -e "
// Paste the incoming_script here and wrap in a function
// Provide a sample 'incoming' object matching the task's input
const incoming = {/* paste from job task output */};
// Paste incoming_script body here:
{INCOMING_SCRIPT}
"
```

---

## Phase 5: Workflow Import Failures

### Step 5a — Validate Before Import

```bash
# Check if workflow JSON is valid before attempting import
python3 -c "
import json, sys
try:
    with open('{WORKFLOW_FILE}') as f:
        d = json.load(f)
    print('JSON valid ✅')
    print('name:', d.get('name','?'))
    print('tasks:', len(d.get('tasks',{})))
    print('version:', d.get('version','?'))
except json.JSONDecodeError as e:
    print(f'🔴 JSON parse error: {e}')
"
```

### Step 5b — Common Import Failure Causes

| Cause | Symptom | Check |
|-------|---------|-------|
| Invalid JSON | `SyntaxError` on import | Validate JSON syntax |
| Missing `name` field | Import rejected | Ensure top-level `name` key exists |
| Task references non-existent app | `No config found` at runtime | Verify `app` field matches `apps.json` type names |
| Circular childJob references | Import succeeds but job hangs | Trace all childJob task `workflow` references |
| Version conflict | `Workflow already exists` | Bump `version` field or delete existing |
| Task IDs with non-hex characters | Workflow validates but `$var` refs silently fail | Ensure all task IDs are `[0-9a-f]{1,4}` |

### Step 5c — Check if Workflow Already Exists

```bash
curl -sk "{PLATFORM_URL}/automation-studio/workflows?name={WORKFLOW_NAME}&token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('items', [])
if items:
    print(f'Workflow already exists ({len(items)} version(s)):')
    for w in items:
        print(f'  v{w.get(\"version\",\"?\")}  id={w.get(\"_id\",\"?\")}')
else:
    print('Workflow does not exist — safe to import fresh')
"
```

---

## Phase 6: ChildJob Analysis

### Step 6a — Find All ChildJobs

```bash
# Get parent job and extract childJob task references
curl -sk "{PLATFORM_URL}/operations-manager/jobs/{PARENT_JOB_ID}?token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
j = d if d.get('_id') else d.get('job', d)
tasks = j.get('tasks', {})
child_ids = []
for tid, t in tasks.items():
    if not isinstance(t, dict): continue
    output = t.get('output', {})
    if isinstance(output, dict):
        child_id = output.get('jobId') or output.get('job_id') or output.get('id')
        if child_id:
            child_ids.append((t.get('name',tid), child_id))
if child_ids:
    print('ChildJob IDs:')
    for name, cid in child_ids:
        print(f'  {name}: {cid}')
else:
    print('No childJob outputs found in task outputs')
"
```

### Step 6b — Fetch ChildJob Status

```bash
curl -sk "{PLATFORM_URL}/operations-manager/jobs/{CHILD_JOB_ID}?token={TOKEN}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
j = d if d.get('_id') else d.get('job', d)
print('ChildJob:', j.get('_id'))
print('Workflow:', j.get('name'))
print('Status:  ', j.get('status'))
errors = j.get('error', [])
if errors:
    print('Errors:')
    for e in (errors if isinstance(errors, list) else [errors]):
        if isinstance(e, dict):
            iap = e.get('IAPerror', e)
            print('  ', iap.get('displayString','?'))
"
```

---

## Phase 7: Workflow Report

Save to `{project_path}/data/{TIMESTAMP}/workflow_report.md`:

```markdown
# Workflow Troubleshoot Report
**Generated:** {YYYY-MM-DD HH:MM:SS UTC}
**Workflow:** {WORKFLOW_NAME}
**Job ID:** {JOB_ID} | **Status:** {status}

## Error Summary
| Field | Value |
|-------|-------|
| IAPerror.source | {source} |
| IAPerror.displayString | {message} |
| Failing Task | {task name} |
| Task Status | {status} |

## Root Cause
{One-sentence diagnosis}

## Failing Task Output
```json
{task output snippet}
```

## Validation Errors
{List or "None"}

## Recommended Actions
1. {Highest-impact fix}
2. {Secondary action}
```

---

## Common Failure Patterns — Quick Reference

| Symptom | Root Cause | Action |
|---------|-----------|--------|
| Job status `error`, `IAPerror.source: adapter` | Adapter not reaching target system | Run `/troubleshoot-adapters {name}` |
| Job stuck in `running` with no task progress | WFE worker saturated or dead | Run `/troubleshoot-jobs` |
| Workflow won't start — `"validation errors"` | Draft workflow | Fix validation errors in Step 3b |
| `No config found for Adapter: {name}` | `app` field = instance name, not type name | Fix `app` field to match type from `apps.json` |
| `$var.job.x` not resolving | Upstream task didn't output `x`, or task ID is non-hex | Check task output schema and task IDs |
| JST output is `null` | Missing `return` statement | Add `return result` to outgoing/incoming script |
| ChildJob never completes | Parent job variable wiring issue | Check childJob task `variables` array format |
| `Job has no available transitions` | No error transition on failed adapter task | Add `"state": "error"` transition to the task |
