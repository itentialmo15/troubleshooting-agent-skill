# Known Issues — ISD-9248

**Generated:** 2026-06-18

---

## Similar ISD Tickets

| Ticket | Summary | Status | Relevance |
|--------|---------|--------|-----------|
| ISD-9305 | [ Labs ] Gateway 5 permission to allow/disallow runCode feature on IAG5 cluster | Requested/Open | **Directly related** — another customer requesting RBAC toggle to enable/disable runCode per cluster. Same security concern, different angle (access control vs isolation). |
| ISD-9202 | [ Labs ] Itential runCode not showing as a role | Completed/Done | Confirms RBAC role exists for runCode. Customer couldn't see the role. Resolution: role was missing from UI, now fixed. This means there IS a platform RBAC gate for runCode today. |
| ISD-7737 | [ Labs ] Inline python script on IAP Canvas | Completed | Early feature request for inline Python on Canvas — precursor to runCode. Shows this is a recurring customer ask. |
| ISD-8271 | [ Labs ] "Scripting" task support | Completed | Another early request for scripting tasks. |

---

## ENG Bugs

**No ENG bugs** found matching runCode + security or sandbox.

**By design — not a bug.** The HLD (Confluence: "HLD: Code Task - Embedded Code Execution", approved by Rowan Gibbs) explicitly documents the security model in Section 3.6:

> "Security is delegated to IAG 5's existing isolation model"
> "No Artificial Restrictions: User code has full language capabilities"
> "Customer Responsibility: IAG 5 runs on customer infrastructure; they control network, filesystem, OS-level security, Memory and CPU limits"

This was a deliberate architectural decision. Security sandboxing was intentionally deferred to the customer/OS layer.

---

## ENG Design History

| Ticket | Summary | Status | Relevance |
|--------|---------|--------|-----------|
| ENG-17200 | HLD - Python Task | Cancelled (Duplicate) | Original HLD — was going to include security sandbox. Pivoted to IAG-based execution, sandbox deferred to customer. |
| ENG-18164 | Open Questions from IAG powering native code on canvas | Done | Engineering Q&A during design. Security questions raised — answered: "full language capabilities," "customer responsibility." |
| ENG-19650 | Code Task (Jira Objective — linked from HLD) | Unknown | The implementation ticket. |

**Key ENG finding from ENG-18164 (answered by Peter Sprygada, IAG lead):**
- Code executes on the same IAG5 cluster as existing services — no separate execution tier
- Ad-hoc execution without git repo: "Not today, however the Gateway runners are being updated to support this capability" (this is what runCode is)
- Full third-party package support via requirements array — no restrictions by default

---

## Relevant Confluence Pages

| Page | Space | Relevance |
|------|-------|-----------|
| [HLD: Code Task - Embedded Code Execution](https://itential.atlassian.net/wiki/spaces/Orcs/pages/5909119119) | Orchestration | **Primary reference.** Section 3.6 Security Model explicitly defines by-design behavior: no artificial restrictions, customer-managed OS-level security. Section C (Open Questions) notes venvs have "full unfettered access to the entire OS/FS." |
| [Run Code Task - Usability Research Synthesis](https://itential.atlassian.net/wiki/spaces/PO/pages/6073778279) | Product Operations | Usability research — no security findings, focused on UX. |
| [Operational Planning Initiatives: May Acceleration List](https://itential.atlassian.net/wiki/spaces/PO/pages/6338379793) | Product Operations | May 2026 acceleration list — runCode security/sandboxing may be on this list (to verify). |

---

## Key Technical Findings

### 1. Security model is by design (HLD Section 3.6)
The runCode task was deliberately designed with no OS-level sandboxing. Itential's position: customers own the IAG5 host and are responsible for its security controls.

### 2. venvs have unfettered OS/FS access (HLD Open Questions)
Quoted from HLD: *"venvs get a per-service folder but are allowed full unfettered access to the entire OS/FS potentially causing collisions or FILO issues at runtime, in particular when running multiple of the same service in parallel"*. This was a known open concern at HLD time.

### 3. RBAC gate exists for runCode (ISD-9202)
A platform RBAC role exists called `runCode` (or similar). Customers can restrict which users can invoke the runCode task via this role. This is the only built-in platform control today.

### 4. ISD-9305 is a parallel request for cluster-level RBAC
Another customer is requesting a per-cluster toggle to allow/disable runCode entirely. This should be linked to ISD-9248 as a related concern.

---

## Mitigation Options (Available Today vs. Product Roadmap)

### TODAY — Customer-managed controls

| Mitigation | Effort | What it addresses |
|-----------|--------|-------------------|
| Dedicated low-privilege OS user for IAG5 (no `~/.ssh`, no shell) | Low | SSH key exfiltration, filesystem access |
| Remove sensitive files from IAG5 host's home directory | Low | Immediate SSH key risk |
| Platform RBAC — restrict `runCode` role to trusted users only | Low | Access control — who can run code |
| Internal PyPI mirror (restrict pip to approved packages) | Medium | Malicious package installation |
| Egress firewall on IAG5 host (allowlist only) | Medium | Data exfiltration over network |
| Read-only filesystem mount + tmpfs for writable areas (containers) | Medium | Persistent VM state mutation |
| Seccomp profile on IAG5 container (block dangerous syscalls) | Medium | Privilege escalation, dangerous syscalls |
| Dedicated isolated IAG5 cluster for runCode workloads only | High | Full isolation from production IAG5 |

### PRODUCT ROADMAP — Requires ENG ticket

| Feature | Description | Priority signal |
|---------|-------------|-----------------|
| runCode sandboxing (OS namespace isolation, seccomp defaults) | Platform-enforced process isolation | ISD-9248 is the first customer explicitly requesting this |
| Cluster-level runCode enable/disable toggle | Per-cluster RBAC to allow/deny runCode | ISD-9305 is an open request for this |
| Execution audit log | Record code content + executor identity per runCode invocation | Part of Oliver's concern — "little to no visibility" |
