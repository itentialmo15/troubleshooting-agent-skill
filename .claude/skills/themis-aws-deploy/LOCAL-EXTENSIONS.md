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

---

## [INSERT AFTER Step 2] Step 2a — Pre-Build Confirmation Gate

> **This gate fires before every `tofu apply`, regardless of `--auto` mode or the
> "run fully autonomously" clause in vendor SKILL.md.** It is a hard stop: Claude does
> not proceed to Step 3 until the engineer responds "yes" to the confirmation prompt.
> If any check is FAIL, Claude must explain the fix and re-run the gate rather than
> proceeding.

Run every check below, capture PASS / FAIL / WARN / SKIP per item, then present the
formatted summary table and cost context. Only advance to Step 3 on explicit "yes".

---

### Check 1 — Required run-vars fields present

```bash
python3 - <<'EOF'
import re, sys
with open(".claude/skills/themis-aws-deploy/run-vars.yml") as f:
    text = f.read()

REQUIRED = ["architecture", "os", "themis_root", "owner",
            "deployer_repo", "tls_repo", "aws_profile", "ssh_key_path"]
missing = []
for key in REQUIRED:
    m = re.search(rf'^{key}:\s*(.+)$', text, re.MULTILINE)
    if not m or m.group(1).strip().strip('"').strip("'") in ("", "<>",
        f"<absolute-path-to-{key}>", f"<absolute-path-to-ssh-private-key>"):
        missing.append(key)
if missing:
    print(f"FAIL: empty required fields: {', '.join(missing)}")
    sys.exit(1)
print("PASS")
EOF
```

---

### Check 2 — AWS STS identity (token freshness)

```bash
aws sts get-caller-identity --profile <aws_profile> --output json 2>&1
```

- **PASS** if the command returns a JSON blob with `Account` and `Arn`.
- **FAIL** if it returns `ExpiredToken` or `InvalidClientTokenId` — re-provision static
  STS credentials in `.env` (`aws_access_key_id`, `aws_secret_access_key`,
  `aws_session_token`) before continuing.
- **FAIL** if it returns `NoCredentialProviders` — the profile is missing from `~/.aws`.

Capture the returned `Account` and `Arn` values for display in the summary.

---

### Check 3 — Architecture tfvars file exists

```bash
ls <themis_root>/vms/aws/tfvars/<architecture>.tfvars 2>/dev/null \
  && echo "PASS" || echo "FAIL: <themis_root>/vms/aws/tfvars/<architecture>.tfvars not found"
```

---

### Check 4 — OS tfvars file exists

```bash
ls <themis_root>/vms/aws/tfvars/<os>.tfvars 2>/dev/null \
  && echo "PASS" || echo "FAIL: <themis_root>/vms/aws/tfvars/<os>.tfvars not found"
```

---

### Check 5 — Repo checkouts valid (not dangling symlinks)

For each of `themis_root`, `deployer_repo`, `tls_repo`:

```bash
git -C <repo_path> rev-parse --short HEAD 2>&1 \
  && echo "PASS (<short_sha>)" \
  || echo "FAIL: <repo_path> is not a valid git checkout"
```

A dangling symlink (directory exists but `git rev-parse` fails) is treated as FAIL.

---

### Check 6 — SSH key file exists and permissions are 400

```bash
if [ ! -f "<ssh_key_path>" ]; then
  echo "FAIL: file not found at <ssh_key_path>"
elif [ "$(stat -f '%A' '<ssh_key_path>')" != "400" ]; then
  echo "WARN: exists but permissions are not 400 — run: chmod 400 <ssh_key_path>"
else
  echo "PASS"
fi
```

**WARN** (not FAIL) allows the build to proceed; Ansible will surface a clear error if
the key is truly unusable.

---

### Check 7 — EC2 key pair exists in AWS account

Read the key pair name from `run-vars.yml`'s `ssh_key_path` filename (strip path and
`.pem` extension) OR from `AWS_KEY_NAME` in `.env` (takes precedence):

```bash
KEY_NAME=$(grep -E "^AWS_KEY_NAME=" .env 2>/dev/null | cut -d= -f2)
if [ -z "${KEY_NAME}" ]; then
  KEY_NAME=$(basename <ssh_key_path> .pem)
fi

aws ec2 describe-key-pairs \
  --key-names "${KEY_NAME}" \
  --profile <aws_profile> \
  --query 'KeyPairs[0].KeyName' --output text 2>&1
# PASS if output is the key name
# FAIL if output contains "InvalidKeyPair.NotFound"
```

---

### Check 8 — Security groups exist (non-pe-team-sbx accounts only)

Skip (SKIP) if `AWS_SECURITY_GROUP_IDS` is not set in `.env`.

```bash
SG_IDS=$(grep -E "^AWS_SECURITY_GROUP_IDS=" .env 2>/dev/null | cut -d= -f2)
if [ -z "${SG_IDS}" ]; then
  echo "SKIP (pe-team-sbx default SGs — no override set)"
else
  aws ec2 describe-security-groups \
    --group-ids ${SG_IDS//,/ } \
    --profile <aws_profile> \
    --query 'SecurityGroups[*].{Id:GroupId,Name:GroupName}' --output table 2>&1
  # PASS if every ID resolves without error
  # FAIL if any ID returns "InvalidGroup.NotFound"
fi
```

---

### Check 9 — PyYAML available

```bash
python3 -c "import yaml; print('PASS')" 2>/dev/null || echo "FAIL: PyYAML missing"
```

**Fix if FAIL:**
```bash
python3 -m pip install --user --break-system-packages pyyaml
```

---

### Check 10 — OpenTofu binary architecture (Apple Silicon)

```bash
TOFU_ARCH=$(file "$(which tofu)" 2>/dev/null)
if echo "${TOFU_ARCH}" | grep -q "arm64"; then
  echo "PASS (arm64)"
elif echo "${TOFU_ARCH}" | grep -q "x86_64"; then
  echo "FAIL: tofu binary is x86_64 (running under Rosetta — plugin timeouts expected)"
  echo "      Fix: brew reinstall opentofu"
else
  echo "WARN: could not determine tofu architecture — ${TOFU_ARCH}"
fi
```

Skip this check on non-Apple-Silicon hosts (Linux x86_64, CI).

---

### Check 11 — JFrog authentication present

```bash
REPO_KEY=$(grep -E "^repository_api_key:" .claude/skills/themis-aws-deploy/run-vars.yml \
  | awk -F': ' '{print $2}' | tr -d '"' | xargs)
JFROG_ENV=$(grep -E "^JFROG_TOKEN=" .env 2>/dev/null | cut -d= -f2)

if [ -n "${REPO_KEY}" ]; then
  echo "PASS (repository_api_key set in run-vars.yml)"
elif [ -n "${JFROG_ENV}" ]; then
  echo "PASS (JFROG_TOKEN in .env — auto-populate via Step 1a)"
else
  echo "FAIL: no JFrog credential found — set JFROG_TOKEN in .env"
fi
```

---

### Check 12 — platform_packages URLs point at JFrog (not dead registry)

Skip (SKIP) if `platform_packages` is not set in `run-vars.yml`.

```bash
python3 - <<'EOF'
import re, sys
with open(".claude/skills/themis-aws-deploy/run-vars.yml") as f:
    text = f.read()
# Extract platform_packages block
block = re.search(r'^platform_packages:\s*\n((?:  - .+\n?)+)', text, re.MULTILINE)
if not block:
    print("SKIP (platform_packages not set — using Themis pinned default)")
    sys.exit(0)
urls = re.findall(r'https?://[^\s]+', block.group(1))
bad = [u for u in urls if "registry.aws.itential.com" in u or "itential.jfrog.io" not in u]
if bad:
    print(f"FAIL: dead/non-JFrog URLs detected:\n  " + "\n  ".join(bad))
    print("      All platform_packages must use https://itential.jfrog.io/...")
    sys.exit(1)
print(f"PASS ({len(urls)} URL(s) — all point at itential.jfrog.io)")
EOF
```

---

### Check 13 — Gateway .whl readiness

Skip (SKIP) if `gateway_release` is not set in `run-vars.yml`.

```bash
GW_REL=$(grep -E "^gateway_release:" .claude/skills/themis-aws-deploy/run-vars.yml \
  | awk -F': ' '{print $2}' | tr -d '"' | xargs)
if [ -z "${GW_REL}" ]; then
  echo "SKIP (gateway_release not set)"
else
  WHL=$(ls <deployer_repo>/playbooks/files/*.whl 2>/dev/null | head -1)
  JFROG_ENV=$(grep -E "^JFROG_TOKEN=" .env 2>/dev/null | cut -d= -f2)
  if [ -n "${WHL}" ]; then
    echo "PASS (.whl found: $(basename ${WHL}))"
  elif [ -n "${JFROG_ENV}" ]; then
    echo "PASS (JFROG_TOKEN present — Step 1c will auto-pull)"
  else
    echo "FAIL: gateway_release=${GW_REL} but no .whl at <deployer_repo>/playbooks/files/ and no JFROG_TOKEN"
    echo "      Place the .whl manually or add JFROG_TOKEN to .env"
  fi
fi
```

---

### Summary Table — Present After All Checks Complete

After running checks 1–13, Claude renders the following summary (fill in actual results):

```
╔══════════════════════════════════════════════════════════════════════╗
║  PRE-BUILD CONFIRMATION GATE                                         ║
╠══════════════════════════════════════════════════════════════════════╣
║  Run vars & repo                                                     ║
╠══════════════════════════════════════════════════════════════╦═══════╣
║  Required run-vars fields (8/8 set)                          ║ PASS  ║
║  themis_root: valid git checkout (<sha>)                     ║ PASS  ║
║  deployer_repo: valid git checkout (<sha>)                   ║ PASS  ║
║  tls_repo: valid git checkout (<sha>)                        ║ PASS  ║
║  SSH key file (<path>) — mode 400                            ║ PASS  ║
╠══════════════════════════════════════════════════════════════╬═══════╣
║  AWS identity & resources                                            ║
╠══════════════════════════════════════════════════════════════╬═══════╣
║  AWS STS (<profile>) — <arn-snippet>                         ║ PASS  ║
║  Architecture tfvars: <arch>.tfvars                          ║ PASS  ║
║  OS tfvars: <os>.tfvars                                      ║ PASS  ║
║  EC2 key pair: <key-name>                                    ║ PASS  ║
║  Security groups                                             ║ SKIP  ║
║    (pe-team-sbx default — no override)                              ║
╠══════════════════════════════════════════════════════════════╬═══════╣
║  Toolchain                                                           ║
╠══════════════════════════════════════════════════════════════╬═══════╣
║  PyYAML                                                      ║ PASS  ║
║  OpenTofu binary (arm64)                                     ║ PASS  ║
╠══════════════════════════════════════════════════════════════╬═══════╣
║  Credentials & packages                                              ║
╠══════════════════════════════════════════════════════════════╬═══════╣
║  JFrog auth (JFROG_TOKEN in .env)                            ║ PASS  ║
║  platform_packages URLs (<N> URLs — all JFrog)               ║ PASS  ║
║  Gateway .whl                                                ║ SKIP  ║
║    (gateway_release not set)                                         ║
╚══════════════════════════════════════════════════════════════╩═══════╝
```

Status values:
- **PASS** — check succeeded
- **FAIL** — check failed; show the specific fix before presenting the confirmation prompt
- **WARN** — non-blocking concern; build can proceed but Claude notes the risk
- **SKIP** — not applicable for this run configuration

**If any check is FAIL:** do not present the confirmation prompt. Instead explain each
FAIL with the exact remediation step (from the check descriptions above), then re-run
the gate after the engineer resolves it.

---

### Cost & Scope Context

After the table, output:

```
About to provision:
  Architecture : <architecture> (<N> VM(s))
  OS           : <os>
  AWS account  : <aws_profile>  [<account-id> — <arn-snippet>]
  AWS region   : <region (from auto-account.tfvars or default us-east-1)>
  Owner tag    : <owner>
  EC2 key pair : <key-name>
  Estimated runtime : <from Section 9 table above>
  Platform     : <platform_release> (<N> package URLs) — OR — Themis pinned default

EC2 instances accrue AWS spend until destroyed. Destroy command when done:
  tofu destroy -var-file=tfvars/<architecture>.tfvars -var-file=tfvars/<os>.tfvars \
    -var owner=<owner> -var profile=<aws_profile> -auto-approve
```

---

### Confirmation Prompt (Hard Stop)

Present this and **wait for engineer input** before executing any Step 3 command:

```
All checks passed. Ready to provision <N> VM(s) for <architecture>/<os> on <aws_profile>.

Proceed with tofu apply? (yes / no / show-run-vars)
```

- **"yes"** → continue to Step 3 (tofu plan, then apply)
- **"no"** → stop cleanly; print the destroy command as a reminder if any state already exists from a prior partial run
- **"show-run-vars"** → print the full contents of `run-vars.yml` (masked: replace `repository_api_key` value with `***`) so the engineer can verify settings, then re-present the confirmation prompt

**No other response proceeds.** Claude does not infer "yes" from silence, prior messages,
or `--auto` flags. The engineer must type "yes" in the chat in response to this prompt.
