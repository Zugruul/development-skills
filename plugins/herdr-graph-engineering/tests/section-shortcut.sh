#!/usr/bin/env bash
# section-shortcut.sh -- sourced by run-tests.sh; do not run standalone.
# The panel shortcut (install-keys.sh prints, and with --write appends, PREFIX then Alt+G bound
# to the toggle action) and a robust toggle: the panel is found by the pane the plugin opened,
# not only by its terminal title, a pane closed outside the plugin is forgotten, a tab never
# gets a second panel, and a failed open is shown to the user.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

K_TMP="$(mktemp -d)"
SC="$PLUGIN/scripts"
# kg: run a script against the stub herdr, with its own plugin state folder and config path.
kg() { local s="$1"; shift; (cd "$K_TMP" && env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_PLUGIN_ID ${K_TAB:+HERDR_TAB_ID=$K_TAB} PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$K_TMP" HERDR_PLUGIN_STATE_DIR="$K_TMP/state" HERDR_CONFIG_PATH="$K_TMP/herdr/config.toml" HERDR_GRAPH_LOCK_TRIES=3 bash "$SC/$s.sh" "$@"); }
kst() { printf '%s' "$1" >"$K_TMP/state.json"; : >"$K_TMP/calls.log"; }
ksj() { jq -c "$1" "$K_TMP/state.json"; }
ORCH='"agents":{"g":{"name":"graph","pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","agent":"claude","agent_status":"idle"}}'

echo "== shortcut: toggle finds the panel the plugin opened =="
kst "{$ORCH,\"pane_list\":[{\"pane_id\":\"w1:p1\",\"tab_id\":\"w1:t1\"}]}"
check "toggle opens the panel" "PANEL OPEN" "$(K_TAB=w1:t1 kg panel-action toggle)"
# The new pane has no "herdr-graph-panel" title yet (or lost it): it is still the panel.
out="$(K_TAB=w1:t1 kg panel-action toggle)"
check "toggle closes an untitled panel it opened" "PANEL CLOSED" "$out"
check "the pane it opened is the one closed" '["w9:p9"]' "$(ksj .closed)"
check "toggle opens it again after closing" "PANEL OPEN" "$(K_TAB=w1:t1 kg panel-action toggle)"
check "one panel opened in all" "1" "$(ksj '[.opened[] | select(.entrypoint == "panel")] | length')"

echo "== shortcut: a panel closed outside the plugin =="
kst "{$ORCH,\"pane_list\":[{\"pane_id\":\"w1:p1\",\"tab_id\":\"w1:t1\"}]}"
K_TAB=w1:t1 kg panel-action toggle >/dev/null
# The user closes the pane by hand: it leaves pane_list, the plugin is not told.
jq -c '.pane_list |= map(select(.pane_id != "w9:p9"))' "$K_TMP/state.json" >"$K_TMP/s" && mv "$K_TMP/s" "$K_TMP/state.json"
out="$(K_TAB=w1:t1 kg panel-action toggle)"
check "toggle reopens a panel closed by hand" "PANEL OPEN" "$out"
check "it opened a new panel" "2" "$(ksj '[.opened[] | select(.entrypoint == "panel")] | length')"
check_absent "it closes nothing that is gone" "w9:p9" "$(ksj '.closed // []')"

echo "== shortcut: never a second panel in a tab =="
kst "{$ORCH,\"pane_list\":[{\"pane_id\":\"w1:p1\",\"tab_id\":\"w1:t1\"}]}"
K_TAB=w1:t1 kg panel-action toggle >/dev/null
: >"$K_TMP/calls.log"
kg panel-action restore >/dev/null
check "restore leaves an untitled panel it opened alone" "1" "$(ksj '[.opened[] | select(.entrypoint == "panel")] | length')"
mkdir -p "$K_TMP/state/toggle.lock" && echo $$ >"$K_TMP/state/toggle.lock/pid"
kst "{$ORCH,\"pane_list\":[{\"pane_id\":\"w1:p1\",\"tab_id\":\"w1:t1\"}]}"
K_TAB=w1:t1 kg panel-action toggle >/dev/null 2>&1
check_rc "a toggle while another runs gives up" 1 "$?"
check "and opens nothing" "0" "$(ksj '[(.opened // [])[] | select(.entrypoint == "panel")] | length')"
echo 999999 >"$K_TMP/state/toggle.lock/pid"
check "a stale toggle lock is taken over" "PANEL OPEN" "$(K_TAB=w1:t1 kg panel-action toggle 2>&1)"
check "the lock is released afterwards" "no" "$([ -d "$K_TMP/state/toggle.lock" ] && echo yes || echo no)"

echo "== shortcut: a failed open is visible =="
kst "{$ORCH,\"pane_list\":[{\"pane_id\":\"w1:p1\",\"tab_id\":\"w1:t1\"}],\"plugin_open\":\"fail\"}"
out="$(K_TAB=w1:t1 kg panel-action toggle 2>&1)"
check_rc "toggle fails when the panel does not open" 1 "$?"
check "it says so" "could not open the graph panel" "$out"
check "the user gets a notification" "Graph panel did not open" "$(ksj '.notified // []')"

echo "== shortcut: install-keys.sh =="
CFG="$K_TMP/herdr/config.toml"
kst '{}'
out="$(kg install-keys 2>&1)"
check "it prints the binding" 'key = "prefix+alt+g"' "$out"
check "bound to the toggle action" 'command = "herdr-graph-engineering.graph.toggle"' "$out"
check "as a plugin action" 'type = "plugin_action"' "$out"
check "it names the config file" "$CFG" "$out"
check "it says how to write it" "--write" "$out"
check "without --write nothing is written" "no" "$([ -e "$CFG" ] && echo yes || echo no)"
mj="$(yq -p=toml -o=json '.' "$PLUGIN/herdr-plugin.toml")"
check "the bound command is the manifest's toggle action" "herdr-graph-engineering.graph.toggle" "$(jq -r '.id + "." + ([.actions[] | select(.id == "toggle")][0].id)' <<<"$mj")"

out="$(kg install-keys --write 2>&1)"
check "--write writes a new config" "KEYS WRITTEN" "$out"
check "the config holds the binding" "herdr-graph-engineering.graph.toggle" "$(yq -p=toml -o=json '.keys.command[] | select(.key == "prefix+alt+g") | .command' "$CFG" 2>&1)"
check "it validates with herdr config check" "config check" "$(cat "$K_TMP/calls.log")"
check "it says how to load it" "herdr server reload-config" "$out"

rm -rf "$K_TMP/herdr" && mkdir -p "$K_TMP/herdr"
printf '[keys]\nprefix = "ctrl+b"\n\n[ui]\nmouse_capture = true\n' >"$CFG"
cp "$CFG" "$K_TMP/orig.toml"
kst '{}'
kg install-keys --write >/dev/null 2>&1
check "the existing settings are kept" '"ctrl+b" true' "$(yq -p=toml -o=json '.' "$CFG" | jq -r '"\(.keys.prefix | tojson) \(.ui.mouse_capture)"')"
check "the binding is added" "prefix+alt+g" "$(yq -p=toml -o=json '.keys.command[0].key' "$CFG" 2>&1)"
bak="$(find "$K_TMP/herdr" -name 'config.toml.bak.*' | head -1)"
check "a backup is made first" "same" "$([ -n "$bak" ] && cmp -s "$bak" "$K_TMP/orig.toml" && echo same || echo differs)"
cp "$CFG" "$K_TMP/once.toml"
out="$(kg install-keys --write 2>&1)"
check "a second --write changes nothing" "ALREADY BOUND prefix+alt+g" "$out"
check "the file is unchanged" "same" "$(cmp -s "$CFG" "$K_TMP/once.toml" && echo same || echo differs)"
check "no second backup" "1" "$(find "$K_TMP/herdr" -name 'config.toml.bak.*' | wc -l | tr -d ' ')"

printf '[[keys.command]]\nkey = "prefix+t"\ntype = "plugin_action"\ncommand = "herdr-graph-engineering.graph.toggle"\n' >"$CFG"
cp "$CFG" "$K_TMP/orig.toml"
out="$(kg install-keys --write 2>&1)"
check "a toggle already bound to another key is reported" "ALREADY BOUND prefix+t" "$out"
check "and left alone" "same" "$(cmp -s "$CFG" "$K_TMP/orig.toml" && echo same || echo differs)"

printf '[keys]\ngoto = "prefix+alt+g"\n' >"$CFG"
cp "$CFG" "$K_TMP/orig.toml"
out="$(kg install-keys --write 2>&1)"
check_rc "a key taken by something else is refused" 1 "$?"
check "it names the clash" "prefix+alt+g is already used" "$out"
check "the config is untouched" "same" "$(cmp -s "$CFG" "$K_TMP/orig.toml" && echo same || echo differs)"

printf '[ui]\nmouse_capture = true\n' >"$CFG"
cp "$CFG" "$K_TMP/orig.toml"
kst '{"config_check":"fail"}'
out="$(kg install-keys --write 2>&1)"
check_rc "a config that fails herdr config check is rolled back" 1 "$?"
check "it says it restored the backup" "restored" "$out"
check "the config is back as it was" "same" "$(cmp -s "$CFG" "$K_TMP/orig.toml" && echo same || echo differs)"

printf 'broken = = \n' >"$CFG"
kst '{}'
kg install-keys --write >/dev/null 2>&1
check_rc "an unreadable config is not touched" 1 "$?"
check "README documents the shortcut" "install-keys.sh" "$(cat "$PLUGIN/README.md")"
rm -rf "$K_TMP"
