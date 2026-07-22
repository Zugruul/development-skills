#!/usr/bin/env bash
# section-kb-seed.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== knowledge-base-seed (#300, GL-050): kb-seed.py/.sh seed a knowledge identity brain =="
KBS_PY="$PLUGIN/scripts/kb-seed.py"
KBS_SH="$PLUGIN/scripts/kb-seed.sh"
BRAIN_PY="$PLUGIN/scripts/brain.py"

# -------------------------------------------------------------- fixture helper
# _kbs_fixture <dir>: a small project with one spec+backlog+epic, two design
# docs, one applied spec-delta, a README, and a git history -- exercises
# every source kind kb-seed.py discovers, kept small enough that the golden
# assertions below stay readable.
_kbs_fixture() {
    local d="$1"
    mkdir -p "$d/docs/design" "$d/docs/spec-deltas/applied" "$d/.claude"
    (
        cd "$d" || exit 1
        git init -q
        git config user.email test@test.com
        git config user.name test
        cat > SPEC.md <<'EOF'
# SPEC
## Section A
## Section B
EOF
        cat > docs/BACKLOG.md <<'EOF'
# Backlog
## E0
EOF
        cat > README.md <<'EOF'
# My Project
## Usage
EOF
        cat > docs/design/foo.md <<'EOF'
# Foo design
## Rationale
EOF
        cat > docs/design/bar.md <<'EOF'
# Bar design
## Rationale
EOF
        cat > docs/spec-deltas/applied/1.md <<'EOF'
---
task: '1'
spec: sw
sections: ["§1"]
---
## §1 -- ADDED
text
EOF
        cat > .claude/project.yaml <<'EOF'
schemaVersion: 2
project:
    name: kbs-fixture/proj
specs:
-   id: sw
    title: Test spec
    specPath: SPEC.md
    backlogPath: docs/BACKLOG.md
    epics:
    -   id: E0
        title: Foo epic
        taskRanges:
        -   - 1
            - 9
paths:
    designDir: docs/design
    specDeltaDir: docs/spec-deltas
EOF
        git add -A
        git commit -qm init >/dev/null
    )
}

_kbs_sha() { find "$1/.claude/identities" -type f 2>/dev/null | LC_ALL=C sort | xargs shasum -a 256 2>/dev/null; }

# --------------------------------------------------------- AC1: golden seed
KB1="$(mktemp -d)"
_kbs_fixture "$KB1"
out="$(python3 "$KBS_PY" "$KB1" seed; echo "rc=$?")"
check "seed: exits 0" "rc=0" "$out"
check "seed: summary reports 9 created" "9 created" "$out"
KB1_NOTES="$KB1/.claude/identities/knowledge/brain/notes"
for slug in spec-sw backlog-sw epic-sw-e0 design-foo design-bar spec-delta-1 doc-readme project-layout git-history; do
    if [[ -f "$KB1_NOTES/$slug.md" ]]; then
        echo "ok   seed: notes/$slug.md exists"
    else
        echo "FAIL seed: notes/$slug.md missing"
        fails=$((fails + 1))
    fi
done
SPEC_NOTE="$(cat "$KB1_NOTES/spec-sw.md" 2>/dev/null)"
check "seed: spec-sw carries source: seed provenance" 'source: "seed"' "$SPEC_NOTE"
check "seed: spec-sw carries a seed-path field naming the source file" "seed-path: SPEC.md" "$SPEC_NOTE"
check "seed: spec-sw carries a seed-commit field (40-hex sha)" "seed-commit:" "$SPEC_NOTE"
check "seed: spec-sw tagged with the spec id" "tags: [spec, sw]" "$SPEC_NOTE"
check "seed: spec-sw body reflects the source file's headers" "## Section A" "$SPEC_NOTE"
EPIC_NOTE="$(cat "$KB1_NOTES/epic-sw-e0.md" 2>/dev/null)"
check "seed: epic note names the epic id, title, spec and task range" "Epic E0 — Foo epic (spec sw, tasks 1-9)" "$EPIC_NOTE"
check "brain.sh directory: knowledge role listed" "## knowledge" "$(bash "$PLUGIN/scripts/brain.sh" "$KB1" directory 2>&1; cat "$KB1/.claude/identities/DIRECTORY.md" 2>/dev/null)"

# ---------------------------------------------------- AC2: idempotent no-op
_kbs_sha "$KB1" > "$KB1/before.sha"
out="$(python3 "$KBS_PY" "$KB1" seed; echo "rc=$?")"
check "re-seed unchanged: exits 0" "rc=0" "$out"
check "re-seed unchanged: summary reports 0 created/updated, 8 unchanged" "0 created, 0 updated, 9 unchanged" "$out"
_kbs_sha "$KB1" > "$KB1/after.sha"
if diff -q "$KB1/before.sha" "$KB1/after.sha" >/dev/null; then
    echo "ok   re-seed unchanged: notes/links.json/DIRECTORY.md byte-identical (sha256)"
else
    echo "FAIL re-seed unchanged: notes/links.json/DIRECTORY.md changed on a no-op re-seed"
    fails=$((fails + 1))
fi

# ------------------------------------------------- AC3: changed source evolves in place
# Subshell, NOT a brace group -- section-*.sh files are SOURCED into the
# runner process, so a bare `{ cd ...; }` would leak the cwd change into
# every later section (including ones that `rm -rf` their own fixture dirs
# out from under the still-cd'd runner) -- a subshell's cd is scoped to it.
(
    cd "$KB1" || exit 1
    printf '## Section C\n' >> SPEC.md
    git add -A && git commit -qm "amend spec" >/dev/null
)
out="$(python3 "$KBS_PY" "$KB1" seed; echo "rc=$?")"
check "re-seed changed source: exits 0" "rc=0" "$out"
check "re-seed changed source: spec-sw updates in place (git-history also updates)" "2 updated" "$out"
NCOUNT="$(find "$KB1_NOTES" -name '*.md' | wc -l | tr -d ' ')"
check "re-seed changed source: note count unchanged (no duplicate slug)" "9" "$NCOUNT"
UPDATED_NOTE="$(cat "$KB1_NOTES/spec-sw.md" 2>/dev/null)"
check "re-seed changed source: updated body reflects the new header" "## Section C" "$UPDATED_NOTE"
check "re-seed changed source: strength bumped (never-delete, in-place update)" "strength: 2" "$UPDATED_NOTE"
if [[ -f "$KB1_NOTES/spec-sw.md" ]]; then
    echo "ok   re-seed changed source: superseded note stays on disk at the same slug"
else
    echo "FAIL re-seed changed source: note file missing after update"
    fails=$((fails + 1))
fi
rm -rf "$KB1"

# --------------------------------------------------------- AC4: shrink guard
KB4="$(mktemp -d)"
_kbs_fixture "$KB4"
( # subshell -- see the AC3 comment above for why this can't be a brace group
    cd "$KB4" || exit 1
    for i in 1 2 3 4 5 6 7; do printf '# Doc %s\n' "$i" > "docs/design/d$i.md"; done
    git add -A && git commit -qm "more design docs" >/dev/null
)
python3 "$KBS_PY" "$KB4" seed >/dev/null
_kbs_sha "$KB4" > "$KB4/pre-guard.sha"
(
    cd "$KB4" || exit 1
    for i in 1 2 3 4 5 6; do printf '# Doc %s changed\n## New section\n' "$i" > "docs/design/d$i.md"; done
    git add -A && git commit -qm "change 6 design doc headers" >/dev/null
)
out="$(python3 "$KBS_PY" "$KB4" seed; echo "rc=$?")"
check "shrink guard: over-threshold refuses (non-zero exit)" "rc=1" "$out"
check "shrink guard: names the count/total/pct" "note(s) (44%" "$out"
check "shrink guard: names the threshold/floor" "30% threshold, floor 5" "$out"
check "shrink guard: names a sample candidate slug" "design-d1" "$out"
check "shrink guard: offers the --force escape hatch" "Re-run with --force" "$out"
_kbs_sha "$KB4" > "$KB4/post-refusal.sha"
if diff -q "$KB4/pre-guard.sha" "$KB4/post-refusal.sha" >/dev/null; then
    echo "ok   shrink guard: nothing written on refusal (sha256)"
else
    echo "FAIL shrink guard: files changed despite refusal"
    fails=$((fails + 1))
fi
out="$(python3 "$KBS_PY" "$KB4" seed --force; echo "rc=$?")"
check "shrink guard --force: proceeds (exit 0)" "rc=0" "$out"
check "shrink guard --force: loud override summary" "SHRINK GUARD OVERRIDDEN (--force)" "$out"
rm -rf "$KB4"

# ---------------------------------------- AC5: no-knowledge-brain regression
KB5="$(mktemp -d)"
_kbs_fixture "$KB5"
printf 'dev lesson body.\n' | (cd "$KB5" && python3 "$BRAIN_PY" "$KB5" mint dev lesson-one --tags a --paths "SPEC.md" --source x) >/dev/null
before_recall="$(bash "$KBS_SH" >/dev/null 2>&1; cd "$KB5" && bash "$PLUGIN/scripts/brain.sh" recall dev --paths "SPEC.md" --keywords "a" 2>&1)"
python3 "$KBS_PY" "$KB5" seed >/dev/null
after_recall="$(cd "$KB5" && bash "$PLUGIN/scripts/brain.sh" recall dev --paths "SPEC.md" --keywords "a" 2>&1)"
if [[ "$before_recall" == "$after_recall" ]]; then
    echo "ok   no-knowledge-brain regression: dev recall byte-identical before/after seeding knowledge"
else
    echo "FAIL no-knowledge-brain regression: dev recall changed after a knowledge brain was seeded"
    echo "     before: $before_recall"
    echo "     after:  $after_recall"
    fails=$((fails + 1))
fi
rm -rf "$KB5"

# ----------------------------------- AC6: recall/explain work unmodified
KB6="$(mktemp -d)"
_kbs_fixture "$KB6"
python3 "$KBS_PY" "$KB6" seed >/dev/null
out="$(cd "$KB6" && bash "$PLUGIN/scripts/brain.sh" recall knowledge --paths "SPEC.md" --keywords "spec"; echo "rc=$?")"
check "brain.sh recall knowledge: exits 0 on the seeded fixture" "rc=0" "$out"
check "brain.sh recall knowledge: surfaces the seeded spec note" "spec-sw" "$out"
out="$(cd "$KB6" && bash "$PLUGIN/scripts/brain.sh" explain knowledge spec-sw; echo "rc=$?")"
check "brain.sh explain knowledge <slug>: exits 0 on the seeded fixture" "rc=0" "$out"
check "brain.sh explain knowledge <slug>: renders the note body" "Spec \`SPEC.md\`" "$out"
rm -rf "$KB6"

# --------------------------------------------------- AC7: spec delta, not spec edit
# Pre-fold the delta sits at spec-deltas/GL-050.md; after the In-review->QA
# fold it moves to spec-deltas/applied/gl-300.md (see build-next §Advancing).
# Either location satisfies AC7 — the requirement is delta-not-direct-edit.
GL050_DELTA="$HERE/../../../docs/spec-deltas/GL-050.md"
GL050_APPLIED="$HERE/../../../docs/spec-deltas/applied/gl-300.md"
if [[ -f "$GL050_DELTA" || -f "$GL050_APPLIED" ]]; then
    echo "ok   GL-050 spec delta exists (pending or applied)"
else
    echo "FAIL GL-050 spec delta missing from docs/spec-deltas/ (pending or applied/)"
    fails=$((fails + 1))
fi
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SPEC_DIFF="$(cd "$REPO_ROOT" && git diff --stat -- SPEC-GRAPHIFY.md 2>/dev/null)"
if [[ -z "$SPEC_DIFF" ]]; then
    echo "ok   SPEC-GRAPHIFY.md has no uncommitted diff (spec delta, not a direct spec edit)"
else
    echo "FAIL SPEC-GRAPHIFY.md has an uncommitted diff — GL-050 must land via docs/spec-deltas/GL-050.md, never a direct spec edit"
    fails=$((fails + 1))
fi

# ------------------------------------------------------ AC8: skill + README
KBSKILL="$PLUGIN/skills/knowledge-base-seed/SKILL.md"
if [[ -f "$KBSKILL" ]]; then echo "ok   knowledge-base-seed/SKILL.md exists"; else echo "FAIL knowledge-base-seed/SKILL.md missing"; fails=$((fails + 1)); fi
KBSKILL_BODY="$(cat "$KBSKILL" 2>/dev/null)"
check "knowledge-base-seed SKILL.md has a name frontmatter field" "name: knowledge-base-seed" "$KBSKILL_BODY"
check "knowledge-base-seed SKILL.md has a description frontmatter field" "description:" "$KBSKILL_BODY"
check "knowledge-base-seed SKILL.md invokes kb-seed.sh" "kb-seed.sh" "$KBSKILL_BODY"
README_BODY="$(cat "$PLUGIN/README.md" 2>/dev/null)"
check "README skills table: knowledge-base-seed row (literal, exact case)" "| \`knowledge-base-seed\` |" "$README_BODY"

# ------------------------------------------------------------ script hygiene
if [[ -x "$KBS_SH" ]]; then echo "ok   kb-seed.sh is executable"; else echo "FAIL kb-seed.sh is not executable"; fails=$((fails + 1)); fi
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x "$KBS_SH" >/dev/null 2>&1; then
        echo "ok   kb-seed.sh passes shellcheck -x"
    else
        echo "FAIL kb-seed.sh fails shellcheck -x"
        fails=$((fails + 1))
    fi
fi
