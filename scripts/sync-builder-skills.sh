#!/usr/bin/env bash
#
# sync-builder-skills.sh
#
# Refreshes (or checks staleness of) the vendored workflow-construction helper
# templates from the upstream builder-skills repo:
#   https://github.com/itential/builder-skills
#
# This is a ONE-SHOT SYNC, not a live dependency:
#   - troubleshooting-agent never calls out to builder-skills at runtime
#   - this script refreshes a committed copy on demand or on a schedule
#   - only specific paths are pulled (sparse checkout), never the full repo
#
# Usage:
#   scripts/sync-builder-skills.sh [branch]          # sync (default: main)
#   scripts/sync-builder-skills.sh --check [branch]  # staleness check only
#
# --check mode:
#   Reads the current vendored SHA from SYNC_MANIFEST.json, fetches the
#   upstream HEAD via git ls-remote (no clone), queries the GitHub compare
#   API for the exact commit count, and prints a staleness report.
#   Exit 0 = up to date.  Exit 1 = stale.  Exit 2 = check could not run.
#
set -euo pipefail

REPO_URL="https://github.com/itential/builder-skills.git"
GITHUB_API="https://api.github.com/repos/itential/builder-skills"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor/builder-skills"
MANIFEST="${VENDOR_DIR}/SYNC_MANIFEST.json"
CHANGELOG="${VENDOR_DIR}/SYNC_CHANGELOG.md"

# ── Argument parsing ──────────────────────────────────────────────────────────

CHECK_ONLY=false
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
  shift
fi
BRANCH="${1:-main}"

# ── Helper: read a field from SYNC_MANIFEST.json ─────────────────────────────

manifest_field() {
  local field="$1"
  python3 -c "import json,sys; d=json.load(open('${MANIFEST}')); print(d.get('${field}',''))" 2>/dev/null || echo ""
}

# ── Helper: print staleness report ───────────────────────────────────────────

staleness_report() {
  local local_sha="$1" local_date="$2" upstream_sha="$3" behind="$4"
  local local_short="${local_sha:0:12}"
  local upstream_short="${upstream_sha:0:12}"
  echo ""
  echo "⚠️  builder-skills vendor copy is out of date."
  echo "   Current:  ${local_short}  (synced ${local_date})"
  echo "   Upstream: ${upstream_short} (${BRANCH})"
  echo "   Behind:   ${behind} commit(s)"
  echo "   Run:      scripts/sync-builder-skills.sh  to update."
  echo ""
}

# ── --check mode ─────────────────────────────────────────────────────────────

if [[ "${CHECK_ONLY}" == true ]]; then
  if [[ ! -f "${MANIFEST}" ]]; then
    echo "builder-skills: no SYNC_MANIFEST.json found — vendor copy has never been synced." >&2
    echo "Run: scripts/sync-builder-skills.sh" >&2
    exit 2
  fi

  LOCAL_SHA="$(manifest_field synced_commit)"
  LOCAL_DATE="$(manifest_field synced_commit_date)"
  if [[ -z "${LOCAL_SHA}" ]]; then
    echo "builder-skills: SYNC_MANIFEST.json is missing synced_commit field." >&2
    exit 2
  fi

  # Fetch upstream HEAD (fast: no clone, just a ref lookup)
  UPSTREAM_LINE="$(git ls-remote "${REPO_URL}" "refs/heads/${BRANCH}" 2>/dev/null || true)"
  if [[ -z "${UPSTREAM_LINE}" ]]; then
    echo "builder-skills: could not reach ${REPO_URL} — network unavailable or repo not found." >&2
    echo "   Current vendor copy: ${LOCAL_SHA:0:12} (synced ${LOCAL_DATE})" >&2
    exit 2
  fi
  UPSTREAM_SHA="$(echo "${UPSTREAM_LINE}" | awk '{print $1}')"

  if [[ "${UPSTREAM_SHA}" == "${LOCAL_SHA}" ]]; then
    echo "builder-skills vendor copy is up to date (${LOCAL_SHA:0:12})."
    exit 0
  fi

  # Query GitHub compare API for commit count (no auth needed for public repos)
  BEHIND="1+"
  if command -v curl >/dev/null 2>&1; then
    COMPARE_JSON="$(curl -sf \
      -H "Accept: application/vnd.github+json" \
      "${GITHUB_API}/compare/${LOCAL_SHA}...${UPSTREAM_SHA}" 2>/dev/null || true)"
    if [[ -n "${COMPARE_JSON}" ]]; then
      BEHIND="$(echo "${COMPARE_JSON}" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d.get('ahead_by','?'))" 2>/dev/null || echo "?")"
    fi
  fi

  staleness_report "${LOCAL_SHA}" "${LOCAL_DATE}" "${UPSTREAM_SHA}" "${BEHIND}"
  exit 1
fi

# ── Full sync mode ────────────────────────────────────────────────────────────

SPARSE_PATHS=(
  "/AGENTS.md"

  # Workflow scaffold and project helpers
  "/helpers/create/create-workflow.json"
  "/helpers/create/create-command-template.json"
  "/helpers/create/create-template-jinja2.json"
  "/helpers/create/create-template-textfsm.json"
  "/helpers/create/create-json-form.json"
  "/helpers/create/import-project.json"
  "/helpers/create/create-lcm-resource-model.json"

  # Update helpers (full-replacement PUT bodies)
  "/helpers/update/update-command-template.json"
  "/helpers/update/update-json-form.json"
  "/helpers/update/update-node-config.json"

  # Operation helpers
  "/helpers/operations/add-components-to-project.json"
  "/helpers/operations/run-compliance-plan.json"

  # Platform core asset bundles
  "/helpers/assets/itential-platform-configuration-management.json"
  "/helpers/assets/itential-platform-data-manipulation.json"
  "/helpers/assets/itential-platform-email.json"
  "/helpers/assets/itential-platform-regex-operations.json"

  # Vendor integration bundles
  "/helpers/assets/vendor-arista-eos.json"
  "/helpers/assets/vendor-cisco-ios.json"
  "/helpers/assets/vendor-infoblox-nios-ddi.json"
  "/helpers/assets/vendor-juniper-junos.json"
  "/helpers/assets/vendor-netbox.json"
  "/helpers/assets/vendor-servicenow.json"

  # LCM resource models and backing workflow projects
  "/helpers/assets/lcm/lcm-fan-device-lifecycle-management.json"
  "/helpers/assets/lcm/lcm-interface-service-provisioning.json"
  "/helpers/assets/lcm/lcm-ip-blocking-service.json"
  "/helpers/assets/lcm/lcm-port-turn-up.json"
  "/helpers/assets/lcm/lcm-vxlan-fabric-management.json"
  "/helpers/assets/lcm/lcm-vxlan-fabric-services-project.json"
)

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Trap for git clone / sparse-checkout failures to emit a human-readable report
# instead of just a raw git error.
sync_failure_report() {
  local exit_code="$?"
  echo "" >&2
  echo "✗  builder-skills sync failed (exit ${exit_code})." >&2
  echo "" >&2
  if [[ -f "${MANIFEST}" ]]; then
    local sha date synced
    sha="$(manifest_field synced_commit)"
    date="$(manifest_field synced_commit_date)"
    synced="$(manifest_field synced_at)"
    echo "   Current vendor copy:" >&2
    echo "     SHA:    ${sha} (short: ${sha:0:12})" >&2
    echo "     Date:   ${date}" >&2
    echo "     Synced: ${synced}" >&2
    echo "" >&2
    echo "   To check how far behind the vendor copy is:" >&2
    echo "     scripts/sync-builder-skills.sh --check" >&2
  else
    echo "   No existing vendor copy found (first sync never completed)." >&2
  fi
  echo "" >&2
}
trap 'sync_failure_report' ERR

echo "==> Sparse-cloning ${REPO_URL} (branch: ${BRANCH})"
git clone --quiet --filter=blob:none --sparse --depth 1 --branch "${BRANCH}" \
  "${REPO_URL}" "${TMP_DIR}/repo"

# Clone succeeded — clear the ERR trap so normal errors don't double-report
trap - ERR

pushd "${TMP_DIR}/repo" >/dev/null
git sparse-checkout set --no-cone "${SPARSE_PATHS[@]}"
UPSTREAM_SHA="$(git rev-parse HEAD)"
UPSTREAM_DATE="$(git log -1 --format=%cI)"
popd >/dev/null

NEW_STAGE="${TMP_DIR}/new"
mkdir -p "${NEW_STAGE}"
for p in "${SPARSE_PATHS[@]}"; do
  src="${TMP_DIR}/repo/${p}"
  if [[ -f "${src}" ]]; then
    dest="${NEW_STAGE}/${p}"
    mkdir -p "$(dirname "${dest}")"
    cp "${src}" "${dest}"
  else
    echo "WARN: ${p} not found upstream (renamed/removed?) — skipping" >&2
  fi
done

mkdir -p "${VENDOR_DIR}"

# Diff old vendored copy vs newly pulled copy before overwriting anything.
CHANGED_FILES=()
if [[ -d "${VENDOR_DIR}" ]]; then
  while IFS= read -r -d '' f; do
    rel="${f#"${NEW_STAGE}"/}"
    old="${VENDOR_DIR}/${rel}"
    if [[ ! -f "${old}" ]] || ! diff -q "${old}" "${f}" >/dev/null 2>&1; then
      CHANGED_FILES+=("${rel}")
    fi
  done < <(find "${NEW_STAGE}" -type f -print0)
fi

echo "==> Applying sync to ${VENDOR_DIR}"
for p in "${SPARSE_PATHS[@]}"; do
  src="${NEW_STAGE}/${p}"
  [[ -f "${src}" ]] || continue
  dest="${VENDOR_DIR}/${p}"
  mkdir -p "$(dirname "${dest}")"
  cp "${src}" "${dest}"
done

cat > "${MANIFEST}" <<EOF
{
  "source_repo": "${REPO_URL}",
  "branch": "${BRANCH}",
  "synced_commit": "${UPSTREAM_SHA}",
  "synced_commit_date": "${UPSTREAM_DATE}",
  "synced_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "files": $(printf '%s\n' "${SPARSE_PATHS[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
}
EOF

{
  echo ""
  echo "## $(date -u +%Y-%m-%dT%H:%M:%SZ) — synced from ${UPSTREAM_SHA:0:12} (${BRANCH})"
  if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
    echo "- No changes vs previously vendored copy."
  else
    echo "- ${#CHANGED_FILES[@]} file(s) changed upstream:"
    for f in "${CHANGED_FILES[@]}"; do
      echo "  - ${f}"
    done
  fi
} >> "${CHANGELOG}"

echo "==> Done."
echo "    Synced commit: ${UPSTREAM_SHA}"
if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
  echo "    No changes vs previous vendored copy."
else
  echo "    ${#CHANGED_FILES[@]} file(s) changed — review before relying on them:"
  printf '      - %s\n' "${CHANGED_FILES[@]}"
fi
echo "    Review ${CHANGELOG} and 'git diff' in vendor/builder-skills/, then commit."
