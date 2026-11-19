#!/usr/bin/env bash
# section-names.sh -- sourced by run-tests.sh; do not run standalone.
# lane_name.py: the branch, Herdr workspace label and agent name of a lane,
# for each task source and for a lane without a task.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-development-skills/tests/run-tests.sh" >&2; exit 2; }

ln_name() { python3 "$PLUGIN/scripts/lane_name.py" "$@"; }
# ln_field FIELD <lane_name args>: one field of the --json answer.
ln_field() { local f="$1"; shift; ln_name "$@" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$f"; }

echo "== lane names: ClickUp task =="
out="$(ln_name --source clickup --id 1k5a5ew4cde --desc "Decision API: image input" --kind claude 2>&1)"
check "clickup: branch is feat/<taskid>-<desc>" "BRANCH feat/1k5a5ew4cde-decision-api-image-input" "$out"
check "clickup: label is CU-<taskid>-<desc>" "LABEL  CU-1k5a5ew4cde-decision-api-image-input" "$out"
check "clickup: agent is <kind>-lane-<taskid>" "AGENT  claude-lane-1k5a5ew4cde" "$out"
check_absent "clickup: the tag is not in the branch" "feat/CU" "$out"

echo "== lane names: GitHub issue =="
out="$(ln_name --source github --id '#123' --desc "Add parser" --kind codex 2>&1)"
check "github: branch is feat/<taskid>-<desc>" "BRANCH feat/123-add-parser" "$out"
check "github: label is GH-<taskid>-<desc>" "LABEL  GH-123-add-parser" "$out"
check "github: agent is <kind>-lane-<taskid>" "AGENT  codex-lane-123" "$out"

echo "== lane names: Jira issue (future source) =="
out="$(ln_name --source jira --id ABC-123 --desc "add parser" --kind claude 2>&1)"
check "jira: label is J-<taskid>-<desc>" "LABEL  J-ABC-123-add-parser" "$out"
check "jira: branch keeps the hyphenated id as given" "BRANCH feat/ABC-123-add-parser" "$out"
check "jira: the id is lowercased in the agent name" "AGENT  claude-lane-abc-123" "$out"
check "a hyphenated id comes back whole, not split" "ABC-123" "$(ln_field id --source jira --id ABC-123 --desc "add parser")"
check "the slug comes back as its own field" "add-parser" "$(ln_field desc --source jira --id ABC-123 --desc "add parser")"
check "the tag comes back as its own field" "J" "$(ln_field tag --source jira --id ABC-123 --desc "add parser")"

echo "== lane names: no task =="
out="$(ln_name --desc "Fix health check 204" 2>&1)"
check "no task: branch is feat/<desc>" "BRANCH feat/fix-health-check-204" "$out"
check "no task: label is the slug alone" "LABEL  fix-health-check-204" "$out"
check "no task: says there is no task" "TASK   none" "$out"
for tag in CU- GH- J-; do
    check_absent "no task: no '$tag' tag anywhere" "$tag" "$out"
done

echo "== lane names: shape and refusals =="
LN_LONG="  Some Title, with: punctuation & SPACES / slashes and a very long tail that goes on  "
for args in "--source clickup --id 86b4nyq2p" "--source github --id 7" "--source jira --id ABC-123" ""; do
    # shellcheck disable=SC2086  # args is a deliberate word list
    out="$(ln_name $args --desc "$LN_LONG" 2>&1)"
    label="$(sed -n 's/^LABEL  //p' <<<"$out")"; branch="$(sed -n 's/^BRANCH //p' <<<"$out")"
    [[ "$label" =~ ^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]] && rc=0 || rc=1; check_rc "label is hyphen-separated letters and digits (${args:-no task})" 0 "$rc"
    [[ "$branch" =~ ^feat/[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]] && rc=0 || rc=1; check_rc "branch is feat/ plus a hyphenated name (${args:-no task})" 0 "$rc"
done
slug="$(ln_field desc --desc "$LN_LONG")"
[[ ${#slug} -le 40 && "$slug" == some-title-with-punctuation* ]] && rc=0 || rc=1; check_rc "the slug is lowercase kebab-case and at most 40 characters" 0 "$rc"
ln_name --source svn --id 1 --desc x >/dev/null 2>&1; check_rc "an unknown source is refused" 6 "$?"
check "the refusal lists the known sources" "known: clickup, github, jira" "$(ln_name --source svn --id 1 --desc x 2>&1)"
ln_name --source github --desc x >/dev/null 2>&1; check_rc "a source without an id is refused" 6 "$?"
ln_name --id 12 --desc x >/dev/null 2>&1; check_rc "an id without a source is refused" 6 "$?"
ln_name --source github --id "12 34" --desc x >/dev/null 2>&1; check_rc "an id with a space is refused" 6 "$?"
ln_name --desc "!!!" >/dev/null 2>&1; check_rc "a description with nothing usable is refused" 6 "$?"
check "the source-to-tag mapping is listed" "clickup  CU" "$(ln_name --sources 2>&1)"

echo "== lane names: agent name =="
ln_agent() { ln_name "$@" | sed -n 's/^AGENT  //p'; }
check "no task: agent is <kind>-lane-<desc>" "codex-lane-health-check-204" "$(ln_agent --desc "health check 204" --kind codex)"
check "the kind is lowercased" "claude-lane-123" "$(ln_agent --source github --id 123 --desc x --kind Claude)"
check "a reviewer is <kind>-review-<taskid>" "codex-review-123" "$(ln_agent --source github --id 123 --desc x --kind codex --role review)"
check "without a kind there is no agent name" "give --kind" "$(ln_agent --desc x)"
long="$(ln_agent --desc "fix health check 204" --kind opencode)"
check "a name over 32 characters is shortened after the role, with a digest" "opencode-lane-fix-health-ch-5450" "$long"
check_rc "the shortened name is exactly at the limit" 32 "${#long}"
for args in "--source clickup --id 86b4nyq2p9xk3m7w2a5d8f1g4h6j0q --kind opencode" "--desc averyveryverylongsinglewordwithoutanyhyphensatall --kind claude" "--source jira --id PLATFORM-INFRA-123456 --kind opencode --role review"; do
    # shellcheck disable=SC2086  # args is a deliberate word list
    n="$(ln_agent $args --desc "${LN_LONG}")"
    [[ "$n" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] && rc=0 || rc=1; check_rc "a long name is still valid for Herdr ($n)" 0 "$rc"
    kind="$(sed -n 's/.*--kind \([a-z]*\).*/\1/p' <<<"$args")"
    [[ "$n" == "$kind"-* ]] && rc=0 || rc=1; check_rc "the kind is never cut ($n)" 0 "$rc"
done
a="$(ln_agent --source clickup --id 86b4nyq2p9xk3m7w2a5d8f1g4h6j0q --desc x --kind opencode)"
b="$(ln_agent --source clickup --id 86b4nyq2p9xk3m7w2a5d8f1g4h6j0z --desc x --kind opencode)"
[[ "$a" != "$b" ]] && rc=0 || rc=1; check_rc "two long ids that differ only at the end get different names" 0 "$rc"
check "a taken name gets -2" "codex-lane-123-2" "$(ln_agent --source github --id 123 --desc x --kind codex --taken codex-lane-123)"
check "and then -3" "codex-lane-123-3" "$(ln_agent --source github --id 123 --desc x --kind codex --taken codex-lane-123 codex-lane-123-2)"
n="$(ln_agent --desc "fix health check 204" --kind opencode --taken "$long")"
[[ "$n" != "$long" && ${#n} -le 32 && "$n" == opencode-lane-*-2 ]] && rc=0 || rc=1; check_rc "a taken shortened name stays within the limit ($n)" 0 "$rc"
ln_name --desc x --kind "my kind" >/dev/null 2>&1; check_rc "a kind that is not one word is refused" 6 "$?"
ln_name --desc x --kind averyveryverylongagentkindname >/dev/null 2>&1; check_rc "a kind that leaves no room is refused, not cut" 6 "$?"

