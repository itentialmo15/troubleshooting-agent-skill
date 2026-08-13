# Pre-Investigation Summary — ISD-9288

**Ticket:** ISD-9288 — [ Labs ] Itential is not sending trap message on service stop or crashed
**Customer:** AT&T | **Priority:** Major | **SLA:** unknown | **Assignee:** Cody Rester

---

## What the Customer Reports

AT&T's SNMP trap manager successfully receives two trap types from the Itential Platform:
`itenProngAppUp` (application online) and `itenProngSystemRestart` (platform restarted).
However, it never receives `itenProngAppDown` (application offline) or `itenProngAppCrash`
(application crashed unexpectedly) — even when services are intentionally stopped or crashed
during testing.

---

## Initial Hypothesis

**Dead-man's switch limitation — IAP cannot send its own "I crashed" trap.**

When an IAP service stops gracefully or crashes, it is the SNMP trap sender itself that
terminates. A dead process cannot emit a "I am going down" notification. This explains
why `itenProngAppUp` and `itenProngSystemRestart` work (IAP is alive and healthy when
those traps are sent), but `itenProngAppDown` and `itenProngAppCrash` are never received
(IAP is dead or dying when those traps need to be sent).

The `itenProngAppDown` and `itenProngAppCrash` traps require a **separate watchdog or
process supervisor** that:
1. Monitors the IAP process independently
2. Detects process death or abnormal exit
3. Sends the SNMP trap on behalf of the dead process

Likely root causes (in priority order):
1. **Watchdog not configured** — The systemd/PM2/supervisor unit for IAP is not configured
   with an ExecStopPost or equivalent hook to send the AppDown/AppCrash trap after the
   process exits. This is the most likely cause.
2. **IAP sends the trap on shutdown but it's too late** — The process exits before the
   trap UDP packet is dispatched. Less likely since UDP is connectionless and fast.
3. **SNMP configuration difference** — AppDown/AppCrash traps may require a different
   configuration section in pronghorn.json or the SNMP notifier config that is missing.
   Less likely since AppUp works with the same stack.
4. **Platform design limitation** — AppDown/AppCrash traps may not be implemented in the
   current platform version. This would make it a feature gap, not a bug.

---

## Known Issue Match

No matching ENG bug or resolved ISD ticket. No Confluence KB article.

This is either:
- A **configuration gap** (watchdog not set up — most likely)
- A **platform design limitation** (traps not emitted on process exit — possible)

---

## Investigation Plan

1. **Phase 1** — Get IAP version, confirm SNMP is configured, review current pronghorn.json
   or SNMP notifier settings. Check if AppDown/AppCrash trap definitions exist in config.
2. **Phase 2** — Ask customer for: IAP version, deployment type (VM/Docker/K8s),
   how IAP is started (systemd unit name, Docker compose, PM2), and whether they ever
   see AppDown/AppCrash traps under any condition.
3. **Phase 3** — Check if IAP's process manager (systemd ExecStopPost / Docker healthcheck
   callback / PM2 shutdown handler) is configured to trigger SNMP notification on exit.
   Check platform docs for watchdog setup guidance.
4. **Platform docs check** — Review docs.itential.com for SNMP notifier configuration
   and AppDown/AppCrash trap emission design.

---

## Escalation Risk

Low — Lab environment, no production impact. Monitor for SLA as assigned.
However, customer (AT&T) likely has SNMP monitoring as a go-live requirement — if this
is a platform limitation with no workaround, escalation to Product Management is needed.
