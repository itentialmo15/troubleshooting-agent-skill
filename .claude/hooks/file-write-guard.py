#!/usr/bin/env python3
"""
PreToolUse hook for Write and Edit tool calls.
Scans content being written to data/ investigation folders for high-confidence
credential patterns. Fires only for paths under data/ — other files are
unaffected. Exit 2 = block; exit 0 = allow.
"""
import json, re, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)  # fail-open: don't block on parse error

tool = data.get("tool_name", "")
inp = data.get("tool_input", {})
path = inp.get("file_path", "")

# Only guard writes to investigation artifact folders
if not (path.startswith("data/") or "/data/" in path):
    sys.exit(0)

content = inp.get("content", "") if tool == "Write" else inp.get("new_string", "")
if not content:
    sys.exit(0)

CREDENTIAL_PATTERNS = [
    (r"Bearer\s+eyJ[A-Za-z0-9._\-]{30,}", "JWT Bearer token"),
    (r"Authorization:\s*Basic\s+[A-Za-z0-9+/=]{20,}", "Basic auth credential"),
    (r'"client_secret"\s*:\s*"[^"]{8,}"', "OAuth client_secret value"),
    (r"client_secret\s*=\s*\S{8,}", "OAuth client_secret value"),
    (r'"password"\s*:\s*"[^"]{6,}"', "password value in JSON"),
    (r"password\s*=\s*\S{8,}", "password in config format"),
    (r"MONGO_URL\s*=\s*mongodb\S{20,}", "MongoDB connection string with credentials"),
    (r"REDIS_URL\s*=\s*redis://:[^@\s]{8,}@", "Redis URL with password"),
]

found = [label for pattern, label in CREDENTIAL_PATTERNS
         if re.search(pattern, content, re.IGNORECASE)]

if found:
    print(
        f"BLOCKED — Possible credential exposure in write to: {path}\n"
        f"Detected patterns: {', '.join(found)}\n"
        "Safety rule: Investigation files under data/ must not contain raw\n"
        "credential values. Mask sensitive values (first 6 chars + '...' + last 4)\n"
        "before writing. Review the content, redact the values, then retry."
    )
    sys.exit(2)

sys.exit(0)
