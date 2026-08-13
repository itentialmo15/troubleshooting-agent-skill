---
generated: 2026-06-09
ticket: ISD-9244
phase: 0c
---

# Known Issues Search — ISD-9244

## Similar ISD Tickets

### ✅ ISD-8741 — [ Labs ] Netbox adapter POST error (Completed / Done)
**Customer:** AstraZeneca (GammaNetboxLab adapter)
**Pattern match: HIGH — same adapter, same "operation succeeds but adapter errors" behaviour**

**Description:**
Using `postVirtualizationInterfaces` in NetboxV33 adapter, the workflow errors even though the interface
was successfully created in Netbox.

**Exact error:**
```json
{
  "icode": "AD.312",
  "IAPerror": {
    "origin": "GammaNetboxLab-translatorUtil-extractJSONEntity",
    "displayString": "Schema validation failed on must be string,number",
    "recommendation": "Verify the information provided is in the correct format with everything required"
  }
}
```

**Key log lines from ISD-8741:**
```
GammaNetboxLab-restHandler-handleRestRequest: RESPONSE NO KEY
GammaNetboxLab-translatorUtil-extractJSONEntity: Schema validation failure must be string,number
```

**Root cause (inferred):** The adapter received a response with no parseable JSON key, ran it through
`translatorUtil.extractJSONEntity`, and the schema validator failed because the response body
did not match the expected type. For DELETE operations this is almost certainly an HTTP 204 No Content
response — Netbox returns empty body on successful delete, and the adapter errors on the empty body.

**Resolution in ISD-8741:** Marked Done — resolution comment not available in ticket, but the pattern
points to the adapter schema validation not handling empty/no-content responses.

---

### ✅ ISD-4562 — Production Workflow erroring on netbox adapter (Completed / Done)
**Pattern:** Workflow errors on Netbox adapter due to token mismatch — different root cause.
Not directly applicable to ISD-9244.

---

### ✅ ISD-7466 — [ Labs ] Netbox Adapter is not working (Completed)
Not enough detail to determine pattern match.

---

### ✅ ISD-3555 — [ Labs ] Error on Netbox Adapter when performing a Get operation for Device by ID (Completed)
GET operation errors — different method, but same adapter response handling path.

---

## Related ENG Bugs

### ✅ ENG-24148 — Job no longer starts after upgrading to P6.4 (Released — Platform-6.4.1)
**Priority:** Critical
**Fix versions:** Platform-6.4.1 (released 2026-06-03), Cloud-Platform-6.4.1 (releasing 2026-06-11)

**Description:**
After upgrading from P6.3.4 → P6.4.0, the `AZ - NetBox Inventory Sync` workflow can no longer start.

**Root cause (from triage):**
```
TypeError: Cannot read properties of undefined (reading 'indexOf')
  at Object.taskRefPointer (utils.js:383)
  at Object.compileIncomingValues (utils.js:569)
  at Object.compileIncomingWithStaticReferences (utils.js:475)
  at Object.startJob (jobStart.js:330)
```
Empty task incoming variable in a query task causes WFE to crash during job start — before the job even
reaches the Netbox adapter.

**Relevance to ISD-9244:**
- Different root cause — ISD-9244 job DID start and DID reach the Netbox delete step (device was deleted)
- ENG-24148 is about a different workflow (`AZ - NetBox Inventory Sync`) failing at job start
- However, AZ is on Platform 6.4.0 — if Cloud-Platform-6.4.1 is not yet deployed, they may be
  simultaneously affected by ENG-24148 on OTHER workflows
- **The ISD-9244 issue is distinct from ENG-24148**

**Note from ENG-24148:** Rowan Gibbs clarified: "the `AZ - NetBox Inventory Sync` workflow is out of
scope as this cannot be caused by our UI" — the AZ workflow has an issue independent of the P6.4 bug,
which the ENG-24148 fix does not address.

---

## Summary Assessment

| Source | Finding | Applicability |
|--------|---------|---------------|
| ISD-8741 | Same adapter, same "action succeeds + adapter errors" pattern, `AD.312` / `translatorUtil` failure | **HIGH — use as diagnostic baseline** |
| ENG-24148 | WFE job start crash (P6.4.0), affects AZ NetBox Inventory Sync | Low — different issue, different workflow |
| ISD-4562 | Netbox token mismatch | Low — different root cause |
| ISD-3555 | Netbox GET errors | Low — different method |

**Primary hypothesis going into Phase 3:**
The Netbox DELETE API returns HTTP 204 No Content (empty body). The adapter's `translatorUtil.extractJSONEntity`
attempts to validate the empty response against an expected schema and fails with `AD.312`. The device
is actually deleted at the Netbox level — the error is purely in the adapter's response processing path.
