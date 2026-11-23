#!/usr/bin/env bash
# section-detect.sh -- sourced by run-tests.sh; do not run standalone.
# detect.py: which plugins are enabled/installed, whether spec-workflow is
# configured for the repository, and which integrations come out READY.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-development-skills/tests/run-tests.sh" >&2; exit 2; }

DT_TMP="$(mktemp -d)"
DT_DETECT="$PLUGIN/scripts/detect.py"
DT_BIN="$DT_TMP/bin"; mkdir -p "$DT_BIN" "$DT_TMP/home/.claude" "$DT_TMP/empty-plugins"
printf '#!/bin/sh\nexit 0\n' >"$DT_BIN/herdr"; chmod +x "$DT_BIN/herdr"
# dt [VAR=VALUE ...] -- <detect args>: private HOME, stub herdr on PATH, inside Herdr unless overridden.
dt() {
    # HDS_NOOP keeps the array non-empty: bash 3.2 (macOS) rejects an empty "${envs[@]}" under set -u.
    local envs=(HDS_NOOP=1)
    while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    env -u CODEX_SESSION_ID HOME="$DT_TMP/home" CLAUDE_CONFIG_DIR="$DT_TMP/home/.claude" PATH="$DT_BIN:$PATH" HERDR_ENV=1 "${envs[@]}" python3 "$DT_DETECT" "$@"
}
dt_repo() { # dir [with-config]
    git init -q -b main "$1"
    git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    if [[ "${2:-}" == with-config ]]; then
        mkdir -p "$1/.neural-network"
        cp "$PLUGINS/spec-workflow/tests/fixtures/valid.project.yaml" "$1/.neural-network/project.yaml"
    fi
}
dt_settings() { printf '%s' "$1" >"$DT_TMP/home/.claude/settings.json"; }

echo "== detect: nothing installed =="
dt_repo "$DT_TMP/bare"
dt_settings '{}'
out="$(dt HDS_PLUGINS_DIR="$DT_TMP/empty-plugins" -- --root "$DT_TMP/bare" 2>&1)"; rc=$?
check_rc "detection always exits 0" 0 "$rc"
check "the herdr plugin is reported absent" "herdr           absent" "$out"
check "spec-workflow is reported absent" "spec-workflow   absent" "$out"
check "task-lane is unavailable" "task-lane    UNAVAILABLE" "$out"
check "build-lanes is unavailable" "build-lanes  UNAVAILABLE" "$out"
check "review-lane is unavailable" "review-lane  UNAVAILABLE" "$out"
check "the reason names the missing herdr plugin" "install herdr@development-skills" "$out"
check "the reason names the missing spec-workflow plugin" "the spec-workflow plugin is not available" "$out"
check "without the herdr plugin no lane can run, even without a task" "1 run without a task           NOT POSSIBLE" "$out"
check_absent "nothing crashes" "Traceback" "$out"

echo "== detect: outside Herdr =="
out="$(dt HERDR_ENV=0 -- --root "$DT_TMP/bare" 2>&1)"
check "outside Herdr is reported" "NOT USABLE -- not running inside a Herdr pane" "$out"
check "outside Herdr makes every feature unavailable" "review-lane  UNAVAILABLE" "$out"
check "outside Herdr the no-task lane is unavailable too" "task-lane    UNAVAILABLE" "$out"
check "outside Herdr no task source is possible" "1 run without a task           NOT POSSIBLE" "$out"
out="$(env HOME="$DT_TMP/home" PATH="/usr/bin:/bin" HERDR_ENV=1 "$(command -v python3)" "$DT_DETECT" --root "$DT_TMP/bare" 2>&1)"
check "a missing herdr binary is reported" "the herdr binary is not on PATH" "$out"

echo "== detect: plugin states =="
dt_settings '{"enabledPlugins":{"spec-workflow@development-skills":true,"herdr@development-skills":true}}'
out="$(dt HDS_PLUGINS_DIR="$DT_TMP/empty-plugins" -- --root "$DT_TMP/bare" 2>&1)"
check "user settings enable a plugin" "spec-workflow   enabled" "$out"
mkdir -p "$DT_TMP/bare/.claude"
printf '{"enabledPlugins":{"spec-workflow@development-skills":false}}' >"$DT_TMP/bare/.claude/settings.json"
out="$(dt HDS_PLUGINS_DIR="$DT_TMP/empty-plugins" -- --root "$DT_TMP/bare" 2>&1)"
check "project settings override user settings" "spec-workflow   absent" "$out"
check "the override is explained" "disabled in $DT_TMP/bare/.claude/settings.json" "$out"
rm "$DT_TMP/bare/.claude/settings.json"
dt_settings '{}'
out="$(dt -- --root "$DT_TMP/bare" 2>&1)"
check "a sibling plugin directory counts as available, not enabled" "spec-workflow   available" "$out"
check "available plugins carry the unconfirmed note" "could not confirm it is enabled" "$out"
mkdir -p "$DT_TMP/bare/.agents/skills/peer-review"; : >"$DT_TMP/bare/.agents/skills/peer-review/SKILL.md"
out="$(dt HDS_PLUGINS_DIR="$DT_TMP/empty-plugins" -- --root "$DT_TMP/bare" 2>&1)"
check "skills linked into a skills directory count as enabled" "peer-review     enabled" "$out"

echo "== detect: spec-workflow not configured =="
dt_settings '{"enabledPlugins":{"spec-workflow@development-skills":true,"herdr@development-skills":true,"peer-review@development-skills":true}}'
out="$(dt -- --root "$DT_TMP/bare" 2>&1)"
check "an unconfigured repository is reported" "not configured" "$out"
check "task-lane runs only without a task when there is no project config" "task-lane    LIMITED" "$out"
check "build-lanes runs only without a task when there is no project config" "build-lanes  LIMITED" "$out"
check "the limit is named" "without a task only" "$out"
check "the build loop needs a board and is unavailable" "build-loop   UNAVAILABLE" "$out"
check "not configured: running without a task is possible" "1 run without a task           possible" "$out"
check "not configured: creating a task is not possible" "2 create a task for it         NOT POSSIBLE" "$out"
check "not configured: providing an identifier is not possible" "3 provide the task identifier  NOT POSSIBLE" "$out"
ts="$(sed -n '/^TASK SOURCE/,/^remote-compute/p' <<<"$out")"
check "not configured: the dead options say why" "spec-workflow is not configured here" "$ts"
js="$(dt -- --root "$DT_TMP/bare" --json 2>&1)"
check "json carries the task-source verdicts" '"without-task"' "$js"
check "json marks the possible option" "True False False" "$(python3 -c 'import json,sys; t=json.load(sys.stdin)["taskSource"]; print(t["without-task"]["ok"], t["create-task"]["ok"], t["task-id"]["ok"])' <<<"$js")"
dt_settings '{"enabledPlugins":{"herdr@development-skills":true}}'
out="$(dt HDS_PLUGINS_DIR="$DT_TMP/empty-plugins" -- --root "$DT_TMP/bare" 2>&1)"
check "spec-workflow not enabled: only the no-task option is possible" "2 create a task for it         NOT POSSIBLE" "$out"
check "spec-workflow not enabled: the reason names the plugin" "the spec-workflow plugin is not available" "$(sed -n '/^TASK SOURCE/,/^remote-compute/p' <<<"$out")"
check "spec-workflow not enabled: the no-task lane still runs" "task-lane    LIMITED" "$out"
dt_settings '{"enabledPlugins":{"spec-workflow@development-skills":true,"herdr@development-skills":true,"peer-review@development-skills":true}}'
out="$(dt -- --root "$DT_TMP/bare" 2>&1)"
check "the reason points at setup" "setup-project" "$out"
check "review-lane does not need spec-workflow" "review-lane  READY" "$out"

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "SKIP detect configured-repository checks — python 'yaml' package unavailable (spec-workflow's config loader needs it)"
else
    echo "== detect: configured repository =="
    dt_repo "$DT_TMP/cfg" with-config
    out="$(dt -- --root "$DT_TMP/cfg" 2>&1)"
    check "task-lane is ready" "task-lane    READY" "$out"
    check "build-loop is ready" "build-loop   READY" "$out"
    check "one lane is the default" "build-lanes  READY (up to 1 lane)" "$out"
    check "a single lane is explained" "methodology.maxInProgress is 1" "$out"
    check "settings are read through spec-workflow's own loader" "mainBranch=main" "$out"
    check "the pause flag is clear" "checkpoint: clear" "$out"
    check "a branchPattern other than the lane rule is noted" "note: lane branches are feat/<taskid>-<desc>" "$out"
    sed -i.bak 's|branchPattern: .*|branchPattern: feat/<id>-<slug>|' "$DT_TMP/cfg/.neural-network/project.yaml"
    check_absent "the default branchPattern raises no note" "note: lane branches" "$(dt -- --root "$DT_TMP/cfg" 2>&1)"
    mv "$DT_TMP/cfg/.neural-network/project.yaml.bak" "$DT_TMP/cfg/.neural-network/project.yaml"
    for opt in "1 run without a task           possible" "2 create a task for it         possible" "3 provide the task identifier  possible"; do
        check "configured: task source '$opt'" "$opt" "$out"
    done
    check "json output carries the same verdict" '"state": "READY"' "$(dt -- --root "$DT_TMP/cfg" --json 2>&1)"

    printf '\nherdr:\n    enabled: true\n' >>"$DT_TMP/cfg/.neural-network/project.yaml"
    python3 "$PLUGINS/spec-workflow/scripts/config.py" "$DT_TMP/cfg" set methodology.maxInProgress 3 >/dev/null 2>&1
    out="$(dt -- --root "$DT_TMP/cfg" 2>&1)"
    check "the lane limit follows methodology.maxInProgress" "build-lanes  READY (up to 3 lanes)" "$out"
    check "spec-workflow's own herdr switch is reported" "herdr.enabled=true" "$out"

    echo "== detect: paused loop, seen from a linked worktree =="
    git -C "$DT_TMP/cfg" add -A; git -C "$DT_TMP/cfg" -c user.name=t -c user.email=t@t commit -q -m cfg
    git -C "$DT_TMP/cfg" worktree add -q "$DT_TMP/lane" -b lane
    flag="$(python3 "$PLUGINS/spec-workflow/scripts/config.py" "$DT_TMP/cfg" get paths.checkpointFile 2>/dev/null)"
    flag="${flag:-.claude/CHECKPOINT}"
    mkdir -p "$DT_TMP/cfg/$(dirname "$flag")"; : >"$DT_TMP/cfg/$flag"
    out="$(dt -- --root "$DT_TMP/lane" 2>&1)"
    check "the primary checkout is found from a linked worktree" "primary checkout: " "$out"
    check "a pause flag in the primary checkout pauses the build loop" "build-loop   PAUSED" "$out"
    check "paused: task-lane runs only without a task" "task-lane    LIMITED" "$out"
    check "paused: build-lanes runs only without a task" "build-lanes  LIMITED" "$out"
    check "paused: running without a task stays possible" "1 run without a task           possible" "$out"
    check "paused: creating a task to run is not possible" "2 create a task for it         NOT POSSIBLE" "$out"
    check "paused: providing an identifier is not possible" "3 provide the task identifier  NOT POSSIBLE" "$out"
    check "the pause names how to resume" "checkpoint skill resumes it" "$out"
    check "a paused loop does not stop a review" "review-lane  READY" "$out"

    echo "== detect: configured repository, plugin missing =="
    dt_settings '{"enabledPlugins":{"herdr@development-skills":true}}'
    out="$(dt HDS_PLUGINS_DIR="$DT_TMP/empty-plugins" -- --root "$DT_TMP/cfg" 2>&1)"
    check "config without the plugin: the loop is unavailable" "build-loop   UNAVAILABLE" "$out"
    check "config without the plugin: lanes run only without a task" "task-lane    LIMITED" "$out"
    check "config without the plugin: no task can be created" "2 create a task for it         NOT POSSIBLE" "$out"
    check "the config is still noticed" "configured (" "$out"
    check_absent "no crash without the plugin" "Traceback" "$out"
fi
rm -rf "$DT_TMP"
