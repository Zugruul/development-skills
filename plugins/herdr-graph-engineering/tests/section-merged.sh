#!/usr/bin/env bash
# section-merged.sh -- sourced by run-tests.sh; do not run standalone.
# Which merge counts and what cleanup says about it: the recorded pull request only, an early
# merge is not "cleanup", a stale question is withdrawn, a wrong entry can be dismissed, a yes
# covers only what was shown, and ignored files are named before they are lost.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

M_TMP="$(mktemp -d)"
M_REPO="$M_TMP/repo"
git init -q -b main "$M_REPO" && git -C "$M_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf '.env\nout/\nnode_modules/\nbuild/\ntarget/\n' >>"$M_REPO/.git/info/exclude"
export XDG_CONFIG_HOME="$M_TMP/config"
m() { local s="$1"; shift; (cd "$M_TMP" && PATH="$FIX/stub-herdr:$FIX/stub-gh:$PATH" HERDR_STUB_DIR="$M_TMP" GH_STUB_DIR="$M_TMP" HERDR_ENV=1 NO_COLOR=1 bash "$PLUGIN/scripts/$s.sh" "$@"); }
M_DIR="$M_REPO/.git/herdr-graph"
ml() { yq -r "$2" "$M_DIR/$1.yaml"; }
mattn() { m status --json --repo "$M_REPO" | jq -r --arg l "$1" '.[] | select(.lane == $l) | .attention | join(" | ")'; }
mopen() { ml "$1" '[(.questions // [])[] | select(.answer == null) | .text] | join(" | ")'; }
mpr() { jq -cn --argjson n "$1" --arg b "$2" --arg s "$3" --arg c "${4:-2999-01-01T00:00:00Z}" --arg h "${5:-}" '{number: $n, url: "https://github.com/o/r/pull/\($n)", state: $s, isDraft: false, reviewDecision: "", headRefName: $b, headRefOid: $h, createdAt: $c}'; }
mcache() { jq -cn --argjson l "$1" '{fetched: 1, lanes: $l}' >"$M_DIR/prs.json"; }
mgh() { printf '%s' "$1" >"$M_TMP/gh.json"; }
mkdir -p "$M_TMP"; printf '{}' >"$M_TMP/state.json"; mgh '{}'
mlane() { # lane [done]
    git -C "$M_REPO" worktree add -q -b "feat/$1" "$M_TMP/wt-$1" main
    git -C "$M_TMP/wt-$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m work
    m lane new --repo "$M_REPO" --lane "$1" --pattern solo --idea x --gate true --branch "feat/$1" --workspace "w-$1" >/dev/null
    if [ "${2:-}" = "done" ]; then
        m lane node --repo "$M_REPO" --lane "$1" --node impl --status "done" --result pass >/dev/null
        m lane node --repo "$M_REPO" --lane "$1" --node tests --status "done" --result pass >/dev/null
        m lane set --repo "$M_REPO" --lane "$1" --key status --value "done" >/dev/null
    fi
}

echo "== merged: only the recorded pull request counts =="
mlane hot "done"
m lane set --repo "$M_REPO" --lane hot --key pr --value https://github.com/o/r/pull/9 >/dev/null
mcache "{\"hot\": [$(mpr 3 feat/hot MERGED), $(mpr 9 feat/other OPEN)]}"
check_absent "an old merged PR on the branch does not count when another is recorded" "merged" "$(mattn hot)"
mcache "{\"hot\": [$(mpr 9 feat/other MERGED)]}"
check "the recorded one does" "PR #9 merged" "$(mattn hot)"

echo "== merged: without a recorded PR, an old one or an open one on the branch rules it out =="
mlane old "done"
mcache "{\"old\": [$(mpr 3 feat/old MERGED 2000-01-01T00:00:00Z)]}"
check_absent "a merged PR older than the lane is not this lane's" "merged" "$(mattn old)"
mcache "{\"old\": [$(mpr 3 feat/old MERGED), $(mpr 4 feat/old OPEN)]}"
check_absent "with a PR on the branch still open, none is merged" "merged" "$(mattn old)"
head_old="$(git -C "$M_TMP/wt-old" rev-parse HEAD)"
mgh "{\"feat/old\": $(mpr 3 feat/old MERGED 2000-01-01T00:00:00Z "$head_old")}"
check "cleanup.sh applies the same rule" "WAIT old (the pull request https://github.com/o/r/pull/3 for branch feat/old is older than the lane" "$(m cleanup check --repo "$M_REPO" --lane old 2>&1)"
check "prs.sh records when each PR was made" "createdAt" "$(grep -E '^FIELDS=' "$PLUGIN/scripts/prs.sh")"

echo "== merged: the panel says what is really asked =="
mlane say "done"
mcache "{\"say\": [$(mpr 5 feat/say MERGED)]}"
check "merged and not yet checked" "PR #5 merged, checking cleanup" "$(mattn say)"
check_absent "is not waiting for a confirmation" "waiting for cleanup confirmation" "$(mattn say)"
head_say="$(git -C "$M_TMP/wt-say" rev-parse HEAD)"
mgh "{\"feat/say\": $(mpr 5 feat/say MERGED 2999-01-01T00:00:00Z "$head_say")}"
m cleanup check --repo "$M_REPO" --lane say >/dev/null
check "asked: waiting for the confirmation" "PR #5 merged, waiting for cleanup confirmation" "$(mattn say)"
check "the question is a cleanup question" "cleanup" "$(ml say '[.questions[] | select(.answer == null)][0].kind')"
check "the offer remembers what was shown" "https://github.com/o/r/pull/5" "$(ml say .cleanup_offer.pr)"
check "with the head" "$head_say" "$(ml say .cleanup_offer.head)"

echo "== merged: a stale question is withdrawn =="
m lane ask --repo "$M_REPO" --lane say --text "an unrelated question" >/dev/null
mgh "{\"feat/say\": $(mpr 5 feat/say OPEN 2999-01-01T00:00:00Z "$head_say")}"
out="$(m cleanup check --repo "$M_REPO" --lane say 2>&1)"
check "check says it withdrew" "WITHDRAWN say" "$out"
check "the cleanup state is cleared" "[]" "[$(ml say '.cleanup // ""')]"
check_absent "its question is gone" "Cleanup say" "$(mopen say)"
check "another question is left alone" "an unrelated question" "$(mopen say)"
check "no node changed" "done done" "$(ml say '[.nodes[].status] | join(" ")')"

echo "== merged: a yes covers only what was shown =="
mlane yes "done"
head_yes="$(git -C "$M_TMP/wt-yes" rev-parse HEAD)"
mgh "{\"feat/yes\": $(mpr 6 feat/yes MERGED 2999-01-01T00:00:00Z "$head_yes")}"
m cleanup check --repo "$M_REPO" --lane yes >/dev/null
m lane answer --repo "$M_REPO" --lane yes --text yes >/dev/null
m lane set --repo "$M_REPO" --lane yes --key cleanup --value confirmed >/dev/null
git -C "$M_TMP/wt-yes" -c user.name=t -c user.email=t@t commit -q --allow-empty -m more
mgh "{\"feat/yes\": $(mpr 6 feat/yes MERGED 2999-01-01T00:00:00Z "$(git -C "$M_TMP/wt-yes" rev-parse HEAD)")}"
: >"$M_TMP/calls.log"
out="$(m cleanup run --repo "$M_REPO" --lane yes 2>&1)"; rc=$?
check_rc "a changed head voids the yes" 6 "$rc"
check "and says why" "changed since the user was asked" "$out"
check_absent "nothing is removed" "worktree remove" "$(cat "$M_TMP/calls.log")"
out="$(m cleanup check --repo "$M_REPO" --lane yes 2>&1)"
check "the next check asks again" "CLEANUP yes" "$out"

echo "== merged: a block is asked once per reason, not per changed detail =="
mlane blk "done"
head_blk="$(git -C "$M_TMP/wt-blk" rev-parse HEAD)"
mgh "{\"feat/blk\": $(mpr 7 feat/blk MERGED 2999-01-01T00:00:00Z "$head_blk")}"
git -C "$M_TMP/wt-blk" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
m cleanup check --repo "$M_REPO" --lane blk >/dev/null
m lane answer --repo "$M_REPO" --lane blk --text "later" >/dev/null
git -C "$M_TMP/wt-blk" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
m cleanup check --repo "$M_REPO" --lane blk >/dev/null
check "a changed count is not a new question" "" "$(mopen blk)"
echo x >"$M_TMP/wt-blk/new.txt"
m cleanup check --repo "$M_REPO" --lane blk >/dev/null
check "a new kind of reason is" "uncommitted changes" "$(mopen blk)"
mcache "{\"blk\": [$(mpr 7 feat/blk MERGED)]}"
check "the panel says it is blocked, not waiting for cleanup" "cleanup blocked: the checkout has uncommitted changes" "$(mattn blk)"

echo "== merged: merged early is its own question =="
mlane early
m lane set --repo "$M_REPO" --lane early --key pr --value https://github.com/o/r/pull/20 >/dev/null
mgh "{\"https://github.com/o/r/pull/20\": $(mpr 20 feat/early MERGED)}"
mcache "{\"early\": [$(mpr 20 feat/early MERGED)]}"
check "an unfinished lane never waits for cleanup" "PR #20 merged but the lane is unfinished (impl, tests)" "$(mattn early)"
out="$(m cleanup check --repo "$M_REPO" --lane early 2>&1)"
check "check reports it" "MERGED-EARLY early" "$out"
check "and asks what to do, not to clean up" "keep working, finish the lane, or dismiss" "$(mopen early)"
check "as a merged-early question" "merged-early" "$(ml early '[.questions[] | select(.answer == null)][0].kind')"
out="$(m cleanup check --repo "$M_REPO" --lane early 2>&1)"
check "asked once" "1" "$(ml early '[.questions[] | select(.kind == "merged-early")] | length')"
check_absent "no node or cleanup state changes" "CLEANUP early" "$out"
m lane answer --repo "$M_REPO" --lane early --text "keep working" >/dev/null
check "answered: the panel stops repeating it" "[]" "[$(mattn early)]"
out="$(m lane set --repo "$M_REPO" --lane early --key cleanup --value confirmed 2>&1)"
check "a merged-early lane has no cleanup to confirm" "NOT ASKED" "$out"

echo "== merged: a wrong entry is dismissed for that PR only =="
mlane wrong "done"
mcache "{\"wrong\": [$(mpr 30 feat/wrong MERGED)]}"
mgh "{\"feat/wrong\": $(mpr 30 feat/wrong MERGED 2999-01-01T00:00:00Z "$(git -C "$M_TMP/wt-wrong" rev-parse HEAD)")}"
m cleanup check --repo "$M_REPO" --lane wrong >/dev/null
m lane dismiss --repo "$M_REPO" --lane wrong --reason pr-merged --ref https://github.com/o/r/pull/30 --text "another lane's PR" >/dev/null
check "the entry is gone" "[]" "[$(mattn wrong)]"
check "why is recorded" "another lane's PR" "$(ml wrong '.dismissed[0].why')"
out="$(m cleanup check --repo "$M_REPO" --lane wrong 2>&1)"
check "check stays quiet about it and withdraws its question" "WITHDRAWN wrong" "$out"
check "nothing is asked" "" "$(mopen wrong)"
mcache "{\"wrong\": [$(mpr 30 feat/wrong MERGED), $(mpr 31 feat/wrong MERGED)]}"
check "a later real merge still reports" "PR #31 merged" "$(mattn wrong)"
m lane dismiss --repo "$M_REPO" --lane wrong --ref https://github.com/o/r/pull/30 --undo >/dev/null
check "a dismissal can be undone" "0" "$(ml wrong '.dismissed | length')"

echo "== merged: a kept lane can be reopened =="
m lane set --repo "$M_REPO" --lane wrong --key cleanup --value declined >/dev/null
m cleanup reopen --repo "$M_REPO" --lane wrong >/dev/null
check "reopen clears the no" "[]" "[$(ml wrong '.cleanup // ""')]"

echo "== merged: ignored files are named before they are lost =="
mlane ign "done"
echo SECRET >"$M_TMP/wt-ign/.env"
mkdir -p "$M_TMP/wt-ign/out" "$M_TMP/wt-ign/node_modules/a" "$M_TMP/wt-ign/web/build"
echo r >"$M_TMP/wt-ign/out/result.txt"; echo x >"$M_TMP/wt-ign/node_modules/a/i.js"; echo x >"$M_TMP/wt-ign/web/build/o.js"
mgh "{\"feat/ign\": $(mpr 40 feat/ign MERGED 2999-01-01T00:00:00Z "$(git -C "$M_TMP/wt-ign" rev-parse HEAD)")}"
out="$(m cleanup facts --repo "$M_REPO" --lane ign 2>&1)"
check "the facts name the pull request" "https://github.com/o/r/pull/40" "$out"
check "the worktree" "$M_TMP/wt-ign" "$out"
check "that the branch stays" "branch feat/ign is kept" "$out"
check "ignored files that would be lost" "LOST: .env, out/" "$out"
check "build folders are safe to lose by default" "safe to lose: node_modules/, web/build/" "$out"
out="$(m cleanup check --repo "$M_REPO" --lane ign 2>&1)"
check "the cleanup question names them too" ".env, out/" "$(mopen ign)"
mkdir -p "$XDG_CONFIG_HOME/herdr-graph"; printf 'out/\n' >"$XDG_CONFIG_HOME/herdr-graph/safe-to-lose"
check "the user's own list adds to the default" "LOST: .env" "$(m cleanup facts --repo "$M_REPO" --lane ign 2>&1)"
check_absent "and out/ is then safe" "LOST: .env, out/" "$(m cleanup facts --repo "$M_REPO" --lane ign 2>&1)"

git -C "$M_REPO" worktree prune 2>/dev/null
rm -rf "$M_TMP"
unset XDG_CONFIG_HOME
unset -f m ml mattn mopen mpr mcache mgh mlane
