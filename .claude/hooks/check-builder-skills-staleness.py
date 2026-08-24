#!/usr/bin/env python3
"""
Stop hook: checks if vendor/builder-skills is stale relative to upstream main.
Prints a staleness report if behind. Always exits 0 — informational only,
never blocks the session. Fails silently if network is unavailable.
"""
import json, os, subprocess, urllib.request

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
MANIFEST = os.path.join(REPO_ROOT, "vendor", "builder-skills", "SYNC_MANIFEST.json")
UPSTREAM = "https://github.com/itential/builder-skills.git"
GITHUB_API = "https://api.github.com/repos/itential/builder-skills"
BRANCH = "main"


def main():
    # Read the current vendored commit
    try:
        with open(MANIFEST) as f:
            m = json.load(f)
        local_sha = m["synced_commit"]
        local_date = m.get("synced_commit_date", "unknown")
    except Exception:
        return  # no manifest or bad JSON — skip silently

    # Fetch upstream HEAD via git ls-remote (no clone, fast)
    try:
        result = subprocess.run(
            ["git", "ls-remote", UPSTREAM, f"refs/heads/{BRANCH}"],
            capture_output=True, text=True, timeout=10
        )
        parts = result.stdout.strip().split()
        upstream_sha = parts[0] if parts else None
    except Exception:
        return  # network unavailable — skip silently

    if not upstream_sha or upstream_sha == local_sha:
        return  # up to date or couldn't resolve

    # Try GitHub compare API for exact commit count
    behind = "1+"
    try:
        url = f"{GITHUB_API}/compare/{local_sha}...{upstream_sha}"
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=8) as r:
            data = json.load(r)
            ahead_by = data.get("ahead_by")
            if isinstance(ahead_by, int):
                behind = str(ahead_by)
    except Exception:
        pass  # API unavailable — use default "1+"

    local_short = local_sha[:12]
    upstream_short = upstream_sha[:12]
    print(
        f"\n⚠️  builder-skills vendor copy is out of date.\n"
        f"   Current:  {local_short}  (synced {local_date})\n"
        f"   Upstream: {upstream_short} ({BRANCH})\n"
        f"   Behind:   {behind} commit(s)\n"
        f"   Run:      scripts/sync-builder-skills.sh  to update.\n"
    )


main()
