#!/usr/bin/env bash
# section-two-pass-review-preflight.sh -- sourced by run-tests.sh; do not run
# standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# #236 (CDX-031 gap #4): two-pass-review-preflight.sh checks that BOTH
# documented review passes (spec-compliance, code-quality) are recorded in
# telemetry for a task before it may move to "QA". KNOWN LIMITATION (see the
# script's own header comment and docs/design/cdx-E3.md's "Follow-up:
# #236"): this verifies RECORDS exist, not that they came from genuinely
# independent review sessions.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== two-pass review preflight (#236, CDX-031 gap #4: independent two-pass review) =="

TPS="$PLUGIN/scripts/two-pass-review-preflight.sh"

# _tp_rec <dir> <json> -- appends a raw telemetry line directly (bypassing
# telemetry.py's CLI) so fixtures can build records with an arbitrary `pass`
# value cheaply.
_tp_rec() {
    local dir="$1" json="$2"
    mkdir -p "$dir/.claude" "$dir/.neural-network"
    printf '%s\n' "$json" >> "$dir/.claude/telemetry.jsonl"
}

# --- (a) both passes recorded for the task -> PASS.
T6A="$(mktemp -d)"
_tp_rec "$T6A" '{"kind":"review-round","task":"236","round":1,"verdict":"approved","pass":"spec-compliance","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6A" '{"kind":"review-round","task":"236","round":2,"verdict":"approved","pass":"code-quality","ts":"2026-01-01T01:00:00Z"}'
out="$(bash "$TPS" --root "$T6A" --task 236 2>&1)"; rc=$?
check_rc "two-pass: (a) both passes recorded -- exit 0" 0 "$rc"
check "two-pass: (a) both passes recorded -- silent stdout on pass" "" "$out"
rm -rf "$T6A"

# --- (b) only spec-compliance recorded -> FAIL, names code-quality missing.
T6B="$(mktemp -d)"
_tp_rec "$T6B" '{"kind":"review-round","task":"236","round":1,"verdict":"approved","pass":"spec-compliance","ts":"2026-01-01T00:00:00Z"}'
out="$(bash "$TPS" --root "$T6B" --task 236 2>&1)"; rc=$?
check_rc "two-pass: (b) only spec-compliance -- exit 2" 2 "$rc"
check "two-pass: (b) message is actionable (BLOCKED)" "BLOCKED" "$out"
check "two-pass: (b) message names code-quality as missing" "code-quality" "$out"
rm -rf "$T6B"

# --- (c) only code-quality recorded -> FAIL, names spec-compliance missing.
T6C="$(mktemp -d)"
_tp_rec "$T6C" '{"kind":"review-round","task":"236","round":1,"verdict":"approved","pass":"code-quality","ts":"2026-01-01T00:00:00Z"}'
out="$(bash "$TPS" --root "$T6C" --task 236 2>&1)"; rc=$?
check_rc "two-pass: (c) only code-quality -- exit 2" 2 "$rc"
check "two-pass: (c) message is actionable (BLOCKED)" "BLOCKED" "$out"
check "two-pass: (c) message names spec-compliance as missing" "spec-compliance" "$out"
rm -rf "$T6C"

# --- (d) neither recorded: missing telemetry.jsonl entirely -> FAIL, both
# named missing, no crash.
T6D="$(mktemp -d)"
mkdir -p "$T6D/.claude" "$T6D/.neural-network"
out="$(bash "$TPS" --root "$T6D" --task 236 2>&1)"; rc=$?
check_rc "two-pass: (d1) missing telemetry file -- exit 2" 2 "$rc"
check "two-pass: (d1) missing telemetry file -- names spec-compliance" "spec-compliance" "$out"
check "two-pass: (d1) missing telemetry file -- names code-quality" "code-quality" "$out"
rm -rf "$T6D"

# --- (d2) records exist, but only for a DIFFERENT task -> FAIL, both missing
# for the task actually being checked.
T6D2="$(mktemp -d)"
_tp_rec "$T6D2" '{"kind":"review-round","task":"999","round":1,"verdict":"approved","pass":"spec-compliance","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6D2" '{"kind":"review-round","task":"999","round":2,"verdict":"approved","pass":"code-quality","ts":"2026-01-01T01:00:00Z"}'
out="$(bash "$TPS" --root "$T6D2" --task 236 2>&1)"; rc=$?
check_rc "two-pass: (d2) records exist only for a different task -- exit 2" 2 "$rc"
check "two-pass: (d2) names spec-compliance" "spec-compliance" "$out"
check "two-pass: (d2) names code-quality" "code-quality" "$out"
rm -rf "$T6D2"

# --- (e) merge-dialogue review-round records (no `pass` field, e.g.
# auto-merge's round 1/2/3) present for the task do NOT satisfy either pass.
T6E="$(mktemp -d)"
_tp_rec "$T6E" '{"kind":"review-round","task":"236","round":1,"verdict":"approved","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6E" '{"kind":"review-round","task":"236","round":2,"verdict":"approved","ts":"2026-01-01T01:00:00Z"}'
_tp_rec "$T6E" '{"kind":"review-round","task":"236","round":3,"verdict":"approved","ts":"2026-01-01T02:00:00Z"}'
out="$(bash "$TPS" --root "$T6E" --task 236 2>&1)"; rc=$?
check_rc "two-pass: (e) no-pass merge-dialogue rounds do not satisfy either pass -- exit 2" 2 "$rc"
check "two-pass: (e) names spec-compliance" "spec-compliance" "$out"
check "two-pass: (e) names code-quality" "code-quality" "$out"
rm -rf "$T6E"

# --- (f) wiring: board-queue.sh's _do_move() calls two-pass-review-preflight.sh
# on the "qa" transition -- NOT on "in review". Fake `gh` as in
# section-gate-preflight.sh / section-red-first-preflight.sh.
_tp_gh_fixture() {
    local dir="$1" marker="$2"
    mkdir -p "$dir"
    cat >"$dir/gh" <<FAKE
#!/usr/bin/env bash
set -uo pipefail
case "\$1 \$2" in
    "api graphql") exec python3 "\$GH_GQL_ADAPTER" "\$0" "\$@" ;;
    "project item-list") echo '{"items":[{"id":"ITEM_236","content":{"number":236}}]}' ;;
    "project item-edit") touch "$marker" 2>/dev/null; echo "edited" ;;
    *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
    chmod +x "$dir/gh"
}

T6F="$(mktemp -d)"; mkdir -p "$T6F/.claude" "$T6F/.neural-network"
cp "$FIX/valid.project.yaml" "$T6F/.neural-network/project.yaml"
T6FGH="$(mktemp -d)"
MARKER_F="$T6FGH/mutated"
_tp_gh_fixture "$T6FGH" "$MARKER_F"
out="$(cd "$T6F" && PATH="$T6FGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 236 "QA" 2>&1)"; rc=$?
check "two-pass wiring: (f) move to QA blocked with no review-round telemetry" "BLOCKED" "$out"
if [[ "$rc" -ne 0 ]]; then
    echo "ok   two-pass wiring: (f) blocked move -- nonzero exit"
else
    echo "FAIL two-pass wiring: (f) blocked move -- nonzero exit (got rc=$rc)"
    fails=$((fails+1))
fi
if [[ -f "$MARKER_F" ]]; then
    echo "FAIL two-pass wiring: (f) blocked move must not reach gh project item-edit"
    fails=$((fails+1))
else
    echo "ok   two-pass wiring: (f) blocked move never reached gh project item-edit"
fi
rm -rf "$T6F" "$T6FGH"

# --- (g) wiring: both passes recorded -> move to QA succeeds, reaching gh.
T6G="$(mktemp -d)"; mkdir -p "$T6G/.claude" "$T6G/.neural-network"
cp "$FIX/valid.project.yaml" "$T6G/.neural-network/project.yaml"
_tp_rec "$T6G" '{"kind":"review-round","task":"236","round":1,"verdict":"approved","pass":"spec-compliance","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6G" '{"kind":"review-round","task":"236","round":2,"verdict":"approved","pass":"code-quality","ts":"2026-01-01T01:00:00Z"}'
T6GGH="$(mktemp -d)"
MARKER_G="$T6GGH/mutated"
_tp_gh_fixture "$T6GGH" "$MARKER_G"
out="$(cd "$T6G" && PATH="$T6GGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 236 "QA" 2>&1)"; rc=$?
check "two-pass wiring: (g) move to QA succeeds with both passes recorded" "moved #236 -> QA" "$out"
check_rc "two-pass wiring: (g) move to QA exit 0" 0 "$rc"
if [[ -f "$MARKER_G" ]]; then
    echo "ok   two-pass wiring: (g) allowed move reached gh project item-edit"
else
    echo "FAIL two-pass wiring: (g) allowed move should have reached gh project item-edit"
    fails=$((fails+1))
fi
rm -rf "$T6G" "$T6GGH"

# --- (h) regression: moving to a status OTHER than "QA" is completely
# unaffected by missing two-pass telemetry (e.g. "In review" itself, which
# has its own independent gate-preflight/red-first-preflight checks and no
# review-round telemetry at all here).
T6H="$(mktemp -d)"
( cd "$T6H" && git init -q -b main . && git commit -q --allow-empty -m init )
mkdir -p "$T6H/.claude" "$T6H/.neural-network"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T6H/.neural-network/project.json"
( cd "$T6H" && git add -A && git commit -q -m "fixture config" && git checkout -q -b feature )
mkdir -p "$T6H/tests" "$T6H/src"
echo t > "$T6H/tests/foo.sh"
( cd "$T6H" && git add tests/foo.sh && git commit -q -m "test(236): red" )
echo i > "$T6H/src/foo.sh"
( cd "$T6H" && git add src/foo.sh && git commit -q -m "feat(236): green" )
out="$(cd "$T6H" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "two-pass regression: (h) gate pass recorded on fixture" "GATE PASS recorded" "$out"
T6HGH="$(mktemp -d)"
MARKER_H="$T6HGH/mutated"
cat >"$T6HGH/gh" <<FAKE
#!/usr/bin/env bash
set -uo pipefail
case "\$1 \$2" in
    "api graphql") exec python3 "\$GH_GQL_ADAPTER" "\$0" "\$@" ;;
    "project item-list") echo '{"items":[{"id":"ITEM_236","content":{"number":236}}]}' ;;
    "project item-edit") touch "$MARKER_H" 2>/dev/null; echo "edited" ;;
    *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$T6HGH/gh"
out="$(cd "$T6H" && PATH="$T6HGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 236 "In review" 2>&1)"; rc=$?
check "two-pass regression: (h) move to 'In review' unaffected by missing two-pass telemetry" "moved #236 -> In review" "$out"
check_rc "two-pass regression: (h) move to 'In review' exit 0" 0 "$rc"
rm -rf "$T6H" "$T6HGH"

# --- (i) regression: moving to Backlog/Ready/Deployed is also unaffected.
T6I="$(mktemp -d)"; mkdir -p "$T6I/.claude" "$T6I/.neural-network"
cp "$FIX/valid.project.yaml" "$T6I/.neural-network/project.yaml"
T6IGH="$(mktemp -d)"
MARKER_I="$T6IGH/mutated"
_tp_gh_fixture "$T6IGH" "$MARKER_I"
_tp_rec "$T6I" '{"kind":"retro-skip","task":"236","reason":"identities disabled in fixture","ts":"2026-01-01T00:00:00Z"}'
for st in Backlog Ready Deployed; do
    out="$(cd "$T6I" && PATH="$T6IGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 236 "$st" 2>&1)"; rc=$?
    check "two-pass regression: (i) move to '$st' unaffected" "moved #236 -> $st" "$out"
    check_rc "two-pass regression: (i) move to '$st' exit 0" 0 "$rc"
done
rm -rf "$T6I" "$T6IGH"

# --- #562: user-accepted merge. `board.sh move N QA --accepted-by-user "<quote>"`
# records the user's words (a user-acceptance telemetry event FIRST, then one
# REST issue comment) BEFORE the two-pass guard runs, so the same move passes.
# Fake gh: logs every call; REST comment is `gh api -X POST repos/R/issues/N/comments`.
# UA_COMMENT_FAIL=1 makes the comment POST fail (rate limit); UA_EDIT_FAIL=1 makes item-edit fail.
_ua_gh_fixture() {
    local dir="$1" log="$2"
    mkdir -p "$dir"
    cat >"$dir/gh" <<FAKE
#!/usr/bin/env bash
set -uo pipefail
echo "\$*" >>"$log"
case "\$1 \$2" in
    "api graphql") exec python3 "\$GH_GQL_ADAPTER" "\$0" "\$@" ;;
    "api -X")
        for a in "\$@"; do
            if [[ "\$a" == body=@* ]]; then cat "\${a#body=@}" >>"$log.body"; fi
            if [[ "\$a" == body=* && "\$a" != body=@* ]]; then printf '%s\n' "\${a#body=}" >>"$log.body"; fi
        done
        if [[ -n "\${UA_COMMENT_FAIL:-}" ]]; then echo "API rate limit exceeded" >&2; exit 1; fi
        echo '{"id":1}' ;;
    "project item-list") echo '{"items":[{"id":"ITEM_562","content":{"number":562}}]}' ;;
    "project item-edit")
        if [[ -n "\${UA_EDIT_FAIL:-}" ]]; then echo "edit failed" >&2; exit 1; fi
        echo "edited" ;;
    *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
    chmod +x "$dir/gh"
}
_ua_root() {
    local d; d="$(mktemp -d)"; mkdir -p "$d/.claude" "$d/.neural-network"
    cp "$FIX/valid.project.yaml" "$d/.neural-network/project.yaml"
    echo "$d"
}
_ua_events() { python3 -c 'import json,sys
n=0
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r["kind"]=="user-acceptance" and r["task"]==sys.argv[2]: n+=1
print(n)' "$1/.claude/telemetry.jsonl" "$2" 2>/dev/null || echo 0; }
_ua_count() { grep -c "$1" "$2" 2>/dev/null || true; }
QUOTE="Looks fine, merge it anyway"

# (j) accepted move passes with NO APPROVE and NO review passes recorded.
T6J="$(_ua_root)"; T6JGH="$(mktemp -d)"; _ua_gh_fixture "$T6JGH" "$T6JGH/calls"
_tp_rec "$T6J" '{"kind":"review-round","task":"562","round":1,"verdict":"REQUEST_CHANGES","ts":"2026-01-01T00:00:00Z"}'
out="$(cd "$T6J" && PATH="$T6JGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA --accepted-by-user "$QUOTE" 2>&1)"; rc=$?
check_rc "user-accept: (j) move QA --accepted-by-user exit 0" 0 "$rc"
check "user-accept: (j) move reports success" "moved #562 -> QA" "$out"
UA_EV="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r["kind"]=="user-acceptance": print(r["task"], r["quote"], bool(r["ts"]))' "$T6J/.claude/telemetry.jsonl")"
check "user-accept: (j) event carries task, exact quote and ts" "562 $QUOTE True" "$UA_EV"
check "user-accept: (j) comment body has quote" "$QUOTE" "$(cat "$T6JGH/calls.body")"
check "user-accept: (j) comment body says accepted without a reviewer APPROVE" "Accepted by the user without a reviewer APPROVE" "$(cat "$T6JGH/calls.body")"
check_rc "user-accept: (j) comment body does not claim a merge happened" 0 "$(grep -ci 'merged' "$T6JGH/calls.body")"
# API budget: the comment is ONE REST call (gh api -X POST repos/R/issues/N/comments); no `issue comment`
# (GraphQL) call; every other gh call is identical to a plain QA move (no new reads).
check_rc "user-accept: (j) exactly ONE REST comment call" 1 "$(_ua_count '^api -X POST repos/.*/issues/562/comments' "$T6JGH/calls")"
check_rc "user-accept: (j) no 'gh issue comment' (GraphQL) call" 0 "$(_ua_count '^issue comment' "$T6JGH/calls")"
T6J2="$(_ua_root)"; T6J2GH="$(mktemp -d)"; _ua_gh_fixture "$T6J2GH" "$T6J2GH/calls"
_tp_rec "$T6J2" '{"kind":"review-round","task":"562","round":1,"verdict":"approved","pass":"spec-compliance","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6J2" '{"kind":"review-round","task":"562","round":2,"verdict":"approved","pass":"code-quality","ts":"2026-01-01T01:00:00Z"}'
( cd "$T6J2" && PATH="$T6J2GH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA >/dev/null 2>&1 )
check_rc "user-accept: (j) total gh calls = plain QA move + 1 REST comment" \
    "$(( $(wc -l <"$T6J2GH/calls") + 1 ))" "$(wc -l <"$T6JGH/calls")"
# (j2) guard + approval-check accept the event; other tasks do not.
out="$(bash "$TPS" --root "$T6J" --task 562 2>&1)"; rc=$?
check_rc "user-accept: (j2) two-pass preflight accepts the event" 0 "$rc"
out="$(bash "$PLUGIN/scripts/review-round.sh" approval-check --task 562 --root "$T6J" 2>&1)"; rc=$?
check_rc "user-accept: (j2) review-round approval-check accepts the event" 0 "$rc"
out="$(bash "$TPS" --root "$T6J" --task 563 2>&1)"; rc=$?
check_rc "user-accept: (j2) event for 562 does not satisfy task 563" 2 "$rc"
out="$(bash "$PLUGIN/scripts/review-round.sh" approval-check --task 563 --root "$T6J" 2>&1)"; rc=$?
check_rc "user-accept: (j2) approval-check for 563 still refuses" 2 "$rc"
rm -rf "$T6J" "$T6JGH" "$T6J2" "$T6J2GH"

# (o) acceptance must not bypass LATER reviews: it counts only if newer than the task's
# latest review-round event and no round is pending.
_ua_both() { # root task expected-rc label
    bash "$TPS" --root "$1" --task "$2" >/dev/null 2>&1; local a=$?
    bash "$PLUGIN/scripts/review-round.sh" approval-check --task "$2" --root "$1" >/dev/null 2>&1; local b=$?
    check_rc "user-accept: $4 (two-pass guard)" "$3" "$a"
    check_rc "user-accept: $4 (approval-check)" "$3" "$b"
}
ACC='{"kind":"user-acceptance","task":"562","quote":"ok merge","ts":"2026-02-01T00:00:00Z"}'
T6O="$(_ua_root)"
_tp_rec "$T6O" '{"kind":"review-round","task":"562","round":1,"verdict":"REQUEST_CHANGES","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6O" "$ACC"
_tp_rec "$T6O" '{"kind":"review-round","task":"562","round":2,"verdict":"REQUEST_CHANGES","ts":"2026-03-01T00:00:00Z"}'
_ua_both "$T6O" 562 2 "(o1) accept then a LATER REQUEST_CHANGES round fails"
rm -rf "$T6O"
T6O="$(_ua_root)"
_tp_rec "$T6O" '{"kind":"review-round","task":"562","round":1,"verdict":"REQUEST_CHANGES","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6O" "$ACC"
_tp_rec "$T6O" '{"kind":"review-round-start","task":"562","round":2,"ts":"2026-01-15T00:00:00Z"}'
_ua_both "$T6O" 562 2 "(o2) accept with a pending reservation fails"
rm -rf "$T6O"
T6O="$(_ua_root)"
_tp_rec "$T6O" '{"kind":"review-round","task":"562","round":1,"verdict":"REQUEST_CHANGES","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6O" '{"kind":"review-round-start","task":"562","round":2,"ts":"2026-01-10T00:00:00Z"}'
_tp_rec "$T6O" '{"kind":"review-round","task":"562","round":2,"verdict":"REQUEST_CHANGES","ts":"2026-01-11T00:00:00Z"}'
_tp_rec "$T6O" "$ACC"
_ua_both "$T6O" 562 0 "(o3) accept after the last round passes"
rm -rf "$T6O"

# (o4) order is by POSITION in the log, never by ts: a pending reservation recorded BEFORE an
# acceptance still blocks (guard and approval-check must agree), whatever the timestamps say.
T6O="$(_ua_root)"
_tp_rec "$T6O" '{"kind":"review-round","task":"562","round":1,"verdict":"REQUEST_CHANGES","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6O" '{"kind":"review-round-start","task":"562","round":2,"ts":"2026-01-02T00:00:00Z"}'
_tp_rec "$T6O" "$ACC"
_ua_both "$T6O" 562 2 "(o4) pending reservation before an acceptance blocks"
rm -rf "$T6O"
# (o4b) file order, not ts order: r2's start has the NEWEST ts but its verdict is logged AFTER the
# start (older ts), and the acceptance is logged after both. File order clears r2, so the
# acceptance counts (ts order would have blocked).
T6O="$(_ua_root)"
_tp_rec "$T6O" '{"kind":"review-round","task":"562","round":1,"verdict":"REQUEST_CHANGES","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6O" '{"kind":"review-round-start","task":"562","round":2,"ts":"2026-03-01T00:00:00Z"}'
_tp_rec "$T6O" '{"kind":"review-round","task":"562","round":2,"verdict":"REQUEST_CHANGES","ts":"2026-01-15T00:00:00Z"}'
_tp_rec "$T6O" '{"kind":"user-acceptance","task":"562","quote":"ok merge","ts":"2026-02-01T00:00:00Z"}'
_ua_both "$T6O" 562 0 "(o4b) file order clears r2; acceptance counts despite older ts"
rm -rf "$T6O"
# (o5) acceptance logged BEFORE a round whose ts is OLDER still loses to that later line.
T6O="$(_ua_root)"
_tp_rec "$T6O" "$ACC"
_tp_rec "$T6O" '{"kind":"review-round","task":"562","round":1,"verdict":"REQUEST_CHANGES","ts":"2020-01-01T00:00:00Z"}'
_ua_both "$T6O" 562 2 "(o5) a round logged after the acceptance wins even with an older ts"
rm -rf "$T6O"
# (o6) non-ISO ts ("t1") never breaks review, with or without an acceptance: same as origin/main.
T6O="$(_ua_root)"
_tp_rec "$T6O" '{"kind":"review-round-start","task":"562","round":1,"ts":"t1"}'
_tp_rec "$T6O" '{"kind":"review-round","task":"562","round":1,"verdict":"APPROVE","ts":"t1"}'
bash "$PLUGIN/scripts/review-round.sh" approval-check --task 562 --root "$T6O" >/dev/null 2>&1
check_rc "user-accept: (o6) APPROVE with ts 't1' still passes approval-check" 0 "$?"
rm -rf "$T6O"
T6O="$(_ua_root)"
_tp_rec "$T6O" '{"kind":"review-round","task":"562","round":1,"verdict":"approved","pass":"spec-compliance","ts":"t1"}'
_tp_rec "$T6O" '{"kind":"review-round","task":"562","round":2,"verdict":"approved","pass":"code-quality","ts":"<now>"}'
bash "$TPS" --root "$T6O" --task 562 >/dev/null 2>&1
check_rc "user-accept: (o6) both passes with non-ISO ts still satisfy the guard" 0 "$?"
rm -rf "$T6O"

# (s) accept, then a later round, then re-accept: the move passes, with 2 events and 2 comments.
T6S="$(_ua_root)"; T6SGH="$(mktemp -d)"; _ua_gh_fixture "$T6SGH" "$T6SGH/calls"
_tp_rec "$T6S" '{"kind":"review-round","task":"562","round":1,"verdict":"REQUEST_CHANGES","ts":"2026-01-01T00:00:00Z"}'
( cd "$T6S" && PATH="$T6SGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA --accepted-by-user "first" >/dev/null 2>&1 )
_tp_rec "$T6S" '{"kind":"review-round","task":"562","round":2,"verdict":"REQUEST_CHANGES","ts":"2026-01-02T00:00:00Z"}'
bash "$TPS" --root "$T6S" --task 562 >/dev/null 2>&1
check_rc "user-accept: (s) a later round invalidates the first acceptance" 2 "$?"
out="$(cd "$T6S" && PATH="$T6SGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA --accepted-by-user "second" 2>&1)"; rc=$?
check_rc "user-accept: (s) re-accept after a later round passes the move" 0 "$rc"
check_rc "user-accept: (s) 2 events" 2 "$(_ua_events "$T6S" 562)"
check_rc "user-accept: (s) 2 REST comments" 2 "$(_ua_count '^api -X POST repos/.*/issues/562/comments' "$T6SGH/calls")"
rm -rf "$T6S" "$T6SGH"

# (p) idempotent + ordered: a move that fails after acceptance, re-run -> exactly 1 comment, 1 event.
T6P="$(_ua_root)"; T6PGH="$(mktemp -d)"; _ua_gh_fixture "$T6PGH" "$T6PGH/calls"
out="$(cd "$T6P" && UA_EDIT_FAIL=1 PATH="$T6PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA --accepted-by-user "$QUOTE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]]; then echo "ok   user-accept: (p) failing move exits non-zero"; else echo "FAIL user-accept: (p) failing move should exit non-zero"; fails=$((fails+1)); fi
out="$(cd "$T6P" && PATH="$T6PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA --accepted-by-user "$QUOTE" 2>&1)"; rc=$?
check_rc "user-accept: (p) re-run succeeds" 0 "$rc"
check_rc "user-accept: (p) exactly 1 REST comment across both runs" 1 "$(_ua_count '^api -X POST repos/.*/issues/562/comments' "$T6PGH/calls")"
check_rc "user-accept: (p) exactly 1 event across both runs" 1 "$(_ua_events "$T6P" 562)"
rm -rf "$T6P" "$T6PGH"

# (q) comment POST fails (rate limit): warn on stderr, the move still proceeds; the event holds the quote.
T6Q="$(_ua_root)"; T6QGH="$(mktemp -d)"; _ua_gh_fixture "$T6QGH" "$T6QGH/calls"
out="$(cd "$T6Q" && UA_COMMENT_FAIL=1 PATH="$T6QGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA --accepted-by-user "$QUOTE" 2>&1)"; rc=$?
check_rc "user-accept: (q) comment failure does not stop the move" 0 "$rc"
check "user-accept: (q) move still completes" "moved #562 -> QA" "$out"
check "user-accept: (q) warns about the comment" "WARN" "$out"
check_rc "user-accept: (q) event recorded with the quote" 1 "$(_ua_events "$T6Q" 562)"
rm -rf "$T6Q" "$T6QGH"

# (t) pending round: refuse up front (exit 2), naming the round; retries record nothing and post nothing.
T6T="$(_ua_root)"; T6TGH="$(mktemp -d)"; _ua_gh_fixture "$T6TGH" "$T6TGH/calls"
_tp_rec "$T6T" '{"kind":"review-round","task":"562","round":1,"verdict":"REQUEST_CHANGES","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6T" '{"kind":"review-round-start","task":"562","round":2,"ts":"2026-01-02T00:00:00Z"}'
for i in 1 2 3; do
    out="$(cd "$T6T" && PATH="$T6TGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA --accepted-by-user "$QUOTE" 2>&1)"; rc=$?
    check_rc "user-accept: (t) pending round retry $i exits 2" 2 "$rc"
    check "user-accept: (t) retry $i names the pending round" "round 2" "$out"
    check "user-accept: (t) retry $i says to record its verdict" "verdict" "$out"
done
check_rc "user-accept: (t) 0 events after 3 retries" 0 "$(_ua_events "$T6T" 562)"
if [[ -s "$T6TGH/calls" ]]; then echo "FAIL user-accept: (t) no gh call while a round is pending"; fails=$((fails+1)); else echo "ok   user-accept: (t) no gh call while a round is pending"; fi
rm -rf "$T6T" "$T6TGH"

# (t2) same shape for the script's refusal: a start with a newer ts whose verdict is logged after it
# is NOT pending, so there is no refusal; the acceptance is recorded and commented.
T6T="$(_ua_root)"; T6TGH="$(mktemp -d)"; _ua_gh_fixture "$T6TGH" "$T6TGH/calls"
_tp_rec "$T6T" '{"kind":"review-round","task":"562","round":1,"verdict":"REQUEST_CHANGES","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6T" '{"kind":"review-round-start","task":"562","round":2,"ts":"2026-03-01T00:00:00Z"}'
_tp_rec "$T6T" '{"kind":"review-round","task":"562","round":2,"verdict":"REQUEST_CHANGES","ts":"2026-01-15T00:00:00Z"}'
out="$(cd "$T6T" && PATH="$T6TGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA --accepted-by-user "$QUOTE" 2>&1)"; rc=$?
check_rc "user-accept: (t2) verdict logged after a newer-ts start is not pending: exit 0" 0 "$rc"
check_rc "user-accept: (t2) event recorded" 1 "$(_ua_events "$T6T" 562)"
check_rc "user-accept: (t2) one REST comment" 1 "$(_ua_count '^api -X POST repos/.*/issues/562/comments' "$T6TGH/calls")"
rm -rf "$T6T" "$T6TGH"

# (u) mktemp failure for the comment body warns on stderr and the move still proceeds.
T6U="$(_ua_root)"; T6UGH="$(mktemp -d)"; _ua_gh_fixture "$T6UGH" "$T6UGH/calls"
mkdir -p "$T6UGH/bin"; printf '#!/bin/sh\nexit 1\n' >"$T6UGH/bin/mktemp"; chmod +x "$T6UGH/bin/mktemp"
out="$(cd "$T6U" && PATH="$T6UGH:$T6UGH/bin:$PATH" bash "$PLUGIN/scripts/user-acceptance.sh" --root "$T6U" --repo o/r --task 562 --status QA --quote "$QUOTE" 2>&1)"; rc=$?
check_rc "user-accept: (u) mktemp failure still exits 0" 0 "$rc"
check "user-accept: (u) mktemp failure warns on stderr" "WARN" "$out"
if [[ -s "$T6UGH/calls" ]]; then echo "FAIL user-accept: (u) no gh call when the body file cannot be made"; fails=$((fails+1)); else echo "ok   user-accept: (u) no gh call when the body file cannot be made"; fi
rm -rf "$T6U" "$T6UGH"

# (k) empty / whitespace-only quote refused (also the `=` form); nothing recorded, no gh call.
for q in "" "   " $'\t \n'; do
    T6K="$(_ua_root)"; T6KGH="$(mktemp -d)"; _ua_gh_fixture "$T6KGH" "$T6KGH/calls"
    out="$(cd "$T6K" && PATH="$T6KGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA --accepted-by-user "$q" 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]]; then echo "ok   user-accept: (k) blank quote refused (rc=$rc)"; else echo "FAIL user-accept: (k) blank quote must be refused"; fails=$((fails+1)); fi
    check "user-accept: (k) blank quote message" "quote" "$out"
    if [[ -s "$T6K/.claude/telemetry.jsonl" ]]; then echo "FAIL user-accept: (k) nothing may be recorded"; fails=$((fails+1)); else echo "ok   user-accept: (k) nothing recorded"; fi
    if [[ -s "$T6KGH/calls" ]]; then echo "FAIL user-accept: (k) no gh call on refusal"; fails=$((fails+1)); else echo "ok   user-accept: (k) no gh call on refusal"; fi
    rm -rf "$T6K" "$T6KGH"
done
T6K="$(_ua_root)"; T6KGH="$(mktemp -d)"; _ua_gh_fixture "$T6KGH" "$T6KGH/calls"
out="$(cd "$T6K" && PATH="$T6KGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA "--accepted-by-user=  " 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]]; then echo "ok   user-accept: (k) blank =quote refused"; else echo "FAIL user-accept: (k) blank =quote refused"; fails=$((fails+1)); fi
if [[ -s "$T6K/.claude/telemetry.jsonl" || -s "$T6KGH/calls" ]]; then echo "FAIL user-accept: (k) =quote nothing recorded"; fails=$((fails+1)); else echo "ok   user-accept: (k) =quote nothing recorded"; fi
rm -rf "$T6K" "$T6KGH"

# (l) flag only valid with a QA target; usage errors exit 2 and name the flag.
T6L="$(_ua_root)"; T6LGH="$(mktemp -d)"; _ua_gh_fixture "$T6LGH" "$T6LGH/calls"
_ua_none() { # label
    if [[ -s "$T6L/.claude/telemetry.jsonl" || -s "$T6LGH/calls" ]]; then echo "FAIL user-accept: $1 nothing recorded, no gh call"; fails=$((fails+1)); else echo "ok   user-accept: $1 nothing recorded, no gh call"; fi
}
out="$(cd "$T6L" && PATH="$T6LGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 "In progress" --accepted-by-user "$QUOTE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]]; then echo "ok   user-accept: (l) non-QA target refused"; else echo "FAIL user-accept: (l) non-QA target must be refused"; fails=$((fails+1)); fi
check "user-accept: (l) message names QA" "QA" "$out"
_ua_none "(l) non-QA"
out="$(cd "$T6L" && PATH="$T6LGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA --accepted-by-user 2>&1)"; rc=$?
check_rc "user-accept: (l) flag without value is a usage error" 2 "$rc"
check "user-accept: (l) flag-without-value names the flag" "--accepted-by-user" "$out"
_ua_none "(l) flag without value"
out="$(cd "$T6L" && PATH="$T6LGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA --bogus x 2>&1)"; rc=$?
check_rc "user-accept: (l) other --flag as 4th arg is a usage error" 2 "$rc"
check "user-accept: (l) unknown flag message names the flag" "--accepted-by-user" "$out"
out="$(cd "$T6L" && PATH="$T6LGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 --accepted-by-user "$QUOTE" QA 2>&1)"; rc=$?
check_rc "user-accept: (l) flag before the status is a usage error" 2 "$rc"
check "user-accept: (l) flag-before-status names the flag" "--accepted-by-user" "$out"
_ua_none "(l) misplaced flag"
# (m) unchanged: no flag, no APPROVE -> still blocked.
out="$(cd "$T6L" && PATH="$T6LGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA 2>&1)"; rc=$?
check_rc "user-accept: (m) no flag and no APPROVE still refused" 1 "$rc"
check "user-accept: (m) still BLOCKED" "BLOCKED" "$out"
rm -rf "$T6L" "$T6LGH"

# (r) `=` form works, and a multi-line / markdown quote is kept verbatim in event and comment.
T6R="$(_ua_root)"; T6RGH="$(mktemp -d)"; _ua_gh_fixture "$T6RGH" "$T6RGH/calls"
MLQ=$'## ship it\n- "fine" by me\n`code` $HOME \\n end'
out="$(cd "$T6R" && PATH="$T6RGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 562 QA "--accepted-by-user=$MLQ" 2>&1)"; rc=$?
check_rc "user-accept: (r) --accepted-by-user=<multi-line quote> exit 0" 0 "$rc"
GOT="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r["kind"]=="user-acceptance": sys.stdout.write(r["quote"])' "$T6R/.claude/telemetry.jsonl")"
if [[ "$GOT" == "$MLQ" ]]; then echo "ok   user-accept: (r) event quote is verbatim"; else echo "FAIL user-accept: (r) event quote is verbatim"; fails=$((fails+1)); fi
check "user-accept: (r) comment keeps the markdown line" '- "fine" by me' "$(cat "$T6RGH/calls.body")"
check "user-accept: (r) comment keeps the literal \$HOME" "\$HOME" "$(cat "$T6RGH/calls.body")"
rm -rf "$T6R" "$T6RGH"

# (n) docs name the flag and the "newer than the last round, none pending" rule.
check "user-accept: (n) auto-review.md documents the flag" "--accepted-by-user" "$(cat "$PLUGIN/skills/build-next/references/auto-review.md")"
check "user-accept: (n) implement-task documents the flag" "--accepted-by-user" "$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "user-accept: (n) auto-review.md states the recorded-after-last-round rule" "recorded after the last review round" "$(cat "$PLUGIN/skills/build-next/references/auto-review.md")"
check "user-accept: (n) implement-task states the recorded-after-last-round rule" "recorded after the last review round" "$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "user-accept: (n) spec delta uses position, not timestamps" "recorded after the last review round" "$(cat "$PLUGIN/../../docs/spec-deltas/562.md")"
check "user-accept: (n) spec delta says REST, not issue comment" "gh api" "$(cat "$PLUGIN/../../docs/spec-deltas/562.md")"
