# /themis-aws-deploy Local Extensions

These extensions layer on top of the vendor SKILL.md without modifying it.
`CLAUDE.md` instructs Claude to read this file alongside SKILL.md for every
`/themis-aws-deploy` invocation. Sections marked **[OVERRIDE]** replace the
corresponding vendor instruction entirely; sections marked **[INSERT AFTER Step N]**
add steps at the specified position.

This file is NOT in `vendor/platform-skills/SYNC_MANIFEST.json` — it survives
`sync-platform-skills.sh` runs unchanged.

---

## [OVERRIDE] Pre-flight Section 1 — OpenTofu Binary (Apple Silicon)

> Extends vendor `references/preflight.md` Section 1, which only checks `tofu`/`terraform`
> is on PATH and `>= 1.6` — it does not check architecture, which is the actual failure
> mode confirmed on Apple Silicon Macs (2026-09-15).

The PATH-resolved `tofu` on macOS is commonly an x86_64 build. Running it under Rosetta on
Apple Silicon causes the AWS provider plugin to fail to launch, surfacing as either:

```
Error: timeout while waiting for plugin to start
```

or

```
Error: Failed to load plugin schemas
Error while loading schemas for plugin components: Failed to ...
```

Neither error message mentions architecture, so this is easy to misdiagnose as a state
lock, network, or credentials problem — rule this out first on Apple Silicon.

**Verify before running any `tofu plan`/`apply`/`destroy`:**
```bash
file "$(which tofu)"
# Expect: Mach-O 64-bit executable arm64
# If it reports x86_64 instead, that is the cause.
```

**Fix:** use a native arm64 binary. Either reinstall via Homebrew (arm64 Homebrew installs
arm64 binaries by default — `brew reinstall opentofu` if a stale x86_64 copy is cached), or
point every tofu invocation in this session at a known-good arm64 binary directly, e.g.
`/tmp/tofu-arm64/tofu` (the workaround used in the first AIO build), instead of the
PATH-resolved `tofu`.

---

## [OVERRIDE] Architecture Reference

> Replaces `references/architectures.md` — that file reflects an older Themis branch
> where gateway VMs were not in the base tfvars. The tables below are verified against
> current Themis main (2026-09-13).

### VM counts (all architectures include gateway in base tfvars)

| Design | Total VMs | Gateway VMs | Use Case |
|--------|-----------|-------------|----------|
| `aio`     | 1  | 0 (colocated — no extra VM) | POC / dev |
| `minimal` | 4  | 1 (`gateway`)               | Small deployments |
| `ha2`     | 9  | 1 (`gateway`)               | Production HA |
| `asa`     | 17 | 2 (`gateway01`, `gateway02`) | Active-Standby dual-site |

### ASA instance names — flat numbering (NOT dc1-/dc2-/dc3-)

Current Themis main uses flat sequential naming for ASA:

- Redis (primary site): `redis01`, `redis02`, `redis03`
- Redis (secondary site): `redis04`, `redis05`, `redis06`
- MongoDB: `mongo01`–`mongo04` (replicas), `mongo05` (arbiter)
- Platform (primary): `platform01`, `platform02`
- Platform (secondary): `platform03`, `platform04`
- Gateway: `gateway01`, `gateway02`

> **Warning:** `tfvars-overrides/asa-with-gateway.tfvars` uses the OLD `dc1-`/`dc2-`/`dc3-`
> naming. Never apply it against current Themis main — it would destroy running instances
> by replacing them with wrongly-named ones.

### Gateway group per architecture

| Architecture | Gateway in base tfvars | `gen_*()` creates gateway group? | Handled by |
|---|---|---|---|
| `aio`     | No extra VM | No | `fix_gateway_group.py` reuses `all` host |
| `minimal` | `gateway`   | No | `fix_gateway_group.py` from tofu state |
| `ha2`     | `gateway`   | No | `fix_gateway_group.py` from tofu state |
| `asa`     | `gateway01`, `gateway02` | **Yes** | No fix needed |

---

## [OVERRIDE] Step 3 — Gateway tfvars handling

> Replaces the `<GATEWAY_TFVARS>` table in vendor SKILL.md Step 3.

**Do not apply `*-with-gateway.tfvars` overrides by default.** Current Themis main
already includes gateway VMs in all base tfvars — those override files are obsolete.

The only exception: set `DEPLOY_GATEWAY_TFVARS=true` in `.env` when running against a
**legacy Themis branch (pre-2024)** that does not have gateway in its base tfvars. Even
then, never use `asa-with-gateway.tfvars`.

```bash
# Evaluate once before tofu plan/apply/destroy:
DEPLOY_GATEWAY_TFVARS=$(grep -E "^DEPLOY_GATEWAY_TFVARS=" .env 2>/dev/null | cut -d= -f2)
if [ "${DEPLOY_GATEWAY_TFVARS}" = "true" ] && [ "<architecture>" != "asa" ]; then
  GATEWAY_TFVARS_FLAG="-var-file=<SKILL_DIR>/tfvars-overrides/<architecture>-with-gateway.tfvars"
else
  GATEWAY_TFVARS_FLAG=""
fi
```

---

## [OVERRIDE] Step 3 — tofu commands (profile + account overrides)

> Replaces vendor Step 3's tofu plan/apply/destroy command blocks.

Themis's `terraform.tfvars` hardcodes `profile = "pe-team-sbx"`. Always pass
`-var profile=<aws_profile>` explicitly so engineers on other accounts get the right
profile. Also append `${ACCOUNT_TFVARS:-}` if Step 1b generated `auto-account.tfvars`.

```bash
cd <themis_root>/vms/aws

tofu plan \
  -var-file=tfvars/<architecture>.tfvars \
  ${GATEWAY_TFVARS_FLAG:-} \
  -var-file=tfvars/<os_tfvars>.tfvars \
  ${ACCOUNT_TFVARS:-} \
  -var owner=<owner> \
  -var profile=<aws_profile>

tofu apply \
  -var-file=tfvars/<architecture>.tfvars \
  ${GATEWAY_TFVARS_FLAG:-} \
  -var-file=tfvars/<os_tfvars>.tfvars \
  ${ACCOUNT_TFVARS:-} \
  -var owner=<owner> \
  -var profile=<aws_profile> \
  -parallelism=20 \
  -auto-approve
```

Destroy (same flags — include whichever `-var-file` flags were used at apply time):

```bash
tofu destroy \
  -var-file=tfvars/<architecture>.tfvars \
  ${GATEWAY_TFVARS_FLAG:-} \
  -var-file=tfvars/<os_tfvars>.tfvars \
  ${ACCOUNT_TFVARS:-} \
  -var owner=<owner> \
  -var profile=<aws_profile> \
  -auto-approve
```

---

## [INSERT AFTER Step 1] Step 1a — Auto-populate repository_api_key from JFROG_TOKEN

`itential.deployer`'s `roles/platform/tasks/validate-vars.yml` requires EITHER
`repository_username` + `repository_password` together, OR `repository_api_key` alone —
setting only `repository_password` (with no username) fails that assert. Since JFrog
Identity Tokens are bearer-style credentials (no companion username), always route
`JFROG_TOKEN` to `repository_api_key`, never to `repository_password`.

If `repository_api_key` is blank in `run-vars.yml` **and** `JFROG_TOKEN` is set in `.env`,
use the token as the repository API key for this session. Write it to
`group_vars/all/jfrog_auth.yml` at Step 4c time — do NOT write it back to `run-vars.yml`.
`repository_username`/`repository_password` should stay unset in this path.

```bash
JFROG_TOKEN=$(grep -E "^JFROG_TOKEN=" .env 2>/dev/null | cut -d= -f2)
REPO_API_KEY=$(grep -E "^repository_api_key:" <SKILL_DIR>/run-vars.yml | awk -F': ' '{print $2}' | tr -d '"')
if [ -z "${REPO_API_KEY}" ] && [ -n "${JFROG_TOKEN}" ]; then
  echo "==> Auto-populating repository_api_key from JFROG_TOKEN (.env)"
  AUTO_REPO_API_KEY="${JFROG_TOKEN}"
fi
```

At Step 4c, after `apply_run_vars.py` runs, if `AUTO_REPO_API_KEY` is set:

```bash
mkdir -p <ENV_DIR>/inventory/group_vars/all
printf -- "---\nrepository_api_key: %s\n" "${AUTO_REPO_API_KEY}" \
  > <ENV_DIR>/inventory/group_vars/all/jfrog_auth.yml
echo "==> Wrote repository_api_key to group_vars/all/jfrog_auth.yml"
```

`repository_api_key` in `run-vars.yml` can be left blank as long as `JFROG_TOKEN` is in
`.env`. `repository_username`/`repository_password` are not needed for JFrog auth.

### `platform_packages` URL construction — GATEWAY-MANAGER path quirk

`run-vars.yml`'s `platform_packages` URLs must point at `itential.jfrog.io` — not
`registry.aws.itential.com`, which is dead and 401s. Every P6 repo (`PLATFORM`, `CONFIG`,
`LIFECYCLE`, `SERVICE`) uses the same nested path shape:

```
https://itential.jfrog.io/artifactory/<REPO>/<Product Name>/<Product Version>/<file>.rpm
```

**`GATEWAY-MANAGER` is the one exception** — it requires the repo name doubled as a path
segment, not the product-name/version nesting the other repos use:

```
https://itential.jfrog.io/artifactory/GATEWAY-MANAGER/GATEWAY-MANAGER/<file>.rpm
```

Confirmed via AQL's raw `path` field (shows `GATEWAY-MANAGER`, not root) and a live
`curl -sIL` redirect chain (302 → 200). Using the nested pattern from the other repos here
404s. Verified working example:
```
https://itential.jfrog.io/artifactory/GATEWAY-MANAGER/GATEWAY-MANAGER/itential-gateway_manager-1.0.4.noarch.rpm
```

---

## [INSERT AFTER Step 1a] Step 1b — Generate auto-account.tfvars from .env

Run `scripts/generate_account_tfvars.py` to convert `.env` AWS overrides into a tofu
`-var-file`. Engineers on `pe-team-sbx` with no AWS overrides in `.env` get a no-op
(script prints a message and removes any stale file).

```bash
<SKILL_DIR>/.venv/bin/python3 <SKILL_DIR>/scripts/generate_account_tfvars.py \
  --env-file .env \
  --run-vars <SKILL_DIR>/run-vars.yml \
  --arch-tfvars <themis_root>/vms/aws/tfvars/<architecture>.tfvars \
  --output <SKILL_DIR>/tfvars-overrides/auto-account.tfvars
```

| .env key | Written to auto-account.tfvars |
|---|---|
| `AWS_REGION` | `region = "..."` |
| `aws_profile` from run-vars.yml (if ≠ `pe-team-sbx`) | `profile = "..."` |
| `AWS_KEY_NAME` | `key_name = "..."` |
| `AWS_SECURITY_GROUP_IDS` | `default_security_group_ids = [...]` (comma-separated) |
| `AWS_SUBNET_IDS` | `subnet_map = { "public-1a" = "...", "public-1b" = "...", "public-1c" = "..." }` |
| `AWS_DEFAULT_SUBNET` | `default_subnet = "public-1a"` (or whichever alias) |
| `AWS_INSTANCE_TYPE_PLATFORM` | rewrites full `instances = [...]` list with per-role types |
| `AWS_INSTANCE_TYPE_REDIS` | same |
| `AWS_INSTANCE_TYPE_MONGODB` | same |
| `AWS_INSTANCE_TYPE_GATEWAY` | same |

Record the generated file for Step 3:

```bash
if [ -f "<SKILL_DIR>/tfvars-overrides/auto-account.tfvars" ]; then
  ACCOUNT_TFVARS="-var-file=<SKILL_DIR>/tfvars-overrides/auto-account.tfvars"
else
  ACCOUNT_TFVARS=""
fi
```

---

## [INSERT AFTER Step 1b] Step 1c — IAG4 gateway package auto-pull

Only runs if `gateway_release` is set in `run-vars.yml` **and** no `.whl` exists in
`<deployer_repo>/playbooks/files/`.

```bash
GATEWAY_RELEASE=$(grep -E "^gateway_release:" <SKILL_DIR>/run-vars.yml | awk -F': ' '{print $2}' | tr -d '"' | xargs)
if [ -n "${GATEWAY_RELEASE}" ]; then
  WHL_EXISTS=$(ls <deployer_repo>/playbooks/files/*.whl 2>/dev/null | head -1)
  if [ -z "${WHL_EXISTS}" ]; then
    JFROG_TOKEN=$(grep -E "^JFROG_TOKEN=" .env 2>/dev/null | cut -d= -f2)
    if [ -n "${JFROG_TOKEN}" ]; then
      echo "==> Pulling IAG4 .whl for release ${GATEWAY_RELEASE} from JFrog..."
      <SKILL_DIR>/.venv/bin/python3 <SKILL_DIR>/../../scripts/pull-platform-rpms.sh \
        --version "${GATEWAY_RELEASE}" \
        --components iag4 \
        --out-dir <deployer_repo>/playbooks/files/
    else
      echo "ERROR: gateway_release is set but no .whl found and JFROG_TOKEN is missing."
      echo "       Place the .whl at <deployer_repo>/playbooks/files/ manually,"
      echo "       or add JFROG_TOKEN to .env for auto-pull."
      exit 1
    fi
  fi
fi
```

---

## [INSERT AFTER Step 1c] Step 1d — AWS STS Credential Freshness Check

Some accounts (including `mohan-env-sts`) use **static STS credentials** in `.env`
(`aws_access_key_id`/`aws_secret_access_key`/`aws_session_token`, case-insensitive lookup)
rather than an SSO-backed profile. These are NOT auto-refreshed by `aws sso login` and will
silently expire mid-session, surfacing at `tofu plan`/`apply` time as:

```
An error occurred (ExpiredToken) when calling the GetCallerIdentity operation:
The security token included in the request is expired
```

Check this **before** Step 3 provisioning starts, not after a failure:

```bash
aws sts get-caller-identity --profile <aws_profile>
```

If expired, re-provision fresh STS credentials into `.env` (`aws_access_key_id`,
`aws_secret_access_key`, `aws_session_token`) before continuing — there is no in-session
refresh command for static creds, unlike SSO profiles.

---

## [OVERRIDE] Extended Pre-flight (replaces preflight.md Section 4, adds Sections 5a/9/10)

### Section 4 — AWS Credentials and Resources

**Standard path (pe-team-sbx):**
```bash
aws sso login --profile pe-team-sbx
aws sts get-caller-identity --profile pe-team-sbx
```

**Custom account — add to `.env`** (gitignored, per-engineer):
```bash
AWS_KEY_NAME=your-ec2-key-pair-name
AWS_SECURITY_GROUP_IDS=sg-xxxxxxxxxxxx        # must allow SSH (22) inbound
AWS_SUBNET_IDS=subnet-aaa,subnet-bbb,subnet-ccc  # maps to public-1a/b/c aliases
AWS_REGION=us-west-2                          # optional — default: us-east-1
AWS_INSTANCE_TYPE_PLATFORM=t3.large           # optional — all default to t3.medium
AWS_INSTANCE_TYPE_REDIS=t3.medium
AWS_INSTANCE_TYPE_MONGODB=t3.medium
AWS_INSTANCE_TYPE_GATEWAY=t3.medium
```

Step 1b generates `auto-account.tfvars` from these automatically.

**Verify key pair and SG exist before every run, not just the first time** — SG IDs get
deleted/rotated between sessions on shared or sandbox AWS accounts. Confirmed failure mode:
`AWS_SECURITY_GROUP_IDS` in `.env` referenced a SG from a prior session that no longer
existed, only caught at `tofu plan` time as `InvalidGroup.NotFound`. Re-run this check even
if `.env` hasn't changed since last time:

```bash
aws ec2 describe-key-pairs \
  --key-names <key_name> --profile <aws_profile> \
  --query 'KeyPairs[0].KeyName' --output text

aws ec2 describe-security-groups \
  --group-ids <sg_id> --profile <aws_profile> \
  --query 'SecurityGroups[0].{Id:GroupId,Name:GroupName}' --output table
```

### Section 4b — PyYAML for apply_run_vars.py

`scripts/apply_run_vars.py` (Step 4c, distributes `run-vars.yml` into generated
`group_vars`) requires `PyYAML`. Confirmed missing on both Homebrew Python 3.13 and system
Python 3.9 on macOS — check before Step 4c, not after it fails:

```bash
python3 -c "import yaml" 2>&1 && echo "PyYAML OK" || echo "PyYAML MISSING"
```

**If missing on Homebrew Python:** PEP 668's externally-managed-environment guard blocks a
plain `pip install`. Use:
```bash
python3 -m pip install --user --break-system-packages pyyaml
```

### Section 5a — Gateway .whl Pre-flight

Only if `gateway_release` is set in `run-vars.yml`:
```bash
ls <deployer_repo>/playbooks/files/*.whl
# Missing + JFROG_TOKEN in .env → Step 1c auto-pulls it (no action needed)
# Missing + no JFROG_TOKEN → place the .whl manually before running
```

### Section 9 — Cost / Spend Confirmation

| Architecture | VMs | Approx. runtime |
|---|---|---|
| `aio` | 1 | ~45–70 min |
| `minimal` | 4 | ~57 min |
| `ha2` | 9 | ~44 min |
| `asa` | 17 | ~68 min |

EC2 instances accrue AWS spend until explicitly destroyed. Keep the destroy command handy:
```bash
tofu destroy \
  -var-file=tfvars/<architecture>.tfvars \
  -var-file=tfvars/<os>.tfvars \
  -var owner=<owner> \
  -var profile=<aws_profile> \
  -auto-approve
```

### Section 10 — Pre-Run Decision Checklist

- [ ] AWS identity confirmed and key pair + SG exist in account **right now** (or `.env`
      overrides set) — re-check even on a repeat run, SG IDs can go stale between sessions
- [ ] On Apple Silicon: `file "$(which tofu)"` confirms `arm64`, not `x86_64`
- [ ] If `aws_profile` uses static STS creds (not SSO): `aws sts get-caller-identity
      --profile <aws_profile>` succeeds right now
- [ ] `python3 -c "import yaml"` succeeds (PyYAML present for `apply_run_vars.py`)
- [ ] `itential.tls` cloned; `tls_repo` in `run-vars.yml` points at a valid checkout
- [ ] `repository_password` filled in `run-vars.yml` **OR** `JFROG_TOKEN` in `.env` for auto-populate
- [ ] Platform version decided: Themis default or both `platform_release` + `platform_packages` set
      — URLs must be `itential.jfrog.io`, not the dead `registry.aws.itential.com`; if
      `platform_packages` includes Gateway Manager, use the doubled `GATEWAY-MANAGER/GATEWAY-MANAGER/`
      path (see Step 1a note above), not the nested-path pattern the other repos use
- [ ] Gateway: `gateway_release` commented out (skip) OR set + `.whl` on disk / `JFROG_TOKEN` present
- [ ] Required run-vars filled: `architecture`, `os`, `themis_root`, `owner`, `deployer_repo`, `tls_repo`, `aws_profile`, `ssh_key_path`
- [ ] Cost acknowledged: know VM count, have a destroy plan
