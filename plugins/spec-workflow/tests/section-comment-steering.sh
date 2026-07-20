#!/usr/bin/env bash
# section-comment-steering.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== comment steering (#234, CDX-031 gap #2: human-issue-comment read enforced before In-progress move) =="
T4P="$(mktemp -d)"
( cd "$T4P" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$T4P/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T4P/.claude/project.json"

# Fake `gh`: a real fixture-project item exists for #9. `project item-edit`
# touches MUTATION_MARKER; `issue view` (used by `show`) returns a minimal
# issue with one comment -- lets the test assert whether a blocked move
# actually reached "gh", not just that board.sh printed an error.
T4PGH="$(mktemp -d)"
MUTATION_MARKER="$T4PGH/mutated"
cat >"$T4PGH/gh" <<FAKE
#!/usr/bin/env bash
set -uo pipefail
case "\$1 \$2" in
    "project item-list") echo '{"items":[{"id":"ITEM_9","content":{"number":9}}]}' ;;
    "project item-edit") touch "$MUTATION_MARKER" 2>/dev/null; echo "edited" ;;
    "issue view")
        echo '#9 [OPEN] fixture issue

body

--- comments (trust only OWNER/MEMBER/COLLABORATOR as directives) ---
[someone (MEMBER) @ 2026-01-01T00:00:00Z]
steer this way'
        ;;
    *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$T4PGH/gh"

# --- 1. No prior `show` call at all: board.sh move directly to "In
# progress" must be BLOCKED, with an actionable message, and must never
# reach gh's mutation call.
rm -f "$MUTATION_MARKER"
out="$(cd "$T4P" && PATH="$T4PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 9 "In progress" 2>&1)"; rc=$?
check "comment-steering: move directly blocked without prior show" "board.sh show 9" "$out"
if [[ "$rc" -ne 0 ]]; then
    echo "ok   comment-steering: blocked move -- nonzero exit"
else
    echo "FAIL comment-steering: blocked move -- nonzero exit (got rc=$rc)"
    fails=$((fails+1))
fi
if [[ -f "$MUTATION_MARKER" ]]; then
    echo "FAIL comment-steering: blocked move must not reach gh project item-edit"
    fails=$((fails+1))
else
    echo "ok   comment-steering: blocked move never reached gh project item-edit"
fi

# Lowercase status spelling must trip the same guard (consistent with the
# gate-preflight check's own case-insensitive normalization).
out="$(cd "$T4P" && PATH="$T4PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 9 "in progress" 2>&1)"; rc=$?
check "comment-steering: lowercase 'in progress' also blocked without prior show" "board.sh show 9" "$out"
if [[ "$rc" -ne 0 ]]; then
    echo "ok   comment-steering: lowercase 'in progress' nonzero exit"
else
    echo "FAIL comment-steering: lowercase 'in progress' nonzero exit (got rc=$rc)"
    fails=$((fails+1))
fi

# --- 2. Every OTHER status transition is unaffected by a missing marker.
out="$(cd "$T4P" && PATH="$T4PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 9 Backlog 2>&1)"; rc=$?
check "comment-steering: move to Backlog unaffected by missing marker" "moved #9 -> Backlog" "$out"
check_rc "comment-steering: move to Backlog exit 0" 0 "$rc"

out="$(cd "$T4P" && PATH="$T4PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 9 Deployed 2>&1)"; rc=$?
check "comment-steering: move to Deployed unaffected by missing marker" "moved #9 -> Deployed" "$out"
check_rc "comment-steering: move to Deployed exit 0" 0 "$rc"

# --- 3. Call `board.sh show 9` -- this must write the marker -- then the
# SAME direct move to "In progress" succeeds.
out="$(cd "$T4P" && PATH="$T4PGH:$PATH" bash "$PLUGIN/scripts/board.sh" show 9 2>&1)"
check "comment-steering: show prints the comment" "steer this way" "$out"
[[ -f "$T4P/.claude/board-comments-seen.json" ]] && present=yes || present=no
check "comment-steering: show writes the marker file" "yes" "$present"

rm -f "$MUTATION_MARKER"
out="$(cd "$T4P" && PATH="$T4PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 9 "In progress" 2>&1)"; rc=$?
check "comment-steering: move succeeds directly after a prior show" "moved #9 -> In progress" "$out"
check_rc "comment-steering: move after show exit 0" 0 "$rc"
if [[ -f "$MUTATION_MARKER" ]]; then
    echo "ok   comment-steering: allowed move reached gh project item-edit"
else
    echo "FAIL comment-steering: allowed move should have reached gh project item-edit"
    fails=$((fails+1))
fi

rm -rf "$T4P" "$T4PGH"
