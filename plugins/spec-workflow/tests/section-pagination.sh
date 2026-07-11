#!/usr/bin/env bash
# section-pagination.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== board.sh pagination (SW-013: no silent 400/500-item truncation, SPEC 7.4) =="
PG="$(mktemp -d)"; mkdir -p "$PG/.claude"
cp "$FIX/valid.project.yaml" "$PG/.claude/project.yaml"
PGH="$(mktemp -d)"
cat >"$PGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
_limit_of() { # extract the value following a --limit flag from "$@"
    local prev=""
    for a in "$@"; do
        if [[ "$prev" == "--limit" ]]; then printf '%s' "$a"; return 0; fi
        prev="$a"
    done
    printf '400'
}
case "$1 $2" in
    "project item-list")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "$*" >>"$FAKE_GH_LOG"
        if [[ -n "${FAKE_GH_ITEMLIST_CALLCOUNT:-}" ]]; then
            n=$(( $(cat "$FAKE_GH_ITEMLIST_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
            echo "$n" >"$FAKE_GH_ITEMLIST_CALLCOUNT"
        fi
        limit="$(_limit_of "$@")"
        python3 -c "
import json, sys
limit, total, special = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
n = min(limit, total)
items = []
for i in range(1, n + 1):
    if i == special:
        items.append({'id': 'ITEM_PAGE2', 'content': {'number': i, 'title': 'Task ' + str(i)},
                      'title': 'Task ' + str(i), 'status': 'Backlog', 'priority': 'P0'})
    else:
        items.append({'id': 'ITEM_' + str(i), 'content': {'number': i, 'title': 'Filler ' + str(i)},
                      'title': 'Filler ' + str(i), 'status': 'Deployed', 'priority': 'P2'})
print(json.dumps({'items': items}))
" "$limit" "${FAKE_GH_TOTAL_ITEMS:-450}" "${FAKE_GH_SPECIAL_ITEM:-420}"
        ;;
    "project item-edit")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "$*" >>"$FAKE_GH_LOG"
        echo "edited"
        ;;
    "issue list")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "$*" >>"$FAKE_GH_LOG"
        if [[ -n "${FAKE_GH_ISSUELIST_CALLCOUNT:-}" ]]; then
            n=$(( $(cat "$FAKE_GH_ISSUELIST_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
            echo "$n" >"$FAKE_GH_ISSUELIST_CALLCOUNT"
        fi
        limit="$(_limit_of "$@")"
        python3 -c "
import json, sys
limit, total, special = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
n = min(limit, total)
issues = []
for i in range(1, n + 1):
    if i == special:
        issues.append({'number': i, 'title': 'Task ' + str(i), 'body': 'x', 'state': 'OPEN'})
    else:
        issues.append({'number': i, 'title': 'Filler issue ' + str(i), 'body': 'x', 'state': 'OPEN'})
print(json.dumps(issues))
" "$limit" "${FAKE_GH_TOTAL_ISSUES:-450}" "${FAKE_GH_SPECIAL_ITEM:-420}"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$PGH/gh"

# scenario 1: list -- a >limit fixture (450 items, base page 400) proves the page-2 item
# (#420) is visible and NOT silently truncated, and the full 450-item count comes through.
LOGP1="$(mktemp)"; CCP1="$(mktemp)"
out="$(cd "$PG" && PATH="$PGH:$PATH" FAKE_GH_LOG="$LOGP1" FAKE_GH_ITEMLIST_CALLCOUNT="$CCP1" \
    bash "$PLUGIN/scripts/board.sh" list 2>&1)"
check "list: page-2 item (#420) is present, not truncated at page-1's 400" $'Backlog\tP0\t#420\tTask 420' "$out"
linecount="$(wc -l <<<"$out" | tr -d ' ')"
check "list: all 450 items present -- no silent truncation" "450" "$linecount"
callsp1="$(cat "$CCP1")"
if [[ "$callsp1" -ge 2 ]]; then echo "ok   list: item-list was actually re-paged (>=2 gh calls) to reach item 450"
else echo "FAIL list: expected >=2 gh project item-list calls to exhaust 450 items, got $callsp1"; fails=$((fails + 1)); fi

# scenario 2: next -- the page-2 item is the only Backlog item, so it must be picked
# (the picker only sees what board.sh hands it; this proves board.sh, not next.py, paginates)
out="$(cd "$PG" && PATH="$PGH:$PATH" bash "$PLUGIN/scripts/board.sh" next 2>&1)"
check "next: picks the page-2 item that a fixed 400-limit would have hidden" "=> PICK: #420" "$out"

# scenario 3: move (item_id()) -- resolves and edits an item whose id lives on page 2.
# This is the key regression: before pagination, item_id() silently returned empty for
# any item beyond the --limit ceiling and move failed with a generic bad-issue# error.
LOGP3="$(mktemp)"
out="$(cd "$PG" && PATH="$PGH:$PATH" FAKE_GH_LOG="$LOGP3" bash "$PLUGIN/scripts/board.sh" move 420 "In progress" 2>&1; echo "rc=$?")"
check "move: resolves + edits a page-2 item id" "moved #420 -> In progress" "$out"
check "move: rc=0 resolving a page-2 item" "rc=0" "$out"
check "move: item-edit invoked with the page-2 item's real id" "project item-edit --id ITEM_PAGE2" "$(cat "$LOGP3")"

# scenario 4: issues -- gh issue list also paginates past its own page-1 ceiling. Uses a
# 900-item fixture (deliberately > the OLD hardcoded 500 ceiling) so a regression here
# proves real truncation, not just an incidental undercount.
LOGP4="$(mktemp)"; CCP4="$(mktemp)"
out="$(cd "$PG" && PATH="$PGH:$PATH" FAKE_GH_LOG="$LOGP4" FAKE_GH_ISSUELIST_CALLCOUNT="$CCP4" FAKE_GH_TOTAL_ISSUES=900 \
    bash "$PLUGIN/scripts/board.sh" issues 2>&1)"
check "issues: page-2 issue is present" '"number": 420' "$out"
issuecount="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["issues"]))' <<<"$out")"
check "issues: all 900 issues present -- no silent truncation past the old 500 ceiling" "900" "$issuecount"
callsp4="$(cat "$CCP4")"
if [[ "$callsp4" -ge 2 ]]; then echo "ok   issues: gh issue list was actually re-paged (>=2 calls)"
else echo "FAIL issues: expected >=2 gh issue list calls to exhaust 900 issues, got $callsp4"; fails=$((fails + 1)); fi

# scenario 5: hard-cap safety backstop -- SPEC 7.4 forbids SILENT truncation. When the
# escalating-limit loop hits PAGINATE_HARD_CAP without ever seeing a non-full page (still
# can't prove exhaustion), it must warn on stderr rather than just quietly stopping. Lower
# both knobs via env so the 450-item fixture provably can't be exhausted before the cap.
out5="$(cd "$PG" && PATH="$PGH:$PATH" PAGINATE_BASE_LIMIT=10 PAGINATE_HARD_CAP=20 bash "$PLUGIN/scripts/board.sh" list 2>&1 1>/dev/null)"
check "hard cap: warns on stderr when the cap is hit before exhaustion" "WARNING: hit pagination hard cap (20)" "$out5"
out5_stdout="$(cd "$PG" && PATH="$PGH:$PATH" PAGINATE_BASE_LIMIT=10 PAGINATE_HARD_CAP=20 bash "$PLUGIN/scripts/board.sh" list 2>/dev/null)"
check_absent "hard cap: warning stays on stderr, doesn't corrupt stdout output" "WARNING" "$out5_stdout"

rm -rf "$PG" "$PGH" "$LOGP1" "$CCP1" "$LOGP3" "$LOGP4" "$CCP4"

echo "== seed-board.sh pagination (SW-013: sees + doesn't recreate a page-2 item) =="
SBG="$(mktemp -d)"; mkdir -p "$SBG/.claude"
cp "$FIX/valid.project.yaml" "$SBG/.claude/project.yaml"
SBTASKS="$(mktemp)"
cat >"$SBTASKS" <<'TASKS'
FX-005|P0|5|E1|page two existing task
TASKS
SBGH="$(mktemp -d)"
cat >"$SBGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
_limit_of() {
    local prev=""
    for a in "$@"; do
        if [[ "$prev" == "--limit" ]]; then printf '%s' "$a"; return 0; fi
        prev="$a"
    done
    printf '400'
}
case "$1 $2" in
    "label list") echo "$*" >>"$FAKE_GH_LOG"; echo "" ;;
    "label create") echo "$*" >>"$FAKE_GH_LOG"; exit 0 ;;
    "issue list")
        echo "$*" >>"$FAKE_GH_LOG"
        if [[ "$*" == *"--search"* ]]; then
            echo "fake gh: unexpected fallback --search issue list -- FX-005 should already have been found on page 2" >&2
            exit 1
        fi
        n=$(( $(cat "$FAKE_GH_ISSUELIST_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$FAKE_GH_ISSUELIST_CALLCOUNT"
        limit="$(_limit_of "$@")"
        python3 -c "
import json, sys
limit, total, special = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
n = min(limit, total)
out = []
for i in range(1, n + 1):
    out.append({'title': ('FX-005: page two existing task' if i == special else 'Filler issue ' + str(i))})
print(json.dumps(out))
" "$limit" "${FAKE_GH_TOTAL_ISSUES:-450}" "${FAKE_GH_SPECIAL_ITEM:-420}"
        ;;
    "issue create")
        echo "$*" >>"$FAKE_GH_LOG"
        echo "fake gh: unexpected issue create -- FX-005 already exists (page-2 pagination bug would recreate it)" >&2
        exit 1
        ;;
    "project item-list")
        echo "$*" >>"$FAKE_GH_LOG"
        n=$(( $(cat "$FAKE_GH_ITEMLIST_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$FAKE_GH_ITEMLIST_CALLCOUNT"
        limit="$(_limit_of "$@")"
        python3 -c "
import json, sys
limit, total, special = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
n = min(limit, total)
items = []
for i in range(1, n + 1):
    if i == special:
        items.append({'id': 'ITEM_PAGE2', 'content': {'title': 'FX-005: page two existing task'},
                      'title': 'FX-005: page two existing task'})
    else:
        items.append({'id': 'ITEM_' + str(i), 'content': {'title': 'Filler ' + str(i)}, 'title': 'Filler ' + str(i)})
print(json.dumps({'items': items}))
" "$limit" "${FAKE_GH_TOTAL_ITEMS:-450}" "${FAKE_GH_SPECIAL_ITEM:-420}"
        ;;
    "project item-edit")
        echo "$*" >>"$FAKE_GH_LOG"
        echo "edited"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$SBGH/gh"

LOGSB="$(mktemp)"; CCSB_I="$(mktemp)"; CCSB_L="$(mktemp)"
out="$(cd "$SBG" && PATH="$SBGH:$PATH" FAKE_GH_LOG="$LOGSB" FAKE_GH_ISSUELIST_CALLCOUNT="$CCSB_I" FAKE_GH_ITEMLIST_CALLCOUNT="$CCSB_L" \
    bash "$PLUGIN/scripts/seed-board.sh" "$SBTASKS" 2>&1; echo "rc=$?")"
check "seed-board: completes (page-2 existing issue correctly found, not recreated)" "rc=0" "$out"
check "seed-board: does not re-create the page-2 issue (dedup across pages)" "==> done" "$out"
check_absent "seed-board: no missing-project-item warning for the page-2 item" "no project item for" "$out"
check "seed-board: sets fields on the page-2 item's real id" "project item-edit --id ITEM_PAGE2" "$(cat "$LOGSB")"
callssb_i="$(cat "$CCSB_I")"
if [[ "$callssb_i" -ge 2 ]]; then echo "ok   seed-board: issue-list dedup check was re-paged (>=2 calls) to find FX-005 on page 2"
else echo "FAIL seed-board: expected >=2 issue-list calls, got $callssb_i"; fails=$((fails + 1)); fi
callssb_l="$(cat "$CCSB_L")"
if [[ "$callssb_l" -ge 2 ]]; then echo "ok   seed-board: item-list MAP build was re-paged (>=2 calls) to find FX-005's item on page 2"
else echo "FAIL seed-board: expected >=2 item-list calls, got $callssb_l"; fails=$((fails + 1)); fi
check "seed-board: calls board.sh ensure-labels (label list issued)" "label list -R fixture-owner/fixture-project" "$(cat "$LOGSB")"
check "seed-board: ensure-labels creates the configured bug label" "label create type:bug" "$(cat "$LOGSB")"
check "seed-board: ensure-labels creates the configured feature label" "label create type:feature" "$(cat "$LOGSB")"
check "seed-board: ensure-labels creates the (default) inbound label" "label create inbound" "$(cat "$LOGSB")"

rm -rf "$SBG" "$SBGH" "$SBTASKS" "$LOGSB" "$CCSB_I" "$CCSB_L"


