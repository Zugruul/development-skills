#!/usr/bin/env bash
# section-design-registry.sh -- sourced by run-tests.sh; do not run standalone.
# design-registry.sh: the design-meta block in each options page makes a
# design discoverable by tag and records the human's pick in the page itself.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/ui-design/tests/run-tests.sh" >&2; exit 2; }
echo "== design-registry (tags, discovery, pick) =="

DRG="$PLUGIN/scripts/design-registry.sh"
drg_run() { local dir="$1"; shift; DESIGN_REGISTRY_ROOT="$dir" bash "$DRG" "$@" 2>&1; }
drg_repo() { git_repo "$1"; mkdir -p "$1/docs/ui-options"; }
page() { # <file> <meta-json> [body]
    mkdir -p "$(dirname "$1")"
    printf '<!doctype html><html><head>\n<script type="application/json" id="design-meta">%s</script>\n</head><body>%s</body></html>\n' "$2" "${3:-mockup}" >"$1"
}
_drtmp="$(mktemp -d)"

d="$_drtmp/d1"; drg_repo "$d"
out="$(drg_run "$d" index)"
check "index: an empty registry reports 'no designs discovered', not a crash" "no designs discovered" "$out"

page "$d/docs/ui-options/AST-900.html" '{"designId": "AST-900", "round": 1, "tags": ["chat", "chat-composer"], "createdDate": "2026-01-01", "finalizedOption": null, "pickDate": null}'
out="$(drg_run "$d" index)"
check "index: discovers the embedded-block page" "AST-900 r1" "$out"
check "index: parses its tags" "tags=[chat,chat-composer]" "$out"
check "index: an undecided design reports DRAFT/UNDECIDED" "finalized=DRAFT/UNDECIDED" "$out"
check "index: names the page relative to the repository" "page=docs/ui-options/AST-900.html" "$out"
check_absent "index: no task-tracking columns" "staleness=" "$out"

out="$(drg_run "$d" find --tags chat)"
check "find --tags chat: matches a design tagged chat" "AST-900" "$out"
out="$(drg_run "$d" find --tags=chat-composer)"
check "find --tags=: matches via a DIFFERENT one of its tags (ANY, not ALL)" "AST-900" "$out"
out="$(drg_run "$d" find --tags nonexistent-tag,other)"
check "find: no match reports cleanly" "design-registry: no design matches tags ['nonexistent-tag', 'other']" "$out"
out="$(drg_run "$d" find --tags ,)"; rc=$?
check_rc "find: an empty tag list exits 2" 2 "$rc"
check "find: an empty tag list says so" "--tags must name at least one tag" "$out"

printf '<!doctype html><html><head></head><body>no block</body></html>' >"$d/docs/ui-options/AST-901.html"
printf '<script type="application/json" id="design-meta">{not json</script>' >"$d/docs/ui-options/AST-902.html"
out="$(drg_run "$d" index)"
check_absent "index: a page with no block adds no record" "AST-901" "$out"
check_absent "index: a page with a broken block adds no record" "AST-902" "$out"
check "index: the good page is still listed" "AST-900" "$out"

# pick rewrites the block in place and keeps everything around it.
page "$d/docs/ui-options/AST-930.html" '{"designId": "AST-930", "round": 1, "tags": ["chat"], "createdDate": "2026-01-01", "finalizedOption": null, "pickDate": null, "owner": "kept as given"}' '<h1>Option A</h1><p>surrounding content must survive untouched</p>'
before_tail="$(tail -c 20 "$d/docs/ui-options/AST-930.html" | od -c)"
out="$(drg_run "$d" pick AST-930 "Option A" --date 2026-02-01)"
check "pick: reports where it recorded the pick" "design-registry: recorded pick for AST-930 r1 in page docs/ui-options/AST-930.html" "$out"
pc="$(cat "$d/docs/ui-options/AST-930.html")"
check "pick: the surrounding HTML survives untouched" "surrounding content must survive untouched" "$pc"
check "pick: the page keeps its head" "<!doctype html><html><head>" "$pc"
check "pick: the file ending is unchanged" "$before_tail" "$(tail -c 20 "$d/docs/ui-options/AST-930.html" | od -c)"
meta="$(sed -n 's/.*<script type="application\/json" id="design-meta">\(.*\)<\/script>.*/\1/p' "$d/docs/ui-options/AST-930.html")"
check "pick: finalizedOption recorded" "Option A" "$(jq -r .finalizedOption <<<"$meta")"
check "pick: pickDate recorded" "2026-02-01" "$(jq -r .pickDate <<<"$meta")"
check "pick: keys another tool added stay as given" "kept as given" "$(jq -r .owner <<<"$meta")"
out="$(drg_run "$d" index)"
check "pick: the finalized option shows in index" "AST-930 r1 tags=[chat] finalized=Option A" "$out"
out="$(drg_run "$d" pick AST-930 B)"
check "pick: defaults the date to today" "$(date +%F)" "$(sed -n 's/.*"pickDate":"\([^"]*\)".*/\1/p' "$d/docs/ui-options/AST-930.html")"
out="$(drg_run "$d" pick NOPE A)"; rc=$?
check_rc "pick: an unknown design exits 1" 1 "$rc"
check "pick: an unknown design says nothing was recorded" "no page with a design-meta block for NOPE r1" "$out"
out="$(drg_run "$d" pick AST-930 2>&1)"; rc=$?
check_rc "pick: a missing option exits 2" 2 "$rc"

# Rounds: -r<N> names an exact round; a bare id means the highest round.
d2="$_drtmp/d2"; drg_repo "$d2"
page "$d2/docs/ui-options/AST-940.html" '{"designId": "AST-940", "round": 1, "tags": ["chat"], "finalizedOption": null}'
page "$d2/docs/ui-options/AST-940-r2.html" '{"designId": "AST-940", "round": 2, "tags": ["chat"], "finalizedOption": null}'
drg_run "$d2" pick AST-940 A >/dev/null
out="$(drg_run "$d2" index)"
check "bare id picks the highest round" "AST-940 r2 tags=[chat] finalized=A" "$out"
check "round 1 stays undecided" "AST-940 r1 tags=[chat] finalized=DRAFT/UNDECIDED" "$out"
drg_run "$d2" pick AST-940-r1 C >/dev/null
out="$(drg_run "$d2" index)"
check "explicit -r1 addresses round 1" "AST-940 r1 tags=[chat] finalized=C" "$out"
first="$(grep -n 'AST-940 r1' <<<"$out" | cut -d: -f1)"; second="$(grep -n 'AST-940 r2' <<<"$out" | cut -d: -f1)"
check_rc "index lists rounds in order" 1 "$(( ${first:-9} < ${second:-0} ? 1 : 0 ))"

# A finalized page that only lives in the hub is flagged; pick archives it.
d3="$_drtmp/d3"; drg_repo "$d3"
page "$d3/.claude/ui-hub/html/AST-970-r1.html" '{"designId": "AST-970", "round": 1, "tags": ["chat"], "finalizedOption": null}' 'the real hub mockup bytes'
out="$(drg_run "$d3" index)"
check "a hub-only draft is listed with its hub page" "page=.claude/ui-hub/html/AST-970-r1.html" "$out"
check_absent "a hub-only draft is not an anomaly" "ANOMALY" "$out"
out="$(drg_run "$d3" pick AST-970 A)"
check "pick on a hub-only page archives a tracked copy" "archived a tracked copy to docs/ui-options/AST-970.html (was hub-only)" "$out"
check "the archived copy carries the mockup" "the real hub mockup bytes" "$(cat "$d3/docs/ui-options/AST-970.html" 2>/dev/null)"
check "the archived copy carries the pick" '"finalizedOption":"A"' "$(cat "$d3/docs/ui-options/AST-970.html" 2>/dev/null)"
out="$(drg_run "$d3" index)"
check "the tracked copy wins over the hub copy" "page=docs/ui-options/AST-970.html" "$out"
check_absent "an archived design is no anomaly" "ANOMALY" "$out"
page "$d3/.claude/ui-hub/html/AST-971-r1.html" '{"designId": "AST-971", "round": 1, "tags": ["chat"], "finalizedOption": "B"}'
out="$(drg_run "$d3" index)"
check "a finalized hub-only page is flagged" "AST-971 r1 tags=[chat] finalized=B page=.claude/ui-hub/html/AST-971-r1.html ANOMALY=hub-only-not-archived" "$out"

# From a linked worktree, hub pages asked in the main checkout are visible,
# and an archived copy lands in the worktree's own docs/ui-options/.
d4="$_drtmp/d4"; drg_repo "$d4"
page "$d4/.claude/ui-hub/html/AST-980-r1.html" '{"designId": "AST-980", "round": 1, "tags": ["chat"], "finalizedOption": null}'
(cd "$d4" && git worktree add -q -b wt-drg "$d4-wt") >/dev/null 2>&1
r=ABSENT; [[ -d "$d4-wt/.claude/ui-hub" ]] && r=EXISTS
check "control: the worktree has no hub dir of its own" ABSENT "$r"
out="$(cd "$d4-wt" && bash "$DRG" find --tags chat 2>&1)"
check "from a worktree, a hub page asked in the main checkout is found" "AST-980 r1" "$out"
out="$(cd "$d4-wt" && bash "$DRG" pick AST-980 A 2>&1)"
check "pick from a worktree archives into the worktree" "archived a tracked copy to docs/ui-options/AST-980.html" "$out"
r=MISSING; [[ -f "$d4-wt/docs/ui-options/AST-980.html" ]] && r=ARCHIVED
check "the archived copy is in the worktree's docs/ui-options/" ARCHIVED "$r"

out="$(bash "$DRG" 2>&1)"; rc=$?
check_rc "no verb exits 2" 2 "$rc"
check "no verb prints the usage" "usage: design-registry.sh" "$out"

rm -rf "$_drtmp"
