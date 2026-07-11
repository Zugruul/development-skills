#!/usr/bin/env bash
# section-concurrency.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== concurrency (maxInProgress surgical set) =="
CC="$(mktemp -d)"; ( cd "$CC" && git init -q . )
mkdir -p "$CC/.claude"; cp "$FIX/valid.project.yaml" "$CC/.claude/project.yaml"
cc() { (cd "$CC" && bash "$PLUGIN/scripts/concurrency.sh" "$@"); }
check "concurrency default status" "concurrency: 1 (strictly sequential" "$(cc status)"
cc set 3 >/dev/null
check "concurrency set persists" "3" "$(python3 "$PLUGIN/scripts/config.py" "$CC" get methodology.maxInProgress)"
check "concurrency status reflects N" "up to 3 tasks in parallel lanes" "$(cc status)"
check "concurrency comment survives set" "# reviewerTokenEnv: GH_TOKEN_REVIEWER" "$(cat "$CC/.claude/project.yaml")"
check "concurrency flow-style survives set" "taskRanges: [[90, 99]]" "$(cat "$CC/.claude/project.yaml")"
check "concurrency rejects zero" "usage: concurrency.sh set" "$(cc set 0 2>&1 || true)"
check "concurrency rejects non-int" "usage: concurrency.sh set" "$(cc set abc 2>&1 || true)"
python3 "$PLUGIN/scripts/config.py" "$CC" set methodology.maxInProgress 2
check "config.py set verb round-trips" "2" "$(python3 "$PLUGIN/scripts/config.py" "$CC" get methodology.maxInProgress)"
rm -rf "$CC"

