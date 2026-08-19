#!/usr/bin/env bash
#
# sync-builder-skills.sh
#
# Refreshes the workflow-construction helper templates that
# troubleshooting-agent needs (for Phase 4 "Reproduce the Issue") from the
# upstream builder-skills repo, which is owned and updated by a different
# team: https://github.com/itential/builder-skills
#
# This is a ONE-SHOT SYNC, not a live dependency:
#   - troubleshooting-agent never calls out to builder-skills at runtime
#   - this script just refreshes a vendored, committed copy on demand
#   - only the specific workflow-construction paths are pulled (sparse
#     checkout), never the full builder-skills repo
#
# Run this before Phase 4 work that needs current workflow helpers, or on a
# schedule (e.g. via CronCreate) to get a periodic "N files changed upstream"
# signal without auto-applying anything blindly.
#
# Usage:
#   scripts/sync-builder-skills.sh [branch]
#
set -euo pipefail

REPO_URL="https://github.com/itential/builder-skills.git"
BRANCH="${1:-main}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor/builder-skills"
MANIFEST="${VENDOR_DIR}/SYNC_MANIFEST.json"
CHANGELOG="${VENDOR_DIR}/SYNC_CHANGELOG.md"

# Only pull the files troubleshooting-agent actually needs to construct /
# mimic workflows. Extend this list deliberately — don't widen to the whole
# helpers/ dir or the whole repo.
#
# NOTE: as of upstream commit c64e0dc ("feat(helpers): replace hand-crafted
# snippets with real importable assets", builder-skills PR #76), the old flat
# helpers/workflow-task-*.json and helpers/reference-*-workflow.json files
# were REMOVED and replaced by helpers/assets/*.json "real importable
# assets" (full component bundles with live schemas, not hand-written
# snippets) plus helpers/create/create-workflow.json for the bare scaffold.
# That reorg also absorbed an earlier correctness fix (160d7bf,
# "correct all workflow task helpers against live platform schemas") that
# a stale vendored copy from before either commit would have missed
# entirely — this is the exact drift risk this script exists to catch.
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

echo "==> Sparse-cloning ${REPO_URL} (branch: ${BRANCH})"
git clone --quiet --filter=blob:none --sparse --depth 1 --branch "${BRANCH}" \
  "${REPO_URL}" "${TMP_DIR}/repo"

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
