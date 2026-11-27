#!/usr/bin/env bash
# list-models.sh -- discovers codex models available right now via
# `codex debug models`, filters to visibility:"list" + supported_in_api:true,
# sorts by priority ascending, and emits on stdout:
#   {"models":[{"slug","display_name","description"}, ...], "recommended":"<slug>"}
# (PRV-004, SPEC-PEER-REVIEW.md §6.11). recommended = the lowest-priority
# (highest-ranked) eligible model -- codex's own top pick, no other
# heuristic (decided).
#
# On failure -- codex missing from PATH, `codex debug models` exits nonzero,
# its output isn't valid JSON, or zero models survive the filter -- exits
# nonzero with nothing meaningful on stdout. Callers (the /peer-review
# skill) must treat that as "skip model selection, invoke codex with no -m
# flag" (pre-PRV-004 default behavior) -- never block the review on a
# discovery failure.
set -uo pipefail

if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: codex not found on PATH" >&2
    exit 1
fi

raw="$(codex debug models 2>/dev/null)"
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "ERROR: codex debug models exited $rc" >&2
    exit 1
fi

printf '%s' "$raw" | python3 -c '
import json
import sys

try:
    data = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)
models = data.get("models")
if not isinstance(models, list):
    sys.exit(1)

eligible = []
for m in models:
    if not isinstance(m, dict):
        continue
    if m.get("visibility") != "list":
        continue
    if m.get("supported_in_api") is not True:
        continue
    slug = m.get("slug")
    priority = m.get("priority")
    # slug + priority are load-bearing (identification, sort/recommendation)
    # and required. display_name/description are cosmetic -- their absence
    # must not silently drop an otherwise-eligible model from the catalog.
    # bool is a subclass of int in Python (isinstance(True, int) is True),
    # so it must be excluded explicitly or a malformed "priority": true/false
    # would silently sort/recommend as if it were 1/0.
    if not isinstance(slug, str) or not slug.strip():
        continue
    if not isinstance(priority, int) or isinstance(priority, bool):
        continue
    display_name = m.get("display_name")
    if not isinstance(display_name, str):
        display_name = slug
    description = m.get("description")
    if not isinstance(description, str):
        description = ""
    eligible.append((priority, slug, display_name, description))

if not eligible:
    sys.exit(1)

eligible.sort(key=lambda t: t[0])
out = {
    "models": [
        {"slug": s, "display_name": d, "description": desc}
        for _, s, d, desc in eligible
    ],
    "recommended": eligible[0][1],
}
print(json.dumps(out))
'
exit $?
