"""
ISD-9464 local repro/simulation — IAG audit records emitted as invalid JSON.

No live IAG access is configured in environments/local-dev.env (no IAG_URL /
SSH_ROLE_N=iag), so this simulates the log-formatting code path locally using
the exact log lines BT provided in the ticket, to confirm the root-cause
hypothesis before it's handed to engineering.

Hypothesis: the outer {"time","severity","src","msg"} envelope is built with
naive string templating (not a real JSON encoder), and the AUDIT logger passes
an *already json.dumps()'d* string as msg — so its embedded quotes are never
escaped when dropped into the template.
"""
import json

TIME = "2026-08-07 09:53:30,429"

# ── Step 1: reproduce the customer's two log lines byte-for-byte ──────────

def buggy_formatter(time, severity, src, msg):
    """What IAG's AUDIT log formatter almost certainly does today:
    a literal string template, not json.dumps() on the whole record."""
    return '{"time": "%s", "severity": "%s", "src": "%s", "msg": "%s"}' % (
        time, severity, src, msg
    )

# INFO logger: msg is a plain string passed straight through.
info_msg = "Unautorized HTTP Request!"
info_line = buggy_formatter(TIME, "INFO", "automation_gateway.audit", info_msg)

# AUDIT logger: msg is the request/response payload, PRE-SERIALIZED to a
# JSON string before being handed to the formatter (this is the bug).
audit_payload = {
    "request": {
        "audit_id": "d849999c-9245-11f1-9733-fa163e63a21e",
        "user": "",
        "remote_addr": "10.12.214.5",
        "path": "/app/",
        "query_params": {"path": ""},
        "method": "GET",
        "start_time": "2026-08-07 09:53:30.428774",
    },
    "response": {
        "status_code": 200,
        "finish_time": "2026-08-07 09:53:30.429742",
        "duration": 0.0009720325469970703,
    },
}
audit_msg_pre_dumped = json.dumps(audit_payload)  # <-- the bug: dumped too early
audit_line = buggy_formatter(TIME, "AUDIT", "automation_gateway.audit", audit_msg_pre_dumped)

print("── Generated lines ──────────────────────────────────────")
print("INFO :", info_line)
print("AUDIT:", audit_line)
print()

# ── Step 2: confirm parse behaviour matches BT's report exactly ───────────

print("── Parse results ────────────────────────────────────────")
for label, line in [("INFO", info_line), ("AUDIT", audit_line)]:
    try:
        parsed = json.loads(line)
        print(f"{label}: VALID  -> {parsed}")
    except json.JSONDecodeError as e:
        print(f"{label}: INVALID -> {e}")

print()

# ── Step 3: confirm the fix — build the WHOLE envelope with json.dumps(),
#    passing the raw dict (not a pre-dumped string) as msg ────────────────

def fixed_formatter(time, severity, src, msg):
    """Correct approach: let json.dumps() handle escaping for the entire
    record, including whatever msg is (str OR dict)."""
    return json.dumps({"time": time, "severity": severity, "src": src, "msg": msg})

fixed_audit_line = fixed_formatter(TIME, "AUDIT", "automation_gateway.audit", audit_payload)

print("── Fixed AUDIT line ─────────────────────────────────────")
print(fixed_audit_line)
parsed = json.loads(fixed_audit_line)
print("Parses cleanly:", parsed["msg"]["request"]["audit_id"])
