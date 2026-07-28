#!/usr/bin/env bash
# section-design-registry.sh -- design-registry.py: tag/discoverability/
# staleness registry for Iterative UI mode's finalized designs (human-
# directed task: designs must be tagged, discoverable by tag, staleness-
# checked, and actually followed). Sourced by run-tests.sh; do not run
# standalone.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== design-registry (tag/discoverability/staleness registry for finalized UI designs) =="

DRG_SCRIPT="$PLUGIN/scripts/design-registry.py"

# drg_repo <dir> -- a throwaway git repo with the SAME governed path the
# registry's real TAG_PATH_MAP maps "chat" to, so staleness tests exercise
# the real git-log machinery hermetically (never the real repo's history).
drg_repo() {
    local dir="$1"
    mkdir -p "$dir/docs/ui-options" "$dir/plugins/spec-workflow/templates"
    (cd "$dir" && git init -q && git config user.email t@t.com && git config user.name t)
    echo "template v1" >"$dir/plugins/spec-workflow/templates/neural-view.html"
    (cd "$dir" && git add -A && git commit -q -m "init")
}

drg_run() {
    local dir="$1"; shift
    DESIGN_REGISTRY_ROOT="$dir" python3 "$DRG_SCRIPT" "$@" 2>&1
}

# ------------------------------------------------------------------------
echo "-- unit: index -- an empty registry (no pages, no sidecars) reports cleanly, never crashes --"
d="$(mktemp -d)"
drg_repo "$d"
out="$(drg_run "$d" index)"
check "index: an empty registry reports 'no designs discovered', not a crash" "no designs discovered" "$out"

# ------------------------------------------------------------------------
echo "-- unit: index/find -- a page with an embedded design-meta block is discovered and its tags parsed --"
cat >"$d/docs/ui-options/AST-900.html" <<'EOF'
<!doctype html><html><head>
<script type="application/json" id="design-meta">{"designId": "AST-900", "round": 1, "tags": ["chat", "chat-composer"], "createdDate": "2026-01-01", "finalizedOption": null, "pickDate": null}</script>
</head><body>mockup</body></html>
EOF
out="$(drg_run "$d" index)"
check "index: discovers the embedded-block page" "AST-900 r1" "$out"
check "index: parses its tags" "tags=[chat,chat-composer]" "$out"
check "index: an undecided design reports DRAFT/UNDECIDED, never a crash on a null finalizedOption" \
    "finalized=DRAFT/UNDECIDED" "$out"

out="$(drg_run "$d" find --tags chat)"
check "find --tags chat: matches a design tagged chat" "AST-900" "$out"
out="$(drg_run "$d" find --tags chat-composer)"
check "find --tags chat-composer: matches via a DIFFERENT one of its tags (ANY, not ALL)" "AST-900" "$out"
out="$(drg_run "$d" find --tags nonexistent-tag)"
check "find --tags nonexistent-tag: no match reports cleanly, never a crash" "no design matches" "$out"

# ------------------------------------------------------------------------
echo "-- unit: a page with NO embedded block (a legacy page) is tolerated, not broken -- retro-taggable via a sidecar --"
printf '<!doctype html><html><head></head><body>legacy mockup, no design-meta block at all</body></html>' \
    >"$d/docs/ui-options/AST-901.html"
out="$(drg_run "$d" index)"
check_absent "index: a legacy page with no block contributes no phantom record (nothing to crash on)" "AST-901" "$out"

out="$(drg_run "$d" backfill AST-901 --tags trace-inspector --page docs/ui-options/AST-901.html)"
check "backfill: reports the sidecar path it wrote" "AST-901.meta.json" "$out"
out="$(drg_run "$d" find --tags trace-inspector)"
check "find: the legacy page IS now discoverable by tag, via its sidecar" "AST-901" "$out"
check "find: the sidecar's declared page path is reported" "docs/ui-options/AST-901.html" "$out"

echo "-- unit: backfill -- a design with NO page at all (e.g. AST-044 in the real repo) is still tracked --"
out="$(drg_run "$d" backfill AST-902 --tags voice-visualizer --finalized B)"
check "backfill: a pageless design backfills cleanly" "AST-902.meta.json" "$out"
out="$(drg_run "$d" find --tags voice-visualizer)"
check "find: a pageless design is still discoverable by tag" "AST-902" "$out"
check "find: a pageless design reports page=(none), never a crash" "page=(none)" "$out"

echo "-- unit: backfill -- idempotent: re-running with the same arguments produces byte-identical output --"
first_sidecar="$(cat "$d/docs/ui-options/AST-902.meta.json")"
drg_run "$d" backfill AST-902 --tags voice-visualizer --finalized B >/dev/null
second_sidecar="$(cat "$d/docs/ui-options/AST-902.meta.json")"
if [[ "$first_sidecar" == "$second_sidecar" ]]; then r=IDENTICAL; else r=DIFFER; fi
check "backfill: re-running with identical args is byte-identical (idempotent)" "IDENTICAL" "$r"

# ------------------------------------------------------------------------
echo "-- unit: staleness -- a DRAFT (never finalized) design reports DRAFT, never STALE/FRESH/UNAPPLIED --"
out="$(drg_run "$d" staleness AST-900)"
check "staleness: an undecided design reports DRAFT" "staleness=DRAFT" "$out"

echo "-- unit: staleness -- a finalized-but-never-applied design reports UNAPPLIED, not a guess --"
drg_run "$d" pick AST-900 A --date 2026-01-02 >/dev/null
out="$(drg_run "$d" staleness AST-900)"
check "staleness: finalized but never applied -> UNAPPLIED (a real, recorded state)" "staleness=UNAPPLIED" "$out"

# ------------------------------------------------------------------------
echo "-- integration: staleness -- FRESH right after anchoring on the current HEAD (positive control) --"
d2="$(mktemp -d)"
drg_repo "$d2"
anchor="$(cd "$d2" && git rev-parse HEAD)"
drg_run "$d2" backfill AST-910 --tags chat --finalized A --applied-commit "$anchor" >/dev/null
out="$(drg_run "$d2" staleness AST-910)"
check "staleness: FRESH immediately after anchoring on HEAD (positive control -- proves the git-log path actually runs, not just defaults to FRESH)" \
    "staleness=FRESH" "$out"

echo "-- integration: staleness -- STALE after a REAL commit touching the governed path, past the anchor --"
echo "template v2" >"$d2/plugins/spec-workflow/templates/neural-view.html"
(cd "$d2" && git add -A && git commit -q -m "edit the governed template")
out="$(drg_run "$d2" staleness AST-910)"
check "staleness: a real change to the governed path after the anchor -> STALE" "staleness=STALE" "$out"
check "staleness: the STALE detail names the commit that changed it" "edit the governed template" "$out"

echo "-- integration: staleness -- FRESH again for an UNRELATED commit that never touches the governed path --"
d3="$(mktemp -d)"
drg_repo "$d3"
anchor3="$(cd "$d3" && git rev-parse HEAD)"
mkdir -p "$d3/plugins/spec-workflow/scripts"
echo "unrelated" >"$d3/plugins/spec-workflow/scripts/unrelated.py"
(cd "$d3" && git add -A && git commit -q -m "unrelated change")
drg_run "$d3" backfill AST-911 --tags chat --finalized A --applied-commit "$anchor3" >/dev/null
out="$(drg_run "$d3" staleness AST-911)"
check "staleness: a commit that never touches the governed path leaves the design FRESH" "staleness=FRESH" "$out"

# ------------------------------------------------------------------------
echo "-- unit: staleness -- an applied-by-NOTE (no commit hash) design falls back to the pick-date anchor --"
d4="$(mktemp -d)"
drg_repo "$d4"
# pick BEFORE the repo's only commit exists is impossible to arrange
# meaningfully with a single init commit -- use a pick date far in the
# FUTURE relative to the fixture's commits, proving the pick-date anchor
# itself is what is being consulted (nothing since a future date).
drg_run "$d4" backfill AST-912 --tags chat --finalized A --pick-date 2099-01-01 --applied-note "applied manually, no single commit" >/dev/null
out="$(drg_run "$d4" staleness AST-912)"
check "staleness: applied-by-note with a future pick-date anchor reports FRESH (nothing changed since 2099)" \
    "staleness=FRESH" "$out"

d5="$(mktemp -d)"
drg_repo "$d5"
drg_run "$d5" backfill AST-913 --tags chat --finalized A --pick-date 1999-01-01 --applied-note "applied manually, no single commit" >/dev/null
out="$(drg_run "$d5" staleness AST-913)"
check "staleness: applied-by-note with a past pick-date anchor reports STALE (the init commit itself postdates 1999)" \
    "staleness=STALE" "$out"

# ------------------------------------------------------------------------
echo "-- unit: applied -- records a commit-shaped value as a commit (staleness anchors on it) --"
d6="$(mktemp -d)"
drg_repo "$d6"
anchor6="$(cd "$d6" && git rev-parse HEAD)"
drg_run "$d6" backfill AST-920 --tags chat --finalized A >/dev/null
out="$(drg_run "$d6" applied AST-920 "$anchor6")"
check "applied: reports what it recorded" "recorded applied for AST-920" "$out"
sidecar="$(cat "$d6/docs/ui-options/AST-920.meta.json")"
check "applied: a full-length hex string is stored as commit, not note" "\"commit\": \"$anchor6\"" "$sidecar"
check "applied: note stays null when a commit was recognized" "\"note\": null" "$sidecar"

echo "-- unit: applied -- records a non-commit-shaped value as a note (staleness falls back to pick date) --"
out="$(drg_run "$d6" applied AST-920 "landed manually, see PR #123")"
sidecar="$(cat "$d6/docs/ui-options/AST-920.meta.json")"
check "applied: a plain-English value is stored as a note, not a commit" "\"note\": \"landed manually, see PR #123\"" "$sidecar"
check "applied: commit stays null when a note was recognized" "\"commit\": null" "$sidecar"

# ------------------------------------------------------------------------
echo "-- unit: pick -- rewrites the embedded block in place (finalizedOption + pickDate), never corrupts the surrounding HTML --"
d7="$(mktemp -d)"
drg_repo "$d7"
cat >"$d7/docs/ui-options/AST-930.html" <<'EOF'
<!doctype html><html><head>
<script type="application/json" id="design-meta">{"designId": "AST-930", "round": 1, "tags": ["chat"], "createdDate": "2026-01-01", "finalizedOption": null, "pickDate": null}</script>
</head><body><h1>Option A</h1><p>surrounding content must survive untouched</p></body></html>
EOF
drg_run "$d7" pick AST-930 A --date 2026-02-01 >/dev/null
page_content="$(cat "$d7/docs/ui-options/AST-930.html")"
check "pick: the surrounding HTML body survives the in-place block rewrite untouched" \
    "surrounding content must survive untouched" "$page_content"
out="$(drg_run "$d7" index)"
check "pick: the finalized option now shows in index" "finalized=A" "$out"
check "pick: staleness now reports beyond DRAFT (the design is decided)" "staleness=UNAPPLIED" "$out"

# ------------------------------------------------------------------------
echo "-- unit: -r<N> id form -- addresses an exact round directly, distinct from the bare id's latest-round default --"
d8="$(mktemp -d)"
drg_repo "$d8"
drg_run "$d8" backfill AST-940 --round 1 --tags chat --finalized A >/dev/null
drg_run "$d8" backfill AST-940 --round 2 --tags chat >/dev/null
out_bare="$(drg_run "$d8" staleness AST-940)"
check "bare id: resolves to the HIGHEST round found (round 2, DRAFT -- never finalized)" "r2 tags" "$out_bare"
out_r1="$(drg_run "$d8" staleness AST-940-r1)"
check "explicit -r1: addresses round 1 specifically, distinct from the bare id's round-2 default" "r1 tags" "$out_r1"
check "explicit -r1: round 1 was finalized, round 2 was not -- proves they are genuinely separate records" \
    "finalized=A" "$out_r1"

# ------------------------------------------------------------------------
echo "-- unit: ANOMALY -- a finalized design whose sidecar declares a page under the gitignored hub is flagged, not silently trusted --"
d10="$(mktemp -d)"
drg_repo "$d10"
mkdir -p "$d10/.claude/ui-hub/html"
printf 'hub-only mockup, never archived' >"$d10/.claude/ui-hub/html/AST-960-r1.html"
mkdir -p "$d10/docs/ui-options"
cat >"$d10/docs/ui-options/AST-960.meta.json" <<'EOF'
{"designId": "AST-960", "round": 1, "tags": ["chat"], "createdDate": "2026-01-01", "finalizedOption": "A", "pickDate": "2026-01-02", "applied": null, "page": ".claude/ui-hub/html/AST-960-r1.html"}
EOF
out="$(drg_run "$d10" index)"
check "ANOMALY: a finalized design whose only page is a gitignored-hub path is flagged" "ANOMALY=hub-only-not-archived" "$out"

echo "-- unit: ANOMALY -- a finalized design whose page is already tracked carries no anomaly marker (positive control) --"
cat >"$d10/docs/ui-options/AST-961.html" <<'EOF'
<!doctype html><html><head></head><body>tracked mockup</body></html>
EOF
cat >"$d10/docs/ui-options/AST-961.meta.json" <<'EOF'
{"designId": "AST-961", "round": 1, "tags": ["chat"], "createdDate": "2026-01-01", "finalizedOption": "A", "pickDate": "2026-01-02", "applied": null, "page": "docs/ui-options/AST-961.html"}
EOF
out_961="$(drg_run "$d10" staleness AST-961)"
check_absent "ANOMALY: a tracked-page finalized design carries no anomaly marker (proves the check is not always-on -- AST-960 in the SAME fixture stays flagged, see above)" \
    "ANOMALY" "$out_961"

# ------------------------------------------------------------------------
echo "-- integration: backfill/pick auto-archive a hub-only finalized design into the tracked dir --"
d11="$(mktemp -d)"
drg_repo "$d11"
mkdir -p "$d11/.claude/ui-hub/html"
printf 'the real hub mockup bytes' >"$d11/.claude/ui-hub/html/AST-970-r1.html"
out="$(drg_run "$d11" backfill AST-970 --tags chat --finalized A)"
check "backfill: auto-detects and archives a hub-only page for a newly-finalized design" \
    "archived a tracked copy to docs/ui-options/AST-970.html" "$out"
if [[ -f "$d11/docs/ui-options/AST-970.html" ]]; then r=ARCHIVED; else r=MISSING; fi
check "backfill: the archived file actually landed in the tracked dir" "ARCHIVED" "$r"
archived_content="$(cat "$d11/docs/ui-options/AST-970.html")"
check "backfill: the archived copy is a real, byte-faithful copy of the hub original" "the real hub mockup bytes" "$archived_content"
out="$(drg_run "$d11" index)"
check_absent "backfill: the now-archived design carries no ANOMALY marker" "ANOMALY" "$out"

# ------------------------------------------------------------------------
echo "-- integration: worktree visibility -- a hub-only design asked from the MAIN checkout is still findable from a linked WORKTREE --"
echo "-- (dev#-- the exact incident: a lane in its own worktree resolved LIVE_HTML_DIR against its OWN toplevel, saw nothing, and concluded no design existed) --"
d12="$(mktemp -d)"
drg_repo "$d12"
mkdir -p "$d12/.claude/ui-hub/html"
printf '<!doctype html><html><head></head><body>hub-only, asked from main</body></html>' \
    >"$d12/.claude/ui-hub/html/AST-980-r1.html"
(cd "$d12" && git worktree add -q -b wt-design-registry-test "$d12-wt" >/dev/null 2>&1)
out="$(drg_run "$d12-wt" find --tags chat)"
check_absent "worktree visibility control: BEFORE backfill, nothing matches yet (proves the assertion below is a real find, not a tautology)" \
    "AST-980" "$out"
# the worktree fixture's OWN .claude/ui-hub/ does not exist at all -- this
# is the exact condition that broke naive --show-toplevel resolution.
if [[ -d "$d12-wt/.claude/ui-hub" ]]; then r=EXISTS; else r=ABSENT; fi
check "worktree visibility control: the worktree fixture has no .claude/ui-hub of its own (the real failure condition)" "ABSENT" "$r"
drg_run "$d12-wt" backfill AST-980 --tags chat --finalized A >/dev/null
out="$(drg_run "$d12-wt" find --tags chat)"
check "worktree visibility: invoked FROM the worktree, finds a hub-only page that exists ONLY in the main checkout" "AST-980" "$out"
check_absent "worktree visibility: no anomaly once auto-archived" "ANOMALY" "$out"
if [[ -f "$d12-wt/docs/ui-options/AST-980.html" ]]; then r=ARCHIVED; else r=MISSING; fi
check "worktree visibility: the auto-archived copy lands in the WORKTREE's own docs/ui-options/ (branch-relative, not the main checkouts)" \
    "ARCHIVED" "$r"
(cd "$d12" && git worktree remove -f "$d12-wt" >/dev/null 2>&1)

# ------------------------------------------------------------------------
echo "-- unit: TAG_PATH_MAP fails SAFE for an unmapped tag -- defaults to the template rather than checking nothing --"
d13="$(mktemp -d)"
drg_repo "$d13"
anchor13="$(cd "$d13" && git rev-parse HEAD)"
drg_run "$d13" backfill AST-990 --tags totally-unmapped-tag --finalized A --applied-commit "$anchor13" >/dev/null
out="$(drg_run "$d13" staleness AST-990)"
check "TAG_PATH_MAP fail-safe: an unmapped tag still gets a governed path (UNAPPLIED/FRESH, not a crash)" "AST-990" "$out"
echo "template v2 -- unmapped-tag design should now go STALE" >"$d13/plugins/spec-workflow/templates/neural-view.html"
(cd "$d13" && git add -A && git commit -q -m "edit the governed template")
out="$(drg_run "$d13" staleness AST-990)"
check "TAG_PATH_MAP fail-safe: an unmapped tag's design goes STALE on a real change -- proves it is actually checked, not silently skipped" \
    "staleness=STALE" "$out"

# ------------------------------------------------------------------------
echo "-- unit: APPLIED-vs-DRAFT -- an applied-but-undecided design is distinct from a true never-decided DRAFT --"
d14="$(mktemp -d)"
drg_repo "$d14"
anchor14="$(cd "$d14" && git rev-parse HEAD)"
# true DRAFT: never picked, never applied.
drg_run "$d14" backfill AST-995 --tags chat >/dev/null
out="$(drg_run "$d14" staleness AST-995)"
check "APPLIED-vs-DRAFT: a never-picked, never-applied design is a true DRAFT" "finalized=DRAFT/UNDECIDED" "$out"
check "APPLIED-vs-DRAFT: a true DRAFT's staleness state is DRAFT, not FRESH/STALE" "staleness=DRAFT" "$out"

# applied, option unknown: the voice-visualizer shape -- finalizedOption
# stays unset, applied.commit IS recorded.
drg_run "$d14" applied AST-995 "$anchor14" >/dev/null
out="$(drg_run "$d14" staleness AST-995)"
check_absent "APPLIED-vs-DRAFT: once applied, no longer collapses into DRAFT/UNDECIDED" "DRAFT/UNDECIDED" "$out"
check "APPLIED-vs-DRAFT: an applied-but-undecided design shows APPLIED (option unknown)" "finalized=APPLIED (option unknown)" "$out"
check "APPLIED-vs-DRAFT: an applied-but-undecided design gets REAL staleness checking (FRESH right after its own anchor commit)" \
    "staleness=FRESH" "$out"
echo "template v2" >"$d14/plugins/spec-workflow/templates/neural-view.html"
(cd "$d14" && git add -A && git commit -q -m "edit the governed template")
out="$(drg_run "$d14" staleness AST-995)"
check "APPLIED-vs-DRAFT: an applied-but-undecided design goes genuinely STALE on a real change (not stuck showing DRAFT forever)" \
    "staleness=STALE" "$out"

echo "-- unit: APPLIED-vs-DRAFT -- the no-id staleness listing (what preflight.sh scans) now includes applied-but-undecided designs --"
out="$(drg_run "$d14" staleness)"
check "APPLIED-vs-DRAFT: an applied-but-undecided design surfaces in the default (no-id) staleness scan -- this is exactly what preflight.sh's WARN reads" \
    "AST-995" "$out"

# ------------------------------------------------------------------------
echo "-- unit: design-registry-preflight.sh -- blocks/allows/overrides directly, no board.sh involved --"
DRP="$PLUGIN/scripts/design-registry-preflight.sh"

d15="$(mktemp -d)"
drg_repo "$d15"
out="$(bash "$DRP" --root "$d15" --issue 501 2>&1)"; rc=$?
check "design-registry-preflight: an issue with NO registered design allows silently" "" "$out"
check_rc "design-registry-preflight: an issue with NO registered design exits 0" 0 "$rc"

drg_run "$d15" backfill AST-501 --tags chat --finalized A --issue 501 >/dev/null
out="$(bash "$DRP" --root "$d15" --issue 501 2>&1)"; rc=$?
check "design-registry-preflight: BLOCKED when the registered design is UNAPPLIED" "BLOCKED: issue #501" "$out"
check "design-registry-preflight: names the fix action" "design-registry.py applied" "$out"
check_rc "design-registry-preflight: UNAPPLIED exits 2" 2 "$rc"

out="$(DESIGN_REGISTRY_OVERRIDE="human approved shipping without applying yet" bash "$DRP" --root "$d15" --issue 501 2>&1)"; rc=$?
check "design-registry-preflight: DESIGN_REGISTRY_OVERRIDE allows through" "WARNING" "$out"
check "design-registry-preflight: the override note itself is echoed (an actual recorded note, not a bare flag)" \
    "human approved shipping without applying yet" "$out"
check_rc "design-registry-preflight: override exits 0" 0 "$rc"

drg_run "$d15" applied AST-501 abc1234def >/dev/null
out="$(bash "$DRP" --root "$d15" --issue 501 2>&1)"; rc=$?
check "design-registry-preflight: once applied, no longer BLOCKED" "" "$out"
check_rc "design-registry-preflight: applied exits 0" 0 "$rc"

# a design exists for a DIFFERENT issue -- must never leak across issues.
drg_run "$d15" backfill AST-502 --tags trace-inspector --finalized B --issue 502 >/dev/null
out="$(bash "$DRP" --root "$d15" --issue 501 2>&1)"; rc=$?
check_rc "design-registry-preflight: an UNAPPLIED design registered for a DIFFERENT issue does not block this one" 0 "$rc"
out="$(bash "$DRP" --root "$d15" --issue 502 2>&1)"; rc=$?
check "design-registry-preflight: that OTHER issue is correctly blocked on its own UNAPPLIED design" "BLOCKED: issue #502" "$out"
check_rc "design-registry-preflight: that other issue exits 2" 2 "$rc"

# ------------------------------------------------------------------------
echo "-- integration: board.sh move to In review is mechanically blocked by an UNAPPLIED registered design (#461) --"
T4P="$(mktemp -d)"
( cd "$T4P" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$T4P/.claude" "$T4P/docs/ui-options" "$T4P/plugins/spec-workflow/templates"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T4P/.claude/project.json"
# same as the real repos own .gitignore -- without this, a plain `git add
# -A` sweeps gate.sh own gate-pass/telemetry artifacts into a commit, and a
# LATER gate.sh run then dirties them as modified TRACKED files, tripping
# gate-preflight.sh own tree-changed check for a reason unrelated to what
# this test is actually verifying.
printf ".claude/gate-pass\n.claude/telemetry.jsonl\n" >"$T4P/.gitignore"
echo template >"$T4P/plugins/spec-workflow/templates/neural-view.html"
( cd "$T4P" && git add -A && git commit -q -m "add template" )

T4PGH="$(mktemp -d)"
MUTATION_MARKER4="$T4PGH/mutated"
cat >"$T4PGH/gh" <<FAKE
#!/usr/bin/env bash
set -uo pipefail
case "\$1 \$2" in
    "project item-list") echo '{"items":[{"id":"ITEM_9","content":{"number":9}}]}' ;;
    "project item-edit") touch "$MUTATION_MARKER4" 2>/dev/null; echo "edited" ;;
    *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$T4PGH/gh"

DESIGN_REGISTRY_ROOT="$T4P" python3 "$PLUGIN/scripts/design-registry.py" backfill AST-461 --tags chat --finalized A --issue 9 >/dev/null
( cd "$T4P" && git add -A && git commit -q -m "backfill AST-461" )
( cd "$T4P" && bash "$PLUGIN/scripts/gate.sh" >/dev/null 2>&1 )

rm -f "$MUTATION_MARKER4"
out="$(cd "$T4P" && PATH="$T4PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 9 "In review" 2>&1)"; rc=$?
check "design-registry wiring: board.sh move blocked -- gate pass + red-first alone are not enough, the design is UNAPPLIED" \
    "BLOCKED: issue #9" "$out"
if [[ "$rc" -ne 0 ]]; then
    echo "ok   design-registry wiring: blocked move -- nonzero exit"
else
    echo "FAIL design-registry wiring: blocked move -- nonzero exit (got rc=$rc)"
    fails=$((fails+1))
fi
if [[ -f "$MUTATION_MARKER4" ]]; then
    echo "FAIL design-registry wiring: blocked move must not reach gh project item-edit"
    fails=$((fails+1))
else
    echo "ok   design-registry wiring: blocked move never reached gh project item-edit"
fi

# Mark it applied -- the SAME move now succeeds. `applied` only touches
# the gitignored sidecar (docs/ui-options/*.meta.json is tracked, but the
# repo fixture never .gitignores it here) -- re-commit + re-record the
# gate pass so the tree-fingerprint check (gate-preflight.sh, which runs
# BEFORE design-registry-preflight.sh in _do_move) does not itself block
# this on an unrelated stale-tree reason.
DESIGN_REGISTRY_ROOT="$T4P" python3 "$PLUGIN/scripts/design-registry.py" applied AST-461 "$(cd "$T4P" && git rev-parse HEAD)" >/dev/null
( cd "$T4P" && git add -A && git commit -q -m "mark AST-461 applied" )
( cd "$T4P" && bash "$PLUGIN/scripts/gate.sh" >/dev/null 2>&1 )
rm -f "$MUTATION_MARKER4"
out="$(cd "$T4P" && PATH="$T4PGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 9 "In review" 2>&1)"; rc=$?
check "design-registry wiring: once applied, the same move succeeds" "moved #9 -> In review" "$out"
check_rc "design-registry wiring: applied move exits 0" 0 "$rc"
if [[ -f "$MUTATION_MARKER4" ]]; then
    echo "ok   design-registry wiring: allowed move reached gh project item-edit"
else
    echo "FAIL design-registry wiring: allowed move should have reached gh project item-edit"
    fails=$((fails+1))
fi

# ------------------------------------------------------------------------
echo "-- integration: guard-board-move.sh (the Claude PreToolUse hook) independently blocks the same scenario --"
T4H="$(mktemp -d)"
( cd "$T4H" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$T4H/.claude" "$T4H/docs/ui-options" "$T4H/plugins/spec-workflow/templates"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T4H/.claude/project.json"
printf ".claude/gate-pass\n.claude/telemetry.jsonl\n" >"$T4H/.gitignore"
echo template >"$T4H/plugins/spec-workflow/templates/neural-view.html"
( cd "$T4H" && git add -A && git commit -q -m "add template" )
DESIGN_REGISTRY_ROOT="$T4H" python3 "$PLUGIN/scripts/design-registry.py" backfill AST-462 --tags chat --finalized A --issue 11 >/dev/null
( cd "$T4H" && git add -A && git commit -q -m "backfill AST-462" )
( cd "$T4H" && bash "$PLUGIN/scripts/gate.sh" >/dev/null 2>&1 )

out="$(hookjson 'bash board.sh move 11 \"In review\"' | (cd "$T4H" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "design-registry wiring (hook): guard-board-move.sh independently blocks on an UNAPPLIED registered design" \
    "BLOCKED: issue #11" "$out"
check "design-registry wiring (hook): still exits 2" "rc=2" "$out"

DESIGN_REGISTRY_ROOT="$T4H" python3 "$PLUGIN/scripts/design-registry.py" applied AST-462 "$(cd "$T4H" && git rev-parse HEAD)" >/dev/null
( cd "$T4H" && git add -A && git commit -q -m "mark AST-462 applied" )
( cd "$T4H" && bash "$PLUGIN/scripts/gate.sh" >/dev/null 2>&1 )
out="$(hookjson 'bash board.sh move 11 \"In review\"' | (cd "$T4H" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check_rc "design-registry wiring (hook): once applied, the hook allows -- exit 0" 0 "$(sed -n 's/^rc=//p' <<<"$out")"

rm -rf "$T4P" "$T4PGH" "$T4H"

# ------------------------------------------------------------------------
echo "-- unit: design-registry-preflight.sh -- fail-open is silent no longer: a broken registry still allows the move, but now WARNS (review round 3 item 2) --"
d16="$(mktemp -d)"
mkdir -p "$d16/scripts"
# a copy of the real preflight script, pointed (via its own HERE-relative
# lookup) at a scripts dir with NO design-registry.py at all -- the
# missing-script fail-open path.
cp "$PLUGIN/scripts/design-registry-preflight.sh" "$d16/scripts/design-registry-preflight.sh"
out="$(bash "$d16/scripts/design-registry-preflight.sh" --issue 1 2>&1)"; rc=$?
check_absent "fail-open (missing script): never BLOCKED" "BLOCKED" "$out"
check_rc "fail-open (missing script): exit 0" 0 "$rc"
check "fail-open (missing script): now WARNS instead of silently allowing" "WARNING: design-registry-preflight could not query the registry" "$out"

# the broken-registry-CRASHES path: a design-registry.py that raises on
# every invocation (simulates a malformed/corrupted install, not just a
# missing file).
mkdir -p "$d16/scripts2"
cp "$PLUGIN/scripts/design-registry-preflight.sh" "$d16/scripts2/design-registry-preflight.sh"
cat >"$d16/scripts2/design-registry.py" <<'PY'
import sys
sys.exit("simulated registry crash")
PY
out="$(bash "$d16/scripts2/design-registry-preflight.sh" --issue 1 2>&1)"; rc=$?
check_absent "fail-open (registry crashes): never BLOCKED" "BLOCKED" "$out"
check_rc "fail-open (registry crashes): exit 0" 0 "$rc"
check "fail-open (registry crashes): WARNS and names the exit code" "WARNING: design-registry-preflight could not query the registry" "$out"
check "fail-open (registry crashes): the warning surfaces the underlying failure text" "simulated registry crash" "$out"

echo "-- static: the fail-open contract is stated in the script header (review round 3: a grep for it previously found nothing) --"
header_grep="$(grep -c 'FAIL-OPEN CONTRACT' "$PLUGIN/scripts/design-registry-preflight.sh")"
check "design-registry-preflight.sh: header states the fail-open contract explicitly" "1" "$header_grep"

rm -rf "$d16"

# ------------------------------------------------------------------------
# review round 4, finding 1 (High): a sidecar that EXISTS but fails to
# parse must never be indistinguishable from "nothing was ever registered"
# -- that silently un-registers whatever enforcement its design was
# supposed to carry. Reviewer's live reproduction: corrupt
# docs/ui-options/AST-069.meta.json -> `for-issue 344` prints "no design
# registered for issue #344" rc=0, and design-registry-preflight.sh
# --issue 344 exits 0 and ALLOWS the move. Contrast with the
# script-missing/script-crash paths above (635b658), which correctly WARN
# instead of going quiet. Fix-safe posture chosen here matches the
# STRICTER of this branch's two existing fail-safe precedents: not just a
# WARNING (that would still ALLOW, same as the crash path -- wrong here,
# because unlike "the tool is broken", this is "the tool ran fine but a
# specific record it needed is corrupt and might be the very one that
# governs this issue"), but the TAG_PATH_MAP precedent (5c6227f): BLOCK.
echo "-- unit/integration: for-issue/preflight -- a CORRUPT sidecar must fail VISIBLY and fail SAFE, never silently un-register the design it governs (review round 4, finding 1) --"
d17="$(mktemp -d)"
drg_repo "$d17"
drg_run "$d17" backfill AST-950 --tags chat --finalized A --issue 344 >/dev/null

# Sanity: BEFORE corruption, this design is exactly the kind of record
# that's supposed to block the move (finalized, never applied).
out="$(drg_run "$d17" for-issue 344)"
check "for-issue (sanity, pre-corruption): AST-950 is registered and UNAPPLIED against issue #344" "staleness=UNAPPLIED" "$out"

# Corrupt the sidecar in place -- invalid JSON, simulating a partial
# write, a merge conflict marker left behind, or a manual edit gone
# wrong. _iter_sidecars() still yields this path (it's a real
# *.meta.json file); only _read_json's parse fails.
printf '{not valid json, missing everything' >"$d17/docs/ui-options/AST-950.meta.json"

out="$(drg_run "$d17" for-issue 344)"; rc=$?
check_absent "for-issue: a corrupt sidecar must NOT be reported as 'no design registered' -- that claim can no longer be verified" \
    "no design registered for issue #344" "$out"
check "for-issue: a corrupt sidecar surfaces a visible WARNING" "WARNING:" "$out"
check "for-issue: the warning names the actual unreadable sidecar" "AST-950.meta.json" "$out"
check "for-issue: the warning states what cannot be confirmed" "cannot confirm" "$out"
check_rc "for-issue: a corrupt sidecar returns a distinct non-zero/non-clean exit (inconclusive, never the clean rc=0 of a genuine no-match)" 3 "$rc"

out="$(bash "$PLUGIN/scripts/design-registry-preflight.sh" --root "$d17" --issue 344 2>&1)"; rc=$?
check "preflight: a corrupt sidecar BLOCKS the move -- fail SAFE, not fail-open (unlike the script-missing/script-crash paths, which correctly stay fail-open)" \
    "BLOCKED" "$out"
check_rc "preflight: corrupt sidecar exits 2 (blocking), same contract as a genuine UNAPPLIED design" 2 "$rc"
check "preflight: the block message names the unreadable-sidecar situation" "unreadable" "$out"

out="$(DESIGN_REGISTRY_OVERRIDE="known corrupt sidecar, filed as #999, safe to proceed" bash "$PLUGIN/scripts/design-registry-preflight.sh" --root "$d17" --issue 344 2>&1)"; rc=$?
check_rc "preflight: the same DESIGN_REGISTRY_OVERRIDE escape hatch still lets an intentional override through" 0 "$rc"
check "preflight: the override note is echoed for visibility, same as the UNAPPLIED-design override" "known corrupt sidecar, filed as #999, safe to proceed" "$out"

rm -rf "$d17"
