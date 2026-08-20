---
name: troubleshoot-triage
description: Ticket triage sub-skill for ISD (customer support), IPSO, and ENG (engineering bug) tickets. Offline only — Jira + Confluence + local reference files. Reads the ticket, extracts structured context, checks platform support status and version-specific behavioral notes, mines past cases, searches Confluence, detects priority mismatches, generates a targeted question list, and produces a pre-investigation summary. No platform authentication required. Accepts ISD-XXXX, IPSO-XXXX, or ENG-XXXX ticket keys.
argument-hint: "[TICKET-KEY | --list] [--auto]"
---

# Ticket Triage Sub-Skill

**Role:** You are performing the offline triage phase of a support or engineering investigation. You read Jira tickets, cross-reference the Itential platform knowledge base, mine past cases, search Confluence, and produce a structured pre-investigation summary. You never touch the customer platform — no platform auth, no `.env` credentials needed here.

---

## CRITICAL SAFETY RULES

- **All Jira comments must be internal** — always set `commentVisibility: {"type": "role", "value": "Service Desk Team"}` on every `addCommentToJiraIssue` call
- **Never post comments without engineer approval** — present the draft and wait for explicit approval before posting (unless `--auto` flag is active)
- **Never create ENG tickets without explicit engineer approval** — present the draft and wait (unless `--auto` is active)
- **Read-only Jira queries only** — no field edits, no transitions, no priority changes without explicit consent
- **Never guess field values** — mark unknown fields as `unknown`

---

## Invocation Modes

**`/troubleshoot-triage ISD-XXXX`**
Full interactive triage for a customer support ticket. Human gates at Step 1g (question list review) and Step 1h (proceed/wait decision).

**`/troubleshoot-triage IPSO-XXXX`** or **`/troubleshoot-triage ENG-XXXX`**
Engineering bug triage. Skips customer-specific steps (SLA, priority mismatch, deployment questions). Adds engineering question list. At close, drafts an ENG ticket for promotion (if input is IPSO).

**`/troubleshoot-triage --list`**
Print all in-flight investigations found in the `data/` directory. No ticket key needed.

**`--auto` flag** (append to any ticket invocation)
Unattended mode — skips both human gates. Posts the question list directly as an internal comment and writes all output files. Suitable for autonomous/scheduled triage. Example: `/troubleshoot-triage ISD-XXXX --auto`

---

## --list: Active Investigation Inventory

When invoked with `--list` (no ticket key):

```bash
# Find all in-flight investigations
find {project_path}/data -name "pre-investigation-summary.md" | sort -r | while read f; do
  dir=$(dirname "$f")
  ticket=$(basename "$dir")
  timestamp=$(basename "$(dirname "$dir")")
  status=$(head -5 "$f" | grep "SLA\|Status\|Priority" | head -1)
  echo "  [$timestamp]  $ticket  — $status"
done
```

Print a table:
```
Active Investigations:
  [2026-08-20T09-12-00]  ISD-9261  — SLA: At risk | Priority: High
  [2026-08-19T14-05-30]  IPSO-443  — Priority: Medium | ENG draft: saved
  [2026-08-18T11-00-00]  ISD-9200  — SLA: On track | Priority: Low
```

Then stop — do not proceed to any ticket triage unless a specific key was also given.

---

## Resume Check

Before starting any new triage, check whether an investigation folder already exists for the given ticket key:

```bash
TICKET_KEY="{TICKET_KEY}"
PROJECT_PATH="{project_path}"

existing=$(find "$PROJECT_PATH/data" -maxdepth 2 -type d -name "$TICKET_KEY" 2>/dev/null | sort -r | head -1)
if [ -n "$existing" ]; then
  timestamp=$(basename "$(dirname "$existing")")
  echo "Found existing triage: $existing (started $timestamp)"
fi
```

If a folder is found:
- Show the engineer: `"Found existing triage for {TICKET_KEY} from {timestamp}. Resume it or start fresh? [resume/fresh]"`
- **Resume:** set `DATA_DIR` to the existing folder path and skip to Step 1h to re-present the summary
- **Fresh:** create a new timestamped folder and run full triage from Step 1a

If no folder exists → proceed normally.

---

## Project Type Detection

Detect the Jira project from the ticket key prefix:

| Prefix | Type | Flow |
|--------|------|------|
| `ISD-` | Customer support ticket | Full Steps 1a–1h: SLA, priority mismatch, customer question list |
| `IPSO-` | Engineering/product bug | Steps 1a–1h with engineering variant; IPSO→ENG promotion at close |
| `ENG-` | Existing engineering ticket | Steps 1a–1h with engineering variant; no promotion (already an ENG ticket) |

---

## ISD Tickets — Full Triage (Steps 1a–1h)

### Step 1a — Read the ISD Ticket

If `JIRA_URL` + `JIRA_USER` + `JIRA_API_TOKEN` are in `.env`:

```bash
TICKET_KEY="{ISD_TICKET_KEY}"

# Fetch issue
curl -s "${JIRA_URL}/rest/api/3/issue/${TICKET_KEY}?expand=renderedFields" \
  -u "${JIRA_USER}:${JIRA_API_TOKEN}" \
  -H "Accept: application/json" \
  | python3 -c "
import sys, json

def extract_adf_text(node):
    if not node: return ''
    if isinstance(node, str): return node
    text = []
    for block in node.get('content', []):
        for inline in block.get('content', []):
            if inline.get('type') == 'text':
                text.append(inline.get('text',''))
        text.append('\n')
    return ''.join(text).strip()

d = json.load(sys.stdin)
f = d.get('fields', {})

print('╔══════════════════════════════════════════════════════╗')
print('  ISD TICKET:', d.get('key','?'))
print('╚══════════════════════════════════════════════════════╝')
print('Summary:  ', f.get('summary','?'))
print('Status:   ', f.get('status',{}).get('name','?'))
print('Priority: ', f.get('priority',{}).get('name','?'))
print('Reporter: ', f.get('reporter',{}).get('displayName','?'))
print('Assignee: ', (f.get('assignee') or {}).get('displayName','Unassigned'))
print('Created:  ', f.get('created','?')[:19])
print('Updated:  ', f.get('updated','?')[:19])
print()

for key in ['customfield_10020', 'customfield_10030', 'customfield_10040']:
    sla = f.get(key)
    if isinstance(sla, list):
        for s in sla:
            if isinstance(s, dict) and s.get('name'):
                breached = s.get('breached', False)
                ongoing  = s.get('ongoingCycle',{})
                flag = '🔴 BREACHED' if breached else ('⚠️  AT RISK' if ongoing.get('breached') else '✅')
                print(f'SLA [{s[\"name\"]}]: {flag}')

print()
print('── DESCRIPTION ──────────────────────────────────────')
print(extract_adf_text(f.get('description')) or f.get('description','(no description)'))
"

# Fetch all comments
curl -s "${JIRA_URL}/rest/api/3/issue/${TICKET_KEY}/comment?orderBy=created&maxResults=50" \
  -u "${JIRA_USER}:${JIRA_API_TOKEN}" \
  -H "Accept: application/json" \
  | python3 -c "
import sys, json
def extract_adf_text(node):
    if not node: return ''
    if isinstance(node, str): return node
    text = []
    for block in node.get('content', []):
        for inline in block.get('content', []):
            if inline.get('type') == 'text': text.append(inline.get('text',''))
        text.append('\n')
    return ''.join(text).strip()
d = json.load(sys.stdin)
comments = d.get('comments', [])
print(f'── COMMENTS ({len(comments)}) ────────────────────────────────')
for c in comments:
    author = c.get('author',{}).get('displayName','?')
    ts     = c.get('created','?')[:19]
    text   = extract_adf_text(c.get('body')) or str(c.get('body',''))
    print(f'[{ts}] {author}:')
    print(text[:500])
    print()
"

# List attachments and blueprint field
curl -s "${JIRA_URL}/rest/api/3/issue/${TICKET_KEY}?fields=attachment,blueprint" \
  -u "${JIRA_USER}:${JIRA_API_TOKEN}" \
  -H "Accept: application/json" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
fields = d.get('fields', {})
attachments = fields.get('attachment', [])
if attachments:
    print(f'── ATTACHMENTS ({len(attachments)}) ─────────────────────────────')
    for a in attachments:
        print(f'  {a.get(\"filename\",\"?\")}  ({a.get(\"size\",0)//1024}KB)  {a.get(\"created\",\"?\")[:10]}')
blueprint = fields.get('blueprint') or fields.get('customfield_blueprint')
if blueprint:
    print()
    print('── BLUEPRINT (adapter/component versions) ───────────')
    if isinstance(blueprint, dict):
        for k, v in blueprint.items(): print(f'  {k}: {v}')
    elif isinstance(blueprint, list):
        for item in blueprint: print(f'  {item}')
    else: print(f'  {blueprint}')
"
```

If Atlassian MCP is available, prefer it:
```
mcp__claude_ai_Atlassian_MCP__getJiraIssue(issueIdOrKey: "{ISD_TICKET_KEY}")
```

---

### Step 1b — Extract Structured Context

Parse and save to `{project_path}/data/{TIMESTAMP}/{TICKET_KEY}/ticket_context.md`:

```
╔══════════════════════════════════════════════════════════╗
  TICKET CONTEXT — {ISD_TICKET_KEY}
╠══════════════════════════════════════════════════════════╣
  TICKET
  ──────
  Ticket:        {ISD_TICKET_KEY}
  Summary:       {one-line summary}
  Priority:      Critical | High | Medium | Low
  Severity:      S1 | S2 | S3 | S4
  SLA Status:    On track | At risk | BREACHED
  Customer:      {customer name / org}

  ENVIRONMENT
  ──────────
  IAP Version:   {e.g. 6.3.2 | unknown}
  IAG Version:   {4 | 5 | unknown}
  Deployment:    Docker | VM | Kubernetes | unknown
  OS:            {RHEL 8.x | Ubuntu 22.04 | unknown}
  MongoDB:       {version | unknown}
  Redis:         {version | unknown}
  Adapter(s):    {adapter name(s) and package IDs | none | unknown}
                 ← read from the ticket's blueprint field first

  PROBLEM
  ───────
  Component:     IAP | IAG | Adapter | MongoDB | Redis | OS | Kafka | unknown
  Symptom:       {what the customer sees — their words}
  Error Message: {exact error string | "none provided"}
  Job ID:        {if provided | none}
  Workflow:      {workflow name | none}
  Incident Time: {date + time + timezone | unknown}
  Frequency:     always | intermittent | once
  Regression:    yes (was working before) | no (never worked) | unknown
  Steps Provided: yes | no

  ATTACHMENTS
  ──────────
  {filename — description, OR "none"}
╚══════════════════════════════════════════════════════════╝
```

---

### Step 1c — Platform Support Status Check & Version-Specific Behavioral Notes

Read `data/product-capability-reference.md` and run both checks against the customer's IAP version:

**Part A — Support Status (Section 1 of reference)**
```
Determine:
  - Active support → note inline, continue
  - Maintenance-only → warn: "⚠️ IAP {version} is in maintenance-only support. Critical bugs and security patches only."
  - End of Life → flag immediately: "⚠️ IAP {version} is EOL as of {date}. Standard support unavailable. Recommend upgrade."
  - Not found → "support status unverified — check support.itential.com"
```

**Part B — Version-Specific Behavioral Notes (Section 7 of reference)**

Scan Section 7 for rows matching the customer's IAP version. For each match, append to `ticket_context.md`:

```markdown
## Version-Specific Behavioral Notes (from product-capability-reference.md Section 7)
- [{version}] {Component}: {What Does NOT Apply / Exist} — {Diagnostic Impact}
- [{version}] {Component}: {What Applies}
```

No matches → no block. These notes must be included in the pre-investigation summary (Step 1h) and in any sub-skill invocation message passed by the orchestrator in Phase 2.

---

### Step 1d — Mine Similar Jira Tickets

Search ISD (past support cases) and ENG (engineering bugs) for matching symptoms:

```
# ISD similar cases
mcp__claude_ai_Atlassian_MCP__searchJiraIssuesUsingJql(
  jql: "project = ISD AND text ~ \"{ERROR_TERM}\" ORDER BY resolutiondate DESC",
  fields: ["summary","status","resolution","comment","fixVersions"]
)

# ENG bugs
mcp__claude_ai_Atlassian_MCP__searchJiraIssuesUsingJql(
  jql: "project = ENG AND issuetype = Bug AND text ~ \"{ERROR_TERM}\" ORDER BY created DESC",
  fields: ["summary","status","fixVersions","affectedVersions","resolution","comment"]
)
```

| Result type | Extract | Use as |
|---|---|---|
| Resolved ISD | Root-cause comment + resolution steps | Top diagnostic hypothesis |
| Resolved ENG (fix version > customer version) | Workaround from ENG comments | Known unpatched bug |
| Open ENG | Linked ISDs + engineering notes | Phase 5 escalation reference |

Save to `{project_path}/data/{TIMESTAMP}/{TICKET_KEY}/known_issues.md`.

---

### Step 1e — Search Confluence for Relevant Knowledge

```
mcp__claude_ai_Atlassian_MCP__searchConfluenceUsingCql(
  cql: "type = page AND text ~ \"{ERROR_TERM}\" ORDER BY lastmodified DESC",
  limit: 10
)

mcp__claude_ai_Atlassian_MCP__searchConfluenceUsingCql(
  cql: "type = page AND text ~ \"{COMPONENT}\" AND text ~ \"troubleshoot\" ORDER BY lastmodified DESC",
  limit: 10
)

mcp__claude_ai_Atlassian_MCP__searchConfluenceUsingCql(
  cql: "type = page AND text ~ \"{SYMPTOM_KEYWORD}\" AND (title ~ \"investigation\" OR title ~ \"incident\" OR title ~ \"root cause\" OR title ~ \"runbook\") ORDER BY lastmodified DESC",
  limit: 10
)
```

Fetch relevant pages with `getConfluencePage`. Extract: step-by-step commands (runbooks), root cause + resolution (post-mortems), version-specific regressions (release notes).

Save titles, URLs, and key excerpts to `{project_path}/data/{TIMESTAMP}/{TICKET_KEY}/confluence_references.md`.

---

### Step 1f — Priority Mismatch Detection (ISD only)

Scan ticket description for any of these signals:

| Signal | Implication |
|---|---|
| "production is down", "cannot work", "all users affected" | Total/near-total service loss — S1/P1 |
| "blocking our go-live", "release is at risk" | Time-critical business impact |
| "customer-facing", "impacting clients", "SLA breach to our customer" | Downstream impact |
| "entire team is blocked", "no one can use X" | Broad user impact |
| "this has been broken for [X days/weeks]" | Long-running; SLA likely breached |
| "critical automation", "network operations down" | Core business process affected |
| "escalating to you", "need this urgently", "ASAP" | Customer already frustrated |
| "tried everything", "no workaround" | Customer stuck |

**When detected:**
1. Flag: `"⚠️ Priority Mismatch: filed as {STATED_PRIORITY} but description indicates [{impact}]. Recommend treating as {RECOMMENDED_PRIORITY}."`
2. Escalate to senior manager immediately
3. With engineer approval — upgrade priority and post internal triage comment

---

### Step 1g — Generate Engineer Question List

Produce a tailored checklist. Pre-fill answers already in the ticket; remove inapplicable categories.

```markdown
## Pre-Investigation Questions — {ISD_TICKET_KEY}

**Resolve these before proceeding to Phase 2.**

### A. Version & Environment
1. [ ] Exact IAP version in production: (confirm `{version_from_ticket}` or get from `GET /api/about`)
2. [ ] Deployment type: Docker Compose / Kubernetes (EKS/GKE) / VM / Cloud managed?
3. [ ] Customer-managed or Itential-managed (SaaS)?

### B. Symptom Precision
4. [ ] Exact error message — copy/paste from platform, not paraphrased
5. [ ] First occurrence: exact UTC timestamp from logs or job record (not user-reported clock)
6. [ ] Frequency: always fails / intermittent / started after {event}?

### C. Scope & Reproduction
7. [ ] Which workflow(s) / adapter(s) affected? Are others working?
8. [ ] Can you reproduce on demand? If yes, exact trigger steps
9. [ ] All users affected or specific users/roles?

### D. Recent Changes
10. [ ] Changes in 48h before first occurrence: IAP upgrade, adapter config, network/firewall, cert renewal?

### E. Evidence Needed
11. [ ] Failing job ID (from Operations Manager) or workflow name
12. [ ] IAP application logs covering the incident window
13. [ ] Adapter settings export (if adapter-related)
```

**Interactive mode:** Present to engineer and wait for approval before posting as internal ISD comment (`Service Desk Team` visibility).
**`--auto` mode:** Post directly without waiting.

---

### Step 1h — Pre-Investigation Summary

```markdown
## Pre-Investigation Summary

**Ticket:** {ISD_TICKET_KEY} — {summary}
**Customer:** {name} | **Priority:** {P1-P4} | **Severity:** {S1-S4} | **SLA:** {status}
**IAP Version:** {version} | **Support Status:** {active | maintenance-only | EOL | unverified}

**What the customer reports:**
{2–3 sentence plain-English description of the problem}

**Initial hypothesis:**
{Most likely root cause based on error string, component, and regression status.}

**Known issue match:**
{ENG-XXXX (fix in vX.Y.Z, workaround: ...) | No matching ticket found}

**Version-specific behavioral notes:** *(omit if none)*
- [{version}] {Component}: {What does NOT exist / apply} — {Diagnostic impact}

**Investigation plan:**
1. Phase 2 — Route to {sub-skill} because {reason}
2. Phase 3 — Reproduce / build workaround in selected environment

**Escalation risk:**
{None | Monitor — SLA at risk in Xh | ACTION REQUIRED — SLA breached}
```

Save to `{project_path}/data/{TIMESTAMP}/{TICKET_KEY}/pre-investigation-summary.md`.

**Interactive mode gate:** Present summary + question list to engineer, then prompt:
*"Send these questions to the customer and return when you have answers, or proceed directly to Phase 2 if answers are already available."*

**`--auto` mode:** Write files and stop — no prompt. The orchestrator or engineer will pick up from here.

---

## IPSO / ENG Tickets — Engineering Bug Triage

For `IPSO-XXXX` or `ENG-XXXX` tickets, run a variant of the triage steps. The core research (read ticket, mine past cases, search Confluence, version check) is identical. What differs:

### Step 1a — Read the Engineering Ticket (same curl/MCP pattern)

Extract: summary, description, priority, reporter, assignee, `affectedVersions`, `fixVersions`, `components`, linked issues, attachments, all comments.

### Step 1b — Extract Engineering Context

```
╔══════════════════════════════════════════════════════════╗
  ENGINEERING TICKET CONTEXT — {TICKET_KEY}
╠══════════════════════════════════════════════════════════╣
  TICKET
  ──────
  Ticket:           {TICKET_KEY}
  Summary:          {summary}
  Priority:         {priority}
  Reporter:         {reporter}
  Affected Versions: {versions | unknown}
  Fix Versions:     {versions | none}
  Components:       {component(s) | unknown}
  Linked Issues:    {ISD-XXXX, ENG-XXXX, ... | none}

  BUG DESCRIPTION
  ──────────────
  Symptom:          {what breaks}
  Error Message:    {exact string | "none provided"}
  Steps to Reproduce: {as described in ticket | unknown}
  Expected:         {what should happen}
  Actual:           {what happens instead}
  Regression:       yes | no | unknown
  Workaround:       {if described | none}

  ATTACHMENTS
  ──────────
  {filename — description, OR "none"}
╚══════════════════════════════════════════════════════════╝
```

Save to `{project_path}/data/{TIMESTAMP}/{TICKET_KEY}/ticket_context.md`.

### Step 1c — Version-Specific Behavioral Notes Only

Skip Part A (support status — not applicable to internal bugs). Run Part B: scan Section 7 of `product-capability-reference.md` for rows matching affected versions. Append to `ticket_context.md` if matches found.

### Step 1d — Mine Related Tickets

```
# Past IPSO bugs with same error/component
mcp__claude_ai_Atlassian_MCP__searchJiraIssuesUsingJql(
  jql: "project = IPSO AND text ~ \"{ERROR_TERM}\" ORDER BY created DESC",
  fields: ["summary","status","fixVersions","resolution","comment"]
)

# ENG bugs — same or related
mcp__claude_ai_Atlassian_MCP__searchJiraIssuesUsingJql(
  jql: "project = ENG AND issuetype = Bug AND text ~ \"{ERROR_TERM}\" ORDER BY created DESC",
  fields: ["summary","status","fixVersions","affectedVersions","resolution","comment"]
)

# ISD tickets — customers hitting the same bug
mcp__claude_ai_Atlassian_MCP__searchJiraIssuesUsingJql(
  jql: "project = ISD AND text ~ \"{ERROR_TERM}\" ORDER BY created DESC",
  fields: ["summary","status","resolution","comment"]
)
```

Note any ISD tickets where customers are affected by this bug — this informs the impact scope in the ENG ticket draft (Step 1g-eng).

### Step 1e — Search Confluence (same as ISD)

Same three CQL searches. Save to `confluence_references.md`.

### Step 1f — Skip (priority mismatch detection is ISD-only)

### Step 1g-eng — Generate Engineering Question List

```markdown
## Engineering Investigation Questions — {TICKET_KEY}

### A. Reproduction
1. [ ] Exact steps to reproduce (minimum viable scenario):
2. [ ] Does it reproduce on a clean install? Which IAP version?
3. [ ] Does it reproduce on all affected versions listed, or only specific ones?

### B. Affected Code Path
4. [ ] Which component / module is the failure point? (adapter name, workflow engine, API route, DB query)
5. [ ] Is there a failing test? If yes, test name and file path
6. [ ] Stack trace or error log (full, not truncated)

### C. Versions Confirmed
7. [ ] Earliest version where this bug exists:
8. [ ] Latest version confirmed affected:
9. [ ] Is there a version where this worked correctly (regression point)?

### D. Workaround
10. [ ] Is there any workaround available? If yes, describe it
11. [ ] How many customers are affected? (cross-reference ISD tickets from Step 1d)
```

**Interactive mode:** Present to engineer for review. For IPSO tickets, also present the ENG ticket draft (Step 1h-promo) at the same time.
**`--auto` mode:** Write to `pre-investigation-summary.md` and post as internal comment without waiting.

### Step 1h-eng — Pre-Investigation Summary (Engineering)

```markdown
## Engineering Bug Triage Summary

**Ticket:** {TICKET_KEY} — {summary}
**Priority:** {priority} | **Reporter:** {reporter}
**Affected Versions:** {versions} | **Fix Versions:** {none | versions}

**Bug description:**
{2–3 sentence plain-English description}

**Initial hypothesis:**
{Most likely code path or root cause based on error string and component}

**Related tickets:**
- Similar IPSO/ENG: {list or "none found"}
- Affected customers (ISD): {ISD-XXXX, ... | "none found in ISD search"}

**Version-specific behavioral notes:** *(omit if none)*
- [{version}] {Component}: {behavioral difference}

**Recommended next steps:**
1. {Reproduce with steps from question list}
2. {Code investigation path — which module/file to look at first}
3. {Check if fix can be backported to affected versions}
```

Save to `{project_path}/data/{TIMESTAMP}/{TICKET_KEY}/pre-investigation-summary.md`.

---

## IPSO → ENG Ticket Promotion

At the end of IPSO triage (after Step 1h-eng), draft an ENG ticket and present it to the engineer for review. This step runs for `IPSO-XXXX` tickets only (not for `ENG-XXXX` input tickets).

**Draft ENG ticket:**

```markdown
## ENG Ticket Draft — Promote from {IPSO_KEY}

**Project:** ENG
**Issue Type:** Bug
**Summary:** {derived from IPSO summary + root-cause hypothesis — 1 concise line}
**Priority:** {same as IPSO priority}

**Description:**
{Plain-English bug description, 3–5 sentences covering: what fails, under what conditions, what the expected behavior is}

**Steps to Reproduce:**
{Steps from the engineering question list answers, or "see {IPSO_KEY} for details" if not yet answered}

**Actual Result:**
{What happens}

**Expected Result:**
{What should happen}

**Affects Versions:** {versions from ticket_context.md}
**Fix Versions:** (to be determined)
**Components:** {inferred from component in ticket_context.md}
**Labels:** {troubleshoot-triage-generated}

**Workaround:** {from Confluence search, or "None identified"}

**Links:**
- Is caused by: {IPSO_KEY}
- Customer impact: {ISD-XXXX, ... | "No related ISD tickets found"}
```

Present draft to engineer:
> "Ready to promote {IPSO_KEY} to an ENG bug ticket. Review the draft above and approve to file, or edit any field. Type `approve` to file, `skip` to save the draft for later."

**On approval:** file using `createJiraIssue` (Atlassian MCP) and add a comment to the IPSO ticket linking to the new ENG ticket (internal visibility).

**On skip/decline:** save draft to `{project_path}/data/{TIMESTAMP}/{TICKET_KEY}/eng_ticket_draft.md`. Note the path so the engineer can find it.

**`--auto` mode:** Save draft to `eng_ticket_draft.md` without filing. Do not file automatically — ENG ticket creation always requires engineer approval even in `--auto` mode.
