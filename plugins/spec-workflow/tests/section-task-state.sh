#!/usr/bin/env bash
# section-task-state.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced _lib.sh
# (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky.
# Covers task-state.sh: the local record agents keep of what they are working on.
# shellcheck disable=SC2016  # the single-quoted expectations are literal source text

declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }

TS_TOOL="$PLUGIN/scripts/task-state.sh"
TS_TMP="$(mktemp -d)"
TS_R="$TS_TMP/repo"
git init -q -b main "$TS_R"
mkdir -p "$TS_R/.neural-network"; cp "$FIX/valid.project.yaml" "$TS_R/.neural-network/project.yaml"
git -C "$TS_R" add -A; git -C "$TS_R" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$TS_R" worktree add -q "$TS_R-lane" -b lane
ts() { bash "$TS_TOOL" "$@"; }
tsj() { (cd "$TS_R" && ts show --id "$1" --json); }

echo "== task-state: set and show =="
(cd "$TS_R" && ts set --id 12 --title "Add parser" --status "In progress" --agent orchestrator --todo "write test" --todo "implement" >/dev/null 2>&1); rc=$?
check_rc "set: exits 0" 0 "$rc"
state="$(tsj 12)"
check "set: stores the title" '"title": "Add parser"' "$state"
check "set: stores the status" '"status": "In progress"' "$state"
check "set: records the agent" '"orchestrator"' "$state"
check "set: records the worktree" "$TS_R" "$state"
shown="$(cd "$TS_R" && ts show --id 12)"
check "show: numbers the TODOs" "1. [ ] write test" "$shown"
check "show: numbers them all" "2. [ ] implement" "$shown"
check_absent "state never lands in the working tree" "12.json" "$(git -C "$TS_R" status --short --ignored)"
(cd "$TS_R" && ts set --id '#13' --title "Hash id" >/dev/null)
check "ids: a leading # is ignored" '"id": "13"' "$(tsj 13)"
(cd "$TS_R" && ts clear --id 13)

echo "== task-state: several agents and worktrees =="
(cd "$TS_R-lane" && ts todo --id 12 --done 1 --agent dev >/dev/null)
check "another worktree sees and updates the same task" '1. [x] write test' "$(cd "$TS_R" && ts show --id 12)"
state="$(tsj 12)"
check "a second agent is recorded" '"dev"' "$state"
check "the first agent is kept" '"orchestrator"' "$state"
check "the second worktree is recorded" "$TS_R-lane" "$state"
(cd "$TS_R" && ts set --id 12 --title "Add parser" --agent orchestrator --todo "write test" --todo "implement" --todo "docs" >/dev/null)
shown="$(cd "$TS_R" && ts show --id 12)"
check "seeding again keeps progress" "1. [x] write test" "$shown"
check "seeding again adds only what is new" "3. [ ] docs" "$shown"
check_rc "seeding again creates no duplicates" 3 "$(grep -c '\[.\]' <<<"$shown")"
(cd "$TS_R" && ts todo --id 12 --add "reviewer finding" --agent reviewer >/dev/null)
(cd "$TS_R" && ts todo --id 12 --done "implement" --agent dev >/dev/null)
shown="$(cd "$TS_R" && ts show --id 12)"
check "todos can be ticked by exact text" "2. [x] implement" "$shown"
check "added todos go last, so numbers stay stable" "4. [ ] reviewer finding" "$shown"
(cd "$TS_R" && ts todo --id 12 --undo 2 >/dev/null)
check "todos can be reopened" "2. [ ] implement" "$(cd "$TS_R" && ts show --id 12)"

(cd "$TS_R" && ts set --id 41 --title "parallel" --agent x >/dev/null)
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    (cd "$TS_R" && ts todo --id 41 --add "parallel $i" --agent "a$i" >/dev/null) &
done
wait
check_rc "concurrent writers lose no updates" 12 "$(cd "$TS_R" && ts show --id 41 | grep -c '\[ \] parallel')"
(cd "$TS_R" && ts clear --id 41)

echo "== task-state: refusals =="
(cd "$TS_R" && ts todo --id 12 --done 99 >/dev/null 2>&1); check_rc "unknown TODO number is refused" 1 "$?"
(cd "$TS_R" && ts todo --id 999 --done 1 >/dev/null 2>&1); check_rc "unknown task is refused" 1 "$?"
(cd "$TS_R" && ts set --id '../../evil' --title x >/dev/null 2>&1); check_rc "path-like id is refused" 1 "$?"
check_absent "path-like id writes nothing" "evil" "$(find "$TS_TMP" -name '*evil*')"
(cd "$TS_TMP" && ts list >/dev/null 2>&1); check_rc "outside a git repo is refused" 1 "$?"

echo "== task-state: list and clear =="
(cd "$TS_R" && ts set --id 14 --title "Second" --status "In review" >/dev/null)
listed="$(cd "$TS_R" && ts list)"
check "list: shows each task" "#12" "$listed"
check "list: shows the other task" "#14" "$listed"
check "list: shows progress" "1/4" "$listed"
(cd "$TS_R-lane" && ts clear --id 14)
check_absent "clear: works from any worktree" "#14" "$(cd "$TS_R" && ts list)"
printf 'not json' >"$(git -C "$TS_R" rev-parse --path-format=absolute --git-common-dir)/spec-workflow/task-state/broken.json"
listed="$(cd "$TS_R" && ts list 2>&1)"; rc=$?
check_rc "list: a corrupt record does not fail the listing" 0 "$rc"
check "list: a corrupt record is reported" "broken.json" "$listed"
check "list: good records still show" "#12" "$listed"
rm -f "$(git -C "$TS_R" rev-parse --path-format=absolute --git-common-dir)/spec-workflow/task-state/broken.json"
(cd "$TS_R" && ts clear --id 14); check_rc "clear: an absent task is not an error" 0 "$?"

echo "== task-state: valid JSON of the wrong shape =="
TS_STATE="$(git -C "$TS_R" rev-parse --path-format=absolute --git-common-dir)/spec-workflow/task-state"
(cd "$TS_R" && ts set --id 60 --title "Good neighbour" --status "In progress" --todo a >/dev/null)
TS_DEEP="$(printf '%*s' 200000 '' | tr ' ' '[')"
ts_bad_shapes() { printf '%s\n' '[]' '5' '{}' 'null' '"text"' '{"id":"x"}' \
    '{"id":"x","title":"t","status":"s","agents":[],"worktrees":[],"todos":[{"text":"a"}]}' \
    '{"id":"x","title":"t","status":"s","agents":5,"worktrees":[],"todos":[]}' \
    '{"id":"x","title":"t","status":"s","agents":[],"worktrees":[],"todos":5}' "$TS_DEEP"
    local head='{"id":"x","title":"t","status":"s","agents":[],"worktrees":[],"todos":[{"text":"a","done":false,'
    local field
    for field in '"num":null' '"num":null},{"text":"b","done":false' '"num":true' '"num":0' '"num":-1' '"num":1.0' '"num":"1"' \
        '"active":"yes"' '"active":null' '"active":true,"activeBy":5' '"active":true,"activeBy":null'; do
        printf '%s%s}]}\n' "$head" "$field"
    done; }
while IFS= read -r payload; do
    label="${payload: -34}"
    printf '%s' "$payload" >"$TS_STATE/9.json"
    out="$(cd "$TS_R" && ts list 2>&1)"; rc=$?
    check_rc "wrong shape $label: list exits 0" 0 "$rc"
    check "wrong shape $label: list skips it with a notice" "skipped 9.json" "$out"
    check "wrong shape $label: list still shows the good task" "#60" "$out"
    check_absent "wrong shape $label: list does not crash" "Traceback" "$out"
    out="$(cd "$TS_R" && ts list --json 2>&1)"; rc=$?
    check_rc "wrong shape $label: list --json exits 0" 0 "$rc"
    check_absent "wrong shape $label: list --json does not crash" "Traceback" "$out"
    out="$(cd "$TS_R" && ts show --id 9 2>&1)"; rc=$?
    check_rc "wrong shape $label: show refuses" 1 "$rc"
    check "wrong shape $label: show names the problem" "corrupt" "$out"
    check_absent "wrong shape $label: show does not crash" "Traceback" "$out"
    before="$(cat "$TS_STATE/9.json")"
    out="$(cd "$TS_R" && ts set --id 9 --title T --agent a 2>&1)"; rc=$?
    check_rc "wrong shape $label: set refuses" 1 "$rc"
    check_absent "wrong shape $label: set does not crash" "Traceback" "$out"
    (cd "$TS_R" && ts todo --id 9 --done 1 >/dev/null 2>&1); rc=$?
    check_rc "wrong shape $label: todo refuses" 1 "$rc"
    after="$(cat "$TS_STATE/9.json")"
    [[ "$before" == "$after" ]] && same=same || same=changed
    check "wrong shape $label: set and todo never overwrite it" "same" "$same"
    (cd "$TS_R" && bash "$TS_TOOL" sync --id 9 --status "In review" >/dev/null 2>&1); rc=$?
    check_rc "wrong shape $label: sync never fails" 0 "$rc"
done < <(ts_bad_shapes)
rm -f "$TS_STATE/9.json"
(cd "$TS_R" && ts clear --id 60)

echo "== task-state: empty and odd TODO references =="
(cd "$TS_R" && ts set --id 61 --title "Refs" --todo a --todo b >/dev/null)
for flag in --done --drop --undo --add; do
    out="$(cd "$TS_R" && ts todo --id 61 "$flag" "" 2>&1)"; rc=$?
    check_rc "todo $flag '': refused" 1 "$rc"
    check_absent "todo $flag '': no traceback" "Traceback" "$out"
    check "todo $flag '': says what is wrong" "empty" "$out"
done
out="$(cd "$TS_R" && ts todo --id 61 --done '²' 2>&1)"; rc=$?
check_rc "todo --done '²': refused, not a crash" 1 "$rc"
check_absent "todo --done '²': no traceback" "Traceback" "$out"
check_rc "refused references change nothing" 2 "$(cd "$TS_R" && ts show --id 61 | grep -c '\[ \]')"
(cd "$TS_R" && ts clear --id 61)

echo "== task-state: board.sh move keeps it honest =="
TS_BIN="$TS_TMP/bin"; mkdir -p "$TS_BIN"
cat >"$TS_BIN/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
    "project item-list") echo '{"items":[{"id":"I1","status":"In progress","content":{"number":12,"type":"Issue"}}],"totalCount":1}' ;;
    "project item-edit") echo '{}' ;;
    "issue view") echo '{"comments":[],"number":12,"title":"x","body":"","url":"u"}' ;;
    "api graphql") # board reads (#544) go through the shared adapter; task_state's own issue lookup keeps its canned answer
        if [[ "$*" == *"projectV2(number"* ]]; then exec python3 "$GH_GQL_ADAPTER" "$0" "$@"; fi
        echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"I1","project":{"id":"PVT_x"},"fieldValueByName":{"name":"In progress"}}]}}}}}' ;;
    "api "*) echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"I1","project":{"id":"PVT_x"},"fieldValueByName":{"name":"In progress"}}]}}}}}' ;;
esac
exit 0
FAKE
chmod +x "$TS_BIN/gh"
mkdir -p "$TS_R/.claude"; echo '{"12":true}' >"$TS_R/.claude/board-comments-seen.json"
ts_seed12() { (cd "$TS_R" && ts clear --id 12 && ts set --id 12 --title t --status was --todo a >/dev/null && ts todo --id 12 --done 1 >/dev/null); }
ts_move12() { (cd "$TS_R" && PATH="$TS_BIN:$PATH" bash "$PLUGIN/scripts/board.sh" move 12 "$1" 2>&1); }
# Moves to review and later statuses run their own preflights (gate, review evidence), so they are
# covered through sync below; the moves here are the ones the board accepts in any case and spacing.
for st in "In progress" "in progress" "IN  PROGRESS" "  in   progress " "Backlog" " BACKLOG"; do
    ts_seed12; out="$(ts_move12 "$st")"; rc=$?
    check_rc "board.sh move '$st': exits 0" 0 "$rc"
    check "board.sh move '$st': says it moved" "moved #12" "$out"
    check "board.sh move '$st': keeps the record and its progress" "(1/1)" "$(cd "$TS_R" && ts list)"
    check "board.sh move '$st': writes the status as given" "\"status\": \"$st\"" "$(tsj 12)"
    (cd "$TS_R" && ts clear --id 12)
done
ts_seed12; out="$(ts_move12 "Nope")"; rc=$?
check_rc "board.sh move: a bad status still fails" 1 "$rc"
check "board.sh move: a bad status keeps the record" "(1/1)" "$(cd "$TS_R" && ts list)"
(cd "$TS_R" && ts clear --id 12)
printf '{' >"$(git -C "$TS_R" rev-parse --path-format=absolute --git-common-dir)/spec-workflow/task-state/12.json"
out="$(ts_move12 "In progress")"; rc=$?
check_rc "board.sh move: a corrupt record does not fail the move" 0 "$rc"
check "board.sh move: a corrupt record still reports the move" "moved #12" "$out"
(cd "$TS_R" && ts clear --id 12)
for st in "In progress" "in review" "BACKLOG" " in  progress "; do
    ts_seed12; (cd "$TS_R" && bash "$TS_TOOL" sync --id 12 --status "$st")
    check "sync '$st': keeps the record" "(1/1)" "$(cd "$TS_R" && ts list)"
    (cd "$TS_R" && ts clear --id 12)
done
for st in "QA" "qa" "Deployed" "ready"; do
    ts_seed12; (cd "$TS_R" && bash "$TS_TOOL" sync --id 12 --status "$st")
    check_absent "sync '$st': clears the record" "#12" "$(cd "$TS_R" && ts list)"
done
ts_seed12
(cd "$TS_R" && bash "$TS_TOOL" sync --id 12 --status "In review")
check "sync: a working status updates the record" '"status": "In review"' "$(tsj 12)"
(cd "$TS_R" && bash "$TS_TOOL" sync --id 12 --status "QA")
check_absent "sync: a status past review clears the task" "#12" "$(cd "$TS_R" && ts list)"
(cd "$TS_R" && bash "$TS_TOOL" sync --id 77 --status "In progress"); check_rc "sync: an untracked task is a no-op" 0 "$?"
check_absent "sync: never creates a task" "#77" "$(cd "$TS_R" && ts list)"
board="$(cat "$PLUGIN/scripts/board.sh")"
check "board.sh move calls task-state sync" 'task_state.py" --root "$ROOT" sync' "$board"

echo "== task-state: drop, undo and counts =="
(cd "$TS_R" && ts set --id 50 --title "Scope" --agent orchestrator --todo "alpha" --todo "beta" --todo "gamma" >/dev/null)
(cd "$TS_R" && ts todo --id 50 --done 1 --agent dev >/dev/null)
(cd "$TS_R" && ts todo --id 50 --drop 2 --agent dev >/dev/null); check_rc "drop: exits 0" 0 "$?"
(cd "$TS_R" && ts todo --id 50 --add "delta" --agent dev >/dev/null)
shown="$(cd "$TS_R" && ts show --id 50)"
check "drop: show prints [-] for a dropped TODO" "2. [-] beta" "$shown"
check "drop: show keeps the number of later TODOs" "3. [ ] gamma" "$shown"
check "drop: a TODO added afterwards goes last" "4. [ ] delta" "$shown"
check "drop: the count leaves the dropped TODO out" "(1/3)" "$shown"
check "drop: list leaves it out of the count" "(1/3)" "$(cd "$TS_R" && ts list)"
check "drop: json marks it" '"dropped": true' "$(tsj 50)"
(cd "$TS_R" && ts set --id 50 --title "Scope" --agent orchestrator --todo "alpha" --todo "beta" --todo "gamma" >/dev/null)
shown="$(cd "$TS_R" && ts show --id 50)"
check "drop: seeding again does not bring it back" "2. [-] beta" "$shown"
check_rc "drop: seeding again adds no duplicate" 4 "$(grep -c '^[0-9]' <<<"$shown")"
(cd "$TS_R" && ts todo --id 50 --done beta --agent dev >/dev/null 2>&1); check_rc "drop: ticking a dropped TODO is refused" 1 "$?"
check "drop: the refusal leaves it dropped" "2. [-] beta" "$(cd "$TS_R" && ts show --id 50)"
(cd "$TS_R" && ts todo --id 50 --drop beta --agent dev >/dev/null); check_rc "drop: dropping twice is harmless" 0 "$?"
(cd "$TS_R" && ts todo --id 50 --undo 2 --agent dev >/dev/null)
shown="$(cd "$TS_R" && ts show --id 50)"
check "undo: restores a dropped TODO to open" "2. [ ] beta" "$shown"
check "undo: the restored TODO counts again" "(1/4)" "$shown"
(cd "$TS_R" && ts todo --id 50 --done 3 --agent dev >/dev/null)
check "reopen: counts rise when ticked" "(2/4)" "$(cd "$TS_R" && ts show --id 50)"
(cd "$TS_R" && ts todo --id 50 --undo 3 --agent dev >/dev/null)
check "reopen: an undone TODO lowers the count" "(1/4)" "$(cd "$TS_R" && ts show --id 50)"
(cd "$TS_R" && ts todo --id 50 --drop 1 --agent dev >/dev/null)
check "drop: a dropped done TODO leaves done and total" "(0/3)" "$(cd "$TS_R" && ts list)"
(cd "$TS_R" && ts clear --id 50)

echo "== task-state: active TODOs and work order =="
ts_eq() { # name expected actual: exact match
    if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1 — expected: $2"; echo "     got: $3"; fails=$((fails + 1)); fi
}
ts_nums() { (cd "$TS_R" && ts show --id "$1" | sed -n 's/^\([0-9][0-9]*\)\. .*/\1/p' | tr '\n' ' '); }
ts_shown() { (cd "$TS_R" && ts show --id "$1"); }
(cd "$TS_R" && ts set --id 70 --title "Order" --agent orchestrator --todo "alpha" --todo "beta" --todo "gate" --todo "merge" >/dev/null)
(cd "$TS_R" && ts todo --id 70 --start 2 --agent dev >/dev/null); check_rc "start: exits 0" 0 "$?"
check "start: show marks the active TODO and who has it" "2. [>] beta · dev" "$(ts_shown 70)"
check "start: the record says who" '"activeBy": "dev"' "$(tsj 70)"
(cd "$TS_R" && ts todo --id 70 --start alpha --agent reviewer >/dev/null)
shown="$(ts_shown 70)"
check "start: several TODOs can be active across agents (first)" "2. [>] beta · dev" "$shown"
check "start: several TODOs can be active across agents (second)" "1. [>] alpha · reviewer" "$shown"
check "start: the count only changes when something is done" "(0/4)" "$shown"
(cd "$TS_R" && ts todo --id 70 --done 2 --agent dev >/dev/null)
shown="$(ts_shown 70)"
check "done clears the active mark" "2. [x] beta" "$shown"
check_absent "done clears the active mark (no leftover)" "beta ·" "$shown"
(cd "$TS_R" && ts todo --id 70 --undo 1 --agent dev >/dev/null)
check "undo clears the active mark" "1. [ ] alpha" "$(ts_shown 70)"
(cd "$TS_R" && ts todo --id 70 --start 3 --agent dev >/dev/null; ts todo --id 70 --drop 3 --agent dev >/dev/null)
check "drop clears the active mark" "3. [-] gate" "$(ts_shown 70)"
(cd "$TS_R" && ts todo --id 70 --start 3 >/dev/null 2>&1); check_rc "start: a dropped TODO is refused" 1 "$?"
(cd "$TS_R" && ts todo --id 70 --start 2 >/dev/null 2>&1); check_rc "start: a done TODO is refused" 1 "$?"
(cd "$TS_R" && ts todo --id 70 --undo 3 --agent dev >/dev/null)
(cd "$TS_R" && ts todo --id 70 --start 1 >/dev/null); check "start without --agent still marks it" "1. [>] alpha" "$(ts_shown 70)"
(cd "$TS_R" && ts todo --id 70 --undo 1 --agent dev >/dev/null; ts todo --id 70 --undo 2 --agent dev >/dev/null)

(cd "$TS_R" && ts todo --id 70 --add "fix finding" --before gate --agent dev >/dev/null); check_rc "add --before: exits 0" 0 "$?"
ts_eq "add --before: shows in work order, with permanent numbers out of sequence" "1 2 5 3 4 " "$(ts_nums 70)"
check "add --before: the new TODO is numbered max+1" "5. [ ] fix finding" "$(ts_shown 70)"
(cd "$TS_R" && ts todo --id 70 --done 5 --agent dev >/dev/null)
check "numbers stay permanent: --done 5 ticks the inserted TODO" "5. [x] fix finding" "$(ts_shown 70)"
check "numbers stay permanent: gate is still 3" "3. [ ] gate" "$(ts_shown 70)"
(cd "$TS_R" && ts todo --id 70 --move merge --before alpha --agent dev >/dev/null); check_rc "move: exits 0" 0 "$?"
ts_eq "move: changes only the order" "4 1 2 5 3 " "$(ts_nums 70)"
(cd "$TS_R" && ts todo --id 70 --done 4 --agent dev >/dev/null)
check "move: the moved TODO keeps its number" "4. [x] merge" "$(ts_shown 70)"
check "list counts are unaffected by order" "(2/5)" "$(cd "$TS_R" && ts list)"
(cd "$TS_R" && ts set --id 70 --title "Order" --agent orchestrator --todo "alpha" --todo "beta" --todo "gate" --todo "merge" --todo "late" >/dev/null)
ts_eq "set --todo: keeps the order and appends only what is new" "4 1 2 5 3 6 " "$(ts_nums 70)"
check "set --todo: the appended TODO is numbered max+1" "6. [ ] late" "$(ts_shown 70)"
before="$(tsj 70)"
for args in "--add x --before 99" "--move 99 --before 1" "--move 1 --before 99" "--add x --before nope" "--drop 1 --before 2"; do
    # shellcheck disable=SC2086  # the words are separate arguments on purpose
    out="$(cd "$TS_R" && ts todo --id 70 $args 2>&1)"; rc=$?
    check_rc "refused: todo $args" 1 "$rc"
    check_absent "refused: todo $args: no traceback" "Traceback" "$out"
done
check "unknown reference: says which one" "99" "$(cd "$TS_R" && ts todo --id 70 --move 99 --before 1 2>&1)"
ts_eq "refused requests change nothing" "$before" "$(tsj 70)"
(cd "$TS_R" && ts clear --id 70)

TS_STATE="$(git -C "$TS_R" rev-parse --path-format=absolute --git-common-dir)/spec-workflow/task-state"
cat >"$TS_STATE/71.json" <<'LEGACY'
{"id": "71", "title": "Written before permanent numbers", "status": "In progress", "agents": ["dev"], "worktrees": ["/x"],
 "todos": [{"text": "first", "done": true}, {"text": "second", "done": false}, {"text": "third", "done": false, "dropped": true}], "updatedAt": 1}
LEGACY
sum_before="$(cksum <"$TS_STATE/71.json")"
shown="$(ts_shown 71)"
check "legacy record: numbers come from the current positions" "2. [ ] second" "$shown"
check "legacy record: a done TODO keeps its mark" "1. [x] first" "$shown"
check "legacy record: a dropped TODO keeps its mark" "3. [-] third" "$shown"
(cd "$TS_R" && ts list >/dev/null; ts show --id 71 --json >/dev/null)
ts_eq "legacy record: reading does not rewrite it" "$sum_before" "$(cksum <"$TS_STATE/71.json")"
(cd "$TS_R" && ts todo --id 71 --add "inserted" --before second --agent dev >/dev/null)
ts_eq "legacy record: --before works on the old numbers" "1 4 2 3 " "$(ts_nums 71)"
(cd "$TS_R" && ts todo --id 71 --done 2 --agent dev >/dev/null)
check "legacy record: --done 2 still means the old second TODO" "2. [x] second" "$(ts_shown 71)"
(cd "$TS_R" && ts clear --id 71)

(cd "$TS_R" && ts set --id 72 --title "parallel before" --agent x --todo "tail" >/dev/null)
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    (cd "$TS_R" && ts todo --id 72 --add "early $i" --before tail --agent "a$i" >/dev/null) &
done
wait
check_rc "concurrent --add --before loses no updates" 13 "$(ts_nums 72 | wc -w | tr -d ' ')"
check_rc "concurrent --add --before gives every TODO its own number" 13 "$(ts_nums 72 | tr ' ' '\n' | sort -u | grep -c .)"
check "concurrent --add --before keeps the TODO they precede last" "] tail" "$(ts_shown 72 | tail -1)"
(cd "$TS_R" && ts clear --id 72)

echo "== task-state: odd shapes and repeated requests =="
printf '%s' '{"id":"9","title":"t","status":"s","agents":[],"worktrees":[],"todos":[{"text":"a","done":false,"num":3,"active":true,"activeBy":"dev"},{"text":"b","done":true}]}' >"$TS_STATE/9.json"
check "a record with a number, an active mark and a TODO without a number is valid" "3. [>] a · dev" "$(cd "$TS_R" && ts show --id 9 2>&1)"
rm -f "$TS_STATE/9.json"

# mixed record: some TODOs carry a number, some do not
printf '%s' '{"id":"73","title":"mixed","status":"s","agents":[],"worktrees":[],"todos":[{"text":"a","done":false,"num":5},{"text":"b","done":false},{"text":"c","done":false,"num":2},{"text":"d","done":false}]}' >"$TS_STATE/73.json"
ts_eq "mixed record: unnumbered TODOs get fresh numbers after the highest" "5 6 2 7 " "$(ts_nums 73)"
(cd "$TS_R" && ts clear --id 73)

(cd "$TS_R" && ts set --id 74 --title "Self move" --agent dev --todo a --todo b --todo c >/dev/null)
before="$(ts_shown 74)"
(cd "$TS_R" && ts todo --id 74 --move b --before b >/dev/null 2>&1); check_rc "move a TODO before itself: exits 0" 0 "$?"
ts_eq "move a TODO before itself: changes nothing" "$before" "$(ts_shown 74)"
(cd "$TS_R" && ts todo --id 74 --move 2 --before 2 >/dev/null 2>&1); check_rc "move by number before itself: exits 0" 0 "$?"
ts_eq "move by number before itself: changes nothing" "$before" "$(ts_shown 74)"

before="$(ts_shown 74)"
out="$(cd "$TS_R" && ts todo --id 74 --add b 2>&1 >/dev/null)"; rc=$?
check_rc "add existing text: still exits 0" 0 "$rc"
check "add existing text: the notice names the existing number" "TODO 2" "$out"
ts_eq "add existing text: adds nothing" "$before" "$(ts_shown 74)"
out="$(cd "$TS_R" && ts todo --id 74 --add c --before a 2>&1 >/dev/null)"; rc=$?
check_rc "add existing text with --before: still exits 0" 0 "$rc"
check "add existing text with --before: the notice names the existing number" "TODO 3" "$out"
ts_eq "add existing text with --before: adds nothing" "$before" "$(ts_shown 74)"
(cd "$TS_R" && ts todo --id 74 --drop 3 >/dev/null)
out="$(cd "$TS_R" && ts todo --id 74 --add c 2>&1 >/dev/null)"; rc=$?
check_rc "add the text of a dropped TODO: still exits 0" 0 "$rc"
check "add the text of a dropped TODO: the notice names it and says it is dropped" "TODO 3" "$out"
check "add the text of a dropped TODO: the notice says it is dropped" "dropped" "$out"
out="$(cd "$TS_R" && ts todo --id 74 --add brand-new 2>&1 >/dev/null)"
check_absent "add new text: no notice" "already" "$out"
(cd "$TS_R" && ts clear --id 74)

echo "== task-state: instructions =="
skill="$PLUGIN/skills/task-state/SKILL.md"
check "skill: exists with its name" "name: task-state" "$(cat "$skill" 2>/dev/null)"
check "skill: covers concurrent agents" "worktree" "$(cat "$skill" 2>/dev/null)"
check "implement-task seeds the state on pickup" "task-state.sh set" "$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "implement-task briefs the dev agent to tick TODOs" "task-state.sh todo" "$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "implement-task clears the state at the end" "task-state.sh clear" "$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "parallel lanes get the rules" "task-state" "$(cat "$PLUGIN/skills/build-next/references/concurrency.md")"
check "skill is indexed in AGENTS.md" "skills/task-state/SKILL.md" "$(cat "$PLUGIN/../../AGENTS.md")"
check "skill is listed in the marketplace README" '`task-state`' "$(cat "$PLUGIN/../../README.md")"
check "skill is listed in the plugin README" '`task-state`' "$(cat "$PLUGIN/README.md")"


echo "== task-state: every agent brief carries the upkeep rules =="
ts_brief() {  # label, file: each surface is pinned on its own
    local text; text="$(cat "$2")"
    check "$1: has the required section" '## TODO UPKEEP (required)' "$text"
    check "$1: completion, one at a time" 'one at a time, not in a batch at the end' "$text"
    check "$1: scope change adds with --add" 'Scope change' "$text"
    check "$1: scope change drops with --drop" 'task-state.sh todo --id N --drop' "$text"
    check "$1: regression reopens with --undo" 'Regression or rework' "$text"
    check "$1: reopen before starting the fix" 'before starting the fix' "$text"
    check "$1: reviewers record findings" 'Reviewers record findings' "$text"
    check "$1: names the role and task id" '--agent <role>' "$text"
    check "$1: start marks the TODO in progress" 'Start: mark a TODO with `task-state.sh todo --id N --start <number> --agent <role>` when you begin it' "$text"
    check "$1: start is not left set" 'do not leave it set after you stop' "$text"
    check "$1: order inserts with --before" 'Order: insert new work where it really happens' "$text"
    check "$1: order is not the end by default" 'never at the end by default' "$text"
    check "$1: a re-gate stays after the fix" 'the gate item stays after the fix' "$text"
}
ts_brief "dev brief (implement-task)" "$PLUGIN/skills/implement-task/SKILL.md"
ts_brief "reviewer brief (auto-review)" "$PLUGIN/skills/build-next/references/auto-review.md"
check "implement-task: the two review passes get the section" 'orchestrator pastes `## TODO UPKEEP (required)` into each review-pass brief' "$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "implement-task: the orchestrator follows the rules too" 'The orchestrator follows these rules itself' "$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check_absent "implement-task: the old optional item is folded in" '0. Keep the task record current' "$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "concurrency: every lane's brief carries the section" '## TODO UPKEEP (required)' "$(cat "$PLUGIN/skills/build-next/references/concurrency.md")"
check "task-state skill: documents --drop" 'todo --id 12 --drop' "$(cat "$PLUGIN/skills/task-state/SKILL.md")"
check "task-state skill: covers a regression" 'Regression or rework' "$(cat "$PLUGIN/skills/task-state/SKILL.md")"
check "task-state skill: covers a scope change" 'Scope change' "$(cat "$PLUGIN/skills/task-state/SKILL.md")"
check "task-state skill: documents --start" 'todo --id 12 --start' "$(cat "$PLUGIN/skills/task-state/SKILL.md")"
check "task-state skill: documents --before" '--before' "$(cat "$PLUGIN/skills/task-state/SKILL.md")"
check "task-state skill: documents --move" 'todo --id 12 --move' "$(cat "$PLUGIN/skills/task-state/SKILL.md")"
check "task-state skill: numbers are permanent" 'permanent number' "$(cat "$PLUGIN/skills/task-state/SKILL.md")"
check_absent "task-state skill: no longer says TODOs are only appended" 'TODOs are only appended' "$(cat "$PLUGIN/skills/task-state/SKILL.md")"
check_rc "implement-task: both copies of the section carry the new rules" 2 "$(grep -c 'Order: insert new work where it really happens' "$PLUGIN/skills/implement-task/SKILL.md")"
check "task-state skill: the panel never claims undone work" 'never claim something a regression has undone' "$(cat "$PLUGIN/skills/task-state/SKILL.md")"

rm -rf "$TS_TMP"
