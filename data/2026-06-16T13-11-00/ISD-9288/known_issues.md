# Known Issues Search — ISD-9288

**Search terms used:**
- "SNMP trap" (ISD project)
- "itenProngAppDown OR itenProngAppCrash" (ENG project)
- "snmp monitoring", "itenProngAppDown" (Confluence)

---

## Similar ISD Tickets

**No matching ISD tickets found.**

The ISD search for "SNMP trap" returned ISD-9288 itself plus unrelated tickets.
No prior support case documents this specific symptom (AppDown/AppCrash traps not sent).

---

## Matching ENG Bugs

**No matching ENG bugs found.**

No engineering bug exists for itenProngAppDown or itenProngAppCrash trap delivery failure.

---

## Confluence References

**No matching KB articles, runbooks, or investigation notes found** for:
- SNMP trap AppDown/AppCrash configuration
- itenProngAppDown OID behavior
- Itential SNMP watchdog configuration

The Platform Engineering "Monitoring (legacy)" page exists but did not surface
relevant content in the summary — worth checking manually if deeper investigation
requires exact configuration steps.

---

## Interpretation

This appears to be a **new or unreported issue** — or more precisely, a known architectural
limitation of how IAP sends SNMP traps that has not previously been filed as a bug.

The root cause hypothesis (see pre-investigation summary) is based on first principles:
a process cannot send its own "I crashed" notification after it has died.

No pre-formed diagnostic bias applies — proceed to full investigation.
