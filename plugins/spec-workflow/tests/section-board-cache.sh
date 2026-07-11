#!/usr/bin/env bash
# section-board-cache.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# Covers issue #78 (board GraphQL economy): the local item-id cache
# (.claude/board-cache.json) that lets move/prio/est/add/adopt resolve an
# issue's project-item id without a full-board re-pagination on every call.
# Live evidence (issue #78): three board mutations once burned ~1400
# GraphQL points via full-board re-pagination per op on a 95-item board --
# these tests assert an actual gh-invocation COUNT, not just behavior, so a
# regression back to "one full list per mutation" fails loudly here.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== board.sh item-id cache (#78): gh call-count guarantees =="

_cgh() { # -> sets BC (fixture repo dir) and CGH (fake-gh dir on PATH); fake gh understands
         # issue create / project item-add / project item-list / project item-edit
    BC="$(mktemp -d)"; mkdir -p "$BC/.claude"
    cp "$FIX/valid.project.yaml" "$BC/.claude/project.yaml"
    CGH="$(mktemp -d)"
    cat >"$CGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >>"$FAKE_GH_LOG"
n=$(( $(cat "${FAKE_GH_CALLCOUNT:-/dev/null}" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"${FAKE_GH_CALLCOUNT:-/dev/null}"
case "$1 $2" in
    "issue create")
        echo "https://github.com/fixture-owner/fixture-project/issues/${FAKE_GH_NEW_ISSUE_NUM:-778}"
        ;;
    "project item-add")
        : # board.sh discards item-add's stdout; only the call itself matters
        ;;
    "project item-list")
        n2=$(( $(cat "$FAKE_GH_LIST_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n2" >"$FAKE_GH_LIST_CALLCOUNT"
        # Both the pre-existing issue and any newly-created one (item-add is a
        # no-op above; this fixture just always shows both as visible, so a
        # cache miss on the new issue resolves on its first poll attempt).
        echo "{\"items\":[{\"id\":\"ITEM_${FAKE_GH_ISSUE_NUM:-777}\",\"content\":{\"number\":${FAKE_GH_ISSUE_NUM:-777}},\"status\":\"${FAKE_GH_ITEM_STATUS:-Backlog}\"},{\"id\":\"ITEM_${FAKE_GH_NEW_ISSUE_NUM:-778}\",\"content\":{\"number\":${FAKE_GH_NEW_ISSUE_NUM:-778}},\"status\":\"Backlog\"}]}"
        ;;
    "project item-edit")
        n3=$(( $(cat "$FAKE_GH_EDIT_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n3" >"$FAKE_GH_EDIT_CALLCOUNT"
        echo "edited"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
    chmod +x "$CGH/gh"
}

# --- (a) full iteration (list + 3 moves + 1 add) stays single-digit gh calls ---
# (issue #78 criterion 6: pick-context list + move In progress + move In
# review + move QA + one add, in a single digit total of gh invocations)
_cgh
LOG="$(mktemp)"; TOTALCC="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
run() { PATH="$CGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_CALLCOUNT="$TOTALCC" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=777 FAKE_GH_NEW_ISSUE_NUM=778 "$@"; }
out1="$(cd "$BC" && run bash "$PLUGIN/scripts/board.sh" list 2>&1; echo "rc=$?")"
out2="$(cd "$BC" && run bash "$PLUGIN/scripts/board.sh" move 777 "In progress" 2>&1; echo "rc=$?")"
out3="$(cd "$BC" && run bash "$PLUGIN/scripts/board.sh" move 777 "In review" 2>&1; echo "rc=$?")"
out4="$(cd "$BC" && run bash "$PLUGIN/scripts/board.sh" move 777 "QA" 2>&1; echo "rc=$?")"
out5="$(cd "$BC" && run bash "$PLUGIN/scripts/board.sh" add --type feature "found during QA" P2 2>&1; echo "rc=$?")"
check "(a) list succeeds" "Backlog" "$out1"
check "(a) move -> In progress succeeds" "moved #777 -> In progress" "$out2"
check "(a) move -> In review succeeds" "moved #777 -> In review" "$out3"
check "(a) move -> QA succeeds" "moved #777 -> QA" "$out4"
check "(a) add succeeds" "filed feature #778" "$out5"
total="$(cat "$TOTALCC")"
if [[ "$total" -le 9 ]]; then
    echo "ok   (a) full iteration (list + 3 moves + 1 add) stays single-digit gh calls (got $total)"
else
    echo "FAIL (a) full iteration expected <=9 gh calls, got $total"
    fails=$((fails + 1))
fi
listn="$(cat "$LISTCC")"
if [[ "$listn" -le 2 ]]; then
    echo "ok   (a) at most 2 full item-list calls across the whole iteration (list itself + one cache-miss on the newly-added issue), got $listn"
else
    echo "FAIL (a) expected <=2 item-list calls across the iteration, got $listn"
    fails=$((fails + 1))
fi
rm -rf "$BC" "$CGH" "$LOG" "$TOTALCC" "$LISTCC" "$EDITCC"

# --- (b) two consecutive moves on the same issue: 1 lookup + 2 mutations (cache hit on the 2nd) ---
_cgh
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
out1="$(cd "$BC" && PATH="$CGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=779 bash "$PLUGIN/scripts/board.sh" move 779 "In progress" 2>&1; echo "rc=$?")"
out2="$(cd "$BC" && PATH="$CGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=779 bash "$PLUGIN/scripts/board.sh" move 779 "QA" 2>&1; echo "rc=$?")"
check "(b) first move (cache miss) succeeds" "moved #779 -> In progress" "$out1"
check "(b) second move (cache hit) succeeds" "moved #779 -> QA" "$out2"
listn="$(cat "$LISTCC")"; editn="$(cat "$EDITCC")"
if [[ "$listn" -eq 1 ]]; then echo "ok   (b) exactly 1 item-list call (cache miss on the 1st move only)"
else echo "FAIL (b) expected exactly 1 item-list call, got $listn"; fails=$((fails + 1)); fi
if [[ "$editn" -eq 2 ]]; then echo "ok   (b) exactly 2 item-edit calls (one mutation each)"
else echo "FAIL (b) expected exactly 2 item-edit calls, got $editn"; fails=$((fails + 1)); fi
rm -rf "$BC" "$CGH" "$LOG" "$LISTCC" "$EDITCC"

echo "== board.sh item-id cache (#78): invalidation on a stale/rejected id =="

# --- (c) a mutation rejected because the cached id no longer resolves drops
# the entry and re-resolves ONCE (a fresh full-board lookup), then retries
# the edit against the real id -- instead of failing outright.
_cgh
cat >"$CGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
    "project item-list")
        n=$(( $(cat "$FAKE_GH_LIST_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$FAKE_GH_LIST_CALLCOUNT"
        echo '{"items":[{"id":"ITEM_REAL","content":{"number":780},"status":"Backlog"}]}'
        ;;
    "project item-edit")
        id=""; prev=""
        for a in "$@"; do
            if [[ "$prev" == "--id" ]]; then id="$a"; fi
            prev="$a"
        done
        n=$(( $(cat "$FAKE_GH_EDIT_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$FAKE_GH_EDIT_CALLCOUNT"
        if [[ "$id" == "ITEM_STALE" ]]; then
            echo "could not resolve to a ProjectV2Item with the global id of 'ITEM_STALE'" >&2
            exit 1
        fi
        echo "edited"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$CGH/gh"
printf '{"780": {"itemId": "ITEM_STALE", "status": "Backlog"}}' >"$BC/.claude/board-cache.json"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BC" && PATH="$CGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    bash "$PLUGIN/scripts/board.sh" move 780 "QA" 2>&1; echo "rc=$?")"
check "(c) stale-id mutation still succeeds after dropping + re-resolving once" "moved #780 -> QA" "$out"
check "(c) exits 0" "rc=0" "$out"
editn="$(cat "$EDITCC")"
if [[ "$editn" -eq 2 ]]; then echo "ok   (c) exactly 2 item-edit attempts (stale id, then the re-resolved real id)"
else echo "FAIL (c) expected exactly 2 item-edit attempts, got $editn"; fails=$((fails + 1)); fi
listn="$(cat "$LISTCC")"
if [[ "$listn" -eq 1 ]]; then echo "ok   (c) exactly 1 full-board re-resolve (not a retry loop)"
else echo "FAIL (c) expected exactly 1 item-list call, got $listn"; fails=$((fails + 1)); fi
check "(c) item-edit was retried against the real id" "--id ITEM_REAL" "$(cat "$LOG")"
cache_after="$(cat "$BC/.claude/board-cache.json" 2>/dev/null)"
check "(c) cache now holds the real id, not the stale one" '"itemId": "ITEM_REAL"' "$cache_after"
check_absent "(c) cache no longer holds the stale id" "ITEM_STALE" "$cache_after"
rm -rf "$BC" "$CGH" "$LOG" "$LISTCC" "$EDITCC"

echo "== .gitignore + setup-project cover .claude/board-cache.json (#78) =="
check "repo .gitignore covers .claude/board-cache.json" ".claude/board-cache.json" "$(cat "$(dirname "$(dirname "$PLUGIN")")/.gitignore")"
check "setup-project SKILL.md gitignores .claude/board-cache.json" ".claude/board-cache.json" "$(cat "$PLUGIN/skills/setup-project/SKILL.md")"

echo "== plugin README documents the item-id cache (#78) =="
README="$(cat "$PLUGIN/README.md" 2>/dev/null)"
check "README documents the cache file" ".claude/board-cache.json" "$README"
