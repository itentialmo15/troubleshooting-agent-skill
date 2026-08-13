# Known Issues — ISD-9298

**Generated:** 2026-06-18

---

## Similar ISD Tickets

**No direct match found** for IAG5 + SSL certificate + private GitLab on-prem.

Closest related tickets:

| Ticket | Summary | Status | Relevance |
|--------|---------|--------|-----------|
| ISD-9034 | [ Production ] Issue with pyproject.toml related service on IAG5 | Pending | Same component (IAG5 Python service) — root cause was requirements.txt cache hash mismatch; not SSL. |
| ISD-6964 | IAG 5 supporting pyproject.toml | Completed (IAG 5.1) | Shows pyproject.toml now supported as of IAG 5.1 — customer on 5.4.1 has this. |

## Matching ENG Bugs

**No ENG bugs** found matching IAG5 + GitLab SSL certificate or `GIT_SSL_CAINFO`/`REQUESTS_CA_BUNDLE`.

This appears to be a **configuration/deployment issue**, not a platform bug. IAG5 does not have a dedicated field for injecting custom CA certificates into the git clone or Python execution environment.

---

## Relevant Confluence Pages

| Page | Space | Relevance |
|------|-------|-----------|
| [IAG5 TLS Certificate Validation Commands](https://itential.atlassian.net/wiki/spaces/PROD/pages/6182731848) | Product Engineering | Covers IAG5 cluster TLS validation (mTLS between nodes). Not directly about trusting a private GitLab CA but has useful openssl diagnostic commands. |
| [Repo Basic Auth torero/IAG5 Code Split](https://itential.atlassian.net/wiki/spaces/IAG/pages/5483364413) | Automation Engineering | Documents the IAG5 repository auth model: SSH key (`--private-key-name`) and HTTP basic auth (`--username` + `--password-name`). No dedicated SSL CA cert field exists on the repository resource. |
| [Static Execution Environments](https://itential.atlassian.net/wiki/spaces/IAG/pages/5505908778) | Automation Engineering | Documents pre-provisioned venv approach for air-gapped environments — relevant if customer can't reach private GitLab at all. |

---

## Key Technical Finding

From the "Repo Basic Auth" Confluence page, IAG5's repository proto supports:
- `private_key_name` — SSH key for git clone
- `username` + `password_name` — HTTP basic auth for git clone

**There is no dedicated field for SSL CA certificate injection in the IAG5 repository resource.**

This means the fix must happen at the **container/OS level** (OpenShift Deployment spec) via environment variables:
- `GIT_SSL_CAINFO=/path/to/ca.crt` — trusts the cert for git clone operations
- `REQUESTS_CA_BUNDLE=/path/to/ca.crt` — trusts the cert for Python `requests` library calls
- `SSL_CERT_FILE=/path/to/ca.crt` — trusts the cert for Python's `ssl` module

Or by **switching the repository to SSH auth** (avoids SSL cert validation entirely).
