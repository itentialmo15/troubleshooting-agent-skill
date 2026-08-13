---
generated: 2026-06-09
ticket: ISD-9244
phase: 0b
---

╔══════════════════════════════════════════════════════════╗
  TICKET CONTEXT — ISD-9244
╠══════════════════════════════════════════════════════════╣
  TICKET
  ──────
  Ticket:        ISD-9244
  Summary:       [ Labs ] Netbox Delete Module - Unexpected behaviour.
  Type:          Problem
  Priority:      unknown (not stated in ticket)
  Severity:      unknown (not stated)
  SLA Status:    unknown
  Customer:      AstraZeneca (staging environment)
  Assignee:      Nayana M P (nayana.mp@itential.com)
  Status:        Waiting for support

  ENVIRONMENT
  ──────────
  IAP Version:   unknown (inferred: likely 6.4.0 based on ENG-24148 context)
  Deployment:    SaaS / Cloud (astrazeneca-stg-iap01.iap-prod.itential.io)
  MongoDB:       unknown
  Redis:         unknown
  Adapter:       Netbox (version unknown — likely netbox_v33 based on prior AZ tickets)

  PROBLEM
  ───────
  Component:     Netbox Adapter
  Symptom:       The Netbox delete module is deleting the device successfully
                 (operation completes on Netbox side) but the adapter returns
                 an error response back to the workflow.
  Error Message: "none provided" — customer requests backend logs to diagnose
  Job ID:        f24b1f389bac4380b3b28e0f
  Job URL:       https://astrazeneca-stg-iap01.iap-prod.itential.io/operations-manager/#/jobs/f24b1f389bac4380b3b28e0f
  Workflow:      unknown (not named in ticket)
  Incident Time: unknown
  Frequency:     unknown
  Regression:    unknown
  Steps Provided: no

  ATTACHMENTS
  ──────────
  none
╚══════════════════════════════════════════════════════════╝

## Access Gaps

We do NOT have credentials for the AstraZeneca staging environment.
All investigation must be based on:
- Job details shared by the customer or Nayana
- Platform logs pulled by the AZ team / cloud ops
- Adapter response data from the job document

## Customer Environment URL
https://astrazeneca-stg-iap01.iap-prod.itential.io
