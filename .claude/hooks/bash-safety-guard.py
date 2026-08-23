#!/usr/bin/env python3
"""
PreToolUse hook for Bash commands.
Blocks MongoDB writes, Redis writes, service/container restarts, and
git staging of customer investigation data — all without explicit engineer
consent. Exit 2 = block; exit 0 = allow.
"""
import json, re, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)  # fail-open: don't block on parse error

cmd = data.get("tool_input", {}).get("command", "")

# For git commands only check the git-staging rule, not DB/restart patterns —
# commit messages and branch names can legitimately contain pattern strings.
IS_GIT_CMD = bool(re.match(r"\s*git\s+", cmd))

RULES = [
    # ── MongoDB writes ─────────────────────────────────────────────────────
    (
        [
            r"\bdb\.\w+\.(insert|insertOne|insertMany|update|updateOne|updateMany"
            r"|replaceOne|delete|deleteOne|deleteMany|remove|drop)\s*\(",
            r"\bdropCollection\s*\(",
            r"\bdb\.(createCollection|dropDatabase)\s*\(",
            r"\bdb\.\w+\.(createIndex|ensureIndex|dropIndex)\s*\(",
        ],
        "BLOCKED — MongoDB write operation detected.\n"
        "Safety rule: MongoDB is READ-ONLY during investigations.\n"
        "No inserts, updates, deletes, drops, or index changes without explicit\n"
        "engineer approval. Get consent, document the reason, then proceed.",
    ),
    # ── Redis writes ───────────────────────────────────────────────────────
    (
        [
            r"\bFLUSHDB\b",
            r"\bFLUSHALL\b",
            r"redis-cli\b.*\b(DEL|SET|EXPIRE|RENAME|LPUSH|RPUSH|HSET|HDEL|SADD|SREM)\b",
        ],
        "BLOCKED — Redis write operation detected.\n"
        "Safety rule: Redis is READ-ONLY during investigations.\n"
        "No SET, DEL, FLUSHDB, or FLUSHALL without explicit engineer approval.",
    ),
    # ── Service / container restarts ───────────────────────────────────────
    (
        [
            r"\bdocker(\s+container)?\s+restart\b",
            r"\bdocker-compose\s+restart\b",
            r"\bsystemctl\s+restart\b",
            r"\bservice\s+\S+\s+restart\b",
            r"\bpm2\s+(restart|reload|stop)\b",
            r"\bkubectl\s+rollout\s+restart\b",
            r"\bkubectl\s+delete\s+pod\b",
        ],
        "BLOCKED — Service or container restart detected.\n"
        "Safety rule: Never restart adapters, applications, or containers without\n"
        "explicit engineer consent. Present the restart plan, wait for approval,\n"
        "then proceed.",
    ),
    # ── git staging of investigation data ─────────────────────────────────
    (
        [
            r"\bgit\s+add\s+data/",
            r"\bgit\s+add\s+-f\b",   # force-add could override gitignore
        ],
        "BLOCKED — git staging of customer investigation data.\n"
        "Safety rule: data/<timestamp>/ folders contain customer PII, ticket\n"
        "context, and log excerpts — they must not be committed to git.\n"
        "Stage specific reference files instead: git add data/known-resolutions.md",
    ),
]

GIT_STAGING_RULE_INDEX = 3  # index of the git-staging rule in RULES

for i, (patterns, message) in enumerate(RULES):
    # Skip MongoDB, Redis, and restart rules for git commands
    if IS_GIT_CMD and i != GIT_STAGING_RULE_INDEX:
        continue
    for pattern in patterns:
        if re.search(pattern, cmd, re.IGNORECASE):
            print(message)
            print(f"\nCommand that triggered this guard:\n  {cmd[:300]}")
            sys.exit(2)

sys.exit(0)
