# Troubleshooting Spec: Troubleshoot Adapters

## 1. Problem Statement

Adapter failures are among the most common sources of IAP job errors. When an adapter goes OFFLINE or starts returning wrong data, diagnosis requires checking multiple layers: IAP-side settings, the target system's reachability, authentication configuration, and live connection behavior. Without a structured process, engineers either miss the root cause (e.g., `stub: true`) or leave adapters in debug mode — exposing credentials in logs and generating disk pressure.

**Goal:** Systematically gather adapter settings, compare them against sampleProperties, identify misconfigurations, capture live debug logs if needed, and always clean up debug state — leaving the adapter in a known good configuration.

---

## 2. High-Level Flow

```
Gather          →   Analyze        →   Debug Mode?   →   Cleanup
    │                  │                   │                │
    │                  │                   │                │
 GET adapter       Compare live        If root cause    Reset
 settings,         vs sample-          still unclear:   auth_logging=false,
 fetch sample-     Properties,         enable debug     console_level=error,
 Properties        flag stub,          logging,         restart adapter,
 from GitLab       auth_method,        restart,         verify ONLINE
                   host, SSL,          capture logs,
                   token_timeout       analyze
```

---

## 3. Investigation Phases

### Phase 1: Gather
GET `/adapters/{ADAPTER_NAME}` — full settings. Extract `data.properties.properties` (double-nested). Parse: host, port, protocol, base_path, stub, auth_method, token_timeout, auth_field, auth_field_format, ssl.enabled, accept_invalid_cert, healthcheck type and URI, loggerProps. Also GET adapter health state from `/health/adapters`.

Derive the package repo name from `data.model` and fetch `sampleProperties.json` from GitLab (`itentialopensource/adapters/{repo}`). If the fetch returns HTML (private package or not found), proceed without sampleProperties and note it.

### Phase 2: Analyze (Compare and Flag)
Compare live settings against sampleProperties. Check in order:

1. **Stub mode** — `stub: true` = no real API calls. Most common silent failure. Always check first.
2. **Auth method mismatch** — wrong `auth_method` fails every call before connection is made.
3. **Host unconfigured** — `localhost` or empty = never pointed at target.
4. **Protocol/SSL mismatch** — `protocol: https` + `ssl.enabled: false` = TLS errors.
5. **Base path mismatch** — missing `base_path` means all API paths are wrong.
6. **Auth field/format mismatch** — wrong token header format fails every auth call.
7. **token_timeout: -1** — no auto token refresh; adapter goes OFFLINE after session expires.
8. **AWS temporary credentials** — `ASIA` prefix = STS creds that expire in 1-12h.

If a clear misconfiguration is found, present findings and ask the user if they want to fix it before proceeding to debug mode.

### Phase 3: Debug Mode (Only if gather is inconclusive)
This phase requires explicit user consent before each action.

1. Start log watcher first (Docker or Kubernetes) — capture logs to `data/{TIMESTAMP}/{ADAPTER_NAME}/live_logs.txt`
2. Enable `auth_logging: true` and `console_level: debug` via PUT (full body, not partial)
3. Restart the adapter via PUT `/adapters/{ADAPTER_NAME}/restart`
4. Analyze captured logs: auth flows, ECONNREFUSED, EHOSTUNREACH, ENOTFOUND, SSL errors, token expiry

### Phase 4: Cleanup (Always after Phase 3)
Reset `auth_logging: false` and `console_level: error` via PUT. Restart adapter. Verify ONLINE state. Never skip cleanup — `auth_logging: true` in production exposes credentials and fills disk.

---

## 4. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Gather before debug | Always run Phase 1-2 first | Most misconfigs are visible in settings; debug mode adds risk |
| sampleProperties as reference | Compare live vs source-of-truth | Detects drift without guessing expected values |
| Stub check is always first | Stub=true silently fakes all calls | Most commonly overlooked setting; must be ruled out first |
| User consent before debug and cleanup | Confirm before PUT/restart | Adapter restart causes brief downtime; debug exposes credentials |
| PUT is full replacement | Always GET → modify → PUT full body | IAP adapter API does not support partial PATCH |
| Cleanup is mandatory | Phase 4 always follows Phase 3 | Security and disk risk of leaving debug settings active |
| Log watcher started before restart | Start → debug → restart order | Captures the restart cycle where auth/connect errors appear |

---

## 5. Scope

**In scope:** Adapter settings collection from IAP API, sampleProperties comparison, stub/auth/host/SSL/token_timeout misconfiguration detection, AWS credential type detection, debug mode lifecycle (enable → capture → analyze → cleanup), adapter restart (with consent), ONLINE state verification.

**Out of scope:** Fixing the target system (e.g., wrong credentials on the downstream API — the engineer fixes that). Network-layer fixes (firewall rules, routing — infra team). IAG adapter deep dive (→ `/troubleshoot-iag` for IAG-specific adapter issues). Adapter package installation or upgrade.

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Debug mode left active | Credentials exposed in logs, disk fills | Always run Phase 4 cleanup; confirm before leaving session |
| PUT with wrong body shape | Adapter settings corrupted | Always GET first, verify body starts with `{"properties":`, check before sending |
| Adapter restart during live traffic | Brief downtime for workflows using this adapter | Confirm with user; check if any jobs are currently using the adapter |
| sampleProperties fetch fails | No reference for comparison | Note unavailability, proceed with known critical checks (stub, host, auth_method) |
| Log watcher misses restart cycle | No useful log data | Start watcher before debug settings are applied and before restart |
| `auth_logging: true` reveals tokens | Security risk | Mask token values in report output; run cleanup immediately after analysis |

---

## 7. Requirements

### What access is needed

| Credential / Access | Required | If Not Available |
|--------------------|----------|------------------|
| `PLATFORM_URL` + auth credentials in `.env` | Yes | Cannot proceed |
| Adapter name | Yes | List adapters from health/adapters if unknown |
| Docker / kubectl access | For log capture in Phase 3 | Phase 3 log analysis limited to API-visible errors only |
| Internet access to GitLab | For sampleProperties fetch | Skip comparison, use known critical checks only |

### What external systems are involved

| System | Purpose | Required |
|--------|---------|----------|
| IAP Adapters API | GET settings, PUT debug/cleanup, restart | Yes |
| IAP Health API | Check adapter state before and after | Yes |
| GitLab (`itentialopensource/adapters`) | Fetch sampleProperties for reference | No — fetch best-effort |
| Docker / kubectl | Live log capture during debug mode | For Phase 3 only |

### Discovery Questions

Ask the user before investigating:

1. Which adapter is failing? (name as it appears in IAP, e.g., `servicenow`, `iag1`)
2. What is the symptom? (OFFLINE, wrong data, auth error, specific error message)
3. Has this adapter worked before? If so, what changed?
4. Is the target system (e.g., ServiceNow, AWS, IAG) accessible from this environment?
5. Do you have the correct credentials for the target system?
6. Is there a maintenance window for the adapter restart if debug mode is needed?

---

## 8. Acceptance Criteria

1. Adapter settings are fetched and all critical fields are extracted and displayed
2. sampleProperties are fetched from GitLab; unavailability is noted without blocking
3. All critical checks run: stub, auth_method, host, protocol/SSL, base_path, token_timeout
4. AWS STS credential detection runs for AWS adapter types
5. Any misconfiguration is flagged with severity (critical / warning) and explanation
6. If root cause is found in gather phase, debug mode is not triggered unless user asks
7. Debug mode (Phase 3) only runs after explicit user consent
8. Log watcher is started before debug settings are applied and before restart
9. Cleanup (Phase 4) always runs after debug mode; settings are verified reset
10. Adapter ONLINE state is confirmed after cleanup restart
11. A gather report is saved to `data/{TIMESTAMP}/{ADAPTER_NAME}/gather_report.md`
12. Log analysis is saved to `data/{TIMESTAMP}/{ADAPTER_NAME}/log_analysis.md` if Phase 3 ran
