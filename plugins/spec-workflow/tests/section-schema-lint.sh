#!/usr/bin/env bash
# section-schema-lint.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. Covers #80: the WHOLE project-config schema is
# hover-complete (editor hover via the `yaml-language-server: $schema=` line
# atop .claude/project.yaml shows every key's description/enum values/
# defaults). This is the ONE canonical schema-lint check -- section-work-mode.sh
# used to carry a work.*-only hand-rolled copy of this same idea; it now
# points here instead of duplicating it.

declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
SCHEMA="$PLUGIN/schemas/project-config.schema.json"

echo "== schema-lint.py: whole schema is hover-complete =="
out="$(python3 "$PLUGIN/scripts/schema-lint.py" "$SCHEMA")"
check "project-config.schema.json: every property/enum is hover-complete" "OK" "$out"

echo "== schema-lint.py: catches a missing property description =="
BAD1="$(mktemp)"
python3 - "$SCHEMA" "$BAD1" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    s = json.load(f)
del s["properties"]["project"]["properties"]["mainBranch"]["description"]
with open(dst, "w") as f:
    json.dump(s, f)
PY
out="$(python3 "$PLUGIN/scripts/schema-lint.py" "$BAD1" || true)"
check "missing property description is caught" "project.mainBranch: missing description" "$out"
rm -f "$BAD1"

echo "== schema-lint.py: catches an enumDescriptions/enum length mismatch =="
BAD2="$(mktemp)"
python3 - "$SCHEMA" "$BAD2" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    s = json.load(f)
s["properties"]["methodology"]["properties"]["mergeMethod"]["enumDescriptions"] = ["only one"]
with open(dst, "w") as f:
    json.dump(s, f)
PY
out="$(python3 "$PLUGIN/scripts/schema-lint.py" "$BAD2" || true)"
check "enumDescriptions/enum length mismatch is caught" "methodology.mergeMethod: enumDescriptions missing or length mismatch" "$out"
rm -f "$BAD2"

echo "== schema-lint.py: a bare \$ref property is satisfied by the definition's own description =="
GOOD="$(mktemp)"
python3 - "$SCHEMA" "$GOOD" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    s = json.load(f)
assert "description" not in s["properties"]["boards"]["items"]["properties"]["fields"]["properties"]["status"], (
    "fixture assumption broken: boards[].fields.status is expected to be a bare $ref"
)
with open(dst, "w") as f:
    json.dump(s, f)
PY
out="$(python3 "$PLUGIN/scripts/schema-lint.py" "$GOOD")"
check "bare \$ref (boards[].fields.status -> singleSelectField) does not need its own description" "OK" "$out"
rm -f "$GOOD"

echo "== schema-lint.py: an EMPTY-STRING description must not silently pass (reviewer finding) =="
BAD3="$(mktemp)"
python3 - "$SCHEMA" "$BAD3" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    s = json.load(f)
s["properties"]["project"]["properties"]["mainBranch"]["description"] = ""
with open(dst, "w") as f:
    json.dump(s, f)
PY
out="$(python3 "$PLUGIN/scripts/schema-lint.py" "$BAD3" || true)"
check "an empty-string description is treated as undocumented, not present" "project.mainBranch: missing description" "$out"
rm -f "$BAD3"

echo "== schema-lint.py: enum inside an array's 'items' schema is checked (not just named properties) =="
BAD4="$(mktemp)"
cat >"$BAD4" <<'JSON'
{
    "type": "object",
    "properties": {
        "foo": {
            "type": "array",
            "description": "an array of enum strings",
            "items": { "type": "string", "enum": ["a", "b"] }
        }
    }
}
JSON
out="$(python3 "$PLUGIN/scripts/schema-lint.py" "$BAD4" || true)"
check "an enum inside 'items' without enumDescriptions is caught" "\$.foo[]: enumDescriptions missing" "$out"
rm -f "$BAD4"
