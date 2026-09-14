# /themis-aws-deploy Local Extensions

These extensions layer on top of the vendor SKILL.md without modifying it.
`CLAUDE.md` instructs Claude to read this file alongside SKILL.md for every
`/themis-aws-deploy` invocation. Sections marked **[OVERRIDE]** replace the
corresponding vendor instruction entirely; sections marked **[INSERT AFTER Step N]**
add steps at the specified position.

This file is NOT in `vendor/platform-skills/SYNC_MANIFEST.json` — it survives
`sync-platform-skills.sh` runs unchanged.

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

## [INSERT AFTER Step 1] Step 1a — Auto-populate repository_password from JFROG_TOKEN

If `repository_password` is blank in `run-vars.yml` **and** `JFROG_TOKEN` is set in `.env`,
use the token as the repository password for this session. Write it to
`group_vars/all/jfrog_auth.yml` at Step 4c time — do NOT write it back to `run-vars.yml`.

```bash
JFROG_TOKEN=$(grep -E "^JFROG_TOKEN=" .env 2>/dev/null | cut -d= -f2)
REPO_PASS=$(grep -E "^repository_password:" <SKILL_DIR>/run-vars.yml | awk -F': ' '{print $2}' | tr -d '"')
if [ -z "${REPO_PASS}" ] && [ -n "${JFROG_TOKEN}" ]; then
  echo "==> Auto-populating repository_password from JFROG_TOKEN (.env)"
  AUTO_REPO_PASSWORD="${JFROG_TOKEN}"
fi
```

At Step 4c, after `apply_run_vars.py` runs, if `AUTO_REPO_PASSWORD` is set:

```bash
mkdir -p <ENV_DIR>/inventory/group_vars/all
printf -- "---\nrepository_password: %s\n" "${AUTO_REPO_PASSWORD}" \
  > <ENV_DIR>/inventory/group_vars/all/jfrog_auth.yml
echo "==> Wrote repository_password to group_vars/all/jfrog_auth.yml"
```

`repository_password` in `run-vars.yml` can be left blank as long as `JFROG_TOKEN` is in `.env`.

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

Verify key pair and SG exist before running:
```bash
aws ec2 describe-key-pairs \
  --key-names <key_name> --profile <aws_profile> \
  --query 'KeyPairs[0].KeyName' --output text

aws ec2 describe-security-groups \
  --group-ids <sg_id> --profile <aws_profile> \
  --query 'SecurityGroups[0].{Id:GroupId,Name:GroupName}' --output table
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

- [ ] AWS identity confirmed and key pair + SG exist in account (or `.env` overrides set)
- [ ] `itential.tls` cloned; `tls_repo` in `run-vars.yml` points at a valid checkout
- [ ] `repository_password` filled in `run-vars.yml` **OR** `JFROG_TOKEN` in `.env` for auto-populate
- [ ] Platform version decided: Themis default or both `platform_release` + `platform_packages` set
- [ ] Gateway: `gateway_release` commented out (skip) OR set + `.whl` on disk / `JFROG_TOKEN` present
- [ ] Required run-vars filled: `architecture`, `os`, `themis_root`, `owner`, `deployer_repo`, `tls_repo`, `aws_profile`, `ssh_key_path`
- [ ] Cost acknowledged: know VM count, have a destroy plan
