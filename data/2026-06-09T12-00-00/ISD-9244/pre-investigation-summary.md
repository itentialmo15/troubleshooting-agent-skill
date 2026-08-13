---
generated: 2026-06-09
ticket: ISD-9244
phase: 0e
---

## Pre-Investigation Summary

**Ticket:** ISD-9244 — [ Labs ] Netbox Delete Module - Unexpected behaviour.
**Customer:** AstraZeneca (staging) | **Assignee:** Nayana M P | **Status:** Waiting for support
**Environment:** SaaS — astrazeneca-stg-iap01.iap-prod.itential.io | **IAP:** ~6.4.0 (inferred)

---

### What the customer reports

The Netbox delete module inside a workflow is successfully deleting the device on the Netbox side —
the device is gone from Netbox after the job runs. However, the adapter task returns an error response
back to the workflow instead of a success response. The customer provided job ID
`f24b1f389bac4380b3b28e0f` and is asking for backend platform logs to understand why.

---

### Initial hypothesis — HIGH CONFIDENCE

**The Netbox HTTP DELETE endpoint returns HTTP 204 No Content on success — an empty response body.**

The Netbox adapter's response pipeline (specifically `translatorUtil.extractJSONEntity`) attempts to
validate the response body against an expected schema. When the body is empty (204 No Content), the
validator finds nothing to parse and throws a schema validation error (`AD.312`) — even though the
HTTP call fully succeeded at the network level.

This is confirmed by ISD-8741 (same customer adapter, same `translatorUtil` failure path):
```
RESPONSE NO KEY  ← adapter detected no parseable response
translatorUtil-extractJSONEntity: Schema validation failure must be string,number
```

The device is deleted. The error is in the adapter's response handling, not in the Netbox operation itself.

---

### Known issue match

| Ticket | Match | Notes |
|--------|-------|-------|
| ISD-8741 | ✅ Strong match | Same AZ Netbox adapter, same `AD.312` / `translatorUtil` failure on successful operation |
| ENG-24148 | ❌ Different issue | WFE job-start crash (P6.4.0) — fix in Platform-6.4.1, but unrelated to ISD-9244 |

---

### Investigation plan

**Phase 1 — We cannot directly access the AZ staging environment.** Investigation relies on:
1. Pull the job document for `f24b1f389bac4380b3b28e0f` from the AZ team or cloud ops
2. Read `job.error[]` — confirm the error is `AD.312` / `translatorUtil-extractJSONEntity`
3. Identify the exact Netbox delete method called (e.g., `deleteDevice`, `deleteVirtualMachine`)
4. Identify the Netbox adapter package version on the AZ instance
5. If confirmed — check whether a fix or config workaround exists in the adapter version

**Phase 2 — Questions to post on the ticket (targeted):**
- What is the exact error from the job? (full `job.error[]` array)
- Which specific Netbox delete method is the workflow calling?
- What Netbox adapter package and version is installed on this instance?
- What HTTP status code does Netbox return for this delete? (visible in adapter debug logs)

**Phase 3 — Adapter investigation (on PE Labs or from adapter source):**
- Check if the Netbox adapter's delete method has a known issue with HTTP 204 handling
- Compare against ISD-8741 resolution path

---

### Escalation risk

None currently. Staging environment, delete succeeds functionally — the workflow errors but the
operation completes. No production impact. No SLA breach signals in the ticket description.

---

### Access gaps

| Missing | Impact |
|---------|--------|
| AZ staging credentials | Cannot pull job document or adapter logs directly |
| Netbox adapter version | Cannot verify if 204-handling fix exists in installed version |
| Jira API token for AZ env | Not in `.env` — Nayana must pull job data manually |

We have PE Labs (`p6.pe.itential.io:3443`) with OAuth credentials. We can use PE Labs to replicate
the behaviour if we have the Netbox adapter version and the specific method name.
