# Troubleshooting Spec: Troubleshoot Workflows

## 1. Problem Statement

When an IAP workflow job fails or won't start, engineers face a multi-step investigation with no consistent process: check the UI, open the job, look at the error, guess at the cause. The `IAPerror` structure is nested and not human-readable at a glance. Validation errors block jobs from starting but are displayed without context. JST failures are opaque. ChildJob error chains require opening multiple jobs manually.

**Goal:** Systematically traverse the job error chain — from the top-level `job.error` array through failing task outputs, validation errors, JST scripts, and childJob chains — to identify root cause and deliver an actionable finding.

---

## 2. High-Level Flow

```
Fetch Job   →   Parse Errors   →   Classify   →   Deep Dive   →   Report
    │                │                │               │               │
    │                │                │               │               │
 By job ID       job.error[]      adapter /        JST script,    Root cause +
 or workflow     + failing        workflow /        import err,    task output +
 name search     task output      jst / om         childJob       recommendation
                                  / wfe            chain
```

---

## 3. Investigation Phases

### Fetch Job
If the user has a job ID, fetch it directly via `/operations-manager/jobs/{JOB_ID}`. If not, search recent jobs for the workflow by name and status=error. Display job ID, workflow name, status, start/end time, and duration.

### Parse Errors
Extract `job.error[]` array — iterate each entry, pull `IAPerror.source` and `IAPerror.displayString`. Extract task map from `job.tasks`, find tasks with `status: error`, and display their outputs and error fields.

### Classify by Error Source

| Source | Investigation Path |
|--------|-------------------|
| `adapter` | Route to `/troubleshoot-adapters` |
| `automation-studio` | Workflow validation errors — check draft state |
| `operations-manager` | Worker saturation or job timeout — route to `/troubleshoot-jobs` |
| `WorkFlowEngine` | WFE execution error — route to `/troubleshoot-jobs` |
| `jst` | JST script error — inspect inline |
| Task name | Task-specific failure — inspect task output |

### Workflow Validation Analysis
GET the workflow definition. Check `errors[]` array — any entry means the workflow is in draft state and cannot start. Inspect task transitions for missing error transitions on adapter/external tasks (→ "Job has no available transitions" at runtime). Verify all task IDs are hex-only.

### JST Deep Dive
If source is `jst`: fetch the transformation by name or ID. Print `incoming_script` and `outgoing_script`. Check for missing `return` statement, async code, `require` usage, and undefined variable access. Suggest a local `node -e` test with sample input.

### Import Failure Analysis
If the user is trying to import a workflow: validate JSON syntax, check for duplicate workflow name, verify `app` fields use type names not instance names, check for non-hex task IDs, check for circular childJob references.

### ChildJob Chain Traversal
Scan task outputs of the parent job for `jobId` / `job_id` fields. Fetch each child job. Recursively check child job errors. Build a chain: `Parent → ChildJob → GrandchildJob` with status at each level.

### Report
Save to `data/{TIMESTAMP}/workflow_report.md`. Print root cause, failing task, error message, and top recommended action.

---

## 4. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Read-only throughout | GET only | Investigation must not alter job state |
| Error source drives routing | `IAPerror.source` is the primary classifier | Source is reliable; avoids guessing from error text |
| Validation errors treated as distinct case | Draft state = cannot start | Separate from runtime failures; requires workflow edit, not re-run |
| ChildJob traversal is recursive | Follow chain until leaf | Root cause is often in a grandchild job, not the parent |
| JST tested locally with node | Suggest `node -e` test | Faster iteration than re-running the workflow |
| Adapter errors routed, not investigated | Redirect to `/troubleshoot-adapters` | Keeps each skill focused |

---

## 5. Scope

**In scope:** Job error array analysis, failing task output inspection, `IAPerror.source` classification, workflow validation error analysis, JST script failure diagnosis, workflow import failure analysis, childJob error chain traversal, transition gap detection (missing error transitions), task ID validity check.

**Out of scope:** Adapter root-cause diagnosis (→ `/troubleshoot-adapters`). Slow/stuck job performance investigation (→ `/troubleshoot-jobs`). Database-level query analysis (→ `/troubleshoot-databases`). Log file collection (→ `/troubleshoot-logs`).

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Job error array is empty despite failure | Root cause unclear | Check individual task `output` and `error` fields directly |
| ChildJob IDs not in task output | Chain cannot be traversed | Note limitation; ask user to check UI for child job references |
| JST error is in `incoming_script` vs `outgoing_script` | Wrong script inspected | Check both; error message usually specifies which direction |
| Workflow has hundreds of tasks | Analysis is slow | Focus on tasks with `status: error` first |
| `$var` ref silently fails (non-hex task ID) | No error, wrong output | Check all task IDs for non-hex characters |
| Validation errors after import | Workflow in draft | Always check `workflow.errors[]` after import, not just HTTP status |

---

## 7. Requirements

### What access is needed

| Credential / Access | Required | If Not Available |
|--------------------|----------|------------------|
| `PLATFORM_URL` + auth credentials in `.env` | Yes | Cannot proceed |
| Job ID or workflow name | Yes (one of them) | Ask the user |
| Workflow ID (for definition fetch) | Derived from workflow name search | Resolved automatically |

### What external systems are involved

| System | Purpose | Required |
|--------|---------|----------|
| IAP Operations Manager API | Fetch job and error data | Yes |
| IAP Automation Studio API | Fetch workflow definition and validation errors | Yes |
| IAP Transformations API | Fetch JST script definitions | Only for JST errors |

### Discovery Questions

Ask the user before investigating:

1. Do you have a specific job ID, or should I search by workflow name?
2. What workflow is failing? Is it a workflow you built or one you imported?
3. Is this a job that errors at runtime, or a workflow that won't import / can't be started?
4. Is there a specific error message you see in the UI (copy/paste helps)?
5. Does this workflow call child workflows? If so, do you know which ones?
6. Has this workflow worked before, or is this the first run after a change?

---

## 8. Extended Troubleshooting — Import Failures & Stuck Jobs

---

### 8a. Workflow Import Failures

Workflow imports fail silently or with cryptic errors. Always validate locally before attempting API import, and always check `workflow.errors[]` post-import.

**Step 1 — Validate JSON syntax locally before importing:**
```bash
python3 -c "import json,sys; json.load(open('{workflow_file}')); print('JSON valid')"
```

**Step 2 — Check for the most common pre-import errors:**

| Check | Command | What to look for |
|-------|---------|-----------------|
| Duplicate workflow name | `GET /automation-studio/automations?name={NAME}` | Returns items — name already exists |
| Non-hex task IDs | `jq '.automation.tasks \| keys[]' wf.json \| grep -v "^[0-9a-f]*$"` | Any non-hex ID causes `$var` references to silently fail |
| Wrong `app` field (instance vs type) | `jq '.automation.tasks[] \| select(.location=="Adapter") \| {id:.name,app}' wf.json` | `app` must be type name (e.g., `Servicenow`) not instance name (e.g., `servicenow-prod`) |
| Missing error transitions on adapter tasks | `jq '.automation.transitions' wf.json` | Each adapter task must have both `success` and `error` transition |
| Circular childJob refs | Check all `childJob.incoming.workflow` values | A calls B calls A → import succeeds but job never completes |
| `$var` inside nested objects | `jq '.. \| strings \| select(startswith("$var"))' wf.json` | `$var` in nested object values doesn't resolve at runtime |

**Step 3 — Attempt import and capture full error response:**
```bash
curl -sk -X POST "{PLATFORM_URL}/automation-studio/automations" \
  -H "Authorization: Bearer {TOKEN}" \
  -H "Content-Type: application/json" \
  -d @{workflow_file} \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d,indent=2))"
```

**Step 4 — Check `workflow.errors[]` after import (draft state):**
```bash
curl -sk "{PLATFORM_URL}/automation-studio/automations/{ID}" \
  -H "Authorization: Bearer {TOKEN}" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
wf = d.get('data',d)
errors = wf.get('errors',[])
print('Draft errors:', len(errors))
for e in errors:
    print(' -', e.get('task'), ':', e.get('message','?'))
"
```

Any entry in `errors[]` = workflow is in **draft state** and **cannot be started**. Fix each error and re-PUT.

**Common import errors and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| `name already exists` | Workflow with same name is on platform | Rename or delete existing; include `_id` on PUT |
| `Cannot find match for input: 'X' from model` | Task incoming variable name doesn't match schema | Fetch correct schema via `multipleTaskDetails`, align field names |
| `task ID must match pattern ^[0-9a-f]{1,4}$` | Non-hex task ID in JSON | Rename all task IDs to hex (e.g., `a1b2`, `cj01`, `nv01`) |
| `No config found for Adapter` at runtime | `app` uses instance name not type name | Change `app` and `locationType` to type name from `apps.json` |
| `Job has no available transitions` at runtime | Missing error transition on adapter/external task | Add `"state": "error"` transition from every adapter task |
| `$var` reference resolves to `undefined` | Non-hex task ID in the referenced task | Rename task ID to hex |
| `Cannot find workflow: X` | childJob references workflow not on platform or wrong project scope | Check `workflow` field matches exact name; add `@projectId:` prefix if project-scoped |
| Validation error after import | `errors[]` array not empty | Check each error entry; workflow is draft until all resolved |

---

### 8b. JSON Form Import Failures

JSON forms are the UI input layer for workflows (Operations Manager triggers, manual jobs). Import failures block users from starting jobs through the UI.

**Step 1 — Validate the form schema:**
```bash
# Validate JSON syntax
python3 -c "import json,sys; json.load(open('{form_file}')); print('JSON valid')"

# Check required top-level structure
python3 -c "
import json
d = json.load(open('{form_file}'))
required = ['name','schema','form']
missing = [k for k in required if k not in d]
print('Missing top-level keys:', missing or 'none')
print('Schema type:', d.get('schema',{}).get('type','?'))
print('Form fields:', len(d.get('form',[])))
"
```

**Step 2 — Attempt import:**
```bash
curl -sk -X POST "{PLATFORM_URL}/form-builder/forms" \
  -H "Authorization: Bearer {TOKEN}" \
  -H "Content-Type: application/json" \
  -d @{form_file} \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d,indent=2)[:500])"
```

**Common JSON form errors and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| `name already exists` | Form with same name exists | Delete existing or use PUT to update; forms use `{name}` as unique key |
| `schema validation failed` | `schema` object is malformed JSON Schema | Validate with jsonschema; ensure all `$ref` entries resolve |
| `form field references undefined schema property` | A `form[]` item references a key not in `schema.properties` | Align form field keys with schema property names exactly |
| `type mismatch` | Schema says `array` but form renders as string input | Change field `type` in schema to match expected UI widget |
| Form saves but renders blank | `form` array is empty or all fields have `condition` blocks that evaluate to false | Check `form` array length; review `condition` expressions |
| Trigger linked to form fails | Form variable names don't match workflow `inputSchema.properties` | Align form field names with workflow input variable names exactly |

**Step 3 — Check form renders correctly after import:**
```bash
curl -sk "{PLATFORM_URL}/form-builder/forms/{FORM_NAME}" \
  -H "Authorization: Bearer {TOKEN}" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
form = d.get('data',d)
print('Form name:', form.get('name'))
print('Fields:', len(form.get('form',[])))
for f in form.get('form',[])[:10]:
    key = f.get('key') if isinstance(f,dict) else f
    print(' -', key)
"
```

---

### 8c. Template Import Failures (Jinja2 / TextFSM)

Templates are used for config generation (Jinja2) and output parsing (TextFSM). Import failures are usually syntax errors in the template body.

**Step 1 — Validate template locally before importing:**

For Jinja2:
```bash
python3 -c "
from jinja2 import Environment, TemplateSyntaxError
env = Environment()
try:
    env.parse(open('{template_file}').read())
    print('Jinja2 syntax OK')
except TemplateSyntaxError as e:
    print(f'Syntax error at line {e.lineno}: {e.message}')
"
```

For TextFSM:
```bash
python3 -c "
import textfsm, io
try:
    fsm = textfsm.TextFSM(io.StringIO(open('{template_file}').read()))
    print(f'TextFSM OK — {len(fsm.states)} states, {len(fsm.values)} values')
except Exception as e:
    print('TextFSM error:', e)
"
```

**Step 2 — Attempt import:**
```bash
curl -sk -X POST "{PLATFORM_URL}/template-builder/templates" \
  -H "Authorization: Bearer {TOKEN}" \
  -H "Content-Type: application/json" \
  -d @{template_json_file} \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d,indent=2)[:300])"
```

**Common template errors and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| `name already exists` | Template with same name on platform | Rename or PUT to update existing |
| `unexpected end of template` | Unclosed `{%` or `{{` block | Add missing `%}` or `}}` |
| `undefined variable` at render time | Jinja2 variable used but not passed in | Ensure all `{{ varName }}` have corresponding input variable defined |
| TextFSM `ValueError: ` | Malformed state definition or missing `EOF` at end | Add `EOF` as final state; fix `Value` or `State` syntax |
| Template renders empty output | Regex patterns in TextFSM don't match actual device output | Test with sample output using `textfsm_parse_file` |
| `<!var!>` not substituted | Command template syntax used in wrong context | `<!var!>` is for command templates only; use `{{ var }}` in Jinja2 |

---

### 8d. Command Template Import Failures

Command templates define MOPs (Method of Procedure) — pre/post checks, configuration commands, and validation rules. Failures block network automation procedures.

**Step 1 — Validate structure before importing:**
```bash
python3 -c "
import json
d = json.load(open('{cmd_template_file}'))
required = ['name','description','commands']
missing = [k for k in required if k not in d]
print('Missing keys:', missing or 'none')
print('Commands:', len(d.get('commands',[])))
# Check for <!var!> syntax in commands
import re
for i, cmd in enumerate(d.get('commands',[])):
    tmpl = cmd.get('template','')
    vars_found = re.findall(r'<!(.+?)!>', tmpl)
    print(f'  cmd[{i}] vars: {vars_found}')
"
```

**Step 2 — Attempt import:**
```bash
curl -sk -X POST "{PLATFORM_URL}/command-template-builder/command-templates" \
  -H "Authorization: Bearer {TOKEN}" \
  -H "Content-Type: application/json" \
  -d @{cmd_template_file} \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d,indent=2)[:300])"
```

**Common command template errors and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| `name already exists` | Duplicate command template name | Rename or PUT to update |
| `validation rule regex invalid` | Regex in pre/post check is malformed | Test regex with `python3 -c "import re; re.compile('{PATTERN}')"` |
| `<!var!>` not passed at runtime | Variable referenced in template not in workflow variables at execution time | Add variable to workflow inputSchema and wire to command template task |
| Analytic template mismatch | Pre/post check uses TextFSM analytic template that doesn't parse device output | Test analytic template separately with sample device output |
| Commands execute but validation fails | Regex matches wrong line in output | Make regex more specific; anchor with `^` or add context lines |

---

### 8e. Transformation (JST) Import Failures

Transformations (JSON Schema Transformations) are JavaScript functions used inline in workflows. Failures block any workflow that references the transformation.

**Step 1 — Test the script locally:**
```bash
# Test incoming_script (transforms input to intermediate)
node -e "
const incoming = {/* sample input */};
const iapT = { incoming };
// Paste incoming_script here
const result = {/* run script */};
console.log(JSON.stringify(result, null, 2));
"

# Test outgoing_script (transforms intermediate to output)
node -e "
const outgoing = {/* sample intermediate */};
// Paste outgoing_script here
"
```

**Step 2 — Check for common script errors:**

| Error | Cause | Fix |
|-------|-------|-----|
| `return` statement missing | Script executes but returns `undefined` | Add explicit `return result;` at end of `incoming_script` |
| `require()` fails | Node.js `require` is not available in JST sandbox | Remove `require`; use only native JS + provided IAP utilities |
| `async/await` not supported | JST runs synchronously | Convert to synchronous code; use `.then()` is also unsupported |
| `Cannot read property of undefined` | Accessing `.key` on null/undefined input | Add null check: `if (!iapT.incoming.x) return {}` |
| Script passes lint but fails at runtime | Edge case in input data not tested locally | Add defensive checks for missing fields; test with real job data |

**Step 3 — Import and verify:**
```bash
curl -sk -X POST "{PLATFORM_URL}/transformations" \
  -H "Authorization: Bearer {TOKEN}" \
  -H "Content-Type: application/json" \
  -d @{jst_file} \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Created:', d.get('name','?'), d.get('_id','?'))"
```

---

### 8f. Project Import Failures

Project imports bundle all assets together. Failures cascade — if one component fails, the whole project import can fail or import in a broken state.

**Step 1 — Inspect the project bundle before importing:**
```bash
python3 -c "
import json
d = json.load(open('{project_file}'))
proj = d.get('project',d)
print('Project name:', proj.get('name'))
print('Components:')
for c in proj.get('components',[]):
    print(f'  {c.get(\"type\",\"?\")} — {c.get(\"name\",\"?\")}')
"
```

**Step 2 — Import:**
```bash
curl -sk -X POST "{PLATFORM_URL}/projects/import" \
  -H "Authorization: Bearer {TOKEN}" \
  -H "Content-Type: application/json" \
  -d @{project_file} \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d,indent=2)[:500])"
```

**Step 3 — Verify all components imported without errors:**
```bash
curl -sk "{PLATFORM_URL}/projects/{PROJECT_ID}" \
  -H "Authorization: Bearer {TOKEN}" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
proj = d.get('data',d)
print('Project:', proj.get('name'))
for c in proj.get('components',[]):
    print(f'  {c.get(\"type\")} — {c.get(\"name\")} [{c.get(\"state\",\"?\") }]')
"
```

**Common project import errors and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| Component `name already exists` on platform | An asset with the same name exists outside the project | Rename the conflicting asset, or delete before reimporting |
| childJob `Cannot find workflow: X` at runtime | childJob refs a workflow by plain name but asset is now project-scoped | Update `workflow` field to `@{projectId}: {workflowName}` |
| Project imports but workflows are draft | Validation errors in one or more workflows | Check each workflow's `errors[]` array post-import |
| Missing members after import | Project members not included in import bundle | PATCH members separately after import via `PUT /projects/{ID}/members` |
| Component type invalid | `type` field in component uses wrong string | Valid types: `workflow`, `template`, `transformation`, `jsonForm`, `mopCommandTemplate`, `mopAnalyticTemplate` |

---

### 8g. Jobs Stuck — Workflow-Level View

Use this when a job is stuck `running` and `/troubleshoot-jobs` confirms there is no WFE/Redis/MongoDB bottleneck. The cause is in the workflow definition itself.

**Step 1 — Identify which task is stuck:**
```bash
curl -sk "{PLATFORM_URL}/operations-manager/jobs/{JOB_ID}" \
  -H "Authorization: Bearer {TOKEN}" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
job=d.get('data',d)
tasks=job.get('tasks',{})
print('Job status:', job.get('status'))
print('Running tasks:')
for tid, t in tasks.items():
    if t.get('status') == 'running':
        start = t.get('start','?')
        print(f'  {tid} ({t.get(\"name\",\"?\")}) — started {start}')
print('Error:', job.get('error',[]))
"
```

**Step 2 — Match stuck task to known patterns:**

| Stuck scenario | What you see | Root cause | Fix |
|---------------|-------------|-----------|-----|
| Job running, no task running | `job.status: running`, all tasks `complete` | Missing transition from last task to `workflow_end` | Add transition from final task to `workflow_end` |
| Adapter task running > 60 min | Task status `running`, no `end` time | Upstream API not responding; no timeout configured | Check adapter connectivity; set `request_timeout` on adapter |
| childJob task running forever | `cj01` status `running`, child job count = 0 | Referenced child workflow not found or draft | Check `workflow` field; verify child workflow is published |
| Evaluation task not transitioning | `eval` task `complete` but job stuck after | Both `success` and `failure` transitions route to same JSON key | JSON cannot have duplicate keys; add intermediate task for one path |
| Loop stuck | childJob `running`, some child jobs complete, others don't | One child job errored with no error transition | Check individual child job `error[]`; add error transition on child workflow tasks |
| newVariable task stuck | Task status `running` for > 5 min | Platform WFE unresponsive (not a workflow issue) | Route to `/troubleshoot-jobs` — this is a WFE/infra issue |
| Job `complete` but never reached `workflow_end` | `status: complete` but expected tasks didn't run | Error transition routed to `workflow_end` silently | Check error path — job may have completed via error route; check `job.error[]` |

**Step 3 — Check for missing transitions in the workflow definition:**
```bash
curl -sk "{PLATFORM_URL}/automation-studio/automations/{WF_ID}" \
  -H "Authorization: Bearer {TOKEN}" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
wf=d.get('data',d)
tasks=set(wf.get('tasks',{}).keys())
transitions=wf.get('transitions',{})
print('Tasks with no outgoing transition:')
for t in tasks:
    if t in ('workflow_start','workflow_end'): continue
    if not transitions.get(t):
        print(f'  WARNING: {t} has no transitions — job will stick here')
print('Tasks with no incoming transition:')
all_targets = set()
for src,outs in transitions.items():
    all_targets.update(outs.keys())
for t in tasks:
    if t in ('workflow_start',) : continue
    if t not in all_targets:
        print(f'  WARNING: {t} is unreachable')
"
```

**Step 4 — Check for infinite loops:**
- Any cycle in the transition graph (A → B → A) will cause a job to loop forever
- Look for evaluation tasks that can loop back to an earlier task without a terminal condition
- Manual check: draw the transition graph from `transitions` block and verify every path reaches `workflow_end`

---

## 9. Known Bugs — Quick Reference

Recognise these before running a full investigation. If the error string matches, skip straight to the workaround and file the ENG escalation.

---

### ISD-9261 — Enable query TypeError on looped childJob task
**Platform:** 6.4.0 | **Component:** Automation Studio UI | **Status:** Open (no ENG fix as of 2026-06-09)

**Error signature (browser console only — not in job.error[]):**
```
TypeError: Cannot set properties of undefined (setting 'childJobLoopIndex')
```

**Trigger:** User clicks the "enable query" toggle on any input field of a childJob task that has `loopType` set (`parallel` or `sequential`). The toggle only appears when loop is enabled — so the bug is invisible without a loop configured.

**Root cause (hypothesis):** The enable query handler runs childJob-specific initialization code that sets `taskConfig.childJobLoopIndex` at click time. At that moment, the task config state object has not yet been instantiated → TypeError. No other task type has this property, so no other task type is affected.

**Scope:**

| Condition | enable query visible? | Result |
|-----------|----------------------|--------|
| childJob — loop NOT enabled | No | n/a |
| childJob — loop enabled (`loopType: parallel`) | Yes | TypeError on click |
| Any other task type | Yes | Works |

**Not affected:** WFE, job execution, MongoDB, Redis, adapters. Runtime loop execution works correctly.

**Workaround:**
Pre-extract the `data_array` value before it reaches the childJob. Two options:

1. **Pass the array as a separate flat job input** and wire `data_array` to `$var.job.arrayVar` directly — no enable query needed.
2. **Add a pre-processing task** (`makeData`, `merge`) before the childJob to build the array, then wire `data_array` to that task's output.

**Demo workflows (PE Labs):**
- `ISD-9261 - Parent Workaround Demo` (`cf4d44a1-2429-4a91-81a3-c633d825c8e9`)
- `ISD-9261 - Child Demo` (`a827f11d-8549-45a7-bb8a-e88ee5733c0c`)

**STR:** `data/2026-06-09T00-00-00/ISD-9261/steps-to-reproduce.md`

---

## 10. Acceptance Criteria

1. Job is fetched by ID or located by workflow name + status=error
2. All entries in `job.error[]` are extracted and `IAPerror.source` + `IAPerror.displayString` are displayed
3. All tasks with `status: error` are identified and their outputs are shown
4. Error source is classified and routed correctly (adapter → sub-skill, jst → inline analysis, etc.)
5. Workflow validation errors (`workflow.errors[]`) are checked and draft state is identified
6. Missing error transitions on adapter/external tasks are flagged
7. Non-hex task IDs are detected and flagged as `$var` reference risk
8. JST errors include: which script (`incoming`/`outgoing`), likely cause, and local test suggestion
9. ChildJob IDs are extracted from task outputs and each child job's status and errors are fetched
10. A markdown report is saved to `data/{TIMESTAMP}/workflow_report.md` with root cause and recommendations
