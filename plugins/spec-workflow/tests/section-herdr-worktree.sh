#!/usr/bin/env bash
# section-herdr-worktree.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced _lib.sh
# (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky.
# Covers the `herdr` config object, herdr-worktree.sh add/remove (task lanes)
# and its subagent-hook mode. A stub `herdr` on PATH keeps this hermetic.

declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }

HW_TOOL="$PLUGIN/scripts/herdr-worktree.sh"
HW_TMP="$(mktemp -d)"
HW_BIN="$HW_TMP/bin"; mkdir -p "$HW_BIN"
HW_LOG="$HW_TMP/herdr.log"
export XDG_CACHE_HOME_ORIG="${XDG_CACHE_HOME:-}"

# Stub modes (HERDR_STUB): ok | down | fail-after-create | error (answers an error, does nothing)
# | branch-only (leaves the branch behind, then errors) | noop (answers success, does nothing)
cat >"$HW_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$HERDR_STUB_LOG"
mode="${HERDR_STUB:-ok}"
if [[ "$mode" == down ]]; then
    echo '{"id":"x","error":{"code":"server_not_running","message":"no server"}}' >&2
    exit 1
fi
cmd="$1 $2"; shift 2
cwd="" path="" branch="" base="" ws=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cwd) cwd="$2"; shift 2 ;;
        --path) path="$2"; shift 2 ;;
        --branch) branch="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        --workspace) ws="$2"; shift 2 ;;
        --label) shift 2 ;;
        --force|--no-focus) shift ;;
        *) ws="$1"; shift ;;
    esac
done
# Real herdr only starts worktree actions from the primary checkout.
if [[ "$cmd" == "worktree create" || "$cmd" == "worktree open" ]] && [[ -f "$cwd/.git" ]] && grep -q '/worktrees/' "$cwd/.git"; then
    echo '{"error":{"code":"linked_worktree_source"}}' >&2
    exit 1
fi
case "$mode:$cmd" in
    "error:worktree create") echo '{"error":{"code":"internal"}}' >&2; exit 1 ;;
    "branch-only:worktree create")
        git -C "$cwd" branch "$branch" ${base:+"$base"}
        echo '{"error":{"code":"internal"}}' >&2; exit 1 ;;
    "noop:worktree create" | "noop:worktree remove") echo '{"result":{}}'; exit 0 ;;
esac
case "$cmd" in
    "worktree create")
        if git -C "$cwd" show-ref --verify --quiet "refs/heads/$branch"; then
            git -C "$cwd" worktree add -q "$path" "$branch" || exit 1
        else
            git -C "$cwd" worktree add -q "$path" -b "$branch" ${base:+"$base"} || exit 1
        fi
        if [[ "$mode" == fail-after-create ]]; then
            echo '{"error":{"code":"connection_lost"}}' >&2
            exit 1
        fi
        printf '{"result":{"type":"worktree_created","workspace":{"workspace_id":"w5"}}}\n'
        ;;
    "worktree open")
        printf '{"result":{"already_open":%s,"workspace":{"workspace_id":"w6"}}}\n' "${HERDR_STUB_OPEN:-false}"
        ;;
    "worktree remove")
        git -C "$HERDR_STUB_ROOT" worktree remove --force "$(cat "$HERDR_STUB_WSPATH")"
        printf '{"result":{"type":"worktree_removed","workspace_id":"%s"}}\n' "$ws"
        ;;
    "workspace list")
        if [[ -n "${HERDR_STUB_LISTJSON:-}" ]]; then printf '%s\n' "$HERDR_STUB_LISTJSON"; exit 0; fi
        p="$(cat "$HERDR_STUB_WSPATH" 2>/dev/null)"
        printf '{"result":{"workspaces":[{"workspace_id":"w7","worktree":{"checkout_path":"%s","is_linked_worktree":true}}]}}\n' "$p"
        ;;
    "workspace get")
        printf '{"result":{"workspace":{"workspace_id":"%s","worktree":{"checkout_path":"%s"}}}}\n' "$ws" "${HERDR_STUB_GETPATH:-}"
        ;;
    "workspace close")
        printf '{"result":{"type":"ok"}}\n'
        ;;
esac
STUB
chmod +x "$HW_BIN/herdr"

hw_repo() { # hw_repo <dir> <herdr-yaml-lines...>
    local d="$1"; shift
    git init -q -b main "$d"
    git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    mkdir -p "$d/.neural-network"
    cp "$FIX/valid.project.yaml" "$d/.neural-network/project.yaml"
    local line
    for line in "$@"; do printf '%s\n' "$line" >>"$d/.neural-network/project.yaml"; done
}
hw() { PATH="$HW_BIN:$PATH" HERDR_STUB_LOG="$HW_LOG" bash "$HW_TOOL" "$@"; }
hw_log_reset() { : >"$HW_LOG"; }

echo "== herdr config: validator =="
HV="$HW_TMP/v"; hw_repo "$HV" "herdr:" "    enabled: true" "    worktrees:" "        taskLanes: true" "        subagents: true"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$HV/.neural-network/project.yaml" 2>&1)"; rc=$?
check_rc "valid herdr object passes validate-config" 0 "$rc"
check_absent "valid herdr object: the validator says nothing about herdr" "herdr" "$(grep -i 'herdr' <<<"$out" || true)"
HV2="$HW_TMP/v2"; hw_repo "$HV2" "herdr:" "    enabled: yes-please" "    bogus: 1" "    worktrees:" "        subagents: 1" "        other: true"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$HV2/.neural-network/project.yaml" 2>&1 || true)"
check "non-boolean herdr.enabled is rejected" "herdr.enabled" "$out"
check "unknown herdr key is rejected" "herdr.bogus" "$out"
check "non-boolean herdr.worktrees.subagents is rejected" "herdr.worktrees.subagents" "$out"
check "unknown herdr.worktrees key is rejected" "herdr.worktrees.other" "$out"
schema_has="$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); h=s["properties"]["herdr"]; print(sorted(h["properties"]), sorted(h["properties"]["worktrees"]["properties"]), h["additionalProperties"])' "$PLUGIN/schemas/project-config.schema.json" 2>&1)"
check "schema declares herdr.enabled/worktrees" "['enabled', 'worktrees']" "$schema_has"
check "schema declares taskLanes/subagents" "['subagents', 'taskLanes']" "$schema_has"

echo "== herdr-worktree add: routing =="
HA="$HW_TMP/a"; hw_repo "$HA" "herdr:" "    enabled: true"
hw_log_reset
out="$(hw add --root "$HA" --path .claude/worktrees/t1 --branch cp/1-a --base main 2>/dev/null)"; rc=$?
check_rc "enabled: add succeeds" 0 "$rc"
check "enabled: add prints the absolute path" "$HA/.claude/worktrees/t1" "$out"
check "enabled: routes through herdr worktree create" "worktree create" "$(cat "$HW_LOG")"
check "enabled: never steals focus" "--no-focus" "$(cat "$HW_LOG")"
check_absent "enabled: never grants repository trust on its own" "--trust-repository" "$(cat "$HW_LOG")"
check "enabled: the worktree exists on the requested branch" "cp/1-a" "$(git -C "$HA" worktree list)"

HO="$HW_TMP/o"; hw_repo "$HO"
hw_log_reset
hw add --root "$HO" --path .claude/worktrees/t1 --branch cp/1-a >/dev/null 2>&1; rc=$?
check_rc "herdr object absent: add succeeds" 0 "$rc"
check_absent "herdr object absent: never calls herdr" "worktree" "$(cat "$HW_LOG")"
check "herdr object absent: git created the worktree" "cp/1-a" "$(git -C "$HO" worktree list)"

HD="$HW_TMP/d"; hw_repo "$HD" "herdr:" "    enabled: false" "    worktrees:" "        subagents: true"
hw_log_reset
hw add --root "$HD" --path wt --branch b1 >/dev/null 2>&1
check_absent "enabled: false: never calls herdr" "worktree" "$(cat "$HW_LOG")"
out="$(HW_EVT='{"hook_event_name":"SubagentStart","agent_id":"abc","agent_type":"x","cwd":"'"$HD"'/.claude/worktrees/agent-abc"}'; mkdir -p "$HD/.claude/worktrees/agent-abc"; hw subagent-hook <<<"$HW_EVT")"; rc=$?
check_rc "enabled: false: subagent hook is a silent no-op" 0 "$rc"
check_absent "enabled: false: subagent hook never calls herdr" "worktree" "$(cat "$HW_LOG")"

HL="$HW_TMP/l"; hw_repo "$HL" "herdr:" "    enabled: true" "    worktrees:" "        taskLanes: false"
hw_log_reset
hw add --root "$HL" --path wt --branch b1 >/dev/null 2>&1
check_absent "taskLanes: false: add stays on git" "worktree" "$(cat "$HW_LOG")"
check "taskLanes: false: git created the worktree" "b1" "$(git -C "$HL" worktree list)"

HLK="$HW_TMP/lk"; hw_repo "$HLK" "herdr:" "    enabled: true"
git -C "$HLK" add -A; git -C "$HLK" -c user.name=t -c user.email=t@t commit -q -m cfg
git -C "$HLK" worktree add -q --detach "$HLK/lane"
hw_log_reset
err="$(hw add --root "$HLK/lane" --path "$HLK/wt2" --branch b2 --base main 2>&1 >/dev/null)"; rc=$?
check_rc "add from a linked lane: succeeds" 0 "$rc"
check "add from a linked lane: herdr starts from the primary checkout" "worktree create --branch b2 --base main --cwd $HLK --path" "$(cat "$HW_LOG")"
check_absent "add from a linked lane: no git fallback" "fell back to git" "$err"

echo "== herdr-worktree add: base from the invoking checkout =="
HB="$HW_TMP/hb"; hw_repo "$HB" "herdr:" "    enabled: true"
git -C "$HB" add -A; git -C "$HB" -c user.name=t -c user.email=t@t commit -q -m cfg
git -C "$HB" worktree add -q "$HB/lane" -b laneb
git -C "$HB/lane" -c user.name=t -c user.email=t@t commit -q --allow-empty -m ahead
lane_head="$(git -C "$HB/lane" rev-parse HEAD)"
hw_log_reset
hw add --root "$HB/lane" --path "$HB/wt3" --branch b3 >/dev/null 2>&1; rc=$?
check_rc "add without --base from a linked checkout: succeeds" 0 "$rc"
check "add without --base: herdr gets the invoking checkout's HEAD as --base" "--base $lane_head" "$(cat "$HW_LOG")"
check "add without --base: the lane starts at the invoking checkout's HEAD" "$lane_head" "$(git -C "$HB/wt3" rev-parse HEAD)"

echo "== herdr-worktree add: failure handling =="
HF="$HW_TMP/f"; hw_repo "$HF" "herdr:" "    enabled: true"
err="$(HERDR_STUB=down hw add --root "$HF" --path wt --branch b1 2>&1 >/dev/null)"; rc=$?
check_rc "server down: add still succeeds" 0 "$rc"
check "server down: says it fell back" "fell back to git" "$err"
check "server down: git created the worktree" "b1" "$(git -C "$HF" worktree list)"
HNP="$HW_TMP/np"; hw_repo "$HNP" "herdr:" "    enabled: true"
mkdir -p "$HW_TMP/nobin"; ln -sf "$(command -v git)" "$HW_TMP/nobin/git"; ln -sf "$(command -v python3)" "$HW_TMP/nobin/python3"; ln -sf "$(command -v bash)" "$HW_TMP/nobin/bash"; ln -sf "$(command -v dirname)" "$HW_TMP/nobin/dirname"
err="$(PATH="$HW_TMP/nobin" "$HW_TMP/nobin/bash" "$HW_TOOL" add --root "$HNP" --path wt --branch b1 2>&1 >/dev/null)"; rc=$?
check_rc "herdr not installed: add still succeeds" 0 "$rc"
check "herdr not installed: says it fell back" "fell back to git" "$err"

HM="$HW_TMP/m"; hw_repo "$HM" "herdr:" "    enabled: true"
err="$(HERDR_STUB=fail-after-create hw add --root "$HM" --path wt --branch b1 2>&1 >/dev/null)"; rc=$?
check_rc "herdr errors after creating: treated as created" 0 "$rc"
check_absent "herdr errors after creating: no second git attempt" "fell back to git" "$err"

HE="$HW_TMP/e"; hw_repo "$HE" "herdr:" "    enabled: true"
err="$(HERDR_STUB=error hw add --root "$HE" --path wt --branch b1 2>&1 >/dev/null)"; rc=$?
check_rc "herdr answers an error: add still succeeds" 0 "$rc"
check "herdr answers an error: the notice says herdr could not create it" "herdr could not create the worktree" "$err"
check_absent "herdr answers an error: the notice does not claim herdr is unavailable" "unavailable" "$err"
check "herdr answers an error: git created the worktree" "b1" "$(git -C "$HE" worktree list)"
check "herdr not installed: the notice says so" "herdr is not installed" "$(PATH="$HW_TMP/nobin" "$HW_TMP/nobin/bash" "$HW_TOOL" add --root "$HNP" --path wt2 --branch b9 2>&1 >/dev/null)"
HBO="$HW_TMP/bo"; hw_repo "$HBO" "herdr:" "    enabled: true"
err="$(HERDR_STUB=branch-only hw add --root "$HBO" --path wt --branch b1 2>&1 >/dev/null)"; rc=$?
check_rc "herdr fails but left the branch behind: add still succeeds" 0 "$rc"
check "herdr fails but left the branch behind: git uses the existing branch" "b1" "$(git -C "$HBO" worktree list)"
HNO="$HW_TMP/no"; hw_repo "$HNO" "herdr:" "    enabled: true"
err="$(HERDR_STUB=noop hw add --root "$HNO" --path wt --branch b1 2>&1 >/dev/null)"; rc=$?
check_rc "herdr says OK but made nothing: add succeeds" 0 "$rc"
check "herdr says OK but made nothing: git creates the worktree" "$HNO/wt" "$(git -C "$HNO" worktree list)"
check "herdr says OK but made nothing: says it fell back" "fell back to git" "$err"

HX="$HW_TMP/x"; hw_repo "$HX" "herdr:" "    enabled: true"
hw add --root "$HX" --path wt --branch b1 >/dev/null 2>&1
hw_log_reset
err="$(hw add --root "$HX" --path wt --branch b2 2>&1 >/dev/null)"; rc=$?
check_rc "existing worktree path is refused, never reused" 1 "$rc"
check "existing worktree path names the conflict" "already" "$err"
check_absent "existing worktree path never reaches herdr" "worktree create" "$(cat "$HW_LOG")"

echo "== herdr-worktree add: detached lanes =="
HDT="$HW_TMP/dt"; hw_repo "$HDT" "herdr:" "    enabled: true"
hw_log_reset
out="$(hw add --root "$HDT" --path lane --detach --base main 2>/dev/null)"; rc=$?
check_rc "detached: add succeeds" 0 "$rc"
check "detached: opened in herdr" "worktree open" "$(cat "$HW_LOG")"
check_absent "detached: never uses create (it would invent a branch)" "worktree create" "$(cat "$HW_LOG")"
check "detached: the worktree really is detached" "detached" "$(git -C "$HDT" worktree list)"
HDT2="$HW_TMP/dt2"; hw_repo "$HDT2" "herdr:" "    enabled: true"
HERDR_STUB=down hw add --root "$HDT2" --path lane --detach >/dev/null 2>&1; rc=$?
check_rc "detached + server down: worktree still created" 0 "$rc"

echo "== herdr-worktree remove =="
HR="$HW_TMP/r"; hw_repo "$HR" "herdr:" "    enabled: true"
hw add --root "$HR" --path wt --branch b1 >/dev/null 2>&1
printf '%s' "$HR/wt" >"$HW_TMP/wspath"
hw_log_reset
HERDR_STUB_ROOT="$HR" HERDR_STUB_WSPATH="$HW_TMP/wspath" hw remove --root "$HR" --path wt >/dev/null 2>&1; rc=$?
check_rc "enabled: remove succeeds" 0 "$rc"
check "enabled: remove goes through the owning workspace" "worktree remove --workspace w7" "$(cat "$HW_LOG")"
check_absent "enabled: the worktree is gone" "$HR/wt" "$(git -C "$HR" worktree list)"

# Removing from inside the lane: the stub deletes the directory, as herdr does.
HRI="$HW_TMP/ri"; hw_repo "$HRI" "herdr:" "    enabled: true"
git -C "$HRI" add -A; git -C "$HRI" -c user.name=t -c user.email=t@t commit -q -m cfg
hw add --root "$HRI" --path wt --branch b1 >/dev/null 2>&1
printf '%s' "$HRI/wt" >"$HW_TMP/wspathi"
hw_log_reset
err="$(cd "$HRI/wt" && HERDR_STUB_ROOT="$HRI" HERDR_STUB_WSPATH="$HW_TMP/wspathi" PATH="$HW_BIN:$PATH" HERDR_STUB_LOG="$HW_LOG" bash "$HW_TOOL" remove --path "$HRI/wt" 2>&1)"; rc=$?
check_rc "remove from inside the lane: succeeds" 0 "$rc"
check_absent "remove from inside the lane: no error text" "rror" "$err"
check_absent "remove from inside the lane: the lane is gone" "$HRI/wt" "$(git -C "$HRI" worktree list)"
check "remove from inside the lane: went through herdr" "worktree remove --workspace w7" "$(cat "$HW_LOG")"
HRG="$HW_TMP/rg"; hw_repo "$HRG" "herdr:" "    enabled: true"
git -C "$HRG" add -A; git -C "$HRG" -c user.name=t -c user.email=t@t commit -q -m cfg
git -C "$HRG" worktree add -q "$HRG/wt" -b b1
err="$(cd "$HRG/wt" && PATH="$HW_BIN:$PATH" HERDR_STUB_LOG="$HW_LOG" HERDR_STUB=down bash "$HW_TOOL" remove --path "$HRG/wt" 2>&1)"; rc=$?
check_rc "remove from inside the lane, herdr down: git fallback succeeds" 0 "$rc"
check_absent "remove from inside the lane, herdr down: the lane is gone" "$HRG/wt" "$(git -C "$HRG" worktree list)"

HR2="$HW_TMP/r2"; hw_repo "$HR2" "herdr:" "    enabled: true"
git -C "$HR2" worktree add -q "$HR2/wt" -b b1
printf '%s' "/somewhere/else" >"$HW_TMP/wspath2"
hw_log_reset
HERDR_STUB_ROOT="$HR2" HERDR_STUB_WSPATH="$HW_TMP/wspath2" hw remove --root "$HR2" --path wt >/dev/null 2>&1; rc=$?
check_rc "no workspace for the path: remove succeeds" 0 "$rc"
check_absent "no workspace for the path: herdr remove is not called" "worktree remove" "$(cat "$HW_LOG")"
check_absent "no workspace for the path: git removed it" "$HR2/wt" "$(git -C "$HR2" worktree list)"

HR3="$HW_TMP/r3"; hw_repo "$HR3" "herdr:" "    enabled: true"
git -C "$HR3" worktree add -q "$HR3/wt" -b b1
HERDR_STUB=down hw remove --root "$HR3" --path wt >/dev/null 2>&1; rc=$?
check_rc "server down: remove still succeeds" 0 "$rc"
check_absent "server down: git removed it" "$HR3/wt" "$(git -C "$HR3" worktree list)"

HR4="$HW_TMP/r4"; hw_repo "$HR4"
git -C "$HR4" worktree add -q "$HR4/wt" -b b1
echo dirty >"$HR4/wt/untracked.txt"
hw remove --root "$HR4" --path wt >/dev/null 2>&1; rc=$?
check_rc "dirty worktree without --force is refused" 1 "$rc"
hw remove --root "$HR4" --path wt --force >/dev/null 2>&1; rc=$?
check_rc "--force removes a dirty worktree" 0 "$rc"

HR5="$HW_TMP/r5"; hw_repo "$HR5" "herdr:" "    enabled: true"
git -C "$HR5" worktree add -q "$HR5/wt" -b b1
printf '%s' "$HR5/wt" >"$HW_TMP/wspath5"
err="$(HERDR_STUB=noop HERDR_STUB_ROOT="$HR5" HERDR_STUB_WSPATH="$HW_TMP/wspath5" hw remove --root "$HR5" --path wt 2>&1 >/dev/null)"; rc=$?
check_rc "herdr says OK but removed nothing: remove succeeds" 0 "$rc"
check_absent "herdr says OK but removed nothing: git removes the worktree" "$HR5/wt" "$(git -C "$HR5" worktree list)"
check "herdr says OK but removed nothing: says it tried git" "trying git" "$err"

HR6="$HW_TMP/r6"; hw_repo "$HR6" "herdr:" "    enabled: true"
for shape in '{"result":{"workspaces":["x"]}}' '{"result":{"workspaces":5}}' '{"result":{"workspaces":[{"worktree":"s"}]}}' \
    '{"result":{"workspaces":[{"worktree":{"checkout_path":5,"is_linked_worktree":true}}]}}' '{"result":{"workspaces":[null]}}' '{"result":{"workspaces":{"a":1}}}'; do
    git -C "$HR6" worktree add -q "$HR6/wt" -b shape
    out="$(HERDR_STUB_LISTJSON="$shape" hw remove --root "$HR6" --path wt 2>&1)"; rc=$?
    check_rc "workspace list $shape: remove succeeds" 0 "$rc"
    check_absent "workspace list $shape: no crash" "Traceback" "$out"
    check_absent "workspace list $shape: git removed the worktree" "$HR6/wt" "$(git -C "$HR6" worktree list)"
    git -C "$HR6" worktree remove --force "$HR6/wt" 2>/dev/null; git -C "$HR6" branch -q -D shape 2>/dev/null
done

HR7="$HW_TMP/r7"; hw_repo "$HR7" "herdr:" "    enabled: true"
for id in 5 '["x"]' '{"a":1}' true null '""'; do
    git -C "$HR7" worktree add -q "$HR7/wt" -b idshape
    shape="{\"result\":{\"workspaces\":[{\"workspace_id\":$id,\"worktree\":{\"checkout_path\":\"$HR7/wt\",\"is_linked_worktree\":true}}]}}"
    hw_log_reset
    out="$(HERDR_STUB_LISTJSON="$shape" hw remove --root "$HR7" --path wt 2>&1)"; rc=$?
    check_rc "workspace_id $id: remove succeeds" 0 "$rc"
    check_absent "workspace_id $id: no crash" "Traceback" "$out"
    check_absent "workspace_id $id: herdr remove is not called with it" "worktree remove" "$(cat "$HW_LOG")"
    check_absent "workspace_id $id: git removed the worktree" "$HR7/wt" "$(git -C "$HR7" worktree list)"
    git -C "$HR7" worktree remove --force "$HR7/wt" 2>/dev/null; git -C "$HR7" branch -q -D idshape 2>/dev/null
done

HRL="$HW_TMP/rl"; hw_repo "$HRL" "herdr:" "    enabled: true" "    worktrees:" "        taskLanes: false"
git -C "$HRL" worktree add -q "$HRL/wt" -b b1
printf '%s' "$HRL/wt" >"$HW_TMP/wspathl"
hw_log_reset
HERDR_STUB_ROOT="$HRL" HERDR_STUB_WSPATH="$HW_TMP/wspathl" hw remove --root "$HRL" --path wt >/dev/null 2>&1; rc=$?
check_rc "taskLanes: false: remove succeeds" 0 "$rc"
check "taskLanes: false: remove still closes a workspace herdr has open for the path" "worktree remove --workspace w7" "$(cat "$HW_LOG")"
check_absent "taskLanes: false: the worktree is gone" "$HRL/wt" "$(git -C "$HRL" worktree list)"

echo "== herdr-worktree: where the primary checkout is =="
HSRC="$HW_TMP/subsrc"; hw_repo "$HSRC" "herdr:" "    enabled: true"; git -C "$HSRC" add -A; git -C "$HSRC" -c user.name=t -c user.email=t@t commit -q -m cfg
HSUP="$HW_TMP/super"; git init -q -b main "$HSUP"; git -C "$HSUP" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$HSUP" -c protocol.file.allow=always -c user.name=t -c user.email=t@t submodule add -q "$HSRC" sub >/dev/null 2>&1
hw_log_reset
err="$(hw add --root "$HSUP/sub" --path ../sublane --branch s1 2>&1 >/dev/null)"; rc=$?
check_rc "submodule: add succeeds" 0 "$rc"
check "submodule: herdr starts from the submodule checkout" "--cwd $(git -C "$HSUP/sub" rev-parse --show-toplevel) " "$(cat "$HW_LOG")"
check "submodule: the lane is a worktree of the submodule" "s1" "$(git -C "$HSUP/sub" worktree list)"
check_absent "submodule: the superproject gets no lane" "s1" "$(git -C "$HSUP" worktree list)"

HSG="$HW_TMP/sg"; mkdir -p "$HSG"
git init -q -b main --separate-git-dir "$HSG/store.git" "$HSG/work"
git -C "$HSG/work" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$HSG/work/.neural-network"; cp "$FIX/valid.project.yaml" "$HSG/work/.neural-network/project.yaml"; printf 'herdr:\n    enabled: true\n' >>"$HSG/work/.neural-network/project.yaml"
hw_log_reset
err="$(hw add --root "$HSG/work" --path wt --branch sg1 2>&1 >/dev/null)"; rc=$?
check_rc "separate git dir: add succeeds" 0 "$rc"
check "separate git dir: herdr starts from the checkout, not the git dir's parent" "--cwd $(git -C "$HSG/work" rev-parse --show-toplevel) " "$(cat "$HW_LOG")"
check_absent "separate git dir: herdr is not reported unavailable" "fell back" "$err"

HBS="$HW_TMP/bsrc"; hw_repo "$HBS" "herdr:" "    enabled: true" "    worktrees:" "        subagents: true"
git -C "$HBS" add -A; git -C "$HBS" -c user.name=t -c user.email=t@t commit -q -m cfg
git clone -q --bare "$HBS" "$HW_TMP/bare.git"
git -C "$HW_TMP/bare.git" worktree add -q "$HW_TMP/bare-main" main
hw_log_reset
err="$(hw add --root "$HW_TMP/bare-main" --path ../bare-lane --branch bl1 2>&1 >/dev/null)"; rc=$?
check_rc "bare repo: add succeeds" 0 "$rc"
check "bare repo: git creates the lane" "bl1" "$(git -C "$HW_TMP/bare.git" worktree list)"
check_absent "bare repo: herdr is not called from a guessed directory" "worktree create" "$(cat "$HW_LOG")"
check "bare repo: the notice names the real reason" "primary checkout" "$err"
check_absent "bare repo: the notice does not blame herdr" "unavailable" "$err"
git -C "$HW_TMP/bare.git" worktree add -q "$HW_TMP/bare-main/.claude/worktrees/agent-bbb333" -b wa-bbb
hw_log_reset
export XDG_CACHE_HOME="$HW_TMP/cache"
out="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"SubagentStart","agent_id":"bbb333","agent_type":"x","cwd":sys.argv[1]}))' "$HW_TMP/bare-main/.claude/worktrees/agent-bbb333" | hw subagent-hook 2>&1)"; rc=$?
check_rc "bare repo: the subagent hook exits 0" 0 "$rc"
check_rc "bare repo: the subagent hook prints nothing" 0 "${#out}"
check_absent "bare repo: the subagent hook calls no herdr" "worktree open" "$(cat "$HW_LOG")"

echo "== subagent-hook =="
HS="$HW_TMP/s"; hw_repo "$HS" "herdr:" "    enabled: true" "    worktrees:" "        subagents: true"
HS_WT="$HS/.claude/worktrees/agent-aaa111"
git -C "$HS" worktree add -q "$HS_WT" -b worktree-agent-aaa111
cp "$HS/.neural-network/project.yaml" "$HW_TMP/s.yaml"; mkdir -p "$HS_WT/.neural-network"; cp "$HW_TMP/s.yaml" "$HS_WT/.neural-network/project.yaml"
hs_evt() { python3 -c 'import json,sys; print(json.dumps({"hook_event_name":sys.argv[1],"agent_id":sys.argv[2],"agent_type":"general-purpose","cwd":sys.argv[3]}))' "$1" "$2" "$3"; }
export XDG_CACHE_HOME="$HW_TMP/cache"

hw_log_reset
out="$(hs_evt SubagentStart aaa111 "$HS_WT" | hw subagent-hook 2>&1)"; rc=$?
check_rc "start: exits 0" 0 "$rc"
check "start: opens the agent worktree in herdr" "worktree open --cwd $HS --path $HS_WT" "$(cat "$HW_LOG")"
check "start: never steals focus" "--no-focus" "$(cat "$HW_LOG")"
check_rc "start: prints nothing" 0 "${#out}"

hw_log_reset
out="$(hs_evt SubagentStop aaa111 "$HS_WT" | HERDR_STUB_GETPATH="$HS_WT" hw subagent-hook 2>&1)"; rc=$?
check_rc "stop: exits 0" 0 "$rc"
check "stop: closes the workspace the hook opened" "workspace close w6" "$(cat "$HW_LOG")"
check "stop: leaves the worktree alone" "$HS_WT" "$(git -C "$HS" worktree list)"
hw_log_reset
hs_evt SubagentStop aaa111 "$HS_WT" | HERDR_STUB_GETPATH="$HS_WT" hw subagent-hook >/dev/null 2>&1
check_absent "stop again: state is gone, closes nothing" "workspace close" "$(cat "$HW_LOG")"

hw_log_reset
hs_evt SubagentStart bbb222 "$HS" | hw subagent-hook >/dev/null 2>&1; rc=$?
check_rc "non-isolated subagent: exits 0" 0 "$rc"
check_absent "non-isolated subagent: nothing opened" "worktree open" "$(cat "$HW_LOG")"

hs_evt SubagentStart ccc333 "$HS/.claude/worktrees/task-lane" | hw subagent-hook >/dev/null 2>&1
check_absent "subagent sharing a task lane: nothing opened" "worktree open" "$(cat "$HW_LOG")"

hw_log_reset
hs_evt SubagentStart aaa111 "$HS_WT" | hw subagent-hook >/dev/null 2>&1
mkdir -p "$HS_WT/sub/dir"
hs_evt SubagentStop aaa111 "$HS_WT/sub/dir" | HERDR_STUB_GETPATH="$HS_WT" hw subagent-hook >/dev/null 2>&1
check "stop from a subdirectory of the worktree: still closes the workspace" "workspace close w6" "$(cat "$HW_LOG")"
check_absent "stop from a subdirectory: the state is gone" "aaa111" "$(ls "$XDG_CACHE_HOME/spec-workflow/herdr-subagents" 2>/dev/null)"
hw_log_reset
hs_evt SubagentStart aaa111 "$HS_WT/sub/dir" | hw subagent-hook >/dev/null 2>&1
check_absent "start from a subdirectory: still does not open a workspace" "worktree open" "$(cat "$HW_LOG")"

hw_log_reset
HERDR_STUB_OPEN=true; export HERDR_STUB_OPEN
hs_evt SubagentStart aaa111 "$HS_WT" | hw subagent-hook >/dev/null 2>&1
hs_evt SubagentStop aaa111 "$HS_WT" | HERDR_STUB_GETPATH="$HS_WT" hw subagent-hook >/dev/null 2>&1
check_absent "already-open workspace is not ours: never closed" "workspace close" "$(cat "$HW_LOG")"
unset HERDR_STUB_OPEN

hw_log_reset
hs_evt SubagentStart aaa111 "$HS_WT" | hw subagent-hook >/dev/null 2>&1
hs_evt SubagentStop aaa111 "$HS_WT" | HERDR_STUB_GETPATH="/reused/by/another/workspace" hw subagent-hook >/dev/null 2>&1
check_absent "workspace id now points elsewhere: never closed" "workspace close" "$(cat "$HW_LOG")"

HSO="$HW_TMP/so"; hw_repo "$HSO" "herdr:" "    enabled: true"
HSO_WT="$HSO/.claude/worktrees/agent-ddd444"; git -C "$HSO" worktree add -q "$HSO_WT" -b wa-ddd
mkdir -p "$HSO_WT/.neural-network"; cp "$HSO/.neural-network/project.yaml" "$HSO_WT/.neural-network/project.yaml"
hw_log_reset
hs_evt SubagentStart ddd444 "$HSO_WT" | hw subagent-hook >/dev/null 2>&1
check_absent "subagents defaults to off while enabled" "worktree open" "$(cat "$HW_LOG")"

hs_evt SubagentStart aaa111 "$HS_WT" | HERDR_STUB=down hw subagent-hook >/dev/null 2>&1; rc=$?
check_rc "server down: hook still exits 0" 0 "$rc"
hw subagent-hook <<<'not json' >/dev/null 2>&1; rc=$?
check_rc "garbage stdin: hook still exits 0" 0 "$rc"
hs_evt SubagentStart '../../evil' "$HS_WT" | hw subagent-hook >/dev/null 2>&1; rc=$?
check_rc "hostile agent id: hook still exits 0" 0 "$rc"
check_absent "hostile agent id: no state escapes the cache dir" "evil" "$(find "$HW_TMP" -name '*evil*' 2>/dev/null)"
# An id that passes the directory-name match but not the id pattern: only the pattern stops it.
HS_ODD="$HS/.claude/worktrees/agent-a.b"; mkdir -p "$HS_ODD/.neural-network"; cp "$HW_TMP/s.yaml" "$HS_ODD/.neural-network/project.yaml"
hw_log_reset
hs_evt SubagentStart a.b "$HS_ODD" | hw subagent-hook >/dev/null 2>&1; rc=$?
check_rc "odd agent id: hook still exits 0" 0 "$rc"
check_absent "odd agent id: nothing is opened for an id outside the pattern" "worktree open" "$(cat "$HW_LOG")"

# A herdr blip while stopping must not leak the workspace: the state stays until the close worked.
hw_log_reset
hs_evt SubagentStart aaa111 "$HS_WT" | hw subagent-hook >/dev/null 2>&1
hs_evt SubagentStop aaa111 "$HS_WT" | HERDR_STUB=down hw subagent-hook >/dev/null 2>&1; rc=$?
check_rc "stop while herdr is down: hook exits 0" 0 "$rc"
check "stop while herdr is down: the state is kept for the next stop" "aaa111.json" "$(ls "$XDG_CACHE_HOME/spec-workflow/herdr-subagents" 2>/dev/null)"
hw_log_reset
hs_evt SubagentStop aaa111 "$HS_WT" | HERDR_STUB_GETPATH="$HS_WT" hw subagent-hook >/dev/null 2>&1
check "stop after herdr is back: closes the workspace" "workspace close w6" "$(cat "$HW_LOG")"
check_absent "stop after herdr is back: the state is gone" "aaa111.json" "$(ls "$XDG_CACHE_HOME/spec-workflow/herdr-subagents" 2>/dev/null)"

# The hook must exit 0 and print nothing even when the config reader exits.
mkdir -p "$HW_TMP/noyaml"; printf 'raise ImportError("no yaml")\n' >"$HW_TMP/noyaml/yaml.py"
hw_log_reset
out="$(hs_evt SubagentStart aaa111 "$HS_WT" | PYTHONPATH="$HW_TMP/noyaml" hw subagent-hook 2>&1)"; rc=$?
check_rc "PyYAML missing: the hook exits 0" 0 "$rc"
check_rc "PyYAML missing: the hook prints nothing" 0 "${#out}"
mkdir -p "$HW_TMP/nogit/agent-z1/.neural-network"; cp "$HW_TMP/s.yaml" "$HW_TMP/nogit/agent-z1/.neural-network/project.yaml"
out="$(hs_evt SubagentStart z1 "$HW_TMP/nogit/agent-z1" | hw subagent-hook 2>&1)"; rc=$?
check_rc "isolated subagent outside any git repo: the hook exits 0" 0 "$rc"
check_rc "isolated subagent outside any git repo: the hook prints nothing" 0 "${#out}"
HNY="$HW_TMP/ny"; hw_repo "$HNY"
out="$(cd "$HNY" && PYTHONPATH="$HW_TMP/noyaml" PATH="$HW_BIN:$PATH" HERDR_STUB_LOG="$HW_LOG" bash "$HW_TOOL" add --path wt --branch y1 2>&1)"; rc=$?
check_rc "PyYAML missing: add treats the config as off and succeeds" 0 "$rc"
check "PyYAML missing: add made the worktree with git" "y1" "$(git -C "$HNY" worktree list)"

hooks_json="$(cat "$PLUGIN/hooks/hooks.json")"
check "hooks.json wires SubagentStart" '"SubagentStart"' "$hooks_json"
hooks_doc="$(sed -n '/^## Enforcement hooks/,/^## Identity brains/p' "$PLUGIN/README.md")"
check "README Enforcement hooks section documents the SubagentStart hook" "SubagentStart" "$hooks_doc"
check "README Enforcement hooks section says it is silent without herdr" "herdr-worktree.sh" "$hooks_doc"
check "README lists herdr-worktree.sh among the scripts" "\`herdr-worktree.sh\` (#543" "$(cat "$PLUGIN/README.md")"
check "README lists task-state.sh among the scripts" "\`task-state.sh\` (#543" "$(cat "$PLUGIN/README.md")"
check "hooks.json wires SubagentStop" '"SubagentStop"' "$hooks_json"
check "hooks.json calls the subagent hook" 'herdr-worktree.sh\" subagent-hook' "$hooks_json"
check "implement-task creates task lanes through the helper" "herdr-worktree.sh add" "$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "concurrency lanes are created through the helper" "herdr-worktree.sh add" "$(cat "$PLUGIN/skills/build-next/references/concurrency.md")"
check "concurrency lanes are removed through the helper" "herdr-worktree.sh remove" "$(cat "$PLUGIN/skills/build-next/references/concurrency.md")"
check "implement-task removes its lane through the helper" "herdr-worktree.sh remove" "$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "build-next removes its isolated lane through the helper" 'herdr-worktree.sh" remove' "$(cat "$PLUGIN/skills/build-next/SKILL.md")"
check "README lists the todo verbs --start, --move and --before" "--add|--done|--undo|--drop|--start|--move|--before" "$(cat "$PLUGIN/README.md")"
check "build-next isolated lanes go through the helper" 'herdr-worktree.sh" add' "$(cat "$PLUGIN/skills/build-next/SKILL.md")"

check "README: remove uses herdr whenever herdr is enabled and a workspace is open" "whenever herdr is enabled and a workspace is open for that path" "$(cat "$PLUGIN/README.md")"
check "spec delta: remove uses herdr whenever herdr is enabled and a workspace is open" "whenever herdr is enabled and a workspace is open for that path" "$(cat "$PLUGIN/../../docs/spec-deltas/543.md")"
check "spec delta: the panel is narrowed when opened" "narrow" "$(cat "$PLUGIN/../../docs/spec-deltas/543.md")"
check_absent "design doc: resizing is not out of scope any more" "resizing or reordering" "$(cat "$PLUGIN/../../docs/design/sw-E0.md")"
check "design doc: reordering panels stays out of scope" "reordering panels" "$(cat "$PLUGIN/../../docs/design/sw-E0.md")"

if [[ -n "$XDG_CACHE_HOME_ORIG" ]]; then export XDG_CACHE_HOME="$XDG_CACHE_HOME_ORIG"; else unset XDG_CACHE_HOME; fi
unset XDG_CACHE_HOME_ORIG
rm -rf "$HW_TMP"
