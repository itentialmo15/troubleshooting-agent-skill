---
name: troubleshoot-ui
description: Troubleshoot frontend/UI interaction bugs that live entirely in the browser — a search box, filter, button, dropdown, or canvas element that doesn't work for some inputs but not others, where no API/log/DB signal confirms the failure. Drives a real browser (isolated pane or the engineer's own Chrome) to reproduce the issue, then diffs network requests between a working and a broken interaction to find root cause. Covers Automation Studio, task palette / Assets tab, JSON Form builder, Operations Manager, and similar UI surfaces.
argument-hint: "[page or component]"
---

# Troubleshoot UI

**Owns:** Browser-driven reproduction and diagnosis of frontend interaction bugs — login verification, UI element location, control-group reproduction across all affected asset/input types, and network/console diffing between a working and a failing case.
**Use when:** A ticket reports a specific UI surface (search box, filter, button, dropdown, canvas, task palette, Assets tab) that doesn't respond, returns no results, or renders incorrectly — as distinct from a pure performance/latency complaint (that stays `Component: IAP`, inline diagnostics + `/troubleshoot-logs`).

---

## CRITICAL SAFETY RULES

- Read-only UI interaction only — navigating, searching, clicking to reproduce, and inspecting Network/Console output needs no approval. Any UI action that would create, modify, save, or delete a platform asset (clicking Save on a workflow, adding a task, deleting a project) requires the same explicit engineer approval as a direct API POST/PUT/DELETE — the existing "read-only platform API" rule already restricts the HTTP verb; this makes clear the restriction applies identically when that verb is fired by a browser click instead of a scripted call. This applies identically on both browser backends.
- **Browser backend selection is always an explicit engineer choice (Step 0) — never silently default to Engineer's Chrome**, since it operates on the engineer's real browser profile and open tabs rather than a disposable sandbox.
- **Automated login only ever runs against a local/sandboxed target host (`localhost`/`127.0.0.1`/`[::1]`/a `.localhost`-or-`.test` name) — this gate is independent of backend and cannot be waived by engineer authorization.** Entering a password into any field is prohibited by standing policy except for testing the user's own application on a local host; "the credential is harmless/a test value" does not create an exception on its own, and neither does the engineer explicitly authorizing it. Against any non-local host (an untunneled EKS/Themis repro environment, or any live/already-deployed customer environment) — on *either* backend — only verify an existing session and hand off to the engineer to log in themselves if unauthenticated. A real corporate/SSO password is never typed into any browser, isolated or the engineer's own.
- On the Engineer's Chrome backend, never close or navigate away from tabs the engineer didn't open for this investigation, never sign out of anything, and never act on any account beyond what this ticket's reproduction needs.
- Never type real customer credentials into the browser on either backend — the only credentials ever auto-entered are `.env`-sourced test/repro values, and only against a local target per the gate above; never a client secret into a password field.
- **Tunneling (Step 0a) is only ever offered for a team-owned EKS/Themis repro environment from this or a related investigation — never for a live/already-deployed customer environment.** A tunnel exists to make testing the team's own infrastructure genuinely local, not to relabel a customer's real system as "local" to work around the login-automation gate; offering it outside the repro-environment case would defeat its purpose. Always tear the tunnel down in Phase 4 cleanup.
- **UI Element Discovery Retry Policy is deliberately distinct from CLAUDE.md's Connectivity Retry Policy (5 attempts/5s gaps)** — that policy is scoped to genuine network requests (platform/Jira/GitLab/GitHub API calls, SSH checks, health polls); it does not apply to `find()` failing to locate a DOM element, because repeating an identical query against a DOM that isn't going to change produces the same empty result every time. Use 2 rounds × up to 2 phrasings (≤4 `find()` calls), 2s between rounds, then escalate to the engineer — never silently retry a `find()` call in a 5×5s loop borrowed from the network policy. The genuine network calls this sub-skill does make (`read_network_requests`, the login-verification fetch) still use the standard 5×5s policy unchanged.
- Visual evidence (screenshots) is session-only — no tool in this repo saves one to disk. Never claim a screenshot was "saved" anywhere; the written report carries only textual evidence (page dumps, network/console output).
- Prefer testing against an isolated repro environment (`/deploy-containers`) over the customer's live production UI when the bug isn't data-dependent, to avoid risking accidental state changes on a customer's system; read-only navigation against a live customer environment is fine, but the "requires approval" rule above applies with extra weight there.
- Requires one of the two browser backends (`mcp__Claude_Browser__*` or `mcp__claude-in-chrome__*`, per Step 0) — if the chosen backend's first `navigate`/`tabs_context` call fails or is denied, try the other backend once; if both are unavailable, abort cleanly with a plain-language message and offer a fallback: draft unverified reproduction steps from the ticket text alone for the engineer to run manually, explicitly labeled as unverified.

---

## Auth Reuse

**Step 0 — Browser Backend Selection (runs once, before Phase 1):** Ask the engineer to pick a backend — never default silently, since one of the two options operates on the engineer's real browser. This choice is about *which browser UI to drive*; it does not by itself decide whether login gets automated — that is the separate, host-based gate below, which applies the same way on either backend.

```
Which browser should I use to reproduce this UI issue?

  [1] Isolated (built-in Browser pane)  — disposable, sandboxed, automated login
      (recommended for: local Docker dev-stack, or a team repro environment you agree to tunnel)
  [2] Your Chrome (Claude-in-Chrome)    — reuses your already-logged-in session
      (recommended for: live/already-deployed customer environments, or a repro environment you'd rather not tunnel)
```

- Recommend **[1] Isolated** when `{PLATFORM_URL}` is the local Docker dev-stack, or a team-owned EKS/Themis repro environment the engineer agrees to tunnel (Step 0a).
- Recommend **[2] Engineer's Chrome** when `{PLATFORM_URL}` is a live/already-deployed customer environment, or an EKS/Themis repro environment the engineer declines to tunnel — neither qualifies for automated login on either backend (see the local-target check below), so reusing an already-authenticated session avoids a manual-login handoff on a fresh isolated browser.
- The engineer can override either way. Once chosen, this sets `{BROWSER_TOOL_PREFIX}` (`mcp__Claude_Browser__` or `mcp__claude-in-chrome__`) used for every subsequent phase — the two tool families are near drop-in replacements for navigate/click/type/find/read_network_requests/read_console_messages/resize_window, so Phases 2–3 are written once below and apply to either backend unchanged.
- If **Engineer's Chrome** is chosen: its tools are deferred — issue one `ToolSearch` call batching every tool this sub-skill needs (per that MCP server's own instructions: one batched call, not one at a time) before proceeding: `ToolSearch("select:mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__computer,mcp__claude-in-chrome__read_page,mcp__claude-in-chrome__find,mcp__claude-in-chrome__form_input,mcp__claude-in-chrome__get_page_text,mcp__claude-in-chrome__read_network_requests,mcp__claude-in-chrome__read_console_messages,mcp__claude-in-chrome__resize_window,mcp__claude-in-chrome__javascript_tool")`.
- If the chosen backend's tools are unavailable or denied on first use (first `navigate`/`tabs_context` call fails), fall back to offering the *other* backend rather than aborting outright — only abort to the manual-fallback path (see Safety Rules) if both are unavailable.

**Step 0a — Repro Environment Tunnel (optional, runs after Step 0, before the local-target check below):** If `{PLATFORM_URL}` is non-local AND this is a team-owned EKS or Themis repro environment (from `/deploy-containers` or `/themis-aws-deploy` in this or a related investigation — never a live/already-deployed customer environment), ask the engineer once:

```
This looks like your own EKS/Themis repro environment, not localhost.
Tunnel it to localhost to enable automated login?
  [yes] — set up a port-forward/SSH tunnel, then log in automatically
  [no]  — I'll log into {PLATFORM_URL} myself
```

- **If yes:** establish the tunnel using existing `.env` credentials:
  - **EKS:** `kubectl port-forward svc/<iap-service> <LOCAL_PORT>:<SERVICE_PORT> -n ${K8S_NAMESPACE}` (pass `--context ${K8S_CONTEXT}` if set), run in the background.
  - **Themis:** `ssh -N -L <LOCAL_PORT>:localhost:<REMOTE_PORT> ${SSH_USER_1}@${SSH_HOST_1} -i ${SSH_KEY_PATH_1}`, run in the background.
  - Pick a high local port (e.g. `18080`); retry once on a different port if the bind fails; if a second attempt also fails, give up and fall through to the manual-login path below — no open-ended retry loop.
  - Once up, **rewrite `{PLATFORM_URL}` to `http://localhost:<LOCAL_PORT>` for every subsequent step.** Record the original (real) URL separately for the report.
- **If no, or if the target is a live customer environment** (tunneling is never offered there): proceed straight to the local-target check below, which will correctly identify the untunneled host as non-local and route to the manual-login handoff.
- **Teardown:** kill the port-forward/SSH process as part of Phase 4 cleanup, alongside closing the browser session — a tunnel must never outlive the investigation.

**Credential resolution order (no standard UI credential var exists, unlike every API-only sub-skill):**

0. **Local-target check (gates whether automated login is even considered, independent of backend):** `{PLATFORM_URL}` (as possibly rewritten by Step 0a's tunnel) qualifies for automated credential entry only if its host is `localhost`, `127.0.0.1`, `[::1]`, or ends in `.localhost`/`.test` — this covers both the Docker local dev-stack directly and a tunneled EKS/Themis repro environment. This is a hard gate per standing safety policy — it is never satisfied by engineer authorization alone, only by the host genuinely being local. Any other host (an untunneled EKS/Themis repro, or any live/already-deployed customer environment) fails this check, and steps 1-4 below are skipped entirely — go straight to Phase 1's non-local-target handoff path.
1. (Local target only) Run the standard project-wide `.env` discovery (same scan every sub-skill uses: root, `environments/`, `repro/{TICKET_KEY}/`, all subdirs).
2. (Local target only) If `.env` defines explicit UI credential vars, use them.
3. (Local target only) Else if `AUTH_METHOD=basic` and `ITENTIAL_DEFAULT_USER_PASSWORD` is set, use username `admin` with that password — but **say this inferred assumption out loud to the engineer before submitting it**, since it's inferred, not confirmed by any declared variable.
4. (Local target only) Else (only OAuth `CLIENT_ID`/`CLIENT_SECRET` exist) — stop and ask the engineer for UI login credentials explicitly. Never type a client secret into a password field.
5. A fresh `.auth.json` token may optionally be tried via `javascript_tool` (non-httpOnly `document.cookie`/`localStorage`) as a time-saving attempt on a local target, but must be verified by the same generic "am I authenticated" check as the form-login path — never reported as "logged in" on the strength of the injection attempt alone, and silently falls through to the real form login if unconfirmed.

---

## Phase 1: Login

Navigate to `{PLATFORM_URL}` using `{BROWSER_TOOL_PREFIX}` (the backend chosen in Step 0), allow one short fixed wait for SPA first-paint (`computer wait` 1-2s — a one-time bootstrap allowance, not a retry loop).

**Detect "already authenticated" vs. "login required"** generically, never from hardcoded IAP DOM IDs, using three independent signals that must agree (or be treated as "unclear — investigate further," never guessed):
- (a) `find(query="password")` present = login page
- (b) `read_network_requests` showing a redirect to a `login`/`auth`-shaped path, or a recent 401 on a `session`-shaped call
- (c) page text matching login-shaped vs. app-shaped nav terms — tie-breaking corroboration only, never the sole signal

**Local target, login required (either backend):** locate the username/password fields via `find(query="username")`/`find(query="email")`/`find(query="password")`, falling back to `read_page(filter="interactive")` and picking the first two text-type inputs if `find` comes up empty; fill via `form_input` with the credential resolved above; submit via a located button (`find(query="log in")`/`"sign in"`/`"submit"`) or, if none found, press Return from the password field as a generic fallback. Verify success primarily by reading the actual login request's response body via `read_network_requests` (2xx + no `error`/`invalid`/`failed`-shaped field), with the same three-signal DOM check as secondary corroboration — if the two disagree after one re-check, treat login as **unconfirmed** and stop rather than proceeding into Phase 2 on an ambiguous result.

**Non-local target, login required (either backend):** never fill or submit the login form, regardless of engineer authorization — this is the hard policy gate from the credential-resolution Step 0 above. Stop, tell the engineer the session isn't authenticated, and ask them to log into `{PLATFORM_URL}` themselves in the active backend's browser; re-run the three-signal check once they confirm, and only proceed into Phase 2 once it agrees "authenticated." No retry loop here — this is a one-time handoff, not a poll.

**Already authenticated (any target, either backend):** skip straight to Phase 2 — the common case on Engineer's Chrome for live customer environments, since the engineer is typically already logged in day-to-day.

---

## Phase 2: Reproduce

Set the viewport once (`resize_window(preset="desktop")`, or a fixed size for byte-for-byte reproducible evidence) before any further action.

**Locate the target UI surface:** derive navigation query terms directly from the ticket's own prose (e.g. "task palette's Assets tab" → try `"task palette"`, then `"Assets"`, then `"palette"`, most-literal-phrase first) using the **UI Element Discovery Retry Policy** (see Safety Rules): 2 rounds × up to 2 query phrasings each (≤4 `find()` calls total), a single 2s wait between rounds for async rendering. If still nothing, stop guessing — capture a screenshot + full `read_page` dump as evidence of what *is* on screen, and ask the engineer for the precise click path rather than trying further synonyms indefinitely.

**Control-group reproduction:** once located, perform the exact reported broken action **and** every reported-still-working action as a control group (e.g., for a search box reported broken for two of five asset types, search all five — not just the two reported broken) so the report confirms scope before asserting anything. Capture a screenshot + `get_page_text`/`read_page` + the fired `read_network_requests` call per case, building a simple pass/fail table as you go:

| Case | Action | Result | Network call | Notes |
|---|---|---|---|---|
| 1 | Search "Template" | ✅ Pass | `GET /search?type=template` → 200, 3 results | — |
| 2 | Search "Command Template" | 🔴 Fail | `GET /search?type=command_template` → 200, 0 results | No error shown in UI either |

If the bug appears intermittent, repeat the specific failing case up to 3 times and report the per-attempt pattern rather than a single pass/fail verdict.

---

## Phase 3: Diagnose

For one working and one failing case from Phase 2's table, fetch both requests' full bodies via `read_network_requests(requestId=...)` and `read_console_messages(onlyErrors=true)` scoped to that interaction.

**Diff exactly** (present as a small side-by-side table, not prose):

| Field | Working case | Failing case |
|---|---|---|
| Request path | `/search` | `/search` |
| Method | `GET` | `GET` |
| Query params | `type=template` | `type=command_template` |
| HTTP status | `200` | `200` |
| Response body shape | `{results: [...3 items]}` | `{results: []}` |
| Console errors | none | none |

The likely root cause lives in the query-param diff. Close with **one explicit root-cause hypothesis sentence** derived directly from the diff (e.g. "the search endpoint's `type` enum doesn't include `command_template`/`json_form`; the backend returns an empty result set instead of an error, and the UI renders that as silent no-results").

---

## Phase 4: Report

Write `{project_path}/data/{TIMESTAMP}/{TICKET_KEY}/ui_report.md`:

```markdown
# UI Investigation Report: {TICKET_KEY}
**Generated:** {YYYY-MM-DD HH:MM:SS UTC} | **Platform:** {PLATFORM_URL (real, not tunneled)}
**Browser backend:** Isolated | Engineer's Chrome
**Login:** {authenticated via automated local-target login | engineer logged in manually | already authenticated}

## Reproduction Steps
{Numbered steps to reach the affected UI surface, in plain language}

## Control-Group Results
{The pass/fail table from Phase 2 — every case tested, not just the reported ones}

## Confirmed Behavior (Actual Result)
{What actually happens for the failing case(s), in plain language}

## Expected Result
{What should happen, inferred from the working control-group cases}

## Network/Console Diff
{The side-by-side diff table from Phase 3}

## Root Cause Hypothesis
{The one-sentence hypothesis from Phase 3}

## Evidence Note
Visual screenshots captured during this investigation exist only in the live session
transcript — no tool in this repo persists a screenshot to disk. Anyone needing the
visual evidence must have been present in the session or have it relayed in chat.
This report's evidence is limited to the textual page/network/console output above.
```

Reproduction Steps / Confirmed Behavior / Root Cause map directly onto the existing IPSO→ENG promotion template's Steps to Reproduce / Actual Result / Expected Result fields (`troubleshoot-triage/SKILL.md:892-906`) — triage's promotion step should pull from `ui_report.md` when one exists.

**Cleanup (always run, last step):**
- Close/detach the browser session.
- If Step 0a established a tunnel, kill that port-forward/SSH process too — a tunnel must never outlive the investigation.
