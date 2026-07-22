#!/usr/bin/env bash
# section-assistant-marker.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant.marker (AST-001: .neural-network grammar + legacy tolerance, SPEC-ASSISTANT.md §6.2) =="

AM_SCRIPTS="$PLUGIN/scripts"

am_py() { # $1: python3 -c snippet body (assistant.marker importable); $2..: sys.argv[1:]
    local script="$1"; shift
    PLUGIN_SCRIPTS="$AM_SCRIPTS" python3 -c '
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
from assistant import marker
'"$script" "$@"
}

# ------------------------------------------------------------- key=value grammar
out="$(am_py '
d = marker.parse_marker("key=value\n")
print(sorted(d.items()))
')"
check "simple key=value pair" "[('key', 'value')]" "$out"

out="$(am_py '
d = marker.parse_marker("  key  =  value  \n")
print(sorted(d.items()))
')"
check "whitespace around key/value is stripped" "[('key', 'value')]" "$out"

out="$(am_py '
d = marker.parse_marker("key=v=alue\n")
print(sorted(d.items()))
')"
check "value containing = keeps the rest (split at FIRST =)" "[('key', 'v=alue')]" "$out"

out="$(am_py '
d = marker.parse_marker("key=v # not-a-comment\n")
print(sorted(d.items()))
')"
check "value containing # is kept verbatim (no inline comments)" "[('key', 'v # not-a-comment')]" "$out"

# ------------------------------------------------------------- comments / blanks
out="$(am_py '
d = marker.parse_marker("# a full-line comment\nkey=value\n")
print(sorted(d.items()))
')"
check "full-line comment ignored, pair still parsed" "[('key', 'value')]" "$out"

out="$(am_py '
d = marker.parse_marker("  # indented comment\nkey=value\n")
print(sorted(d.items()))
')"
check "comment with leading whitespace before # still a comment" "[('key', 'value')]" "$out"

out="$(am_py '
d = marker.parse_marker("key=value\n\n   \nkey2=value2\n")
print(sorted(d.items()))
')"
check "blank / whitespace-only lines ignored" "[('key', 'value'), ('key2', 'value2')]" "$out"

# ------------------------------------------------------------- unknown keys
out="$(am_py '
d = marker.parse_marker("totally-unknown-key=some-value\n")
print(sorted(d.items()))
')"
check "unknown key is parsed and returned (filtering is caller semantics)" "[('totally-unknown-key', 'some-value')]" "$out"

# ------------------------------------------------------------- duplicate keys
out="$(am_py '
d = marker.parse_marker("key=first\nkey=second\n")
print(sorted(d.items()))
')"
check "duplicate key: last wins" "[('key', 'second')]" "$out"

# ------------------------------------------------------------- non-comment line w/o =
out="$(am_py '
d = marker.parse_marker("just some free-form text\nkey=value\n")
print(sorted(d.items()))
')"
check "non-comment line without = is skipped, not an error" "[('key', 'value')]" "$out"

# ------------------------------------------------------------- legacy tolerance
out="$(am_py '
d = marker.parse_marker("")
print(d == {})
')"
check "empty string content -> {}" "True" "$out"

# shipped marker content, verbatim (must match neural-view.py's MARKER_CONTENT exactly)
AM_SHIPPED="$(mktemp -d)/shipped-marker.txt"
printf '# neural-view discovery marker \xe2\x80\x94 repos with this file are included in the aggregated neural view\n' >"$AM_SHIPPED"
out="$(PLUGIN_SCRIPTS="$AM_SCRIPTS" python3 -c '
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
from assistant import marker
d = marker.parse_marker(open(sys.argv[1], "r", encoding="utf-8").read())
print(d == {})
' "$AM_SHIPPED")"
check "shipped marker content (verbatim, comment-only) -> {}" "True" "$out"

out="$(am_py '
d = marker.read_marker(sys.argv[1])
print(d == {})
' "$AM_SHIPPED")"
check "read_marker on shipped marker file -> {}" "True" "$out"
rm -rf "$(dirname "$AM_SHIPPED")"

# ------------------------------------------------------------- read_marker: missing file
out="$(am_py '
try:
    marker.read_marker("/nonexistent/path/does-not-exist/.neural-network")
    print("NO-RAISE")
except FileNotFoundError:
    print("FileNotFoundError")
')"
check "read_marker on a missing file raises FileNotFoundError" "FileNotFoundError" "$out"

# ------------------------------------------------------------- mixed realistic marker
AM_MIXED="$(mktemp -d)/mixed-marker.txt"
cat >"$AM_MIXED" <<'MARKER'
# neural-view discovery marker — repos with this file are included in the aggregated neural view
# additional free-form notes about this repo
owner=acme
  team = platform
totally-unrelated-freeform-line
tag=x=y=z
MARKER
out="$(am_py '
d = marker.read_marker(sys.argv[1])
print(sorted(d.items()))
' "$AM_MIXED")"
check "mixed realistic marker: all pairs parsed, comments/free-form skipped" \
    "[('owner', 'acme'), ('tag', 'x=y=z'), ('team', 'platform')]" "$out"
rm -rf "$(dirname "$AM_MIXED")"
