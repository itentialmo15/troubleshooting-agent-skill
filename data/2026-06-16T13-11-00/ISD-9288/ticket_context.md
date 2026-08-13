╔══════════════════════════════════════════════════════════╗
  TICKET CONTEXT — ISD-9288
╠══════════════════════════════════════════════════════════╣
  TICKET
  ──────
  Ticket:        ISD-9288
  Summary:       [ Labs ] Itential is not sending trap message on service stop or crashed..
  Priority:      Major
  Severity:      unknown (filed as lab issue)
  SLA Status:    unknown (no SLA data in ticket)
  Customer:      AT&T (label: AT&T)
  Reporter:      Santosh Karki (sk848n@att.com)
  Assignee:      Cody Rester
  Created:       2026-06-16T13:11:02
  Status:        Open

  ENVIRONMENT
  ──────────
  IAP Version:   unknown
  IAG Version:   unknown
  Deployment:    unknown (Labs environment)
  OS:            unknown
  MongoDB:       unknown
  Redis:         unknown
  Adapter(s):    none — this is a platform monitoring issue, not adapter-related
                 ← blueprint field absent / not populated in ticket

  PROBLEM
  ───────
  Component:     IAP — SNMP monitoring / trap notification subsystem
  Symptom:       SNMP trap manager receives AppUp and SystemRestart traps correctly,
                 but NEVER receives AppDown (itenProngAppDown) or AppCrash
                 (itenProngAppCrash) traps when a service is stopped or crashes.

  Traps received (working):
    itenProngAppUp     — 1.3.6.1.4.1.47688.1.1.1.0.6  "Application is online"
    itenProngSystemRestart — 1.3.6.1.4.1.47688.1.1.1.0.4  "Platform has restarted"

  Traps NOT received (missing):
    itenProngAppDown   — 1.3.6.1.4.1.47688.1.1.1.0.7  "Application is offline"
    itenProngAppCrash  — 1.3.6.1.4.1.47688.1.1.1.0.8  "Application crashed unexpectedly"

  Error Message: none — no error, just absent traps
  Job ID:        none
  Workflow:      none
  Incident Time: 2026-06-16 (exact time unknown)
  Frequency:     always (reproducible — AppDown/Crash traps never arrive)
  Regression:    unknown (customer testing SNMP — may be first-time setup)
  Steps Provided: partial — customer confirms AppUp/Restart work; confirms AppDown/Crash never arrive

  ATTACHMENTS
  ──────────
  none
╚══════════════════════════════════════════════════════════╝
