#!/usr/bin/env bash
# section-changelog.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== changelog.sh: type-bucket grouping (#165) =="
CGD="$(mktemp -d)"
(
    cd "$CGD" || exit 1
    git init -q
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "chore: init"
) >/dev/null 2>&1
ROOTSHA="$(cd "$CGD" && git rev-parse HEAD)"
(
    cd "$CGD" || exit 1
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "feat: add widget (#10)"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "fix: broken thing"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "docs: update readme"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "refactor: tidy internals"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "test: add coverage"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "retro: mint note"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "not conventional subject"
) >/dev/null 2>&1

out="$(cd "$CGD" && bash "$PLUGIN/scripts/changelog.sh" --from "$ROOTSHA" --to HEAD 2>&1)"
check "changelog.sh: Feat bucket header present" "### Feat" "$out"
check "changelog.sh: Feat bullet keeps PR reference" "- add widget (#10)" "$out"
check "changelog.sh: Fix bucket header present" "### Fix" "$out"
check "changelog.sh: Fix bullet text" "- broken thing" "$out"
check "changelog.sh: Docs bucket header present" "### Docs" "$out"
check "changelog.sh: Docs bullet text" "- update readme" "$out"
check "changelog.sh: Refactor bucket header present" "### Refactor" "$out"
check "changelog.sh: Refactor bullet text" "- tidy internals" "$out"
check "changelog.sh: Test bucket header present" "### Test" "$out"
check "changelog.sh: Test bullet text" "- add coverage" "$out"
check "changelog.sh: Retro bucket header present" "### Retro" "$out"
check "changelog.sh: Retro bullet text" "- mint note" "$out"
check "changelog.sh: Other bucket header present" "### Other" "$out"
check "changelog.sh: Other bullet keeps full subject" "- not conventional subject" "$out"
check_absent "changelog.sh: unused Chore bucket header not printed" "### Chore" "$out"

echo "== changelog.sh: --from/--to ref selection (#165) =="
MIDSHA="$(cd "$CGD" && git log --format=%H --grep="^fix: broken thing$" -1)"
out="$(cd "$CGD" && bash "$PLUGIN/scripts/changelog.sh" --from "$ROOTSHA" --to "$MIDSHA" 2>&1)"
check "changelog.sh: --to restricts range, includes commits up to --to" "- broken thing" "$out"
check_absent "changelog.sh: --to restricts range, excludes commits after --to" "- update readme" "$out"
check "changelog.sh: heading uses literal from/to refs" "## $ROOTSHA..$MIDSHA" "$out"

echo "== changelog.sh: Unreleased heading when --to defaults to untagged HEAD (#165) =="
out="$(cd "$CGD" && bash "$PLUGIN/scripts/changelog.sh" --from "$ROOTSHA" 2>&1)"
check "changelog.sh: no tag at HEAD -> Unreleased heading" "## Unreleased" "$out"

rm -rf "$CGD"

echo "== changelog.sh: default --from resolves the last spec-workflow--v* tag (#165) =="
TGD="$(mktemp -d)"
(
    cd "$TGD" || exit 1
    git init -q
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "chore: init"
    git tag spec-workflow--v1.0.0
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "feat: after tag one"
    git tag spec-workflow--v1.1.0
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "fix: after tag two"
    git tag other-nonmatching-tag
) >/dev/null 2>&1
out="$(cd "$TGD" && bash "$PLUGIN/scripts/changelog.sh" 2>&1)"
check "changelog.sh: default --from resolves most recent tag (heading)" "## spec-workflow--v1.1.0..HEAD" "$out"
check "changelog.sh: default --from excludes commits before the resolved tag" "- after tag two" "$out"
check_absent "changelog.sh: default --from excludes commits before the resolved tag (negative)" "- after tag one" "$out"
rm -rf "$TGD"

echo "== changelog.sh: default --from falls back to the first commit when no tag exists (#165) =="
NGD="$(mktemp -d)"
(
    cd "$NGD" || exit 1
    git init -q
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "chore: root"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "feat: only feature"
    git tag v-marker-not-matching-prefix
) >/dev/null 2>&1
FIRSTSHA="$(cd "$NGD" && git rev-list --max-parents=0 HEAD)"
out="$(cd "$NGD" && bash "$PLUGIN/scripts/changelog.sh" 2>&1)"
check "changelog.sh: no-tag fallback resolves the first commit as --from" "## $FIRSTSHA..HEAD" "$out"
check "changelog.sh: no-tag fallback includes commits after the root" "- only feature" "$out"
rm -rf "$NGD"

echo "== changelog.sh: --write prepends to a fresh file (#165) =="
WGD="$(mktemp -d)"
(
    cd "$WGD" || exit 1
    git init -q
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "chore: init"
) >/dev/null 2>&1
WROOTSHA="$(cd "$WGD" && git rev-parse HEAD)"
(
    cd "$WGD" || exit 1
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "feat: brand new file feature"
) >/dev/null 2>&1
FRESH="$WGD/CHANGELOG.md"
(cd "$WGD" && bash "$PLUGIN/scripts/changelog.sh" --from "$WROOTSHA" --write "$FRESH") >/dev/null 2>&1
check_rc "changelog.sh: --write on a fresh file exits 0" 0 $?
freshbody="$(cat "$FRESH" 2>/dev/null)"
check "changelog.sh: --write creates a # Changelog H1 for a fresh file" "# Changelog" "$freshbody"
check "changelog.sh: --write on a fresh file includes the new section" "- brand new file feature" "$freshbody"

echo "== changelog.sh: --write prepends to an existing file, preserving old content (#165) =="
printf '# Changelog\n\n## old-section\n### Fix\n- an old fix (abc1234)\n' > "$FRESH"
(
    cd "$WGD" || exit 1
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "fix: newer fix for the log"
) >/dev/null 2>&1
NEWFROM="$(cd "$WGD" && git log --format=%H --grep="^feat: brand new file feature$" -1)"
(cd "$WGD" && bash "$PLUGIN/scripts/changelog.sh" --from "$NEWFROM" --write "$FRESH") >/dev/null 2>&1
check_rc "changelog.sh: --write on an existing file exits 0" 0 $?
existbody="$(cat "$FRESH" 2>/dev/null)"
check "changelog.sh: --write prepends the new section" "- newer fix for the log" "$existbody"
check "changelog.sh: --write preserves the old section below" "## old-section" "$existbody"
check "changelog.sh: --write preserves old bullet content" "- an old fix (abc1234)" "$existbody"
newpos=$(grep -n "newer fix for the log" "$FRESH" | head -1 | cut -d: -f1)
oldpos=$(grep -n "old-section" "$FRESH" | head -1 | cut -d: -f1)
if [[ "$newpos" -lt "$oldpos" ]]; then cmp_rc=0; else cmp_rc=1; fi
check_rc "changelog.sh: --write new section appears before old section" 0 "$cmp_rc"

echo "== changelog.sh: --write stays idempotent across consecutive real writes (#165) =="
IDD="$(mktemp -d)"
(
    cd "$IDD" || exit 1
    git init -q
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "chore: init"
) >/dev/null 2>&1
IDROOT="$(cd "$IDD" && git rev-parse HEAD)"
(
    cd "$IDD" || exit 1
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "feat: first feature"
) >/dev/null 2>&1
IDFIRST="$(cd "$IDD" && git rev-parse HEAD)"
IDFILE="$IDD/CHANGELOG.md"
(cd "$IDD" && bash "$PLUGIN/scripts/changelog.sh" --from "$IDROOT" --write "$IDFILE") >/dev/null 2>&1
(
    cd "$IDD" || exit 1
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "fix: second fix"
) >/dev/null 2>&1
(cd "$IDD" && bash "$PLUGIN/scripts/changelog.sh" --from "$IDFIRST" --write "$IDFILE") >/dev/null 2>&1
idbody="$(cat "$IDFILE" 2>/dev/null)"
idfirstline="$(head -1 "$IDFILE" 2>/dev/null)"
idh1count="$(grep -cFx '# Changelog' "$IDFILE" 2>/dev/null)"
check "changelog.sh: --write second write keeps # Changelog as the very first line" "# Changelog" "$idfirstline"
check "changelog.sh: --write second write keeps exactly one H1 (count)" "1" "$idh1count"
check "changelog.sh: --write second write includes the newest section" "- second fix" "$idbody"
check "changelog.sh: --write second write still includes the first write's section" "- first feature" "$idbody"
rm -rf "$IDD"

rm -rf "$WGD"

# ============================================================================
# changelog.py — retro-generated CHANGELOG.md anchored on plugin.json semver
# history (#404). All fixtures below are THROWAWAY git repos built in mktemp
# -d -- never the real repo's live history, which grows every day and would
# make these assertions rot.
# ============================================================================

_cpj() { # _cpj <repo-dir> <version> -- write plugin.json at the canonical
         # relative path the generator reads (plugins/spec-workflow/.claude-plugin/plugin.json)
    local dir="$1" version="$2"
    mkdir -p "$dir/plugins/spec-workflow/.claude-plugin"
    printf '{\n    "name": "spec-workflow",\n    "version": "%s"\n}\n' "$version" \
        > "$dir/plugins/spec-workflow/.claude-plugin/plugin.json"
}

_cgcommit() { # _cgcommit <repo-dir> <date> <subject> [body] -- deterministic
              # author/committer date so heading dates are assertable exactly.
    local dir="$1" date="$2" subject="$3" body="${4:-}"
    (
        cd "$dir" || exit 1
        export GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date"
        if [[ -n "$body" ]]; then
            git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "$subject" -m "$body"
        else
            git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "$subject"
        fi
    ) >/dev/null 2>&1
}

echo "== changelog.py: version-window bucketing across a plugin.json bump (#404) =="
VWD="$(mktemp -d)"
(cd "$VWD" && git init -q) >/dev/null 2>&1
_cgcommit "$VWD" "2026-01-01T00:00:00" "feat: initial feature"
_cpj "$VWD" "0.1.0"
(cd "$VWD" && git add -A) >/dev/null 2>&1
_cgcommit "$VWD" "2026-01-02T00:00:00" "chore(release): spec-workflow v0.1.0"
_cgcommit "$VWD" "2026-01-03T00:00:00" "feat: add widget (#10)"
_cpj "$VWD" "0.2.0"
(cd "$VWD" && git add -A) >/dev/null 2>&1
_cgcommit "$VWD" "2026-01-10T00:00:00" "chore(release): spec-workflow v0.2.0"
_cgcommit "$VWD" "2026-01-11T00:00:00" "fix: broken thing"
python3 "$PLUGIN/scripts/changelog.py" generate --repo "$VWD" --output "$VWD/CHANGELOG.md" >/dev/null 2>&1
vwout="$(cat "$VWD/CHANGELOG.md" 2>/dev/null)"
check "changelog.py: v0.1.0 heading dated by its window's newest commit" "## v0.1.0 — 2026-01-03" "$vwout"
check "changelog.py: v0.2.0 heading dated by its window's newest commit" "## v0.2.0 — 2026-01-11" "$vwout"
check "changelog.py: pre-plugin.json commit buckets under the oldest known version" "initial feature" "$vwout"
check "changelog.py: post-bump commit buckets under the new version" "broken thing" "$vwout"
v1pos=$(grep -n "## v0.1.0" "$VWD/CHANGELOG.md" | head -1 | cut -d: -f1)
v2pos=$(grep -n "## v0.2.0" "$VWD/CHANGELOG.md" | head -1 | cut -d: -f1)
if [[ "$v2pos" -lt "$v1pos" ]]; then vwcmp_rc=0; else vwcmp_rc=1; fi
check_rc "changelog.py: versions render newest-first" 0 "$vwcmp_rc"
rm -rf "$VWD"

echo "== changelog.py: conventional classification into fixed-order groups (#404) =="
CVD="$(mktemp -d)"
(cd "$CVD" && git init -q) >/dev/null 2>&1
_cpj "$CVD" "1.0.0"
(cd "$CVD" && git add -A) >/dev/null 2>&1
_cgcommit "$CVD" "2026-02-01T00:00:00" "chore: init"
_cgcommit "$CVD" "2026-02-02T00:00:00" "feat(x): add feature"
_cgcommit "$CVD" "2026-02-03T00:00:00" "fix(x): fix bug"
_cgcommit "$CVD" "2026-02-04T00:00:00" "perf(x): speed up"
_cgcommit "$CVD" "2026-02-05T00:00:00" "refactor(x): tidy internals"
_cgcommit "$CVD" "2026-02-06T00:00:00" "docs(x): update docs"
_cgcommit "$CVD" "2026-02-07T00:00:00" "test(x): add coverage"
_cgcommit "$CVD" "2026-02-08T00:00:00" "ci(x): pipeline tweak"
_cgcommit "$CVD" "2026-02-09T00:00:00" "build(x): build tweak"
_cgcommit "$CVD" "2026-02-10T00:00:00" "style(x): reformat"
_cgcommit "$CVD" "2026-02-11T00:00:00" "totally not conventional subject"
python3 "$PLUGIN/scripts/changelog.py" generate --repo "$CVD" --output "$CVD/CHANGELOG.md" >/dev/null 2>&1
cvout="$(cat "$CVD/CHANGELOG.md" 2>/dev/null)"
check "changelog.py: Features group header" "### Features" "$cvout"
check "changelog.py: Features bullet with bold scope" "- **x:** add feature" "$cvout"
check "changelog.py: Fixes group header" "### Fixes" "$cvout"
check "changelog.py: Fixes bullet" "- **x:** fix bug" "$cvout"
check "changelog.py: Performance group header" "### Performance" "$cvout"
check "changelog.py: Performance bullet" "- **x:** speed up" "$cvout"
check "changelog.py: Refactoring group header" "### Refactoring" "$cvout"
check "changelog.py: Refactoring bullet" "- **x:** tidy internals" "$cvout"
check "changelog.py: Documentation group header" "### Documentation" "$cvout"
check "changelog.py: Documentation bullet" "- **x:** update docs" "$cvout"
check "changelog.py: Tests group header" "### Tests" "$cvout"
check "changelog.py: Tests bullet" "- **x:** add coverage" "$cvout"
check "changelog.py: CI/Build group header" "### CI/Build" "$cvout"
check "changelog.py: CI/Build bullet (ci)" "- **x:** pipeline tweak" "$cvout"
check "changelog.py: CI/Build bullet (build)" "- **x:** build tweak" "$cvout"
check "changelog.py: Chores group header" "### Chores" "$cvout"
check "changelog.py: Chores bullet (style)" "- **x:** reformat" "$cvout"
check "changelog.py: Other group header" "### Other" "$cvout"
check "changelog.py: Other bullet keeps full non-conventional subject" "- totally not conventional subject" "$cvout"

echo "== changelog.py: fixed group order is actually pinned, not just presence (#404 review round 1) =="
_grouppos() { grep -n "^### $2\$" "$1" | head -1 | cut -d: -f1; }
gp_features="$(_grouppos "$CVD/CHANGELOG.md" "Features")"
gp_fixes="$(_grouppos "$CVD/CHANGELOG.md" "Fixes")"
gp_perf="$(_grouppos "$CVD/CHANGELOG.md" "Performance")"
gp_refactor="$(_grouppos "$CVD/CHANGELOG.md" "Refactoring")"
gp_docs="$(_grouppos "$CVD/CHANGELOG.md" "Documentation")"
gp_tests="$(_grouppos "$CVD/CHANGELOG.md" "Tests")"
gp_ci="$(_grouppos "$CVD/CHANGELOG.md" "CI/Build")"
gp_chores="$(_grouppos "$CVD/CHANGELOG.md" "Chores")"
gp_other="$(_grouppos "$CVD/CHANGELOG.md" "Other")"
order_rc=0
for pair in "$gp_features:$gp_fixes" "$gp_fixes:$gp_perf" "$gp_perf:$gp_refactor" "$gp_refactor:$gp_docs" \
            "$gp_docs:$gp_tests" "$gp_tests:$gp_ci" "$gp_ci:$gp_chores" "$gp_chores:$gp_other"; do
    a="${pair%%:*}"; b="${pair#*:}"
    [[ "$a" -lt "$b" ]] || order_rc=1
done
check_rc "changelog.py: groups render in the fixed order Features<Fixes<Performance<Refactoring<Documentation<Tests<CI/Build<Chores<Other" 0 "$order_rc"

echo "== changelog.py: exclusion list drops workflow-process noise, incl. its own loop-safety commit kind (#404) =="
_cgcommit "$CVD" "2026-02-12T00:00:00" "retro: excl-retro-marker"
_cgcommit "$CVD" "2026-02-13T00:00:00" "retro+feedback: excl-retrofeedback-marker"
_cgcommit "$CVD" "2026-02-14T00:00:00" "feedback: excl-feedback-marker"
_cgcommit "$CVD" "2026-02-15T00:00:00" "brain: excl-brain-marker"
_cgcommit "$CVD" "2026-02-16T00:00:00" "config: excl-config-marker"
_cgcommit "$CVD" "2026-02-17T00:00:00" "chore(changelog): excl-changelog-marker"
python3 "$PLUGIN/scripts/changelog.py" generate --repo "$CVD" --output "$CVD/CHANGELOG.md" >/dev/null 2>&1
exout="$(cat "$CVD/CHANGELOG.md" 2>/dev/null)"
check_absent "changelog.py: excludes retro: subjects" "excl-retro-marker" "$exout"
check_absent "changelog.py: excludes retro+feedback: subjects" "excl-retrofeedback-marker" "$exout"
check_absent "changelog.py: excludes feedback: subjects" "excl-feedback-marker" "$exout"
check_absent "changelog.py: excludes brain: subjects" "excl-brain-marker" "$exout"
check_absent "changelog.py: excludes config: subjects" "excl-config-marker" "$exout"
check_absent "changelog.py: excludes chore(changelog): subjects (loop-safety)" "excl-changelog-marker" "$exout"
rm -rf "$CVD"

echo "== changelog.py: body rendering — blockquote lines + trailer stripping (#404) =="
TRD="$(mktemp -d)"
(cd "$TRD" && git init -q) >/dev/null 2>&1
_cpj "$TRD" "1.0.0"
(cd "$TRD" && git add -A) >/dev/null 2>&1
_cgcommit "$TRD" "2026-03-01T00:00:00" "chore: init"
_cgcommit "$TRD" "2026-03-02T00:00:00" "fix(y): trailer test" "$(printf 'Detail line one.\nDetail line two.\n\nApplied-by: Someone\nReviewed-by: Other\nCo-authored-by: Bot <bot@example.com>')"
python3 "$PLUGIN/scripts/changelog.py" generate --repo "$TRD" --output "$TRD/CHANGELOG.md" >/dev/null 2>&1
trout="$(cat "$TRD/CHANGELOG.md" 2>/dev/null)"
check "changelog.py: body first line rendered as blockquote" "> Detail line one." "$trout"
check "changelog.py: body second line rendered as blockquote" "> Detail line two." "$trout"
check_absent "changelog.py: Applied-by trailer stripped from body" "Applied-by" "$trout"
check_absent "changelog.py: Reviewed-by trailer stripped from body" "Reviewed-by" "$trout"
check_absent "changelog.py: Co-authored-by trailer stripped from body" "Co-authored-by" "$trout"

echo "== changelog.py: idempotence — same history regenerates byte-identical output (#404) =="
python3 "$PLUGIN/scripts/changelog.py" generate --repo "$TRD" --output "$TRD/CHANGELOG.second.md" >/dev/null 2>&1
diff -q "$TRD/CHANGELOG.md" "$TRD/CHANGELOG.second.md" >/dev/null 2>&1
check_rc "changelog.py: two runs against the same history are byte-identical" 0 $?
rm -rf "$TRD"

echo "== changelog.py: plugin.json never present anywhere in history — degenerate 'unversioned' bucket (#404 review round 1) =="
UVD="$(mktemp -d)"
(cd "$UVD" && git init -q) >/dev/null 2>&1
_cgcommit "$UVD" "2026-04-01T00:00:00" "feat: first feature, no plugin.json ever"
_cgcommit "$UVD" "2026-04-02T00:00:00" "fix: second commit, still no plugin.json"
python3 "$PLUGIN/scripts/changelog.py" generate --repo "$UVD" --output "$UVD/CHANGELOG.md" >/dev/null 2>&1
uvout="$(cat "$UVD/CHANGELOG.md" 2>/dev/null)"
check "changelog.py: no-plugin.json-ever history renders a well-formed 'Unversioned' heading" "## Unversioned — 2026-04-02" "$uvout"
check_absent "changelog.py: no-plugin.json-ever heading never renders the raw sentinel with a stray 'v' prefix" "## vunversioned" "$uvout"
rm -rf "$UVD"
