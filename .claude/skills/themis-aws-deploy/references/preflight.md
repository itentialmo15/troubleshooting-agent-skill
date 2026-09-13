# Pre-flight Checks Reference

Run all checks before provisioning. Fix failures before proceeding.

---

## 1. OpenTofu / Terraform

```bash
which tofu || which terraform
tofu version   # requires >= 1.6
```

**If missing:** Install OpenTofu from https://opentofu.org/docs/intro/install/
Use `terraform` as fallback if `tofu` is not available — commands are identical.

---

## 2. Ansible

```bash
which ansible-playbook
ansible --version   # requires >= 2.11, recommend 2.13+
```

**If missing:** `pip install ansible`

---

## 3. Python

```bash
which python3
python3 --version   # requires >= 3.8
```

**If missing:** Install via system package manager or https://python.org

---

## 4. AWS Credentials and Resources

### 4a. Authenticate and verify identity

**Standard path (pe-team-sbx):**
```bash
aws sso login --profile pe-team-sbx
aws sts get-caller-identity --profile pe-team-sbx
```

**Custom account path:** Add these vars to `.env` (gitignored, per-engineer).
Step 1b runs `scripts/generate_account_tfvars.py` to turn them into `auto-account.tfvars`:
```bash
# Required for non-pe-team-sbx accounts:
AWS_KEY_NAME=your-ec2-key-pair-name
AWS_SECURITY_GROUP_IDS=sg-xxxxxxxxxxxx     # comma-separated; must allow SSH (22) inbound
AWS_SUBNET_IDS=subnet-aaa,subnet-bbb,subnet-ccc  # three subnets → public-1a/b/c aliases

# Optional — only needed if deploying outside us-east-1:
AWS_REGION=us-west-2

# Optional — right-size instances per role (all default to t3.medium):
AWS_INSTANCE_TYPE_PLATFORM=t3.large
AWS_INSTANCE_TYPE_REDIS=t3.medium
AWS_INSTANCE_TYPE_MONGODB=t3.medium
AWS_INSTANCE_TYPE_GATEWAY=t3.medium
```

Engineers on `pe-team-sbx` add nothing — the SG/subnet/key defaults already exist in that account.

### 4b. Verify key pair exists in your AWS account

```bash
aws ec2 describe-key-pairs \
  --key-names <key_name_from_run_vars_or_AWS_KEY_NAME> \
  --profile <aws_profile> \
  --query 'KeyPairs[0].KeyName' \
  --output text
```

**If not found:** Create or import the key pair in the AWS console, or set `AWS_KEY_NAME`
to a key pair that already exists in your account.

### 4c. Verify security group exists and allows SSH

```bash
aws ec2 describe-security-groups \
  --group-ids <sg_id_from_AWS_SECURITY_GROUP_IDS> \
  --profile <aws_profile> \
  --query 'SecurityGroups[0].{Id:GroupId,Name:GroupName}' \
  --output table
```

Confirm the SG has an inbound rule allowing TCP port 22 from your IP or CIDR block.

---

## 5. SSH Key

```bash
ls -la <ssh_key_path from run-vars.yml>
```

If using pe-team-sbx, the default is `~/.ssh/pet-east1.open.pem`:
```bash
ls -la ~/.ssh/pet-east1.open.pem
```

**If missing:** Obtain the key from your team. Permissions must be 400:
```bash
chmod 400 <ssh_key_path>
```

Without this key, Ansible cannot SSH into the provisioned EC2 instances.

---

## 5a. Gateway `.whl` Pre-flight (only if `gateway_release` is set in run-vars.yml)

If `gateway_release` is set, check whether the `.whl` file already exists:

```bash
ls <deployer_repo>/playbooks/files/*.whl
```

**If missing and JFROG_TOKEN is set in .env:** the skill auto-pulls the `.whl` from
`itential.jfrog.io/automation-gateway` at Step 1 — no manual action needed.

**If missing and JFROG_TOKEN is not set:** you must place the wheel manually before running:
```bash
# Browse what's available for your release:
scripts/pull-platform-rpms.sh --version <gateway_release> --components iag4 --list

# Download it:
scripts/pull-platform-rpms.sh --version <gateway_release> --components iag4 \
  --out-dir <deployer_repo>/playbooks/files/
```

The gateway role hard-fails before doing anything if `gateway_whl_file` is set but the
file does not exist.

---

## 6. Itential Deployer Collection

```bash
ansible-galaxy collection list | grep itential.deployer
```

**If missing:**
```bash
ansible-galaxy collection install git+https://github.com/itential/itential.deployer.git,main
```

---

## 6a. Required Local Repo Checkouts

`themis_root`, `deployer_repo`, and `tls_repo` in `run-vars.yml` must point at real, valid checkouts of these three repos. This is not covered by any other check above — item 6's `ansible-galaxy collection list` only tells you whether a *globally-installed* copy of `itential.deployer` exists, which is irrelevant here, since this skill always uses the locally symlinked `deployer_repo`/`tls_repo` checkout instead (Local Collections Setup takes precedence over anything in `~/.ansible/collections`).

```bash
git clone git@gitlab.com:itential/platform-engineering/themis.git
git clone git@github.com:itential/itential.deployer.git
git clone git@gitlab.com:itential/platform-engineering/ansible/collections/itential.tls.git
```

**Why this matters more than a typical missing-dependency check:** a bad `deployer_repo` or `tls_repo` path does not fail immediately. `deployer_repo` is only ever referenced through a symlink, which succeeds even when it points at nothing — the first real failure is Step 5's `ansible-playbook itential.deployer.*` call, by which point provisioning, SSH wait, inventory generation, and TLS cert generation have already run against real AWS instances. A bad `tls_repo` fails one step earlier (Step 4a), still after provisioning. Verify all three *before* Step 3, not after a failure:

```bash
[ -f <themis_root>/scripts/generate_inventory.py ] && [ -d <themis_root>/vms/aws ] \
  && echo "themis_root OK" || echo "themis_root MISSING/WRONG"

[ -d <deployer_repo>/roles/platform ] && [ -d <deployer_repo>/roles/gateway ] \
  && echo "deployer_repo OK" || echo "deployer_repo MISSING/WRONG"

[ -f <tls_repo>/playbooks/gen_ca_cert.yml ] && [ -f <tls_repo>/playbooks/gen_certs.yml ] \
  && echo "tls_repo OK" || echo "tls_repo MISSING/WRONG"
```

---

## 7. Python Dependencies (scripts/)

```bash
cd <themis-root>
pip install -r scripts/requirements.txt
```

Packages: `pymongo~=4.15.1`, `redis~=6.4.0`, `requests~=2.32.5`, `urllib3~=2.5.0`

Only required if running `generate_inventory.py` or `validate.py` directly.

---

## 8. Platform Release (group_vars)

Before deploying, confirm `platform_release` is set in the design's group_vars:

```bash
cat <themis-root>/inventories/<design>/group_vars/platform.yml | grep platform_release
```

**If missing:** Set the appropriate release version in that file before running deploy.

---

## 9. Cost / Spend Confirmation

Before `tofu apply`, confirm you understand what will be provisioned:

| Architecture | EC2 Instances | Estimated runtime |
|---|---|---|
| `aio` | 1 | ~20 min |
| `minimal` | 3–4 | ~30 min |
| `ha2` | 8–9 | ~50 min |
| `asa` | 16–18 | ~70 min |

EC2 instances accrue AWS spend until explicitly destroyed. Do not leave environments
running overnight unless intentional.

**Destroy command** (same tfvars as apply):
```bash
cd <themis_root>/vms/aws
tofu destroy \
  -var-file=<architecture>.tfvars \
  -var-file=<os>.tfvars \
  -var owner=<owner>
```

---

## 10. Pre-Run Decision Checklist

Before invoking `/themis-aws-deploy`, confirm all 7 items:

- [ ] **AWS account**: `aws sts get-caller-identity --profile <aws_profile>` succeeds; key pair and SG exist in the account (or `.env` AWS overrides are set)
- [ ] **itential.tls cloned**: `tls_repo` in run-vars.yml points at a valid checkout with `playbooks/gen_ca_cert.yml`
- [ ] **repository_password filled**: paste `JFROG_TOKEN` value into `run-vars.yml`, OR leave blank and ensure `JFROG_TOKEN` is in `.env` for auto-populate
- [ ] **Platform version decided**: use Themis's pinned default (6.3.4), or set both `platform_release` AND `platform_packages` in run-vars.yml
- [ ] **Gateway decision**: skip (leave `gateway_release` commented out), OR set `gateway_release` and ensure `.whl` exists or `JFROG_TOKEN` is present for auto-pull
- [ ] **Required run-vars filled**: `architecture`, `os`, `themis_root`, `owner`, `deployer_repo`, `tls_repo`, `aws_profile`, `ssh_key_path` are all set and non-empty
- [ ] **Cost acknowledged**: you know how many instances will be created, their estimated runtime, and you have a plan to destroy them when done
