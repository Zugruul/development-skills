#!/usr/bin/env bash
# section-repos.sh -- sourced by run-tests.sh; do not run standalone.
# Finding every repository with lanes (src/common.sh lane_repos): herdr's worktree roots, the
# git toplevel of every pane's folder (a plain workspace on a standalone clone has no
# .worktree) and the registry lane.sh new and restore write; every sweep uses it.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }
echo "== repos: every repository with lanes is found =="

N_TMP="$(cd "$(mktemp -d)" && pwd -P)"
N_STATE="$N_TMP/state"
N_REG="$N_STATE/herdr-graph/repos"
N_LINKED="$N_TMP/linked" N_CLONE="$N_TMP/stand alone" N_OLD="$N_TMP/old" N_GONE="$N_TMP/gone"
mkdir -p "$N_TMP/outside"
for r in "$N_LINKED" "$N_CLONE" "$N_OLD" "$N_GONE"; do
    git init -q -b main "$r" && git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
# run from a folder that is in no repository, as a panel may
nr() { local s="$1"; shift; (cd "$N_TMP/outside" && env -u HERDR_PANE_ID PATH="$FIX/stub-herdr:$FIX/stub-gh:$PATH" HERDR_STUB_DIR="$N_TMP" GH_STUB_DIR="$N_TMP" GRAPH_GH="$FIX/stub-gh/gh" HERDR_ENV=1 NO_COLOR=1 XDG_STATE_HOME="$N_STATE" XDG_CONFIG_HOME="$N_TMP/config" bash "$PLUGIN/scripts/$s.sh" "$@"); }
nst() { printf '%s' "$1" >"$N_TMP/state.json"; : >"$N_TMP/calls.log"; : >"$N_TMP/gh.log"; }
nlanes() { nr status --json "$@" 2>&1 | jq -r '.[].lane' | sort | paste -sd' ' -; }
ncount() { grep -cxF -- "$1" "$N_REG" 2>/dev/null; }
nst '{}'

nr lane new --repo "$N_LINKED" --lane lane-linked --pattern investigate --idea x >/dev/null
nr lane new --repo "$N_CLONE" --lane lane-clone --pattern investigate --idea x >/dev/null
check "lane new registers its repository in the state folder" "1" "$(ncount "$N_CLONE")"
check_absent "the registry is not inside a repository" "repos" "$(ls "$N_CLONE/.git/herdr-graph")"
# a lane started from a linked worktree registers the primary checkout, which outlives it
git -C "$N_CLONE" worktree add -q -b side "$N_TMP/side" main
nr lane new --repo "$N_TMP/side" --lane lane-side --pattern investigate --idea x >/dev/null
check "a repository is registered once, as its primary checkout" "1 0" "$(ncount "$N_CLONE") $(ncount "$N_TMP/side")"

# the clone alone, found by its pane folder: its workspace has no .worktree, and no registry
mv "$N_REG" "$N_TMP/reg.saved" 2>/dev/null
mkdir -p "$N_CLONE/sub/dir"
CLONE_ONLY="$(jq -cn --arg c "$N_CLONE/sub/dir" --arg o "$N_TMP/outside" '{workspaces: [{workspace_id: "w2"}, {workspace_id: "w3"}],
    pane_list: [{pane_id: "w2:p1", workspace_id: "w2", cwd: $c, foreground_cwd: $c},
                {pane_id: "w3:p1", cwd: $o}, {pane_id: "w3:p2", cwd: "/does/not/exist"}, {pane_id: "w3:p3"}]}')"
nst "$CLONE_ONLY"
check "a plain workspace on a standalone clone shows its lanes (--json)" "lane-clone lane-side" "$(nlanes)"
check "and in --text" "lane-clone  investigate" "$(nr status --text 2>&1)"
nst "$(jq -cn --arg c "$N_CLONE" '{workspaces: [{workspace_id: "w2"}], pane_list: [{pane_id: "w2:p1", cwd: "/does/not/exist", foreground_cwd: $c}]}')"
check "a pane's foreground folder counts too" "lane-clone lane-side" "$(nlanes)"
mv "$N_TMP/reg.saved" "$N_REG" 2>/dev/null

# every workspace closed: the registry still names the repositories
nst '{}'
check "the lanes still show after their workspaces closed (--json)" "lane-clone lane-linked lane-side" "$(nlanes)"
check "and in --text" "lane-clone  investigate" "$(nr status --text 2>&1)"
check "the panel shows them" "lane-clone" "$(nr panel --frame --width 60 --interval 5 2>&1)"

# the same repository found every way at once
nst "$(jq -cn --arg a "$N_LINKED" --arg c "$N_CLONE" --arg s "$N_TMP/side" '{workspaces: [{workspace_id: "w1", worktree: {repo_root: $a}}, {workspace_id: "w2"}],
    pane_list: [{pane_id: "w1:p1", cwd: $a, foreground_cwd: $a}, {pane_id: "w2:p1", cwd: $s}, {pane_id: "w2:p2", cwd: $c}, {pane_id: "w2:p3", cwd: ($c + "/.git")}]}')"
check_rc "each lane is listed once" 3 "$(nr status --json | jq length)"
check "a repository is named by its primary checkout" "$N_CLONE" "$(nr status --json | jq -r '[.[] | select(.lane != "lane-linked") | .root] | unique | .[]')"
check_absent "--repo still limits the view" "lane-clone" "$(nlanes --repo "$N_LINKED")"

# a registered repository that no longer exists
nst '{}'
nr lane new --repo "$N_GONE" --lane lane-gone --pattern investigate --idea x >/dev/null
rm -rf "$N_GONE"
out="$(nr status --text 2>&1)"; rc=$?
check_rc "a repository that no longer exists is no error" 0 "$rc"
check_absent "and is dropped from the view" "lane-gone" "$out"
check_absent "without a message" "$N_GONE" "$out"
mkdir -p "$N_GONE"
check_absent "a folder that is no longer a repository is dropped too" "$N_GONE" "$(nr status --text 2>&1)"
check "its registry line is kept: a drive may only be away for a while" "1" "$(ncount "$N_GONE")"

echo "== repos: the registry =="
# a lane from before the registry: only restore writes it here
nr lane new --repo "$N_OLD" --lane lane-old --pattern investigate --idea x >/dev/null
nr lane close --repo "$N_OLD" --lane lane-old >/dev/null
rm -f "$N_REG"
nr lane restore --repo "$N_OLD" --lane lane-old >/dev/null
check "lane restore registers its repository" "1" "$(ncount "$N_OLD")"
nr lane close --repo "$N_OLD" --lane lane-old >/dev/null
nr lane restore --repo "$N_OLD" --lane lane-old >/dev/null
check "a second restore adds no duplicate line" "1" "$(ncount "$N_OLD")"
rm -f "$N_REG"
for i in 1 2 3 4 5 6; do
    git init -q -b main "$N_TMP/par$i" && git -C "$N_TMP/par$i" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
for i in 1 2 3 4 5 6; do
    nr lane new --repo "$N_TMP/par$i" --lane "lane-par$i" --pattern investigate --idea x >/dev/null &
done
wait
check_rc "parallel writes keep every line" 6 "$(grep -c "/par[1-6]\$" "$N_REG" 2>/dev/null)"
: >"$N_TMP/not-a-folder"
out="$(N_STATE="$N_TMP/not-a-folder" nr lane new --repo "$N_OLD" --lane lane-nostate --pattern investigate --idea x 2>&1)"; rc=$?
check_rc "a registry that cannot be written does not fail lane new" 0 "$rc"
check "it says so" "NOT REGISTERED" "$out"

echo "== repos: every sweep uses it =="
rm -rf "$N_STATE" "$N_TMP"/par?
rm -f "$N_CLONE/.git/herdr-graph/lane-side.yaml"
# only the registry knows the clone: no workspace, no pane, run from outside every repository
nr lane new --repo "$N_CLONE" --lane lane-reg --pattern investigate --idea x --branch feat/swept --workspace w-reg >/dev/null
nr lane node --repo "$N_CLONE" --lane lane-reg --node investigate --status running --agent claude-lane-reg >/dev/null
nst '{}'
check "drift.sh sweeps it" "DRIFT lane-reg/investigate gone" "$(nr drift 2>&1)"
check "resume.sh lists it" "lane lane-reg" "$(nr resume 2>&1)"
nr prs fetch >/dev/null 2>&1
check "prs.sh fetches its pull requests" "pr list --head feat/swept" "$(cat "$N_TMP/gh.log")"
printf '{"number":7,"url":"https://github.com/o/r/pull/7","headRefName":"feat/swept","state":"OPEN"}' >"$N_TMP/pr-7.json"
check "review-owner.sh finds its owner" "OWNER $N_CLONE lane-reg" "$(nr review-owner --pr https://github.com/o/r/pull/7 2>&1)"

nr lane set --repo "$N_CLONE" --lane lane-reg --key status --value "done" >/dev/null
out="$(nr cleanup check 2>&1)"; rc=$?
check_rc "cleanup.sh check without --repo runs outside a repository" 0 "$rc"
check "and sweeps every repository with lanes" "BLOCKED lane-reg" "$out"
check "naming the repository of what it prints" "REPO $N_CLONE" "$out"
check_absent "a repository with nothing to say is not named" "REPO $N_LINKED" "$out"
check_absent "cleanup.sh check --repo stays in that repository" "lane-reg" "$(nr cleanup check --repo "$N_LINKED" 2>&1)"
check "a named lane is looked up in the current repository only" "NO LANE: lane-reg" "$(nr cleanup check --lane lane-reg 2>&1)"

nr panel-action worktree-removed >/dev/null 2>&1
(export HERDR_PLUGIN_EVENT_JSON='{"workspace_id":"w-reg"}'; nr panel-action worktree-removed >/dev/null 2>&1)
check "the worktree-removed hook closes its lane" "closed" "$(nr lane list --repo "$N_CLONE" --all)"
rm -rf "$N_TMP"
