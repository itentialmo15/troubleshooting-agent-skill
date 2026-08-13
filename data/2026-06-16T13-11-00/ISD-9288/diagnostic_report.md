# Diagnostic Report — ISD-9288

**Ticket:** ISD-9288 — [ Labs ] Itential is not sending trap message on service stop or crashed  
**Customer:** AT&T (Reporter: Santosh Karki)  
**Assignee:** Cody Rester  
**IAP Version:** 6.4.0 | **Deployment:** VM (systemd) | **Investigated:** 2026-06-16

---

## Environment Snapshot

| Component | Value |
|-----------|-------|
| IAP Version | 6.4.0 |
| Deployment | VM — `systemctl restart itential-platform` |
| SNMP Config | `snmp_alarm_configs` in `/etc/itential/platform.properties` |
| SNMP Destination | `localhost:162` (community: public, type: trap, version: V1) |
| Systemd Unit | `/usr/lib/systemd/system/itential-platform.service` |
| Shutdown Handler | `/opt/itential/platform/server/core/startup/Shutdown.js` |

---

## Investigation — tcpdump Evidence

Captured UDP port 162 traffic across a full `systemctl restart` + `systemctl stop` cycle on `pe-iap01.pe.itential.io` (IAP 6.4.0 — same version as customer).

**Total packets captured: 23**

| Trap | Specific Value | Count | Verdict |
|------|---------------|-------|---------|
| `itenProngSystemRestart` | s=4 | 1 | ✅ Sent on restart |
| `itenProngAppUp` | s=6 | 18 | ✅ Sent per-app as each comes online |
| Adapter/connection events | s=2, s=10 | 4 | ✅ Sent (IAG01, InventoryManager2) |
| `itenProngAppDown` | s=7 | **0** | ❌ NEVER SENT |
| `itenProngAppCrash` | s=8 | **0** | ❌ NEVER SENT |

AppDown and AppCrash traps produced **zero packets** — confirmed reproducible on IAP 6.4.0.

---

## Root Cause

**Platform shutdown handler (`Shutdown.js`) does not emit AppDown traps.**

When `systemctl stop itential-platform` is issued:
1. systemd sends SIGTERM to the Node.js process
2. `Shutdown.js` handles the signal and begins graceful shutdown
3. `Shutdown.js` has an internal **3-second timeout** — services that haven't stopped are force-killed
4. The shutdown sequence performs Redis cleanup and exits cleanly — **no AppDown trap is emitted** for any stopping service

Evidence from `journalctl -u itential-platform`:
```
Shutdown.js: 'Shutdown timeout has been hit. Exiting with status'  { timeout: 3, status: 0 }
Shutdown.js: 'Services failed to finish by the timeout'             { totalRunning: 1 }
Shutdown.js: 'Shutdown complete. Exiting with status'               { status: 0 }
```

**For crashes:**
- `Restart=on-failure` in the systemd unit means systemd restarts the process on abnormal exit
- There is **no `ExecStopPost`** hook in the unit file to send an AppCrash trap after unexpected exit
- A crashed process cannot send its own "I crashed" notification — it requires an external watchdog

**Systemd unit — confirms no watchdog:**
```ini
ExecStart=/usr/bin/node --max-old-space-size=8192 server.js --config-file /etc/itential/platform.properties
Restart=on-failure
KillMode=mixed
# ExecStopPost — NOT PRESENT
```

---

## Summary

| Trap | Expected | Actual | Reason |
|------|----------|--------|--------|
| `itenProngSystemRestart` (s=4) | On restart | ✅ Working | Sent by startup sequence |
| `itenProngAppUp` (s=6) | Per-app on start | ✅ Working | Sent as each microservice initialises |
| `itenProngAppDown` (s=7) | Per-app on stop | ❌ Never sent | `Shutdown.js` exits without emitting AppDown |
| `itenProngAppCrash` (s=8) | On crash | ❌ Never sent | No watchdog/ExecStopPost; dead process can't self-report |

---

## Recommendations

### Option 1 — Engineering Fix (preferred)
File ENG bug: `Shutdown.js` must emit `itenProngAppDown` (s=7) for each stopping service before the 3-second timeout, mirroring the AppUp (s=6) logic in the startup path. For crashes, the systemd unit should include an `ExecStopPost` script or the `Restart=on-failure` handler should emit `itenProngAppCrash`.

### Option 2 — Customer Workaround (immediate)
Add a systemd `ExecStopPost` to the unit file that sends an AppDown trap via the `snmptrap` CLI:

```ini
ExecStopPost=/usr/bin/snmptrap -v 1 -c public localhost \
  .1.3.6.1.4.1.47688.1.1.1.0 "" 6 7 "" \
  .1.3.6.1.4.1.47688.1.1.1.1.1.0 s "itential-platform"
```

This fires after every stop (clean or crash), sending a single platform-level AppDown trap. It does not cover per-service granularity but satisfies the monitoring requirement.

**Note:** The customer likely needs to install `net-snmp-utils` (`snmptrap` binary) on the IAP VM for this workaround.

---

## Next Steps

1. Post findings to ISD-9288 with workaround
2. File ENG bug: AppDown/AppCrash traps not emitted by Shutdown.js
3. Check if customer wants the systemd workaround applied while waiting for the platform fix
