---
name: nso-server
description: Install a real Cisco NSO (Network Services Orchestrator) server and connect Itential Platform's adapter-nso instance to it. Gathers the NSO install package location, any device-specific NED package directory, and the adapter's northbound connection protocol (NETCONF, RESTCONF, or JSON-RPC) interactively — never assumes any of these. Complements (does not replace) the existing Cisco XRd device-simulation option in /troubleshoot-adapters.
argument-hint: "[install | status | configure-adapter]"
---

# NSO Server

**Owns:** Installing a real Cisco NSO instance and wiring Itential Platform's `adapter-nso` to it — install-target selection, the NSO installer run, northbound protocol enablement, adapter installation/configuration, and end-to-end verification.
**Use when:** An engineer needs a real NSO instance to reproduce or test an `adapter-nso` ticket against (e.g. the kind of NSO-version-specific behavior seen in `known-resolutions.md`'s ISD-9507 entry), and no existing NSO instance is available to point the adapter at. This installs the orchestrator itself — it does not simulate a managed device; see `/troubleshoot-adapters`'s Device Simulation Option 2 (Cisco XRd) for that complementary piece.

---

## CRITICAL SAFETY RULES

- **Install-target selection (Step 0) is always an explicit engineer choice — never defaulted.** If a new Themis-provisioned VM is chosen, the existing "Environment provisioning confirmation" safety rule applies unchanged (show method + CPU/memory, require explicit "yes") — this skill does not invent a separate gate for that, it hands off to `/themis-aws-deploy`'s own.
- **The NSO install package location and any NED package directory are always gathered via an interactive prompt, every time — never auto-fetched, never defaulted to a fixed directory.** Cisco NSO requires a valid support contract; this repo has no sanctioned way to pull it automatically the way JFrog/GitHub pulls work for other software.
- **The adapter's northbound connection protocol (NETCONF / RESTCONF / JSON-RPC) is always asked explicitly — never assumed.** This repo's own historical ISD-9507 ticket used JSON-RPC, but that was one engagement's configuration, not a default; silently assuming any one protocol would misconfigure the adapter for engagements that use a different one.
- **Adapter installation and configuration reuse `/troubleshoot-adapters` Phase 6's existing approval gates exactly** (`RESTART_APPROVED=yes` for the platform restart, `ADAPTER_CREATE_APPROVED=yes` for instance creation via `POST /adapters/import`) — this skill does not introduce new markers or bypass those gates.
- **The NSO admin password set during `ncs-setup --admin-password` (or post-start AAA config) is masked wherever displayed** — first 6 + last 4 characters, same convention as every other credential in this repo.
- **Adapter settings changes always follow the existing GET → modify-in-place → PUT-full-body rule** — `adapter-nso`'s `properties` object does not support partial updates, same as every other adapter in this repo.

---

## Step 0 — Install Target Selection

```
Where should the Cisco NSO server be installed?
  [1] An existing SSH-accessible host you already have (recommended — most real NSO labs already have one)
  [2] A new Themis-provisioned AWS VM (hands off to /themis-aws-deploy for the VM itself, then installs NSO on top)
  [3] Locally on this machine (dev/test only)
```

If [2] is chosen, invoke `/themis-aws-deploy` for the VM first — its own CPU/memory confirmation gate applies unchanged — then continue here once the VM is reachable over SSH.

## Step 1 — Gather Install Inputs (interactive, every time)

- **NSO version** (e.g. `6.4`, `6.7`) — ask; don't assume. Adapter behavior genuinely differs by NSO version (ISD-9507 is a live example: NSO < 6.7 vs ≥ 6.7 use different trace-context mechanisms).
- **"Where is the NSO install package (the `.signed.bin`/`.installer.bin` file) located on this machine or the target host?"** — a real path prompt, not an auto-fetch.
- **"Do you have any device-specific NED packages to install beyond NSO's generic ones? If so, where's that directory?"** — same interactive-prompt treatment; if none, proceed with only NSO's default generic NEDs.

## Step 2 — Run the Installer

```bash
sh {NSO_INSTALL_PACKAGE} {NSO_INSTALL_DIR}      # self-extracting signed installer
source {NSO_INSTALL_DIR}/ncsrc                   # environment setup
ncs-setup --dest {NSO_RUN_DIR} ${NED_PACKAGE_DIR:+--package "$NED_PACKAGE_DIR"}
```

## Step 3 — Ask Which Northbound Protocol the Adapter Will Use, Then Gather That Protocol's Connection Details

```
How does your adapter-nso instance connect to NSO?
  [1] NETCONF   — ask: port (NSO default 2022 or 830), auth method (SSH key path, or username/password), host-key handling
  [2] RESTCONF  — ask: port (NSO default 8888, or 443 if TLS-fronted), protocol (http/https), base path, auth (basic username/password)
  [3] JSON-RPC  — ask: port (NSO default 8080), protocol (http/https), base path (typically /jsonrpc), auth (username/password)
  (This repo's own ISD-9507 history shows a JSON-RPC deployment, but that's one past engagement's
   configuration, not a default — always confirm which this adapter actually uses.)
```

NSO supports enabling more than one northbound interface simultaneously — if the engineer needs more than one, enable each selected. Set the admin user/password via `ncs-setup --admin-password` or post-start `ncs_cli` AAA config, then start NSO and confirm CLI reachability:

```bash
ncs                                               # start the daemon
ncs_cli -u admin -C                               # confirm CLI reachability
```

The exact `ncs.conf` stanza for each protocol, and NSO-version compatibility specifics, vary — verify against `docs.itential.com/cisco-nso` during execution rather than trusting a single hardcoded snippet across all versions.

## Step 4 — Verify NSO Health (before touching IAP)

Confirm the *selected* protocol's port responds to a real call, not just a TCP connect — a NETCONF `<hello>` exchange, a RESTCONF GET against `/restconf/data`, or a JSON-RPC `login`/`get_system_setting` call, matching Step 3's choice. Use the standard 5×5s Connectivity Retry Policy.

## Step 5 — Configure (or Install) IAP's `adapter-nso` Instance

Reuse `troubleshoot-adapters/SKILL.md` Phase 6's exact existing install flow — do not invent a new one:
1. Resolve `adapter-nso` from GitLab, check if already installed (Phase 6a).
2. If not installed: stage the package, then restart the platform with explicit engineer approval (`RESTART_APPROVED=yes`), then create the instance with explicit approval (`ADAPTER_CREATE_APPROVED=yes`, via `POST /adapters/import`, not `/adapters`).
3. GET the adapter's current `properties`, modify in place with the Step 3 connection details (`host`, `port`, `protocol`, `authentication: {auth_method, ...}`, `ssl: {enabled, accept_invalid_cert}`), then PUT the full body back.

## Step 6 — End-to-End Verification

Confirm the adapter shows ONLINE in `/health/adapters`, then run one trivial NSO RPC through it over the configured protocol (not just a health ping) to confirm the connection genuinely works end-to-end.
