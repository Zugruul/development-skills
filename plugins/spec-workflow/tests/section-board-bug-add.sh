#!/usr/bin/env bash
# section-board-bug-add.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== board.sh bug verb (fake gh: item-add + eventual consistency) =="
BG="$(mktemp -d)"; mkdir -p "$BG/.claude"
cp "$FIX/valid.project.yaml" "$BG/.claude/project.yaml"
FGH="$(mktemp -d)"
cat >"$FGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
    "issue create")
        echo "https://github.com/fixture-owner/fixture-project/issues/${FAKE_GH_ISSUE_NUM:-501}"
        ;;
    "project item-add")
        : # board.sh discards item-add's stdout; only the call itself (in FAKE_GH_LOG) matters
        ;;
    "project item-list")
        n=$(( $(cat "$FAKE_GH_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$FAKE_GH_CALLCOUNT"
        if [[ "${FAKE_GH_NEVER_VISIBLE:-0}" != "1" && "$n" -ge "${FAKE_GH_VISIBLE_AFTER:-1}" ]]; then
            echo "{\"items\":[{\"id\":\"ITEM_${FAKE_GH_ISSUE_NUM:-501}\",\"content\":{\"number\":${FAKE_GH_ISSUE_NUM:-501}}}]}"
        else
            echo '{"items":[]}'
        fi
        ;;
    "project item-edit")
        if [[ "${FAKE_GH_FAIL_EDIT:-0}" == "1" ]]; then
            echo "fake gh: item-edit boom" >&2
            exit 1
        fi
        echo "edited"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$FGH/gh"

# scenario 1: happy path -- issue created, item-add invoked with its URL, item visible on the first poll
LOG1="$(mktemp)"; CC1="$(mktemp)"
out="$(cd "$BG" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG1" FAKE_GH_CALLCOUNT="$CC1" FAKE_GH_ISSUE_NUM=501 FAKE_GH_VISIBLE_AFTER=1 \
    bash "$PLUGIN/scripts/board.sh" bug "widget breaks on save" "" 42 2>&1; echo "rc=$?")"
check "bug verb: filed bug line on success" "filed bug #501 [P0]" "$out"
check "bug verb: exits 0 on success" "rc=0" "$out"
check "bug verb: issue title prefixed BUG:" "BUG: widget breaks on save" "$(cat "$LOG1")"
check "bug verb: default priority is first option (P0)" "filed bug #501 [P0]" "$out"
check "bug verb: origin-issue link in body" "Originating task: #42." "$(cat "$LOG1")"
check "bug verb: item-add invoked with the created issue's URL" "project item-add 1 --owner fixture-owner --url https://github.com/fixture-owner/fixture-project/issues/501" "$(cat "$LOG1")"

# scenario 2: eventual consistency -- item-list only shows the new item from the 2nd call onward
# (the visibility-poll cap is 2, not 3 (#77) or 10 -- issue #78: each attempt is cache-aware, but
# a miss still costs one full-board call, so the cap stays small)
LOG2="$(mktemp)"; CC2="$(mktemp)"
out="$(cd "$BG" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG2" FAKE_GH_CALLCOUNT="$CC2" FAKE_GH_ISSUE_NUM=502 FAKE_GH_VISIBLE_AFTER=2 \
    bash "$PLUGIN/scripts/board.sh" bug "flaky spinner" P1 2>&1; echo "rc=$?")"
check "bug verb: eventual consistency -- retries until item-list shows the item, then succeeds" "filed bug #502 [P1]" "$out"
check "bug verb: eventual consistency exits 0" "rc=0" "$out"
n2="$(cat "$CC2")"
if [[ "$n2" -ge 2 ]]; then echo "ok   bug verb: item-list was polled multiple times before succeeding"
else echo "FAIL bug verb: expected >=2 item-list polls, got $n2"; fails=$((fails + 1)); fi

# scenario 3 (SPEC #77): the item never becomes visible within the poll cap -- queues the
# add-finish instead of erroring (the pre-#77 behavior burned quota back to zero retrying)
LOG3="$(mktemp)"; CC3="$(mktemp)"
out="$(cd "$BG" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG3" FAKE_GH_CALLCOUNT="$CC3" FAKE_GH_ISSUE_NUM=503 FAKE_GH_NEVER_VISIBLE=1 \
    bash "$PLUGIN/scripts/board.sh" bug "ghost item" P2 2>&1; echo "rc=$?")"
check "bug verb: never-visible item -- queues instead of erroring, names the issue" "QUEUED" "$out"
check "bug verb: never-visible item -- QUEUED message names the issue" "item-add #503" "$out"
check_absent "bug verb: never-visible item -- no false 'filed' success line" "filed bug" "$out"
check "bug verb: never-visible item exits 0 (loop keeps going)" "rc=0" "$out"

# scenario 4 (invariant #3): item-add/visibility succeed but the subsequent move/prio fails --
# the verb must not report success
LOG4="$(mktemp)"; CC4="$(mktemp)"
out="$(cd "$BG" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG4" FAKE_GH_CALLCOUNT="$CC4" FAKE_GH_ISSUE_NUM=504 FAKE_GH_VISIBLE_AFTER=1 FAKE_GH_FAIL_EDIT=1 \
    bash "$PLUGIN/scripts/board.sh" bug "move/prio fails" P0 2>&1; echo "rc=$?")"
check_absent "bug verb: move/prio failure -- no false success line" "filed bug" "$out"
check "bug verb: move/prio failure exits nonzero" "rc=1" "$out"

rm -rf "$BG" "$FGH" "$LOG1" "$CC1" "$LOG2" "$CC2" "$LOG3" "$CC3" "$LOG4" "$CC4"

echo "== board.sh add verb (SW-003: generalized bug -> add --type, fake gh) =="
AG="$(mktemp -d)"; mkdir -p "$AG/.claude"
cp "$FIX/valid.project.yaml" "$AG/.claude/project.yaml"
AGH="$(mktemp -d)"
cat >"$AGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
    "issue create")
        echo "https://github.com/fixture-owner/fixture-project/issues/${FAKE_GH_ISSUE_NUM:-601}"
        ;;
    "project item-add")
        if [[ "${FAKE_GH_FAIL_ITEM_ADD:-0}" == "1" ]]; then
            echo "fake gh: item-add boom" >&2
            exit 1
        fi
        ;;
    "project item-list")
        n=$(( $(cat "$FAKE_GH_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$FAKE_GH_CALLCOUNT"
        if [[ "${FAKE_GH_NEVER_VISIBLE:-0}" != "1" && "$n" -ge "${FAKE_GH_VISIBLE_AFTER:-1}" ]]; then
            echo "{\"items\":[{\"id\":\"ITEM_${FAKE_GH_ISSUE_NUM:-601}\",\"content\":{\"number\":${FAKE_GH_ISSUE_NUM:-601}}}]}"
        else
            echo '{"items":[]}'
        fi
        ;;
    "project item-edit")
        echo "edited"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$AGH/gh"

# scenario 1: add --type inbound -- inbound label, no BUG: prefix, filed line names the type
LOGA1="$(mktemp)"; CCA1="$(mktemp)"
out="$(cd "$AG" && PATH="$AGH:$PATH" FAKE_GH_LOG="$LOGA1" FAKE_GH_CALLCOUNT="$CCA1" FAKE_GH_ISSUE_NUM=601 FAKE_GH_VISIBLE_AFTER=1 \
    bash "$PLUGIN/scripts/board.sh" add --type inbound "widget idea from standup" P2 2>&1; echo "rc=$?")"
check "add --type inbound: filed line names the type" "filed inbound #601 [P2]" "$out"
check "add --type inbound: exits 0 on success" "rc=0" "$out"
check "add --type inbound: issue title has no BUG: prefix" "issue create -R fixture-owner/fixture-project --title widget idea from standup" "$(cat "$LOGA1")"
check_absent "add --type inbound: never BUG:-prefixed" "BUG: widget idea from standup" "$(cat "$LOGA1")"
check "add --type inbound: labeled inbound" "--label inbound" "$(cat "$LOGA1")"
check_absent "add --type inbound: never labeled type:bug" "--label type:bug" "$(cat "$LOGA1")"
check "add --type inbound: item-add invoked with the created issue's URL" "project item-add 1 --owner fixture-owner --url https://github.com/fixture-owner/fixture-project/issues/601" "$(cat "$LOGA1")"

# scenario 2: add --type feature -- type:feature label, default priority is first option (P0)
LOGA2="$(mktemp)"; CCA2="$(mktemp)"
out="$(cd "$AG" && PATH="$AGH:$PATH" FAKE_GH_LOG="$LOGA2" FAKE_GH_CALLCOUNT="$CCA2" FAKE_GH_ISSUE_NUM=602 FAKE_GH_VISIBLE_AFTER=1 \
    bash "$PLUGIN/scripts/board.sh" add --type feature "quick filters on the list view" 2>&1; echo "rc=$?")"
check "add --type feature: filed line, default priority" "filed feature #602 [P0]" "$out"
check "add --type feature: labeled type:feature" "--label type:feature" "$(cat "$LOGA2")"

# scenario 3: bug alias === add --type bug -- identical label/prefix/behavior (spot assertion)
LOGA3="$(mktemp)"; CCA3="$(mktemp)"
out="$(cd "$AG" && PATH="$AGH:$PATH" FAKE_GH_LOG="$LOGA3" FAKE_GH_CALLCOUNT="$CCA3" FAKE_GH_ISSUE_NUM=603 FAKE_GH_VISIBLE_AFTER=1 \
    bash "$PLUGIN/scripts/board.sh" bug "widget breaks on save" P1 2>&1; echo "rc=$?")"
check "bug alias: filed line matches add --type bug shape" "filed bug #603 [P1]" "$out"
check "bug alias: still prefixes BUG: and uses type:bug label" "issue create -R fixture-owner/fixture-project --title BUG: widget breaks on save --body Bug found after a task reached a released status; filed as new work (never reopen shipped tasks). --label type:bug" "$(cat "$LOGA3")"

# scenario 4 (SPEC #77): visibility timeout -- queues the add-finish instead of erroring
LOGA4="$(mktemp)"; CCA4="$(mktemp)"
out="$(cd "$AG" && PATH="$AGH:$PATH" FAKE_GH_LOG="$LOGA4" FAKE_GH_CALLCOUNT="$CCA4" FAKE_GH_ISSUE_NUM=604 FAKE_GH_NEVER_VISIBLE=1 \
    bash "$PLUGIN/scripts/board.sh" add --type inbound "ghost inbound item" P2 2>&1; echo "rc=$?")"
check "add: never-visible item -- queues instead of erroring, names the issue" "QUEUED" "$out"
check "add: never-visible item -- QUEUED message names the issue" "item-add #604" "$out"
check_absent "add: never-visible item -- no false success line" "filed inbound" "$out"
check "add: never-visible item exits 0 (loop keeps going)" "rc=0" "$out"

# scenario 5: item-add failure -- honest non-zero failure, no false success line
LOGA5="$(mktemp)"; CCA5="$(mktemp)"
out="$(cd "$AG" && PATH="$AGH:$PATH" FAKE_GH_LOG="$LOGA5" FAKE_GH_CALLCOUNT="$CCA5" FAKE_GH_ISSUE_NUM=605 FAKE_GH_FAIL_ITEM_ADD=1 \
    bash "$PLUGIN/scripts/board.sh" add --type inbound "item-add will fail" P2 2>&1; echo "rc=$?")"
check "add: item-add failure -- actionable ERROR naming the issue" "ERROR: issue #605 was created but gh project item-add failed" "$out"
check_absent "add: item-add failure -- no false success line" "filed inbound" "$out"
check "add: item-add failure exits nonzero" "rc=1" "$out"

# scenario 6: unknown --type -- rejected, no gh calls made
out="$(cd "$AG" && PATH="$AGH:$PATH" FAKE_GH_LOG="$(mktemp)" bash "$PLUGIN/scripts/board.sh" add --type nonsense "whatever" 2>&1; echo "rc=$?")"
check "add: unknown --type rejected" "ERROR:" "$out"
check "add: unknown --type exits nonzero" "rc=1" "$out"

rm -rf "$AG" "$AGH" "$LOGA1" "$CCA1" "$LOGA2" "$CCA2" "$LOGA3" "$CCA3" "$LOGA4" "$CCA4" "$LOGA5" "$CCA5"

echo "== board.sh ensure-labels (SW-046: a configured label must exist on the repo before a runtime path applies it) =="
EG="$(mktemp -d)"; mkdir -p "$EG/.claude"
cp "$FIX/valid.project.yaml" "$EG/.claude/project.yaml"
EGH="$(mktemp -d)"
cat >"$EGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
    "label list")
        cat "$LABELS_FILE" 2>/dev/null || true
        ;;
    "label create")
        echo "$3" >>"$LABELS_FILE"
        ;;
    "issue create")
        label=""; prev=""
        for a in "$@"; do
            if [[ "$prev" == "--label" ]]; then label="$a"; fi
            prev="$a"
        done
        if [[ -n "$label" ]] && ! grep -Fxq "$label" "$LABELS_FILE" 2>/dev/null; then
            echo "could not add label: '$label' not found" >&2
            exit 1
        fi
        echo "https://github.com/fixture-owner/fixture-project/issues/${FAKE_GH_ISSUE_NUM:-701}"
        ;;
    "project item-add")
        : # unconditionally OK for this fixture
        ;;
    "project item-list")
        echo "{\"items\":[{\"id\":\"ITEM_${FAKE_GH_ISSUE_NUM:-701}\",\"content\":{\"number\":${FAKE_GH_ISSUE_NUM:-701}}}]}"
        ;;
    "project item-edit")
        echo "edited"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$EGH/gh"

# scenario 1: type:bug and type:feature already exist (the real incident's starting state);
# inbound does not -- ensure-labels must create only what's missing.
LF1="$(mktemp)"; printf 'type:bug\ntype:feature\n' >"$LF1"
LOGE1="$(mktemp)"
out="$(cd "$EG" && PATH="$EGH:$PATH" FAKE_GH_LOG="$LOGE1" LABELS_FILE="$LF1" bash "$PLUGIN/scripts/board.sh" ensure-labels 2>&1; echo "rc=$?")"
check "ensure-labels: exits 0" "rc=0" "$out"
check "ensure-labels: creates the missing inbound label" "created label: inbound" "$out"
check "ensure-labels: reports existing bug label without recreating it" "label exists: type:bug" "$out"
check "ensure-labels: reports existing feature label without recreating it" "label exists: type:feature" "$out"
check_absent "ensure-labels: never re-creates type:bug" "created label: type:bug" "$out"
check_absent "ensure-labels: never re-creates type:feature" "created label: type:feature" "$out"
check "ensure-labels: gh label create invoked for the missing label only" "label create inbound -R fixture-owner/fixture-project" "$(cat "$LOGE1")"
check_absent "ensure-labels: no gh label create call for the already-existing bug label" "label create type:bug" "$(cat "$LOGE1")"

# scenario 2: idempotent re-run -- now all three exist, nothing is (re)created
LOGE2="$(mktemp)"
out="$(cd "$EG" && PATH="$EGH:$PATH" FAKE_GH_LOG="$LOGE2" LABELS_FILE="$LF1" bash "$PLUGIN/scripts/board.sh" ensure-labels 2>&1; echo "rc=$?")"
check "ensure-labels: idempotent re-run exits 0" "rc=0" "$out"
check_absent "ensure-labels: idempotent re-run creates nothing" "created label:" "$out"
rm -f "$LF1" "$LOGE1" "$LOGE2"

# scenario 3 (the live incident, reproduced then fixed): board.sh add --type inbound fails
# while the inbound label doesn't exist on the repo (RED), then succeeds once ensure-labels
# has created it (GREEN) -- proves ensure-labels is what closes the gap, not a coincidence.
LF2="$(mktemp)"; printf 'type:bug\ntype:feature\n' >"$LF2"
LOGB1="$(mktemp)"
out="$(cd "$EG" && PATH="$EGH:$PATH" FAKE_GH_LOG="$LOGB1" LABELS_FILE="$LF2" FAKE_GH_ISSUE_NUM=701 \
    bash "$PLUGIN/scripts/board.sh" add --type inbound "standup idea" P2 2>&1; echo "rc=$?")"
check "add --type inbound: RED -- fails while the configured label doesn't exist on the repo" "could not add label: 'inbound' not found" "$out"
check "add --type inbound: RED -- exits nonzero" "rc=1" "$out"
check_absent "add --type inbound: RED -- no false success line" "filed inbound" "$out"

( cd "$EG" && PATH="$EGH:$PATH" FAKE_GH_LOG="$(mktemp)" LABELS_FILE="$LF2" bash "$PLUGIN/scripts/board.sh" ensure-labels >/dev/null 2>&1 )

LOGB2="$(mktemp)"
out="$(cd "$EG" && PATH="$EGH:$PATH" FAKE_GH_LOG="$LOGB2" LABELS_FILE="$LF2" FAKE_GH_ISSUE_NUM=702 \
    bash "$PLUGIN/scripts/board.sh" add --type inbound "standup idea" P2 2>&1; echo "rc=$?")"
check "add --type inbound: GREEN -- succeeds once ensure-labels has created the label" "filed inbound #702 [P2]" "$out"
check "add --type inbound: GREEN -- exits 0" "rc=0" "$out"

rm -rf "$EG" "$EGH" "$LF2" "$LOGB1" "$LOGB2"

echo "== create-inbound SKILL.md contract =="
CISKILL="$PLUGIN/skills/create-inbound/SKILL.md"
if [[ -f "$CISKILL" ]]; then echo "ok   create-inbound/SKILL.md exists"; else echo "FAIL create-inbound/SKILL.md missing"; fails=$((fails + 1)); fi
check "create-inbound SKILL.md has allowed-tools frontmatter" "allowed-tools: Bash" "$(cat "$CISKILL" 2>/dev/null)"
check "create-inbound SKILL.md wires board.sh issues (search first)" "board.sh\" issues" "$(cat "$CISKILL" 2>/dev/null)"
check "create-inbound SKILL.md invokes similar.py via python3" "python3 \"\${CLAUDE_PLUGIN_ROOT}/scripts/similar.py\"" "$(cat "$CISKILL" 2>/dev/null)"
check "create-inbound SKILL.md creates via board.sh add --type inbound" "board.sh\" add --type inbound" "$(cat "$CISKILL" 2>/dev/null)"
check "create-inbound SKILL.md: high tier default is comment, not create" "do NOT create a new issue" "$(cat "$CISKILL" 2>/dev/null)"
check "create-inbound SKILL.md: high tier default action is comment on the existing issue" "comment the description onto the existing issue instead" "$(cat "$CISKILL" 2>/dev/null)"
check "create-inbound SKILL.md: medium tier asks the human" "ask the human" "$(cat "$CISKILL" 2>/dev/null)"
check "create-inbound SKILL.md: medium tier, absent human -- do not create" "absent or does not answer, do NOT create" "$(cat "$CISKILL" 2>/dev/null)"

