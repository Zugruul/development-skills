#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes: literal SKILL.md text
# section-lanetype.sh -- sourced by run-tests.sh; do not run standalone.
# A lane's shown type: a bare name only for a pattern the plugin ships; every other graph is
# "custom" or "custom: <name>". The stored name stays, for the rules that read it.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }
echo "== lane type: shipped by name, everything else custom =="

T_TMP="$(mktemp -d)"
T_REPO="$T_TMP/repo"
git init -q -b main "$T_REPO" && git -C "$T_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf '{}' >"$T_TMP/state.json"
printf '#!/bin/sh\nexec cat\n' >"$T_TMP/pager" && chmod +x "$T_TMP/pager"
tg() { local s="$1"; shift; (cd "$T_REPO" && XDG_CONFIG_HOME="$T_TMP/config" XDG_STATE_HOME="$T_TMP/xdg" PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$T_TMP" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 bash "$PLUGIN/scripts/$s.sh" "$@"); }
T_G='when: x\nnodes:\n  a: {agent: investigator, brief: "{idea}"}\ndone: [report]\n'
mkdir -p "$T_REPO/.herdr-graph/patterns" "$T_TMP/config/herdr-graph/patterns"
printf "%b" "$T_G" >"$T_REPO/.herdr-graph/patterns/team.yaml"
printf "%b" "$T_G" >"$T_TMP/config/herdr-graph/patterns/solo.yaml"
printf "%b" "$T_G" >"$T_TMP/hand.yaml"
tg lane new --repo "$T_REPO" --lane t-shipped --pattern investigate --idea i >/dev/null 2>&1
tg lane new --repo "$T_REPO" --lane t-repo --pattern team --idea i >/dev/null 2>&1
tg lane new --repo "$T_REPO" --lane t-user --pattern solo --idea i >/dev/null 2>&1
tg lane new --repo "$T_REPO" --lane t-hand --pattern-file "$T_TMP/hand.yaml" --idea i >/dev/null 2>&1
tg lane new --repo "$T_REPO" --lane t-named --pattern ui-first --pattern-file "$T_TMP/hand.yaml" --idea i >/dev/null 2>&1

T_WANT='t-hand=custom|t-named=custom: ui-first|t-repo=custom: team|t-shipped=investigate|t-user=custom: solo'
T_JSON="$(tg status --json --repo "$T_REPO" 2>&1)"
check "status --json: the type" "$T_WANT" "$(jq -r '[.[] | "\(.lane)=\(.pattern)"] | sort | join("|")' <<<"$T_JSON")"
check "status --json: the stored name stays for the rules" "t-hand=custom|t-named=ui-first|t-repo=team|t-shipped=investigate|t-user=solo" "$(jq -r '[.[] | "\(.lane)=\(.pattern_name)"] | sort | join("|")' <<<"$T_JSON")"
T_TEXT="$(tg status --text --repo "$T_REPO" 2>&1)"
T_RESUME="$(tg resume 2>&1)"
T_LIST="$(tg lane list --repo "$T_REPO" 2>&1)"
for pair in 't-hand|custom' 't-named|custom: ui-first' 't-repo|custom: team' 't-user|custom: solo' 't-shipped|investigate'; do
    l="${pair%%|*}" want="${pair#*|}"
    check "status --text: $l" "  $l  $want  " "$T_TEXT"
    check "resume block: $l" "$want  repo " "$(grep "^lane $l " <<<"$T_RESUME")"
    check "lane list: $l" "$l	open	$want" "$T_LIST"
    check "lane popup: $l" "$l · $want · open" "$(GRAPH_LANE="$l" GRAPH_REPO="$T_REPO" PAGER="$T_TMP/pager" tg popup detail 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
done
check "measure: the type" "custom: ui-first" "$(tg measure --repo "$T_REPO" 2>&1)"
check "panel: the review rule reads the stored name" '.pattern_name == "review"' "$(cat "$PLUGIN/scripts/panel.sh")"
check "events: the review rule reads the stored name" '.pattern_name == "review"' "$(cat "$PLUGIN/scripts/src/events.sh")"
T_ORCH="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check "orchestrate: only shipped patterns show a bare name" "Only a pattern shipped in the plugin's \`patterns/\` is labelled with its bare name" "$T_ORCH"
check "orchestrate: every other option is labelled custom" "\`custom\` or \`custom: <name you suggest>\`" "$T_ORCH"
check "orchestrate: the suggested name reaches the lane" "\`--pattern <name> --pattern-file <file>\`" "$T_ORCH"
check "README: explains the custom type" "\`custom: <name>\`" "$(cat "$PLUGIN/README.md")"
rm -rf "$T_TMP"
