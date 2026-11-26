#!/usr/bin/env bash
# section-status.sh -- sourced by run-tests.sh; do not run standalone.
# The status skill's two jq lists, run exactly as written in its SKILL.md, against the stub herdr.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr/tests/run-tests.sh" >&2; exit 2; }

ST_TMP="$(mktemp -d)"
awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$PLUGIN/skills/status/SKILL.md" >"$ST_TMP/lists.sh"
ct_agent() { # name status [extra json fields]
    printf '"%s":{"name":"%s","pane_id":"w1:p%s","tab_id":"w1:t1","workspace_id":"w1","agent":"claude","agent_status":"%s","state_change_seq":1,"cwd":"/w"%s}' "$1" "$1" "$1" "$2" "${3:-}"
}
echo "== status: the two lists =="
printf '%s' "{\"root\":\"/repo\",\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"monorepo\"},{\"workspace_id\":\"w2B\",\"label\":\"a label with spaces well over 24 characters\"},{\"workspace_id\":\"wK\",\"label\":\"fix-converge-deps\"}],\"worktrees\":[{\"branch\":\"feat/long-branch-name\",\"path\":\"/wt/b\",\"open_workspace_id\":\"w2B\"},{\"branch\":\"main\",\"path\":\"/repo\",\"open_workspace_id\":\"w1\"},{\"branch\":\"old\",\"path\":\"/wt/old\"},{\"branch\":\"older\",\"path\":\"/wt/older\",\"open_workspace_id\":null}],\"agents\":{$(ct_agent 1 idle),$(ct_agent lane-a working),$(ct_agent rev blocked),\"x\":{\"pane_id\":\"wK:p1\",\"workspace_id\":\"wK\",\"agent\":\"opencode\",\"agent_status\":\"working\",\"cwd\":\"/somewhere/long\"}}}" >"$ST_TMP/state.json"
out="$(cd "$ST_TMP" && env -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$ST_TMP" HERDR_PANE_ID=w1:p1 bash lists.sh 2>&1)"; rc=$?
check_rc "status lists succeed" 0 "$rc"
check "status: plain heading counts every live agent" "Agents (4)" "$out"
check "status: blocked agents come first, with the workspace label" "Agents (4)
  w1  monorepo           claude    blocked  rev" "$out"
check "status: this agent is marked" "  w1  monorepo           claude    idle     1  (this agent)" "$out"
check "status: columns are aligned and an unnamed agent has no name column" "  w1  monorepo           claude    working  lane-a
  wK  fix-converge-deps  opencode  working" "$out"
check_absent "status: no word for an unnamed agent" "unnamed" "$out"
check_absent "status: no pane ids" "wK:p1" "$out"
check_absent "status: no paths" "/" "$(printf '%s' "$out" | grep -v 'feat/')"
check "status: worktree heading counts open of total" "Worktrees (2 open of 4)" "$out"
check "status: open worktrees by full label, spaces kept, with a note when no agent runs there" "Worktrees (2 open of 4)
  monorepo                                      main
  a label with spaces well over 24 characters  feat/long-branch-name  (no agent)" "$out"
check_absent "status: git-only worktrees are not listed" "old" "$out"
printf '%s\n' "$out" | grep -q ' $' && rc=1 || rc=0
check_rc "status: no trailing spaces" 0 "$rc"
rm -rf "$ST_TMP"
