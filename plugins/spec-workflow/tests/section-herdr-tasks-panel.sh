#!/usr/bin/env bash
# section-herdr-tasks-panel.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced _lib.sh
# (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky.
# Covers the herdr tasks panel plugin. It reads local task state only, so a
# stub `gh` that records any call proves it never touches the network.
# shellcheck disable=SC2016  # the stub scripts expand at their own run time

declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }

TP_PLUGIN="$PLUGIN/herdr-plugin"
TP_TMP="$(mktemp -d)"

echo "== tasks panel: manifest =="
manifest="$(cat "$TP_PLUGIN/herdr-plugin.toml")"
check "manifest: declares a toggle action" 'id = "toggle"' "$manifest"
check "manifest: declares the panel pane" 'id = "panel"' "$manifest"
if python3 -c 'import tomllib' 2>/dev/null; then
    parsed="$(python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); print(d["id"], d["min_herdr_version"], [a["id"] for a in d["actions"]], [p["id"] for p in d["panes"]])' "$TP_PLUGIN/herdr-plugin.toml" 2>&1)"
else
    # Python before 3.11 has no tomllib; the stdlib-only fallback reads the same fields by pattern.
    parsed="$(python3 - "$TP_PLUGIN/herdr-plugin.toml" <<'PY' 2>&1
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
has = lambda pat: re.search(pat, text, re.M) is not None
assert has(r'^id = "') and has(r'^min_herdr_version = ')
print([m for m in re.findall(r'^\[\[actions\]\]\s*\nid = "([^"]+)"', text, re.M)], [m for m in re.findall(r'^\[\[panes\]\]\s*\nid = "([^"]+)"', text, re.M)])
PY
)"
    parsed="x x $parsed"
fi
check "manifest: is valid TOML with the required fields" "['toggle'] ['panel']" "$parsed"

echo "== tasks panel: toggle =="
TP_HBIN="$TP_TMP/hbin"; mkdir -p "$TP_HBIN"
TP_HLOG="$TP_TMP/herdr.log"; export TP_HLOG
cat >"$TP_HBIN/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$TP_HLOG"
case "$1 $2" in
    "pane get") [[ -n "${TP_PANE_DOWN:-}" ]] && exit 1; [[ -n "${TP_PANEGET_JSON:-}" ]] && { printf '%s\n' "$TP_PANEGET_JSON"; exit 0; }; printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s"}}}\n' "$3" "${TP_PANE_TAB:-w1:t1}" ;;
    "pane list") printf '%s\n' "${TP_PANES:-}" ;;
    "pane resize") printf '{"result":{}}\n' ;;
    "plugin pane")
        if [[ "$3" == open && -n "${TP_OPEN_JSON:-}" ]]; then
            printf '%s\n' "$TP_OPEN_JSON"
        elif [[ "$3" == open ]]; then
            printf '{"result":{"plugin_pane":{"pane":{"pane_id":"w1:p9"}}}}\n'
        else
            printf '{"result":{}}\n'
        fi
        ;;
esac
STUB
chmod +x "$TP_HBIN/herdr"
tp_toggle() {
    PATH="$TP_HBIN:$PATH" HERDR_BIN_PATH="$TP_HBIN/herdr" HERDR_PLUGIN_ID=spec-workflow.tasks \
        HERDR_PLUGIN_STATE_DIR="$TP_TMP/state" HERDR_PANE_ID=w1:p1 HERDR_TAB_ID=w1:t1 HERDR_WORKSPACE_ID=w1 \
        python3 "$TP_PLUGIN/tasks_panel.py" toggle
}
mkdir -p "$TP_TMP/state"
: >"$TP_HLOG"
tp_toggle >/dev/null 2>&1; rc=$?
check_rc "toggle with no panel: exits 0" 0 "$rc"
check "toggle with no panel: opens the panel" "plugin pane open --plugin spec-workflow.tasks --entrypoint panel" "$(cat "$TP_HLOG")"
check "toggle with no panel: splits to the right" "--direction right" "$(cat "$TP_HLOG")"
check "toggle with no panel: keeps focus on the caller" "--no-focus" "$(cat "$TP_HLOG")"

sleep 60 & TP_PID=$!
printf '{"pane_id":"w1:p9","pid":%s}\n' "$TP_PID" >"$TP_TMP/state/panel-w1-p9.json"
: >"$TP_HLOG"
tp_toggle >/dev/null 2>&1
check "toggle with a live panel in this tab: closes it" "plugin pane close w1:p9" "$(cat "$TP_HLOG")"
check_absent "toggle with a live panel: does not also open one" "plugin pane open" "$(cat "$TP_HLOG")"

: >"$TP_HLOG"
TP_PANE_TAB=w2:t1 tp_toggle >/dev/null 2>&1
check_absent "panel in another tab: is left alone" "plugin pane close" "$(cat "$TP_HLOG")"
check "panel in another tab: this tab gets its own" "plugin pane open" "$(cat "$TP_HLOG")"
kill "$TP_PID" 2>/dev/null; wait "$TP_PID" 2>/dev/null

: >"$TP_HLOG"
tp_toggle >/dev/null 2>&1
check_absent "dead panel record: nothing to close" "plugin pane close" "$(cat "$TP_HLOG")"
check "dead panel record: opens a new panel" "plugin pane open" "$(cat "$TP_HLOG")"
check_absent "dead panel record: is cleaned up" "panel-w1-p9" "$(ls "$TP_TMP/state")"

sleep 60 & TP_PID2=$!
printf '{"pane_id":"w1:p8","pid":%s}\n' "$TP_PID2" >"$TP_TMP/state/panel-w1-p8.json"
: >"$TP_HLOG"
TP_PANE_DOWN=1 tp_toggle >/dev/null 2>&1; rc=$?
check_rc "herdr pane get fails for a live panel: toggle exits 0" 0 "$rc"
check "herdr pane get fails for a live panel: the record is kept" "panel-w1-p8" "$(ls "$TP_TMP/state")"
check "herdr pane get fails for a live panel: treated as not in this tab, a panel opens" "plugin pane open" "$(cat "$TP_HLOG")"
check_absent "herdr pane get fails for a live panel: nothing is closed" "plugin pane close" "$(cat "$TP_HLOG")"
kill "$TP_PID2" 2>/dev/null; wait "$TP_PID2" 2>/dev/null
rm -f "$TP_TMP/state/panel-w1-p8.json"
for payload in '[]' '5' 'null' '"text"' '{"pane_id":"w1:p8","pid":"x"}' 'not json'; do
    printf '%s' "$payload" >"$TP_TMP/state/panel-odd.json"
    out="$(tp_toggle 2>&1)"; rc=$?
    check_rc "odd panel record $payload: toggle exits 0" 0 "$rc"
    check_absent "odd panel record $payload: toggle does not crash" "Traceback" "$out"
    check_absent "odd panel record $payload: the dead record is cleaned up" "panel-odd" "$(ls "$TP_TMP/state")"
done

sleep 60 & TP_PID4=$!
for payload in '{"pane_id":["w1:p8"],"pid":%s}' '{"pane_id":5,"pid":%s}' '{"pane_id":"","pid":%s}' '{"pane_id":"w1:p8","pid":1e999}'; do
    # shellcheck disable=SC2059  # the payload is a format that takes the live pid
    printf "$payload" "$TP_PID4" >"$TP_TMP/state/panel-odd.json"
    out="$(tp_toggle 2>&1)"; rc=$?
    check_rc "odd panel record $payload: toggle exits 0" 0 "$rc"
    check_absent "odd panel record $payload: toggle does not crash" "Traceback" "$out"
    check_absent "odd panel record $payload: the bad record is cleaned up" "panel-odd" "$(ls "$TP_TMP/state")"
done
kill "$TP_PID4" 2>/dev/null; wait "$TP_PID4" 2>/dev/null
sleep 60 & TP_PID3=$!
for shape in '{"result":{"pane":"x"}}' '{"result":{"pane":5}}' '{"result":{"pane":[1]}}' '{"result":{"pane":{"tab_id":["w1:t1"]}}}' '[]' '5'; do
    printf '{"pane_id":"w1:p8","pid":%s}\n' "$TP_PID3" >"$TP_TMP/state/panel-w1-p8.json"
    : >"$TP_HLOG"
    out="$(TP_PANEGET_JSON="$shape" tp_toggle 2>&1)"; rc=$?
    check_rc "pane get answers $shape: toggle exits 0" 0 "$rc"
    check_absent "pane get answers $shape: toggle does not crash" "Traceback" "$out"
    check "pane get answers $shape: treated as another tab, a panel opens" "plugin pane open" "$(cat "$TP_HLOG")"
done
kill "$TP_PID3" 2>/dev/null; wait "$TP_PID3" 2>/dev/null
rm -f "$TP_TMP/state/panel-w1-p8.json"
for shape in '{"result":{"plugin_pane":"x"}}' '{"result":{"plugin_pane":{"pane":"x"}}}' '{"result":{"plugin_pane":{"pane":{"pane_id":5}}}}'; do
    : >"$TP_HLOG"
    out="$(TP_OPEN_JSON="$shape" tp_toggle 2>&1)"; rc=$?
    check_rc "plugin pane open answers $shape: toggle exits 0" 0 "$rc"
    check_absent "plugin pane open answers $shape: toggle does not crash" "Traceback" "$out"
    check_absent "plugin pane open answers $shape: no resize of a pane that is not named" "pane resize" "$(cat "$TP_HLOG")"
done
rm -f "$TP_TMP/state/"panel-*.json

echo "== tasks panel: render =="
TP_R="$TP_TMP/repo"; git init -q -b main "$TP_R"; mkdir -p "$TP_R/.neural-network"
cp "$FIX/valid.project.yaml" "$TP_R/.neural-network/project.yaml"
git -C "$TP_R" add -A; git -C "$TP_R" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$TP_R" worktree add -q "$TP_R-lane" -b lane
TP_N="$TP_TMP/notanchored"; git init -q -b main "$TP_N"
ESC="$(printf '\033')"; BEL="$(printf '\007')"
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" set --id 12 --title "Add ${ESC}[31mparser${ESC}[0m" --status "In progress" --agent orchestrator \
    --todo "write the test" --todo "nested ${ESC}]0;pwned${BEL}step" --todo "upper done")
(cd "$TP_R-lane" && bash "$PLUGIN/scripts/task-state.sh" todo --id 12 --done 1 --agent dev >/dev/null)
(cd "$TP_R-lane" && bash "$PLUGIN/scripts/task-state.sh" todo --id 12 --done 3 --agent dev >/dev/null)
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" set --id 13 --title "No checklist here" --status "In review" --agent reviewer)
TP_GHBIN="$TP_TMP/ghbin"; mkdir -p "$TP_GHBIN"; TP_GHLOG="$TP_TMP/gh.log"; export TP_GHLOG
printf '#!/usr/bin/env bash\necho "$*" >>"$TP_GHLOG"\nexit 1\n' >"$TP_GHBIN/gh"; chmod +x "$TP_GHBIN/gh"
: >"$TP_GHLOG"
TP_PANES_JSON="$(python3 -c 'import json,sys; print(json.dumps({"result":{"panes":[{"cwd":sys.argv[1]},{"cwd":sys.argv[2]},{"cwd":sys.argv[3]},{"cwd":"/nonexistent/x"}]}}))' "$TP_R" "$TP_R-lane" "$TP_N")"
tp_snap() {
    PATH="$TP_GHBIN:$TP_HBIN:$PATH" HERDR_BIN_PATH="$TP_HBIN/herdr" TP_PANES="$TP_PANES_JSON" \
        COLUMNS="${1:-60}" python3 "$TP_PLUGIN/tasks_panel.py" snapshot
}
out="$(tp_snap)"; rc=$?
check_rc "snapshot: exits 0" 0 "$rc"
check "snapshot: names the anchored repo" "fixture-project" "$out"
check "snapshot: shows the task" "#12" "$out"
check "snapshot: counts done TODOs" "2/3" "$out"
check "snapshot: shows an open TODO" "[ ] nested" "$out"
check "snapshot: marks done TODOs" "[x] write the test" "$out"
check "snapshot: shows which agents are on the task" "orchestrator, dev" "$out"
check "snapshot: shows how old the update is" "just now" "$out"
check "snapshot: notes a task with no TODOs" "no TODOs" "$out"
check "snapshot: groups by status" "In review" "$out"
check_absent "snapshot: strips terminal escapes" "$ESC" "$out"
check_absent "snapshot: drops the escape payload" "pwned" "$out"
check_absent "snapshot: skips repos without spec-workflow" "notanchored" "$out"
check_rc "snapshot: a repo and its worktree appear once" 1 "$(grep -c "fixture-project" <<<"$out")"
check_rc "snapshot: never runs gh" 0 "$(wc -c <"$TP_GHLOG" | tr -d ' ')"
check_absent "panel source: never calls board.sh" "board.sh" "$(sed -n '/^import/,$p' "$TP_PLUGIN/tasks_panel.py")"
over="$(awk 'length($0) > 24' <<<"$(tp_snap 24)")"
check_rc "snapshot: wraps to the pane width" 0 "${#over}"

TP_STATE="$(git -C "$TP_R" rev-parse --path-format=absolute --git-common-dir)/spec-workflow/task-state"
printf 'not json' >"$TP_STATE/broken.json"
out="$(tp_snap)"; rc=$?
check_rc "corrupt state file: panel still exits 0" 0 "$rc"
check "corrupt state file: the good tasks still show" "#12" "$out"
check "corrupt state file: is reported" "unreadable" "$out"
rm -f "$TP_STATE/broken.json"

(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" set --id 14 --title "Scope shrinks" --status "In progress" --agent dev --todo "keep one" --todo "cut this" --todo "keep two")
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" todo --id 14 --done 1 --agent dev >/dev/null)
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" todo --id 14 --drop 2 --agent dev >/dev/null)
out="$(tp_snap)"
check "dropped TODO: shown dimmed as [-]" "[-] cut this" "$out"
check "dropped TODO: left out of the count" "#14 Scope shrinks (1/2)" "$out"
check "dropped TODO: later TODOs keep their text" "[ ] keep two" "$out"
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" todo --id 14 --undo 1 --agent dev >/dev/null)
check "reopened TODO: lowers the count" "#14 Scope shrinks (0/2)" "$(tp_snap)"
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" todo --id 14 --undo 2 --agent dev >/dev/null)
check "undone drop: counts again" "#14 Scope shrinks (0/3)" "$(tp_snap)"
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" clear --id 14)
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" clear --id 12; bash "$PLUGIN/scripts/task-state.sh" clear --id 13)
check "nothing tracked: says so" "no active tasks" "$(tp_snap)"
out="$(TP_PANES_JSON='{"result":{"panes":[]}}' tp_snap)"
check "no repos open: says so" "No spec-workflow" "$out"

echo "== tasks panel: records of the wrong shape =="
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" set --id 60 --title "Good neighbour" --status "In progress" --agent dev --todo "fine")
TP_DEEP="$(printf '%*s' 200000 '' | tr ' ' '[')"
tp_bad() { # label, payload
    printf '%s' "$2" >"$TP_STATE/9.json"
    out="$(tp_snap 2>&1)"; rc=$?
    check_rc "wrong shape $1: snapshot exits 0" 0 "$rc"
    check "wrong shape $1: the good task still shows" "Good neighbour" "$out"
    check_absent "wrong shape $1: no crash" "Traceback" "$out"
}
tp_bad "agents is a number" '{"id":"x","title":"t","status":"s","agents":5,"worktrees":[],"todos":[]}'
check "wrong shape: a bad record is reported as unreadable" "9.json" "$out"
tp_bad "todos is a number" '{"id":"x","title":"t","status":"s","agents":[],"worktrees":[],"todos":5}'
check "wrong shape: a bad todos list is reported as unreadable" "9.json" "$out"
tp_bad "updatedAt overflows" '{"id":"x","title":"t","status":"s","agents":[],"worktrees":[],"todos":[],"updatedAt":1e999}'
tp_bad "updatedAt has 400 digits" "{\"id\":\"x\",\"title\":\"t\",\"status\":\"s\",\"agents\":[],\"worktrees\":[],\"todos\":[],\"updatedAt\":$(printf '%*s' 400 '' | tr ' ' 9)}"
tp_bad "array" '[]'
tp_bad "number" '5'
tp_bad "nested 200000 deep" "$TP_DEEP"
tp_bad "no fields at all" '{}'
check "wrong shape: an empty record is reported as unreadable" "9.json" "$out"
check_absent "wrong shape: an empty record is not drawn as a task" "#None" "$out"
tp_bad "done is a string" '{"id":"x","title":"t","status":"s","agents":[],"worktrees":[],"todos":[{"text":"a","done":"no"}]}'
check "wrong shape: a TODO with done as a string is reported as unreadable" "9.json" "$out"
check_absent "wrong shape: it is not drawn as ticked" "[x]" "$out"
tp_bad "num is null" '{"id":"x","title":"t","status":"s","agents":[],"worktrees":[],"todos":[{"text":"a","done":false,"num":null}]}'
check "wrong shape: a null number is reported as unreadable" "9.json" "$out"
rm -f "$TP_STATE/9.json"
for shape in '{"result":{"panes":5}}' '{"result":{"panes":["x"]}}' '{"result":{"panes":[null]}}' '{"result":{"panes":[{"cwd":5}]}}' \
    '{"result":{"panes":[{"cwd":["a"]}]}}' '{"result":{"panes":{"a":1}}}' '[]' '5' 'null'; do
    out="$(TP_PANES_JSON="$shape" tp_snap 2>&1)"; rc=$?
    check_rc "pane list answers $shape: snapshot exits 0" 0 "$rc"
    check_absent "pane list answers $shape: no crash" "Traceback" "$out"
done
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" clear --id 60)

echo "== tasks panel: agrees with task-state on what a record is =="
check "panel and task-state accept and refuse the same records" "agree" "$(python3 - "$TP_PLUGIN" "$PLUGIN/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
sys.path.insert(0, sys.argv[2])
import tasks_panel as panel
import task_state as state

def rec(**over):
    base = {'id': 'x', 'title': 't', 'status': 's', 'agents': [], 'worktrees': [], 'todos': []}
    base.update(over)
    return base

def todo(**over):
    base = {'text': 'a', 'done': False}
    base.update(over)
    return base

table = [rec(), rec(todos=[todo()]), rec(todos=[todo(num=3, active=True, activeBy='dev')]), rec(todos=[todo(dropped=True)]),
         [], 5, None, 'text', {}, {'id': 'x'}, rec(id=5), rec(title=None), rec(status=['s']), rec(agents=5), rec(agents=[1]),
         rec(worktrees=None), rec(worktrees=[None]), rec(todos=5), rec(todos=[5]), rec(todos=[None]), rec(todos=[{}]),
         rec(todos=[{'text': 'a'}]), rec(todos=[todo(done='no')]), rec(todos=[todo(done=1)]), rec(todos=[todo(text=5)]),
         rec(todos=[todo(num=None)]), rec(todos=[todo(num=True)]), rec(todos=[todo(num=0)]), rec(todos=[todo(num=-1)]),
         rec(todos=[todo(num=1.0)]), rec(todos=[todo(num='1')]), rec(todos=[todo(active='yes')]), rec(todos=[todo(active=None)]),
         rec(todos=[todo(active=True, activeBy=5)]), rec(todos=[todo(active=True, activeBy=None)])]
bad = [i for i, record in enumerate(table) if panel.readable(record) != state.valid_task(record)]
print('agree' if not bad and any(state.valid_task(r) for r in table) and not all(state.valid_task(r) for r in table) else f'differ at {bad}')
PY
)"

echo "== tasks panel: active TODOs and work order =="
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" set --id 80 --title "Ordered work" --status "In progress" --agent dev --todo "write test" --todo "implement" --todo "gate" >/dev/null)
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" todo --id 80 --add "fix finding" --before gate --agent dev >/dev/null)
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" todo --id 80 --start implement --agent dev >/dev/null)
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" todo --id 80 --start "fix finding" --agent reviewer >/dev/null)
out="$(tp_snap 70)"
check "active TODO: shown with [>] and who has it" "[>] implement · dev" "$out"
check "active TODO: a second one from another agent" "[>] fix finding · reviewer" "$out"
check "Now line: names an active TODO and its agent" "Now: implement · dev" "$out"
check "Now line: one per active TODO" "Now: fix finding · reviewer" "$out"
check_rc "Now line: sits under the task header, above the TODO list" 1 "$(awk '/Ordered work/{h=NR} /Now: implement/{n=NR} /\[ \] write test/{t=NR} END{print (h<n && n<t) ? 1 : 0}' <<<"$out")"
check_rc "work order: a before-insert is listed ahead of what it precedes" 1 "$(awk '/fix finding · reviewer$/ && !/Now/{f=NR} /\[ \] gate/{g=NR} END{print (f && g && f<g) ? 1 : 0}' <<<"$out")"
over="$(awk 'length($0) > 20' <<<"$(tp_snap 20)")"
check_rc "active TODO and Now line: wrap to a narrow pane" 0 "${#over}"
check "narrow pane: the Now line is still there" "Now:" "$(tp_snap 20)"
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" todo --id 80 --done implement --agent dev >/dev/null)
check_absent "done TODO: no longer active" "[>] implement" "$(tp_snap 70)"
check_absent "done TODO: leaves the Now line" "Now: implement" "$(tp_snap 70)"
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" clear --id 80)
printf '%s' '{"id":"81","title":"Old record","status":"In progress","agents":["dev"],"worktrees":[],"todos":[{"text":"before numbers","done":true},{"text":"also old","done":false}],"updatedAt":1}' >"$TP_STATE/81.json"
out="$(tp_snap 70)"
check "legacy record: the panel still reads it" "[x] before numbers" "$out"
check "legacy record: counts are right" "#81 Old record (1/2)" "$out"
rm -f "$TP_STATE/81.json"
styled="$(python3 - "$TP_PLUGIN" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import tasks_panel as t
board = {'name': 'r', 'unreadable': [], 'tasks': [{'id': '1', 'title': 'x', 'status': 's', 'agents': ['dev'], 'todos': [
    {'text': 'doing', 'done': False, 'active': True, 'activeBy': 'dev'}, {'text': 'later', 'done': False}]}]}
lines = t.render([board], 60, color=True)
active = [l for l in lines if '[>] doing' in l]
now = [l for l in lines if 'Now: doing' in l]
print('active-bold' if active and t.BOLD in active[0] else 'active-not-bold')
print('active-not-dim' if active and t.DIM not in active[0] else 'active-dim')
print('now-present' if now else 'now-missing')
PY
)"
check "active TODO: drawn bold" "active-bold" "$styled"
check "active TODO: not dimmed" "active-not-dim" "$styled"
check "Now line: drawn when color is on" "now-present" "$styled"

printf '%s' '{"id":"82","title":"Hand written","status":"In progress","agents":["dev"],"worktrees":[],"todos":[{"text":"finished","done":true,"num":1,"active":true,"activeBy":"ghost-done"},{"text":"cut","done":false,"dropped":true,"num":2,"active":true,"activeBy":"ghost-dropped"},{"text":"live","done":false,"num":3,"active":true,"activeBy":"ev\u001b[31mil\u001b]0;pwned\u0007x"}]}' >"$TP_STATE/82.json"
out="$(tp_snap 70)"
check "active mark on a done TODO: no Now line for it" "Now: live" "$out"
check_absent "active mark on a done TODO: not shown as active" "ghost-done" "$out"
check_absent "active mark on a dropped TODO: not shown as active" "ghost-dropped" "$out"
check_absent "active mark on a done or dropped TODO: no [>]" "[>] finished" "$out"
check_absent "activeBy: terminal escapes are stripped" "$ESC" "$out"
check_absent "activeBy: an escape payload is dropped" "pwned" "$out"
check "activeBy: the readable part is kept" "[>] live" "$out"
rm -f "$TP_STATE/82.json"

echo "== tasks panel: project name lookup =="
TP_PN="$TP_TMP/pn"; mkdir -p "$TP_PN/.neural-network"
tp_name() { # config text -> name, bounded so a hang is a failure, not a stuck suite
    printf '%b' "$1" >"$TP_PN/.neural-network/project.yaml"
    python3 -c 'import signal, sys; signal.alarm(20); sys.path.insert(0, sys.argv[1]); import tasks_panel; print(tasks_panel.project_name(sys.argv[2]))' "$TP_PLUGIN" "$TP_PN"
}
check "project name: read from the project section" "real-name" "$(tp_name 'project:\n  name: real-name\n')"
check "project name: a quoted name loses its quotes" "quoted" "$(tp_name 'project:\n  name: "quoted"\n')"
check "project name: found after blank lines" "late" "$(tp_name 'project:\n  key: v\n\n\n  name: late\n')"
check "project name: no project section falls back to the directory" "pn" "$(tp_name 'schemaVersion: 2\n')"
start=$SECONDS
out="$(tp_name "project:\n  key: v\n$(printf '\\n%.0s' $(seq 1 300))schemaVersion: 2\n")"
check "project name: a large config without a name falls back" "pn" "$out"
[[ $((SECONDS - start)) -lt 10 ]] && fast=fast || fast=slow
check "project name: a large config without a name returns quickly" "fast" "$fast"
start=$SECONDS
out="$(tp_name "project:\n$(printf '   \\n%.0s' $(seq 1 300))x: 1\n")"
[[ $((SECONDS - start)) -lt 10 ]] && fast=fast || fast=slow
check "project name: many whitespace-only lines return quickly" "fast" "$fast"

echo "== tasks panel: repo whose git dir is not <root>/.git =="
TP_S="$TP_TMP/sepdir/work"; mkdir -p "$TP_S" "$TP_TMP/sepdir/gitstore"
git init -q -b main --separate-git-dir "$TP_TMP/sepdir/gitstore/repo.git" "$TP_S"
mkdir -p "$TP_S/.neural-network"; cp "$FIX/valid.project.yaml" "$TP_S/.neural-network/project.yaml"
git -C "$TP_S" add -A; git -C "$TP_S" -c user.name=t -c user.email=t@t commit -q -m init
(cd "$TP_S" && bash "$PLUGIN/scripts/task-state.sh" set --id 31 --title "Separate git dir task" --status "In progress" --agent dev)
TP_PANES_SEP="$(python3 -c 'import json,sys; print(json.dumps({"result":{"panes":[{"cwd":sys.argv[1]}]}}))' "$TP_S")"
out="$(PATH="$TP_HBIN:$PATH" HERDR_BIN_PATH="$TP_HBIN/herdr" TP_PANES="$TP_PANES_SEP" python3 "$TP_PLUGIN/tasks_panel.py" snapshot)"
check "separate git dir: the panel finds the task record" "Separate git dir task" "$out"

echo "== tasks panel: non-UTF-8 project.yaml =="
TP_L1="$TP_TMP/latin1"; git init -q -b main "$TP_L1"; mkdir -p "$TP_L1/.neural-network"
cp "$FIX/valid.project.yaml" "$TP_L1/.neural-network/project.yaml"
git -C "$TP_L1" add -A; git -C "$TP_L1" -c user.name=t -c user.email=t@t commit -q -m init
(cd "$TP_L1" && bash "$PLUGIN/scripts/task-state.sh" set --id 41 --title "Latin one task" --status "In progress" --agent dev)
printf '# caf\351\n' >>"$TP_L1/.neural-network/project.yaml"
TP_PANES_L1="$(python3 -c 'import json,sys; print(json.dumps({"result":{"panes":[{"cwd":sys.argv[1]},{"cwd":sys.argv[2]}]}}))' "$TP_L1" "$TP_S")"
out="$(PATH="$TP_HBIN:$PATH" HERDR_BIN_PATH="$TP_HBIN/herdr" TP_PANES="$TP_PANES_L1" python3 "$TP_PLUGIN/tasks_panel.py" snapshot 2>&1)"; rc=$?
check_rc "latin-1 project.yaml: snapshot exits 0" 0 "$rc"
check_absent "latin-1 project.yaml: no traceback" "Traceback" "$out"
check "latin-1 project.yaml: its own task still shows" "Latin one task" "$out"
check "latin-1 project.yaml: other repos' tasks still show" "Separate git dir task" "$out"

echo "== tasks panel: run (pseudo-terminal) =="
# Drives the real panel in a pty: leaving through any path must restore the terminal.
cat >"$TP_TMP/pty_run.py" <<'PY'
import fcntl, os, pty, re, select, signal, struct, subprocess, sys, termios, time

signal.alarm(120)  # a stuck run ends the test instead of the suite

panel, state, rows = sys.argv[1], sys.argv[2], int(sys.argv[3])
record = os.path.join(state, 'panel-w1-p7.json')
ANSI = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]')


def read_until(fd, needle, seconds):
    """Collect output until `needle` appears or the time is up."""
    out, end = b'', time.time() + seconds
    while needle not in out and time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
    return out


def drain(fd, seconds):
    out, end = b'', time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    return out


def scenario(label, act, close_master=False):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, 40, 0, 0))
    before = termios.tcgetattr(slave)
    env = dict(os.environ, HERDR_PLUGIN_STATE_DIR=state, HERDR_PANE_ID='w1:p7', TERM='xterm')
    child = subprocess.Popen([sys.executable, panel, 'run'], stdin=slave, stdout=slave, stderr=slave,
                             env=env, start_new_session=True, close_fds=True)
    result = {}
    try:
        seen = read_until(master, b'Tasks', 10)
        result['started'] = b'\x1b[?1049h' in seen and b'Tasks' in seen
        result['cbreak'] = termios.tcgetattr(slave) != before
        result['record'] = os.path.exists(record)
        tail = act(child, master, seen)
        if close_master:
            os.close(master)
            master = None
        try:
            child.wait(10)
        except subprocess.TimeoutExpired:
            result['hung'] = True
        if master is not None:
            tail = (tail or b'') + drain(master, 0.3)
        result['rc'] = child.poll()
        result['altscreen'] = b'\x1b[?1049l' in (tail or b'')
        result['cursor'] = b'\x1b[?25h' in (tail or b'')
        try:
            result['restored'] = termios.tcgetattr(slave) == before
        except termios.error:  # the other end is closed, so there is nothing left to restore
            result['restored'] = None
        result['record_gone'] = not os.path.exists(record)
        result['tail'] = tail
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        for fd in (master, slave):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        if os.path.exists(record):
            os.unlink(record)
    return result


def report(label, r, closed=False):
    print(f"{label}: started={int(r.get('started', 0))} cbreak={int(r.get('cbreak', 0))} record={int(r.get('record', 0))} "
          f"hung={int(r.get('hung', 0))} rc={r.get('rc')} restored={int(bool(r.get('restored')))} record_gone={int(r.get('record_gone', 0))}"
          + ('' if closed else f" altscreen={int(r.get('altscreen', 0))} cursor={int(r.get('cursor', 0))}"))


def sent(data):
    def act(child, master, seen):
        os.write(master, data)
        return drain(master, 1.0) if data != b'q' else read_until(master, b'\x1b[?1049l', 5)
    return act


def signalled(sig):
    def act(child, master, seen):
        child.send_signal(sig)
        return read_until(master, b'\x1b[?1049l', 5)
    return act


report('quit with q', scenario('q', sent(b'q')))
report('SIGTERM', scenario('term', signalled(signal.SIGTERM)))
report('SIGINT', scenario('int', signalled(signal.SIGINT)))
report('SIGHUP', scenario('hup', signalled(signal.SIGHUP)))
report('stdin closed', scenario('eof', lambda c, m, s: None, close_master=True), closed=True)


def scrolled(keys, expect_line):
    def act(child, master, seen):
        os.write(master, keys)
        out = drain(master, 1.0)
        frame = ANSI.sub(b'', out.rsplit(b'\x1b[H\x1b[2J', 1)[-1]).split(b'\r\n')
        scrolled.first_body = frame[2].decode('utf-8', 'replace').strip() if len(frame) > 2 else ''
        os.write(master, b'q')
        return out + read_until(master, b'\x1b[?1049l', 5)
    return act


if len(sys.argv) > 4:
    expected = sys.argv[4:]
    for keys, want in (('j', expected[0]), ('jj', expected[1])):
        r = scenario(keys, scrolled(keys.encode(), want))
        print(f"scroll {keys}: first_body={scrolled.first_body.strip()!r} want={want.strip()!r} match={int(scrolled.first_body == want.strip())}")
PY
mkdir -p "$TP_TMP/state-run"
TP_ITEMS=(); for i in $(seq 1 30); do TP_ITEMS+=(--todo "item $i"); done
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" set --id 21 --title "Long list" --status "In progress" --agent dev "${TP_ITEMS[@]}")
TP_PANES_PTY="$(python3 -c 'import json,sys; print(json.dumps({"result":{"panes":[{"cwd":sys.argv[1]}]}}))' "$TP_R")"
export TP_PANES="$TP_PANES_PTY" HERDR_BIN_PATH="$TP_HBIN/herdr"
TP_SNAP_LINES=(); while IFS= read -r pty_line; do TP_SNAP_LINES+=("$pty_line"); done < <(COLUMNS=39 python3 "$TP_PLUGIN/tasks_panel.py" snapshot)
# a job started with `cmd &` inherits SIGINT ignored; the panel must still quit on it
pty_out="$(trap '' INT; python3 "$TP_TMP/pty_run.py" "$TP_PLUGIN/tasks_panel.py" "$TP_TMP/state-run" 8 "${TP_SNAP_LINES[1]}" "${TP_SNAP_LINES[2]}" 2>&1)"
unset TP_PANES HERDR_BIN_PATH
while IFS= read -r pty_line; do echo "     $pty_line"; done <<<"$pty_out"
for label in "quit with q" "SIGTERM" "SIGINT" "SIGHUP"; do
    line="$(grep "^$label:" <<<"$pty_out")"
    check "run, $label: the panel started and set up the terminal" "started=1 cbreak=1 record=1" "$line"
    check "run, $label: exits 0 without hanging" "hung=0 rc=0" "$line"
    check "run, $label: leaves the alternate screen and shows the cursor" "altscreen=1 cursor=1" "$line"
    check "run, $label: restores the terminal settings" "restored=1" "$line"
    check "run, $label: removes its panel record" "record_gone=1" "$line"
done
line="$(grep '^stdin closed:' <<<"$pty_out")"
check "run, stdin closed: exits 0 instead of spinning or crashing" "hung=0 rc=0" "$line"
check "run, stdin closed: removes its panel record" "record_gone=1" "$line"
check_rc "run, scroll j shows the second line" 1 "$(grep -c '^scroll j: .*match=1' <<<"$pty_out")"
check_rc "run, a read of jj scrolls twice" 1 "$(grep -c '^scroll jj: .*match=1' <<<"$pty_out")"
(cd "$TP_R" && bash "$PLUGIN/scripts/task-state.sh" clear --id 21)

rm -rf "$TP_TMP"
