# Ticket Context — ISD-9248

**Generated:** 2026-06-18 | **Investigator:** Mohan Rajanna

---

```
╔══════════════════════════════════════════════════════════╗
  TICKET CONTEXT — ISD-9248
╠══════════════════════════════════════════════════════════╣
  TICKET
  ──────
  Ticket:        ISD-9248
  Summary:       [ Labs ] Security optimization is needed while execution
                 python code via runcode task.
  Priority:      Critical
  Severity:      S3 (Labs environment)
  SLA Status:    On track (opened 2026-06-01, 17 days old)
  Customer:      Gamma Communications (oliver.sowden@gamma.co.uk)

  ENVIRONMENT
  ──────────
  IAP Version:   unknown (not provided; Labs)
  IAG Version:   5.x (IAG5 — runCode task requires IAG5)
  Deployment:    unknown (Labs)
  OS:            unknown
  MongoDB:       N/A
  Redis:         N/A
  Adapter(s):    N/A

  PROBLEM
  ───────
  Component:     IAG5 — runCode task / Python execution
  Symptom:       Python code executed via runCode task runs as the IAG5 OS
                 user (itential) with full filesystem access and no
                 sandboxing. Customer demonstrates SSH key exfiltration.
                 Secondary concern: VM state can be altered by code
                 execution (files written, packages installed) with no
                 visibility or audit trail — affects subsequent runs.
  Error Message: N/A (not an error — this is by-design behavior)
  Job ID:        none (customer provided a Python code snippet as PoC)
  Workflow:      none
  Incident Time: 2026-06-01
  Frequency:     always (by design)
  Regression:    no (never had sandboxing — this is the shipped design)
  Steps Provided: yes — customer provided PoC Python snippet:

    import os
    uid = os.getuid()
    gid = os.getgid()
    print(f"UID {uid} | GID {gid}")
    with open("/home/itential/.ssh/id_rsa_gitlab", "r") as f:
        print(f.readline())

  ATTACHMENTS
  ──────────
  none
╚══════════════════════════════════════════════════════════╝
```

---

## Comments

| Timestamp | Author | Content |
|-----------|--------|---------|
| 2026-06-01T17:17 | Automation for Jira | Auto-ack — ticket assigned to Saptarshi Chowdhury |
| 2026-06-10T02:48 | Oliver Sowden (customer) | "Can you provide me an update on this ticket please?" |
| 2026-06-10T14:28 | Saptarshi Chowdhury | "We are still working on this and might need some enhancements, we will update you soon." |
| 2026-06-25T11:16 | Mohan Rajanna | Detailed response: explained current design (runs as IAG OS user by design), asked 3 clarifying questions: (1) restrict Python packages, (2) restrict filesystem traversal, (3) run under different OS user. Mentioned internal PyPI mirror and dedicated isolated cluster as available controls. CC: Andrew Fox, Holly Holcomb |
| 2026-06-26T02:16 | Oliver Sowden (customer) | Confirmed all three requirements apply. **Key clarification:** "My main concern is that a user can run and execute code via the viewer or API's and we have little to no visibility over that. The state of the VM can be altered depending on what was ran and that can then have a negative impact on further executions." |
| 2026-06-29T09:09 | Saptarshi Chowdhury | Requested follow-up call |
| 2026-06-29T11:17 | Oliver Sowden (customer) | Agreed — proposed 14:00 BST June 30 |
