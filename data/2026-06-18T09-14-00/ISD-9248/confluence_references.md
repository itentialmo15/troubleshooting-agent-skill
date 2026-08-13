# Confluence References — ISD-9248

**Generated:** 2026-06-18

---

## Primary Reference

### [HLD: Code Task - Embedded Code Execution](https://itential.atlassian.net/wiki/spaces/Orcs/pages/5909119119)
**Space:** Orchestration | **Status:** Approved (Rowan Gibbs) | **Version:** 1.1

**Section 3.6 — Security Model (full text):**
> Security is delegated to IAG 5's existing isolation model:
> - **Process Isolation:** Each execution runs in separate child process
> - **No Artificial Restrictions:** User code has full language capabilities
> - **Customer Responsibility:** IAG 5 runs on customer infrastructure; they control network, filesystem, OS-level security, Memory and CPU limits

**Section C — Open Questions (key entries):**
- *"venvs get a per-service folder but are allowed full unfettered access to the entire OS/FS potentially causing collisions or FILO issues at runtime, in particular when running multiple of the same service in parallel"* — known concern at design time, not resolved before ship
- RBAC: "Bespoke RBAC" — confirms a custom RBAC model is in place for the code task
- Concurrency: "Hilbert's hotel" unbounded concurrency model; queue has 100-length limit

**Section 3.4 — Package Dependencies:**
- Packages specified as array of PEP 508 specs (e.g., `requests>=2.28.0`)
- IAG5 creates/reuses content-addressed venvs per requirements hash
- `pip install` runs unrestricted unless customer configures pip to use internal index

---

## Supporting References

### [Run Code Task - Usability Research Synthesis](https://itential.atlassian.net/wiki/spaces/PO/pages/6073778279)
**Space:** Product Operations | **Last Modified:** Mar 16, 2026

Usability research with PS engineers. No security findings — focused on UX gaps. Not directly applicable to this ticket.

### [Operational Planning Initiatives: May Acceleration List](https://itential.atlassian.net/wiki/spaces/PO/pages/6338379793)
**Space:** Product Operations | **Last Modified:** May 28, 2026

Product Management's H2 2026 acceleration recommendations. May include runCode security/sandboxing — to verify if Gamma's concern has been incorporated as a roadmap item.
