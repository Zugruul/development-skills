#!/usr/bin/env bash
# section-gate-preflight.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== gate preflight (CDX-030: hook-independent enforcement in board.sh itself) =="
T3P="$(mktemp -d)"
( cd "$T3P" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$T3P/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3P/.claude/project.json"

# Fake `gh`: a real fixture-project item exists for #7. project item-edit
# touches MUTATION_MARKER -- lets the test assert whether the mutation
# ACTUALLY reached "gh", not just that board.sh printed an error, so a
# preflight that blocks but still mutates would still be caught.
T3PGH="$(mktemp -d)"
MUTATION_MARKER="$T3PGH/mutated"
cat >"$T3PGH/gh" <<FAKE
#!/usr/bin/env bash
set -uo pipefail
case "\$1 \$2" in
    "project item-list") echo '{"items":[{"id":"ITEM_7","content":{"number":7}}]}' ;;
    "project item-edit") touch "$MUTATION_MARKER" 2>/dev/null; echo "edited" ;;
    *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$T3PGH/gh"

# --- 1. No hook in the loop at all: board.sh move is invoked DIRECTLY (no
# guard-board-move.sh, no hook JSON piped anywhere). With no recorded gate
# pass, board.sh itself must still block the move to "In review".
rm -f "$MUTATION_MARKER"
out="$(cd "$T3P" && PATH="$T3PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 7 "In review" 2>&1)"; rc=$?
check "preflight: board.sh move directly blocked without recorded pass" "BLOCKED" "$out"
if [[ "$rc" -ne 0 ]]; then
    echo "ok   preflight: board.sh move directly blocked -- nonzero exit"
else
    echo "FAIL preflight: board.sh move directly blocked -- nonzero exit (got rc=$rc)"
    fails=$((fails+1))
fi
if [[ -f "$MUTATION_MARKER" ]]; then
    echo "FAIL preflight: blocked move must not reach gh project item-edit"
    fails=$((fails+1))
else
    echo "ok   preflight: blocked move never reached gh project item-edit"
fi

# Lowercase status spelling must trip the same guard (consistent with
# guard-board-move.sh's own case-insensitive norm()).
out="$(cd "$T3P" && PATH="$T3PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 7 "in review" 2>&1)"; rc=$?
check "preflight: lowercase 'in review' also blocked without recorded pass" "BLOCKED" "$out"
if [[ "$rc" -ne 0 ]]; then
    echo "ok   preflight: lowercase 'in review' nonzero exit"
else
    echo "FAIL preflight: lowercase 'in review' nonzero exit (got rc=$rc)"
    fails=$((fails+1))
fi

# Non-review moves are never gated by the preflight.
out="$(cd "$T3P" && PATH="$T3PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 7 Backlog 2>&1)"; rc=$?
check "preflight: non-review move unaffected by missing pass" "moved #7 -> Backlog" "$out"
check_rc "preflight: non-review move exit 0" 0 "$rc"

# --- 2. Record a valid pass, then the same direct (no-hook) move succeeds.
out="$(cd "$T3P" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "preflight: gate pass recorded" "GATE PASS recorded" "$out"
rm -f "$MUTATION_MARKER"
out="$(cd "$T3P" && PATH="$T3PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 7 "In review" 2>&1)"; rc=$?
check "preflight: move succeeds directly with a fresh recorded pass" "moved #7 -> In review" "$out"
check_rc "preflight: move with fresh pass exit 0" 0 "$rc"
if [[ -f "$MUTATION_MARKER" ]]; then
    echo "ok   preflight: allowed move reached gh project item-edit"
else
    echo "FAIL preflight: allowed move should have reached gh project item-edit"
    fails=$((fails+1))
fi

# --- 3. Tree changes since the recorded pass -> stale, blocked again, no
# mutation -- directly through board.sh, still no hook involved.
echo dirty > "$T3P/file.txt" && (cd "$T3P" && git add file.txt)
rm -f "$MUTATION_MARKER"
out="$(cd "$T3P" && PATH="$T3PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 7 "In review" 2>&1)"; rc=$?
check "preflight: stale pass re-blocked directly by board.sh" "BLOCKED" "$out"
if [[ "$rc" -ne 0 ]]; then
    echo "ok   preflight: stale pass nonzero exit"
else
    echo "FAIL preflight: stale pass nonzero exit (got rc=$rc)"
    fails=$((fails+1))
fi
if [[ -f "$MUTATION_MARKER" ]]; then
    echo "FAIL preflight: stale-pass blocked move must not reach gh project item-edit"
    fails=$((fails+1))
else
    echo "ok   preflight: stale-pass blocked move never reached gh project item-edit"
fi

# --- 4. Defense in depth: the Claude PreToolUse hook path (guard-board-move.sh)
# is untouched and still independently blocks the same scenario when it IS
# in the loop (simulated hook JSON, no board.sh invocation at all here).
T3PH="$(mktemp -d)"
( cd "$T3PH" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$T3PH/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3PH/.claude/project.json"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3PH" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "preflight: hook-based path (guard-board-move.sh) still independently blocks" "BLOCKED: no recorded gate pass" "$out"
check "preflight: hook-based path still exits 2" "rc=2" "$out"
rm -rf "$T3PH"

rm -rf "$T3P" "$T3PGH"
