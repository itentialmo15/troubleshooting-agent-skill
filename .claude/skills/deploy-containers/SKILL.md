---
name: deploy-containers
description: Provision a containerized Itential Platform environment for reproduction or testing. Supports Docker local (macOS/Windows), Docker on a VM (SSH), and Kubernetes via Helm charts. Handles ECR authentication, dev stack setup, secret creation, and health verification. Integrates with /troubleshoot Phase 3 reproduction workflow.
argument-hint: "[docker-local | docker-vm | k8s | --check-prereqs]"
---

# /deploy-containers — Containerized Environment Provisioning

Provisions an Itential Platform reproduction environment using Docker Compose (local or VM) or Kubernetes (Helm charts). Use this skill when a support engineer needs an isolated environment that matches a customer's platform version — faster and cheaper than full VM provisioning via Themis.

---

## CRITICAL SAFETY RULES

- **Never run `make clean` without explicit engineer approval** — it destroys MongoDB data volumes and is irreversible
- **Never run `kubectl delete namespace` without explicit approval** — removes all secrets, PVCs, and running workloads
- **Never store ECR credentials in any tracked file** — use CRED_MODE pattern (profile or env vars); credentials stay in session variables only
- **Dry-run all Helm installs first** — show rendered output to engineer; require explicit "yes" before applying
- **Always show K8s secret manifests before applying** — use `--dry-run=client -o yaml | kubectl apply -f -` so the engineer sees what will be created
- **Never hardcode credentials** — read from `.env` or prompt engineer; use `<PLACEHOLDER>` for fields to fill in IAP UI
- **Confirm cleanup scope** — distinguish `make down` (safe, preserves volumes) from `make clean` (destructive); always confirm before the destructive variant

---

## Step 0 — Select Deployment Type

Present the menu:

```
╔══════════════════════════════════════════════════════════════╗
║  /deploy-containers — Select Deployment Type                ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  1) Docker local    — this machine (macOS/Windows/Linux)     ║
║                       Fastest; dev/test only; ports on       ║
║                       localhost only                         ║
║                                                              ║
║  2) Docker on VM    — SSH to an existing Linux VM            ║
║                       Isolated from your machine;            ║
║                       Rocky Linux 9 / Ubuntu 22.04           ║
║                                                              ║
║  3) Kubernetes      — Helm charts on an existing cluster     ║
║                       Closest to production containers;      ║
║                       Requires kubectl + Helm 3.15+          ║
║                                                              ║
║  4) VMs on AWS      — Full VM topology via Themis            ║
║                       Use /themis-aws-deploy instead         ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

Choice [1-4]:
```

Set `DEPLOY_TYPE`:
- `1` → `docker-local`
- `2` → `docker-vm`
- `3` → `k8s`
- `4` → stop here, redirect to `/themis-aws-deploy`

If invoked with an argument (`docker-local`, `docker-vm`, `k8s`), skip the menu and set `DEPLOY_TYPE` directly.

---

## Step 1 — AWS Credentials for ECR

All paths (Docker and K8s) need AWS credentials to pull from ECR (`497639811223.dkr.ecr.us-east-2.amazonaws.com`).

**Step 1a — Discover available credential sources:**

```python
import configparser, os, glob

# 1. Named profiles from ~/.aws/config and ~/.aws/credentials
aws_config = os.path.expanduser("~/.aws/config")
aws_creds  = os.path.expanduser("~/.aws/credentials")
profiles = {}

for path in [aws_config, aws_creds]:
    if os.path.exists(path):
        cp = configparser.ConfigParser()
        cp.read(path)
        for section in cp.sections():
            name = section.replace("profile ", "").strip()
            p = dict(cp[section])
            if "sso_start_url" in p:
                kind = "SSO"
            elif "aws_access_key_id" in p:
                kind = "static-key"
            else:
                kind = "other"
            profiles[name] = {"kind": kind, "source": path}

# 2. .env files in repo with AWS creds
env_files = {}
for ef in glob.glob(".env*"):
    if os.path.isfile(ef):
        content = open(ef).read()
        if "AWS_ACCESS_KEY_ID" in content:
            env_files[ef] = ef

print("=== AWS profiles ===")
for i, (name, meta) in enumerate(profiles.items(), 1):
    print(f"  [{i}] {name}  ({meta['kind']})")
print(f"\n=== .env files with AWS creds ===")
for i, ef in enumerate(env_files.keys(), len(profiles)+1):
    print(f"  [{i}] {ef}")
```

**Step 1b — Present numbered menu and collect selection:**

```
Available credential sources:

  Profiles from ~/.aws:
    [1] pe-team-sbx  (SSO)
    [2] mohan-env-sts  (static-key)

  .env files with AWS credentials:
    [3] .env  (AWS_ACCESS_KEY_ID found)

Select credential source [number]:
```

**Step 1c — Process selection:**

- **Profile (SSO):** set `CRED_MODE=profile`, `SESSION_AWS_PROFILE=<name>`. If SSO, run `aws sso login --profile ${SESSION_AWS_PROFILE}` if session is expired.
- **Profile (static-key):** set `CRED_MODE=profile`, `SESSION_AWS_PROFILE=<name>`.
- **.env file:** grep `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` from file; export them; set `CRED_MODE=static-env-vars`.

**Step 1d — Verify identity and ECR login:**

```bash
# Verify identity
if [ "${CRED_MODE}" = "static-env-vars" ]; then
    aws sts get-caller-identity
else
    aws sts get-caller-identity --profile "${SESSION_AWS_PROFILE}"
fi

# ECR login
ECR_REGISTRY=497639811223.dkr.ecr.us-east-2.amazonaws.com

if [ "${CRED_MODE}" = "static-env-vars" ]; then
    aws ecr get-login-password --region us-east-2 \
      | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
else
    aws ecr get-login-password --region us-east-2 --profile "${SESSION_AWS_PROFILE}" \
      | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
fi
```

Print: `✅ ECR login successful — {ECR_REGISTRY}`

---

## Step 2 — Prerequisite Check

Run the checks appropriate to `DEPLOY_TYPE` and print a preflight table.

### Docker local (macOS/Windows/Linux)

```bash
echo "=== Docker local preflight ==="

# Docker running
docker info > /dev/null 2>&1 && echo "✅ Docker running" || echo "❌ Docker not running — start Docker Desktop"

# docker compose v2
docker compose version > /dev/null 2>&1 && echo "✅ docker compose v2 available" \
  || echo "❌ docker compose plugin not found — upgrade Docker Desktop to 4.x+"

# AWS CLI
aws --version > /dev/null 2>&1 && echo "✅ AWS CLI available" \
  || echo "❌ AWS CLI not found — brew install awscli"

# git
git --version > /dev/null 2>&1 && echo "✅ git available" \
  || echo "❌ git not found — brew install git"

# Disk space (20 GB free required)
python3 -c "
import shutil
free = shutil.disk_usage('/').free // (1024**3)
if free >= 20:
    print(f'✅ Disk space: {free} GB free')
else:
    print(f'⚠️  Disk space: {free} GB free — 20 GB recommended')
"
```

**Windows note:** WSL2 backend must be enabled in Docker Desktop → Settings → General → "Use WSL 2 based engine".

### Docker on VM

```bash
# Read SSH vars from .env
SSH_HOST=$(grep "^SSH_HOST_1=" .env | cut -d= -f2)
SSH_USER=$(grep "^SSH_USER_1=" .env | cut -d= -f2)
SSH_KEY=$(grep "^SSH_KEY_PATH_1=" .env | cut -d= -f2)

echo "=== Docker VM preflight (${SSH_HOST}) ==="

# SSH connectivity
ssh -i "${SSH_KEY}" -o ConnectTimeout=5 "${SSH_USER}@${SSH_HOST}" "echo '✅ SSH connection OK'" \
  || echo "❌ SSH failed — check SSH_HOST_1/SSH_USER_1/SSH_KEY_PATH_1 in .env"

# Docker + compose on VM
ssh -i "${SSH_KEY}" "${SSH_USER}@${SSH_HOST}" "
  docker info > /dev/null 2>&1 && echo '✅ Docker running' || echo '❌ Docker not running on VM'
  docker compose version > /dev/null 2>&1 && echo '✅ docker compose v2 available' \
    || echo '❌ docker compose plugin missing — sudo dnf install docker-compose-plugin'
  aws --version > /dev/null 2>&1 && echo '✅ AWS CLI available' \
    || echo '⚠️  AWS CLI not found on VM — will transfer ECR token manually'
  df -BG / | tail -1 | awk '{print \"Disk free: \" \$4}'
"
```

**VM resource minimum:** 4 vCPU / 16 GB RAM / 50 GB disk.

### Kubernetes

```bash
echo "=== Kubernetes preflight ==="

# kubectl
kubectl version --client > /dev/null 2>&1 && echo "✅ kubectl available" \
  || echo "❌ kubectl not found — brew install kubectl"

# Helm version
HELM_VER=$(helm version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
python3 -c "
ver = '${HELM_VER}'.lstrip('v').split('.')
req = [3, 15, 0]
if list(map(int, ver)) >= req:
    print(f'✅ Helm {\"${HELM_VER}\"} — meets 3.15.0+ requirement')
else:
    print(f'❌ Helm {\"${HELM_VER}\"} — need 3.15.0+; brew upgrade helm')
"

# Cluster connectivity
kubectl cluster-info > /dev/null 2>&1 && echo "✅ Cluster reachable" \
  || echo "❌ kubectl cannot reach cluster — check KUBECONFIG / VPN"

# StorageClass
kubectl get storageclass iap-ebs-gp3 > /dev/null 2>&1 \
  && echo "✅ StorageClass iap-ebs-gp3 exists" \
  || echo "⚠️  StorageClass iap-ebs-gp3 not found — Step 5c will create it"

# cert-manager
kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -q Running \
  && echo "✅ cert-manager running" \
  || echo "⚠️  cert-manager not detected — K8s TLS features may not work"

# Node resources
kubectl get nodes -o custom-columns=\
"NAME:.metadata.name,CPU:.status.capacity.cpu,MEM:.status.capacity.memory" 2>/dev/null
```

**Abort if any FAIL.** Warn on WARN. Ask engineer to confirm before continuing if warnings exist.

---

## Step 3 — Clone and Configure Dev Stack (Docker paths)

*Skip this step for K8s — proceed to Step 5.*

### Step 3a — Clone or update repo

```bash
DEVSTACK_DIR="${HOME}/itential-dev-stack"

if [ -d "${DEVSTACK_DIR}/.git" ]; then
    echo "Found existing dev stack at ${DEVSTACK_DIR} — pulling latest"
    git -C "${DEVSTACK_DIR}" pull origin main
else
    echo "Cloning itential-dev-stack..."
    git clone https://github.com/itential/itential-dev-stack "${DEVSTACK_DIR}"
fi

cd "${DEVSTACK_DIR}"
echo "Dev stack version: $(git log -1 --format='%h %s')"
```

**For Docker on VM:** after cloning locally, transfer to the VM:

```bash
scp -i "${SSH_KEY}" -r "${DEVSTACK_DIR}" "${SSH_USER}@${SSH_HOST}:~/itential-dev-stack"
```

### Step 3b — Select platform version

Ask the engineer:
```
What IAP version should the reproduction environment run?
  Example: 6.5.2 (exact maintenance release) or 6 (latest 6.x rolling)
  Version to reproduce: 
```

Set `IAP_VERSION` from engineer input.

Map to image variables:
```bash
ECR=497639811223.dkr.ecr.us-east-2.amazonaws.com
PLATFORM_IMAGE="${ECR}/automation-platform-config-lcm:${IAP_VERSION}"
```

Ask: "Does this issue involve IAG? If yes, which version — 4 or 5?"
- No IAG → `GATEWAY4_ENABLED=false`, `GATEWAY5_ENABLED=false`, `STACK_PROFILE=platform`
- IAG4 → `GATEWAY4_ENABLED=true`, `GATEWAY4_IMAGE="${ECR}/automation-gateway:${GATEWAY4_VERSION}"`, `STACK_PROFILE=full`
- IAG5 → `GATEWAY5_ENABLED=true`, `GATEWAY5_IMAGE="${ECR}/automation-gateway5:${GATEWAY5_VERSION}"`, `STACK_PROFILE=full`

### Step 3c — Build .env file

```bash
# Generate encryption key
ENCRYPTION_KEY=$(openssl rand -hex 32)

# Determine BIND_ADDRESS
if [ "${DEPLOY_TYPE}" = "docker-local" ]; then
    BIND_ADDRESS="127.0.0.1:"   # localhost-only; change to "" to expose on network
else
    BIND_ADDRESS=""             # expose on all interfaces (VM deployment)
fi

# Write .env from .env.example
cp .env.example .env

# Patch values
python3 - <<PYEOF
import re

patches = {
    'PLATFORM_IMAGE': '${PLATFORM_IMAGE}',
    'ITENTIAL_ENCRYPTION_KEY': '${ENCRYPTION_KEY}',
    'STACK_PROFILE': '${STACK_PROFILE}',
    'GATEWAY4_ENABLED': '${GATEWAY4_ENABLED:-false}',
    'GATEWAY5_ENABLED': '${GATEWAY5_ENABLED:-false}',
    'BIND_ADDRESS': '${BIND_ADDRESS}',
}

with open('.env') as f:
    content = f.read()

for key, val in patches.items():
    content = re.sub(rf'^{key}=.*', f'{key}={val}', content, flags=re.MULTILINE)
    if f'{key}=' not in content:
        content += f'\n{key}={val}'

with open('.env', 'w') as f:
    f.write(content)
print('✅ .env written')
PYEOF
```

Show the engineer the final `.env` with the encryption key masked (first 8 + `...`):
```
PLATFORM_IMAGE=497639811223.dkr.ecr.us-east-2.amazonaws.com/automation-platform-config-lcm:6.5.2
ITENTIAL_ENCRYPTION_KEY=a3f9b2c1...  [64-char hex, stored only in this .env]
STACK_PROFILE=platform
GATEWAY4_ENABLED=false
GATEWAY5_ENABLED=false
BIND_ADDRESS=127.0.0.1:
```

---

## Step 4 — Start Services (Docker paths)

### Step 4a — ECR login (Docker local)

If `DEPLOY_TYPE=docker-local`, the Step 1d ECR login already ran on this machine.

If `DEPLOY_TYPE=docker-vm`, transfer the ECR token to the VM:

```bash
# Get token locally, push to VM
if [ "${CRED_MODE}" = "static-env-vars" ]; then
    TOKEN=$(aws ecr get-login-password --region us-east-2)
else
    TOKEN=$(aws ecr get-login-password --region us-east-2 --profile "${SESSION_AWS_PROFILE}")
fi

ssh -i "${SSH_KEY}" "${SSH_USER}@${SSH_HOST}" \
    "echo '${TOKEN}' | docker login --username AWS --password-stdin 497639811223.dkr.ecr.us-east-2.amazonaws.com"
```

### Step 4b — Start the stack

Run on local or via SSH:

```bash
# Option A — automated setup (recommended for first run)
make setup

# Option B — step by step (if setup fails or for debugging)
# make generate-key     # if key not already set in .env
# make certs            # generate TLS certs
# make up               # start services
```

**For Docker on VM, run via SSH:**
```bash
ssh -i "${SSH_KEY}" "${SSH_USER}@${SSH_HOST}" "cd ~/itential-dev-stack && make setup"
```

### Step 4c — Wait for health

Poll until all services are healthy (timeout 3 minutes):

```python
import subprocess, time, sys

deadline = time.time() + 180
while time.time() < deadline:
    result = subprocess.run(
        ["docker", "compose", "ps", "--format", "json"],
        capture_output=True, text=True
    )
    import json
    services = [json.loads(l) for l in result.stdout.strip().split('\n') if l]
    unhealthy = [s for s in services if s.get('Health') not in ('healthy', '')]
    if not unhealthy:
        print("✅ All services healthy")
        break
    print(f"Waiting... unhealthy: {[s['Service'] for s in unhealthy]}")
    time.sleep(10)
else:
    print("❌ Timeout — checking logs:")
    subprocess.run(["docker", "compose", "logs", "--tail=50"])
    sys.exit(1)
```

### Step 4d — Verify platform health

```bash
# Wait a moment for IAP to finish init
sleep 5

curl -sk https://localhost:3443/health/platform | python3 -m json.tool 2>/dev/null \
  || curl -sk http://localhost:3000/health/platform
```

Print status table:

```
╔════════════════════════════════════════════════════════╗
║  Reproduction Environment Ready                        ║
╠═══════════════╦══════════════╦══════════════════════════╣
║ Service       ║ Status       ║ Access                   ║
╠═══════════════╬══════════════╬══════════════════════════╣
║ Platform      ║ ✅ healthy   ║ https://localhost:3443   ║
║ MongoDB       ║ ✅ healthy   ║ localhost:27017           ║
║ Redis         ║ ✅ healthy   ║ localhost:6379           ║
╠═══════════════╬══════════════╬══════════════════════════╣
║ Default creds ║ admin@itential.com / admin             ║
╚═══════════════╩══════════════╧══════════════════════════╝
```

Create `repro/{ISD_TICKET_KEY}/.env` with the dev stack connection details so the orchestrator and sub-skills can use this environment:

```bash
mkdir -p "repro/${ISD_TICKET_KEY}"
cat > "repro/${ISD_TICKET_KEY}/.env" <<EOF
PLATFORM_URL=https://localhost:3443
AUTH_METHOD=basic
CLIENT_ID=admin@itential.com
CLIENT_SECRET=admin
# Reproduction environment — Docker local via /deploy-containers
# IAP version: ${IAP_VERSION}
# Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
echo "✅ repro/${ISD_TICKET_KEY}/.env written — orchestrator will auto-detect on next /troubleshoot run"
```

---

## Step 5 — Kubernetes Deployment

*This section covers DEPLOY_TYPE=k8s only. Steps 3-4 are skipped.*

### Step 5a — Namespace and imagePullSecret

```bash
NAMESPACE="${K8S_NAMESPACE:-itential}"

# Create namespace (idempotent)
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
echo "✅ Namespace ${NAMESPACE} ready"

# Create ECR pull secret
echo "Creating ECR imagePullSecret..."
if [ "${CRED_MODE}" = "static-env-vars" ]; then
    ECR_TOKEN=$(aws ecr get-login-password --region us-east-2)
else
    ECR_TOKEN=$(aws ecr get-login-password --region us-east-2 --profile "${SESSION_AWS_PROFILE}")
fi

kubectl create secret docker-registry ecr-pull-secret \
    --namespace="${NAMESPACE}" \
    --docker-server=497639811223.dkr.ecr.us-east-2.amazonaws.com \
    --docker-username=AWS \
    --docker-password="${ECR_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -

unset ECR_TOKEN
echo "✅ ECR pull secret created"
```

### Step 5b — Platform Secrets

**Show each secret manifest to engineer before applying. Require explicit "yes".**

Collect values from engineer (never echo passwords):

```
To create the required K8s secrets I need the following values.
Credentials you enter will go directly into a K8s Secret — they will not appear in logs.

  Admin user password  (will be ITENTIAL_DEFAULT_USER_PASSWORD): 
  MongoDB password     (ITENTIAL_MONGO_PASSWORD): 
  MongoDB URL          (e.g. mongodb://mongo.example.com:27017/itential): 
  Redis password       (ITENTIAL_REDIS_PASSWORD, or press Enter if none): 
```

Generate encryption key automatically:
```bash
ENCRYPTION_KEY=$(openssl rand -hex 32)
echo "Generated ITENTIAL_ENCRYPTION_KEY — stored only in the K8s secret"
```

Build the secret manifest (for review):

```bash
# Show manifest (password values masked)
cat <<EOF
--- PROPOSED K8s SECRET MANIFEST ---
apiVersion: v1
kind: Secret
metadata:
  name: itential-platform-secrets
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  ITENTIAL_DEFAULT_USER_PASSWORD: "**hidden**"
  ITENTIAL_ENCRYPTION_KEY:        "${ENCRYPTION_KEY:0:8}...[64 chars]"
  ITENTIAL_MONGO_PASSWORD:        "**hidden**"
  ITENTIAL_MONGO_URL:             "${MONGO_URL}"
  ITENTIAL_REDIS_PASSWORD:        "**hidden**"
---
Apply this secret? [yes / abort]:
EOF
```

On approval:
```bash
kubectl create secret generic itential-platform-secrets \
    --namespace="${NAMESPACE}" \
    --from-literal=ITENTIAL_DEFAULT_USER_PASSWORD="${ADMIN_PASSWORD}" \
    --from-literal=ITENTIAL_ENCRYPTION_KEY="${ENCRYPTION_KEY}" \
    --from-literal=ITENTIAL_MONGO_PASSWORD="${MONGO_PASSWORD}" \
    --from-literal=ITENTIAL_MONGO_URL="${MONGO_URL}" \
    --from-literal=ITENTIAL_REDIS_PASSWORD="${REDIS_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -
```

**For IAG5** — also create `itential-gateway-secrets`:
```bash
GATEWAY_ENC_KEY=$(openssl rand -hex 32)
kubectl create secret generic itential-gateway-secrets \
    --namespace="${NAMESPACE}" \
    --from-literal=encryptionKey="${GATEWAY_ENC_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -
```

**For TLS CA** — ask engineer to provide `ca.crt` path (or skip if not needed):
```bash
kubectl create secret generic itential-ca \
    --namespace="${NAMESPACE}" \
    --from-file=ca.crt="${CA_CERT_PATH}" \
    --dry-run=client -o yaml | kubectl apply -f -
```

### Step 5c — StorageClass

```bash
# Check if iap-ebs-gp3 exists
if kubectl get storageclass iap-ebs-gp3 > /dev/null 2>&1; then
    echo "✅ StorageClass iap-ebs-gp3 already exists"
else
    echo "Creating StorageClass iap-ebs-gp3..."
    kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: iap-ebs-gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF
    echo "✅ StorageClass iap-ebs-gp3 created"
fi
```

### Step 5d — Helm Install: IAP Platform

```bash
# Add Helm repo
helm repo add iap https://itential.github.io/iap-helm 2>/dev/null || true
helm repo update iap
echo "Latest iap chart: $(helm search repo iap/iap --output json | python3 -c 'import sys,json; print(json.load(sys.stdin)[0][\"app_version\"])')"

# Show dry-run first
echo "=== Helm dry-run (review before applying) ==="
helm upgrade --install iap iap/iap \
    --namespace="${NAMESPACE}" \
    --set "image.repository=497639811223.dkr.ecr.us-east-2.amazonaws.com/automation-platform-config-lcm" \
    --set "image.tag=${IAP_VERSION}" \
    --set "imagePullSecrets[0].name=ecr-pull-secret" \
    --set "replicaCount=2" \
    --dry-run 2>&1 | head -80
echo ""
echo "Apply this Helm release? [yes / abort]:"
```

On approval, run without `--dry-run`.

### Step 5e — Helm Install: IAG (if needed)

**IAG5:**
```bash
helm repo add iag5 https://itential.github.io/iag5-helm 2>/dev/null || true
helm repo update iag5

helm upgrade --install iag5 iag5/iag5 \
    --namespace="${NAMESPACE}" \
    --set "image.repository=497639811223.dkr.ecr.us-east-2.amazonaws.com/automation-gateway5" \
    --set "image.tag=${GATEWAY5_VERSION}" \
    --set "imagePullSecrets[0].name=ecr-pull-secret" \
    --dry-run
echo "Apply IAG5 Helm release? [yes / skip]:"
```

**IAG4** (requires node labeling first):
```bash
# IAG4 requires node label + taint
echo "IAG4 requires a dedicated node. Which node should run IAG4?"
kubectl get nodes -o wide
echo "Node name: "
# Read NODE_NAME from engineer

kubectl label node "${NODE_NAME}" itential.io/app=iag --overwrite
kubectl taint node "${NODE_NAME}" itential.io/role=iag:NoSchedule --overwrite

helm repo add iag4 https://itential.github.io/iag4-helm 2>/dev/null || true
helm repo update iag4

helm upgrade --install iag4 iag4/iag4 \
    --namespace="${NAMESPACE}" \
    --set "image.repository=497639811223.dkr.ecr.us-east-2.amazonaws.com/automation-gateway" \
    --set "image.tag=${GATEWAY4_VERSION}" \
    --set "imagePullSecrets[0].name=ecr-pull-secret" \
    --dry-run
echo "Apply IAG4 Helm release? [yes / skip]:"
```

### Step 5f — Post-Install Verification

```bash
echo "=== Pod status ==="
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "=== Services ==="
kubectl get svc -n "${NAMESPACE}"

echo ""
echo "Waiting for IAP StatefulSet to reach ready state..."
kubectl rollout status statefulset/iap -n "${NAMESPACE}" --timeout=300s \
  && echo "✅ IAP StatefulSet ready" \
  || echo "❌ Rollout timeout — check: kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=iap"

# Port-forward for access (runs in background)
echo ""
echo "To access the platform, run in a separate terminal:"
echo "  kubectl port-forward svc/iap 3443:3443 -n ${NAMESPACE}"
echo "  Then open: https://localhost:3443"
echo "  Credentials: admin@itential.com / admin"
```

---

## Step 6 — Cleanup

### Docker cleanup

```bash
echo "Cleanup options:"
echo "  1) Stop containers only (preserves data volumes) — make down"
echo "  2) Full teardown (DESTROYS MongoDB volumes — irreversible) — make clean"
echo "Choice [1/2]:"
```

On choice 1 (safe):
```bash
make down
echo "✅ Containers stopped. Data volumes preserved. Run 'make up' to restart."
```

On choice 2 (destructive — require explicit confirmation):
```bash
echo "⚠️  WARNING: make clean will permanently delete all MongoDB data."
echo "This cannot be undone. Type 'yes I want to delete all data' to confirm:"
# Read confirmation
if [ "${CONFIRM}" = "yes I want to delete all data" ]; then
    make clean
    echo "✅ Full teardown complete. All volumes removed."
else
    echo "Aborted. Run 'make down' to stop containers without deleting data."
fi
```

### Kubernetes cleanup

```bash
echo "Cleanup options:"
echo "  1) Uninstall Helm releases only (PVCs survive)"
echo "  2) Uninstall + delete namespace (ALL resources and PVCs deleted — irreversible)"
echo "Choice [1/2]:"
```

On choice 1:
```bash
helm uninstall iap -n "${NAMESPACE}" 2>/dev/null && echo "✅ iap uninstalled"
helm uninstall iag5 -n "${NAMESPACE}" 2>/dev/null && echo "✅ iag5 uninstalled"
helm uninstall iag4 -n "${NAMESPACE}" 2>/dev/null && echo "✅ iag4 uninstalled"
echo "Note: PVCs and secrets remain. Re-install with 'helm upgrade --install' to reuse them."
```

On choice 2 (destructive):
```bash
echo "⚠️  WARNING: deleting namespace '${NAMESPACE}' removes ALL resources, secrets, and PVCs."
echo "Type 'yes delete namespace ${NAMESPACE}' to confirm:"
# Read confirmation
if [ "${CONFIRM}" = "yes delete namespace ${NAMESPACE}" ]; then
    kubectl delete namespace "${NAMESPACE}"
    echo "✅ Namespace ${NAMESPACE} deleted."
else
    echo "Aborted."
fi
```

---

## Quick Reference

| Path | Steps | Time estimate |
|---|---|---|
| Docker local | 0 → 1 → 2 → 3 → 4 | ~5 min |
| Docker on VM | 0 → 1 → 2 → 3 → 4 | ~10 min |
| Kubernetes | 0 → 1 → 2 → 5a → 5b → 5c → 5d → 5e → 5f | ~15-20 min |

| Image | ECR path |
|---|---|
| Platform | `497639811223.dkr.ecr.us-east-2.amazonaws.com/automation-platform-config-lcm:{tag}` |
| Gateway4 | `497639811223.dkr.ecr.us-east-2.amazonaws.com/automation-gateway:{tag}` |
| Gateway5 | `497639811223.dkr.ecr.us-east-2.amazonaws.com/automation-gateway5:{tag}` |

| Dev stack Make target | Effect |
|---|---|
| `make login` | ECR auth |
| `make setup` | Full first-time setup (key + certs + start + configure) |
| `make up` | Start services |
| `make down` | Stop services (preserve volumes) |
| `make clean` | ⚠️ Stop + remove volumes |
| `make logs` | Stream all service logs |
| `make status` | Show URLs, ports, health |
