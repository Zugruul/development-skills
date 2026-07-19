#!/usr/bin/env bash
# section-sync-configs.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# sync-configs.py fixtures: each case gets its own hermetic tmpdir with a
# real (non-bare) working repo + a real bare "origin" remote reachable via
# file://, so the git-safety protocol (worktree route vs. direct-on-main
# route) exercises actual git plumbing, not mocks. One tmpdir per case --
# never folded into shared setup, so a failure in one case can't leave
# state that corrupts another.

declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
SYNCCFG="$PLUGIN/scripts/sync-configs.py"

# _sc_base_yaml <feedback:true|false> -- a full, VALID (per validate-config.py)
# project.yaml body, with or without methodology.feedback already set.
_sc_base_yaml() {
    local feedback="$1"
    cat <<EOF
# yaml-language-server: \$schema=https://raw.githubusercontent.com/event-sorcerer/development-skills/main/plugins/spec-workflow/schemas/project-config.schema.json
schemaVersion: 2
project:
    name: sc-fixture
    mainBranch: main
    branchPattern: fx/<id>-<slug>
boards:
  - id: main
    provider: github-project
    owner: fixture-owner
    repo: fixture-owner/sc-fixture
    projectNumber: 1
    projectId: PVT_fixture0000000
    fields:
        status:
            fieldId: PVTSSF_fixtureStatus0
            options:
                Backlog: aaaa0001
                Done: aaaa0002
        priority:
            fieldId: PVTSSF_fixturePrio00
            options:
                P0: bbbb0001
    statusFlow: [Backlog, Done]
specs:
  - id: core
    board: main
    specPath: SPEC.md
    taskPrefix: FX
    epics:
      - id: E0
        taskRanges: [[1, 9]]
commands:
    gate: "true"
methodology:
    tdd: true
    isolationSuite: ""
    maxInProgress: 1$( [[ "$feedback" == "true" ]] && printf '\n    feedback: true' )
EOF
}

# _sc_base_yaml_noeol -- the same VALID body as _sc_base_yaml(false, ...) but
# with NO trailing newline after the last methodology line. This is a real
# (if obscure) trigger for ensure-feedback-key's insertion landing on the
# same line as the file's last key (no "\n" separator before it), which
# corrupts the YAML -- i.e. a genuine way to make validate() fail on the
# POST-edit call while the ORIGINAL file was fully valid, without any
# test-only hook in the script itself.
_sc_base_yaml_noeol() {
    printf '%s' "$(_sc_base_yaml false)"
}

# _sc_mkrepo <dir> <feedback:true|false> <add_schema_dup:yes|no>
# Creates <dir>/origin.git (bare) + <dir>/work (the "live" clone), commits an
# initial project.yaml on main, and pushes it to origin.
_sc_mkrepo() {
    local dir="$1" feedback="$2" schemadup="$3"
    mkdir -p "$dir"
    git init -q --bare "$dir/origin.git"
    git init -q -b main "$dir/work"
    git -C "$dir/work" config user.name "Fixture Human"
    git -C "$dir/work" config user.email "fixture@example.com"
    git -C "$dir/work" remote add origin "$dir/origin.git"
    mkdir -p "$dir/work/.claude"
    : > "$dir/work/.claude/.neural-network"
    _sc_base_yaml "$feedback" > "$dir/work/.claude/project.yaml"
    if [[ "$schemadup" == "yes" ]]; then
        # insert a literal top-level $schema: line right after the comment header
        # shellcheck disable=SC2016  # single-quoted sed script: literal $schema, not shell expansion
        sed -i.bak '1a\
$schema: https://raw.githubusercontent.com/event-sorcerer/development-skills/main/plugins/spec-workflow/schemas/project-config.schema.json
' "$dir/work/.claude/project.yaml"
        rm -f "$dir/work/.claude/project.yaml.bak"
    fi
    git -C "$dir/work" add -A
    git -C "$dir/work" commit -q -m init
    git -C "$dir/work" push -q origin main
}

# _sc_write_settings <dir> <enabled:yes|no> -- writes .claude/settings.json
# with enabledPlugins.peer-review@development-skills true (yes) or omitted (no).
_sc_write_settings() {
    local dir="$1" enabled="$2"
    if [[ "$enabled" == "yes" ]]; then
        cat <<'EOF' > "$dir/.claude/settings.json"
{"enabledPlugins": {"peer-review@development-skills": true}}
EOF
    else
        cat <<'EOF' > "$dir/.claude/settings.json"
{"enabledPlugins": {"frontend-design@development-skills": true}}
EOF
    fi
}

# _sc_base_yaml_with_delegation <feedback:true|false> -- _sc_base_yaml() plus
# a delegation.identities block (dev + reviewer, no peer-reviewer) matching
# this repo's own project.yaml shape.
_sc_base_yaml_with_delegation() {
    local feedback="$1"
    _sc_base_yaml "$feedback"
    cat <<'EOF'
delegation:
    identities:
        dev:
            name: Dev Agent - {name}
            email: '{local}+dev_agent@{domain}'
        reviewer:
            name: Reviewer Agent - {name}
            email: '{local}+reviewer_agent@{domain}'
EOF
}

# _sc_sync_gitignore <workdir> -- pre-syncs the fixture's .gitignore managed
# block to the CURRENT manifest and commits/pushes it, so a case asserting
# no-op behavior for OTHER rules isn't tripped up by mem013-gitignore-managed-block
# firing on a fixture that never had a .gitignore at all.
_sc_sync_gitignore() {
    local dir="$1"
    bash "$PLUGIN/scripts/gitignore-sync.sh" "$dir/.gitignore"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "pre-sync gitignore"
    git -C "$dir" push -q origin main
}

_sc_head() { git -C "$1" rev-parse HEAD; }
_sc_origin_project_yaml() { # dir -> project.yaml content as pushed to origin's main
    local tmp
    tmp="$(mktemp -d)"
    git clone -q --branch main "$1/origin.git" "$tmp/clone" >/dev/null 2>&1
    cat "$tmp/clone/.claude/project.yaml" 2>/dev/null
    rm -rf "$tmp"
}

echo "== sync-configs.py: clean repo on main (case a) =="
SCA="$(mktemp -d)"
_sc_mkrepo "$SCA/r" false yes
before_head="$(_sc_head "$SCA/r/work")"
out="$(python3 "$SYNCCFG" --repo "$SCA/r/work" --apply 2>&1)"
check "case a: reports main route" "route: main" "$out"
check "case a: strip-schema rule applied" "strip-schema-data-key" "$out"
check "case a: ensure-feedback rule applied" "ensure-feedback-key" "$out"
check "case a: pre-validate ran" "validate pre: VALID" "$out"
check "case a: post-validate ran" "validate post: VALID" "$out"
check "case a: reports a commit sha" "commit:" "$out"
check "case a: reports push ok" "push: ok" "$out"
origin_yaml="$(_sc_origin_project_yaml "$SCA/r")"
# shellcheck disable=SC2016  # single quotes are intentional: literal grep pattern, not shell expansion
check_absent "case a: origin's main no longer has \$schema data key" '$schema:' "$origin_yaml"
check "case a: origin's main now has feedback: true" "feedback: true" "$origin_yaml"
after_head="$(_sc_head "$SCA/r/work")"
check_rc "case a: local work HEAD advanced (committed directly on main)" 0 "$([[ "$before_head" != "$after_head" ]] && echo 0 || echo 1)"
check "case a: local project.yaml updated too" "feedback: true" "$(cat "$SCA/r/work/.claude/project.yaml")"
rm -rf "$SCA"

echo "== sync-configs.py: non-main dirty branch -> worktree route (case b) =="
SCB="$(mktemp -d)"
_sc_mkrepo "$SCB/r" false yes
git -C "$SCB/r/work" checkout -q -b feature
echo "unrelated scratch" > "$SCB/r/work/scratch.txt"
before_head="$(_sc_head "$SCB/r/work")"
out="$(python3 "$SYNCCFG" --repo "$SCB/r/work" --apply 2>&1)"
check "case b: reports worktree route" "route: worktree" "$out"
check "case b: reports a commit sha" "commit:" "$out"
check "case b: reports push ok" "push: ok" "$out"
after_branch="$(git -C "$SCB/r/work" branch --show-current)"
check "case b: live checkout branch unchanged" "feature" "$after_branch"
after_head="$(_sc_head "$SCB/r/work")"
check_rc "case b: live worktree HEAD untouched" 0 "$([[ "$before_head" == "$after_head" ]] && echo 0 || echo 1)"
check "case b: dirty scratch file still present" "unrelated scratch" "$(cat "$SCB/r/work/scratch.txt" 2>/dev/null)"
origin_yaml="$(_sc_origin_project_yaml "$SCB/r")"
# shellcheck disable=SC2016  # single quotes are intentional: literal grep pattern, not shell expansion
check_absent "case b: origin main no longer has \$schema data key" '$schema:' "$origin_yaml"
check "case b: origin main now has feedback: true" "feedback: true" "$origin_yaml"
rm -rf "$SCB"

echo "== sync-configs.py: pre-INVALID config -> skipped (case c) =="
SCC="$(mktemp -d)"
_sc_mkrepo "$SCC/r" false yes
cp "$FIX/broken.project.yaml" "$SCC/r/work/.claude/project.yaml"
git -C "$SCC/r/work" add -A
git -C "$SCC/r/work" commit -q -m "make config invalid"
git -C "$SCC/r/work" push -q origin main
before_head="$(_sc_head "$SCC/r/work")"
out="$(python3 "$SYNCCFG" --repo "$SCC/r/work" --apply 2>&1)"
check "case c: reports skipped-invalid" "skipped-invalid" "$out"
after_head="$(_sc_head "$SCC/r/work")"
check_rc "case c: nothing committed" 0 "$([[ "$before_head" == "$after_head" ]] && echo 0 || echo 1)"
rm -rf "$SCC"

echo "== sync-configs.py: already-synced repo -> no-op (case d) =="
SCD="$(mktemp -d)"
_sc_mkrepo "$SCD/r" true no
_sc_sync_gitignore "$SCD/r/work"
before_head="$(_sc_head "$SCD/r/work")"
out="$(python3 "$SYNCCFG" --repo "$SCD/r/work" --apply 2>&1)"
check "case d: reports no-op" "route: no-op" "$out"
after_head="$(_sc_head "$SCD/r/work")"
check_rc "case d: nothing committed" 0 "$([[ "$before_head" == "$after_head" ]] && echo 0 || echo 1)"
rm -rf "$SCD"

echo "== sync-configs.py: dry-run is the default (case e) =="
SCE="$(mktemp -d)"
_sc_mkrepo "$SCE/r" false yes
before="$(cat "$SCE/r/work/.claude/project.yaml")"
before_head="$(_sc_head "$SCE/r/work")"
out="$(python3 "$SYNCCFG" --repo "$SCE/r/work" 2>&1)"
check "case e: reports dry-run" "dry-run" "$out"
check "case e: still names the rules that would apply" "strip-schema-data-key" "$out"
check "case e: diff message shows added/removed line counts, not a resulting-file total" "[diff] .claude/project.yaml (+" "$out"
check_absent "case e: diff message does not claim the file 'would change' by N total lines" "would change (" "$out"
after="$(cat "$SCE/r/work/.claude/project.yaml")"
check_rc "case e: file untouched" 0 "$([[ "$before" == "$after" ]] && echo 0 || echo 1)"
after_head="$(_sc_head "$SCE/r/work")"
check_rc "case e: nothing committed" 0 "$([[ "$before_head" == "$after_head" ]] && echo 0 || echo 1)"
rm -rf "$SCE"

echo "== sync-configs.py: sw062 feedback-dir migration rule (case f) =="
SCF="$(mktemp -d)"
_sc_mkrepo "$SCF/r" true no
mkdir -p "$SCF/r/work/.claude/feedback"
echo "legacy: true" > "$SCF/r/work/.claude/feedback/feed.yaml"
{
    echo "some-other-line"
    echo ".claude/feedback/"
} > "$SCF/r/work/.gitignore"
git -C "$SCF/r/work" add -A
git -C "$SCF/r/work" commit -q -m "add legacy feedback dir"
git -C "$SCF/r/work" push -q origin main
out="$(python3 "$SYNCCFG" --repo "$SCF/r/work" --apply 2>&1)"
check "case f: sw062 migration rule applied" "sw062-feedbacks-migration" "$out"
check "case f: legacy dir moved" "" "$([[ -d "$SCF/r/work/.claude/feedbacks" ]] && echo yes)"
check_rc "case f: legacy dir gone" 1 "$([[ -d "$SCF/r/work/.claude/feedback" ]] && echo 0 || echo 1)"
check_absent "case f: gitignore line dropped" ".claude/feedback/" "$(cat "$SCF/r/work/.gitignore" 2>/dev/null)"
check "case f: other gitignore lines survive" "some-other-line" "$(cat "$SCF/r/work/.gitignore" 2>/dev/null)"
rm -rf "$SCF"

echo "== sync-configs.py: sw062 migration rule with no .gitignore at all (case f2) =="
SCF2="$(mktemp -d)"
_sc_mkrepo "$SCF2/r" true no
mkdir -p "$SCF2/r/work/.claude/feedback"
echo "legacy: true" > "$SCF2/r/work/.claude/feedback/feed.yaml"
git -C "$SCF2/r/work" add -A
git -C "$SCF2/r/work" commit -q -m "add legacy feedback dir, no gitignore"
git -C "$SCF2/r/work" push -q origin main
out="$(python3 "$SYNCCFG" --repo "$SCF2/r/work" --apply 2>&1)"
check "case f2: sw062 migration rule applied" "sw062-feedbacks-migration" "$out"
check_rc "case f2: legacy dir moved" 0 "$([[ -d "$SCF2/r/work/.claude/feedbacks" ]] && echo 0 || echo 1)"
check_rc "case f2: no .gitignore crash -- repo still committed" 0 "$([[ -n "$(_sc_head "$SCF2/r/work")" ]] && echo 0 || echo 1)"
rm -rf "$SCF2"

echo "== sync-configs.py: post-edit INVALID rolls back the sw062 filesystem move too (case g) =="
SCG="$(mktemp -d)"
mkdir -p "$SCG/r"
git init -q --bare "$SCG/r/origin.git"
git init -q -b main "$SCG/r/work"
git -C "$SCG/r/work" config user.name "Fixture Human"
git -C "$SCG/r/work" config user.email "fixture@example.com"
git -C "$SCG/r/work" remote add origin "$SCG/r/origin.git"
mkdir -p "$SCG/r/work/.claude"
: > "$SCG/r/work/.claude/.neural-network"
_sc_base_yaml_noeol > "$SCG/r/work/.claude/project.yaml"
mkdir -p "$SCG/r/work/.claude/feedback"
echo "legacy: true" > "$SCG/r/work/.claude/feedback/feed.yaml"
{
    echo "some-other-line"
    echo ".claude/feedback/"
} > "$SCG/r/work/.gitignore"
git -C "$SCG/r/work" add -A
git -C "$SCG/r/work" commit -q -m init
git -C "$SCG/r/work" push -q origin main
before_head="$(_sc_head "$SCG/r/work")"
out="$(python3 "$SYNCCFG" --repo "$SCG/r/work" --apply 2>&1)"
check "case g: pre-validate passed (original file was valid)" "validate pre: VALID" "$out"
check "case g: post-validate caught the corruption" "validate post: INVALID" "$out"
check "case g: reports rolled back" "rolled-back-invalid" "$out"
after_head="$(_sc_head "$SCG/r/work")"
check_rc "case g: nothing committed" 0 "$([[ "$before_head" == "$after_head" ]] && echo 0 || echo 1)"
check_rc "case g: legacy .claude/feedback restored (not stranded)" 0 "$([[ -d "$SCG/r/work/.claude/feedback" ]] && echo 0 || echo 1)"
check_rc "case g: .claude/feedbacks NOT left behind" 1 "$([[ -d "$SCG/r/work/.claude/feedbacks" ]] && echo 0 || echo 1)"
check "case g: .gitignore feedback line restored" ".claude/feedback/" "$(cat "$SCG/r/work/.gitignore" 2>/dev/null)"
check_rc "case g: repo is still detectable by a future run (not permanently stranded)" 0 "$(python3 - "$SCG/r/work" "$SYNCCFG" <<'PY'
import sys
import importlib.util
repo_arg, script_arg = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("sync_configs", script_arg)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
from pathlib import Path
print(0 if m.sw062_detect(Path(repo_arg)) else 1)
PY
)"
rm -rf "$SCG"

echo "== sync-configs.py: ensure-peer-reviewer-identity, plugin disabled -> no-op (case h) =="
SCH="$(mktemp -d)"
_sc_mkrepo "$SCH/r" true no
_sc_sync_gitignore "$SCH/r/work"
_sc_write_settings "$SCH/r/work" no
git -C "$SCH/r/work" add -A
git -C "$SCH/r/work" commit -q -m "add settings.json (peer-review not enabled)"
git -C "$SCH/r/work" push -q origin main
out="$(python3 "$SYNCCFG" --repo "$SCH/r/work" --apply 2>&1)"
check "case h: reports no-op" "route: no-op" "$out"
check_absent "case h: rule not applied" "ensure-peer-reviewer-identity" "$out"
check_absent "case h: peer-reviewer not written" "peer-reviewer:" "$(cat "$SCH/r/work/.claude/project.yaml")"
rm -rf "$SCH"

echo "== sync-configs.py: ensure-peer-reviewer-identity, plugin enabled -> adds role to existing identities block (case i) =="
SCI="$(mktemp -d)"
mkdir -p "$SCI/r"
git init -q --bare "$SCI/r/origin.git"
git init -q -b main "$SCI/r/work"
git -C "$SCI/r/work" config user.name "Fixture Human"
git -C "$SCI/r/work" config user.email "fixture@example.com"
git -C "$SCI/r/work" remote add origin "$SCI/r/origin.git"
mkdir -p "$SCI/r/work/.claude"
: > "$SCI/r/work/.claude/.neural-network"
_sc_base_yaml_with_delegation true > "$SCI/r/work/.claude/project.yaml"
_sc_write_settings "$SCI/r/work" yes
git -C "$SCI/r/work" add -A
git -C "$SCI/r/work" commit -q -m init
git -C "$SCI/r/work" push -q origin main
out="$(python3 "$SYNCCFG" --repo "$SCI/r/work" --apply 2>&1)"
check "case i: rule applied" "ensure-peer-reviewer-identity" "$out"
check "case i: post-validate ran" "validate post: VALID" "$out"
check "case i: reports push ok" "push: ok" "$out"
origin_yaml="$(_sc_origin_project_yaml "$SCI/r")"
check "case i: origin's main now has peer-reviewer role" "peer-reviewer:" "$origin_yaml"
check "case i: origin's main has the templated name" "Peer Reviewer (codex) - {name}" "$origin_yaml"
check "case i: origin's main has the templated email" "{local}+peer_reviewer@{domain}" "$origin_yaml"
check "case i: existing dev role untouched" "Dev Agent - {name}" "$origin_yaml"
rm -rf "$SCI"

echo "== sync-configs.py: ensure-peer-reviewer-identity, no delegation block at all -> appends a fresh one (case j) =="
SCJ="$(mktemp -d)"
mkdir -p "$SCJ/r"
git init -q --bare "$SCJ/r/origin.git"
git init -q -b main "$SCJ/r/work"
git -C "$SCJ/r/work" config user.name "Fixture Human"
git -C "$SCJ/r/work" config user.email "fixture@example.com"
git -C "$SCJ/r/work" remote add origin "$SCJ/r/origin.git"
mkdir -p "$SCJ/r/work/.claude"
: > "$SCJ/r/work/.claude/.neural-network"
_sc_base_yaml true > "$SCJ/r/work/.claude/project.yaml"
_sc_write_settings "$SCJ/r/work" yes
git -C "$SCJ/r/work" add -A
git -C "$SCJ/r/work" commit -q -m init
git -C "$SCJ/r/work" push -q origin main
out="$(python3 "$SYNCCFG" --repo "$SCJ/r/work" --apply 2>&1)"
check "case j: rule applied" "ensure-peer-reviewer-identity" "$out"
check "case j: post-validate ran" "validate post: VALID" "$out"
origin_yaml="$(_sc_origin_project_yaml "$SCJ/r")"
check "case j: fresh delegation.identities.peer-reviewer written" "peer-reviewer:" "$origin_yaml"
rm -rf "$SCJ"

echo "== sync-configs.py: ensure-peer-reviewer-identity, already synced -> no-op (case k) =="
SCK="$(mktemp -d)"
mkdir -p "$SCK/r"
git init -q --bare "$SCK/r/origin.git"
git init -q -b main "$SCK/r/work"
git -C "$SCK/r/work" config user.name "Fixture Human"
git -C "$SCK/r/work" config user.email "fixture@example.com"
git -C "$SCK/r/work" remote add origin "$SCK/r/origin.git"
mkdir -p "$SCK/r/work/.claude"
: > "$SCK/r/work/.claude/.neural-network"
_sc_base_yaml_with_delegation true > "$SCK/r/work/.claude/project.yaml"
printf '        peer-reviewer:\n            name: Peer Reviewer (codex) - {name}\n            email: '"'"'{local}+peer_reviewer@{domain}'"'"'\n' >> "$SCK/r/work/.claude/project.yaml"
_sc_write_settings "$SCK/r/work" yes
bash "$PLUGIN/scripts/gitignore-sync.sh" "$SCK/r/work/.gitignore"
git -C "$SCK/r/work" add -A
git -C "$SCK/r/work" commit -q -m init
git -C "$SCK/r/work" push -q origin main
before_head="$(_sc_head "$SCK/r/work")"
out="$(python3 "$SYNCCFG" --repo "$SCK/r/work" --apply 2>&1)"
check "case k: reports no-op" "route: no-op" "$out"
after_head="$(_sc_head "$SCK/r/work")"
check_rc "case k: nothing committed" 0 "$([[ "$before_head" == "$after_head" ]] && echo 0 || echo 1)"
rm -rf "$SCK"

echo "== sync-configs.py: ensure-peer-reviewer-identity, dry-run does not write (case l) =="
SCL="$(mktemp -d)"
mkdir -p "$SCL/r"
git init -q --bare "$SCL/r/origin.git"
git init -q -b main "$SCL/r/work"
git -C "$SCL/r/work" config user.name "Fixture Human"
git -C "$SCL/r/work" config user.email "fixture@example.com"
git -C "$SCL/r/work" remote add origin "$SCL/r/origin.git"
mkdir -p "$SCL/r/work/.claude"
: > "$SCL/r/work/.claude/.neural-network"
_sc_base_yaml_with_delegation true > "$SCL/r/work/.claude/project.yaml"
_sc_write_settings "$SCL/r/work" yes
git -C "$SCL/r/work" add -A
git -C "$SCL/r/work" commit -q -m init
git -C "$SCL/r/work" push -q origin main
before="$(cat "$SCL/r/work/.claude/project.yaml")"
out="$(python3 "$SYNCCFG" --repo "$SCL/r/work" 2>&1)"
check "case l: reports dry-run" "dry-run" "$out"
check "case l: names the rule that would apply" "ensure-peer-reviewer-identity" "$out"
after="$(cat "$SCL/r/work/.claude/project.yaml")"
check_rc "case l: file untouched" 0 "$([[ "$before" == "$after" ]] && echo 0 || echo 1)"
rm -rf "$SCL"

# mem013-gitignore-managed-block -- sync-project-configs also reconciles each
# anchored repo's .gitignore managed block to the CURRENT manifest, via
# gitignore-sync.sh, mirroring the sw062 directory-level-rule pattern.
SC_GS_START="# >>> spec-workflow managed"
SC_GS_END="# <<< spec-workflow managed"

echo "== sync-configs.py: mem013 gitignore rule, dry-run shows diff and writes nothing (case m) =="
SCM="$(mktemp -d)"
_sc_mkrepo "$SCM/r" true no
{
    echo "node_modules/"
} > "$SCM/r/work/.gitignore"
git -C "$SCM/r/work" add -A
git -C "$SCM/r/work" commit -q -m "add divergent gitignore"
git -C "$SCM/r/work" push -q origin main
before="$(cat "$SCM/r/work/.gitignore")"
before_head="$(_sc_head "$SCM/r/work")"
out="$(python3 "$SYNCCFG" --repo "$SCM/r/work" 2>&1)"
check "case m: reports dry-run" "dry-run" "$out"
check "case m: mem013 rule named as applicable" "mem013-gitignore-managed-block" "$out"
check "case m: diff message shown" "[diff] .gitignore managed block (+" "$out"
after="$(cat "$SCM/r/work/.gitignore")"
check_rc "case m: gitignore file untouched" 0 "$([[ "$before" == "$after" ]] && echo 0 || echo 1)"
after_head="$(_sc_head "$SCM/r/work")"
check_rc "case m: nothing committed" 0 "$([[ "$before_head" == "$after_head" ]] && echo 0 || echo 1)"
rm -rf "$SCM"

echo "== sync-configs.py: mem013 gitignore rule, apply syncs a stale managed block, preserving user lines (case n) =="
SCN="$(mktemp -d)"
_sc_mkrepo "$SCN/r" true no
{
    echo "node_modules/"
    echo "$SC_GS_START"
    echo ".claude/OBSOLETE-PATH"
    echo "$SC_GS_END"
    echo "*.log"
} > "$SCN/r/work/.gitignore"
git -C "$SCN/r/work" add -A
git -C "$SCN/r/work" commit -q -m "add stale managed block"
git -C "$SCN/r/work" push -q origin main
out="$(python3 "$SYNCCFG" --repo "$SCN/r/work" --apply 2>&1)"
check "case n: mem013 rule applied" "mem013-gitignore-managed-block" "$out"
check "case n: reports a commit sha" "commit:" "$out"
check "case n: reports push ok" "push: ok" "$out"
gi_content="$(cat "$SCN/r/work/.gitignore" 2>/dev/null)"
check "case n: user line node_modules preserved" "node_modules/" "$gi_content"
check "case n: user line *.log preserved" "*.log" "$gi_content"
check "case n: start marker present" "$SC_GS_START" "$gi_content"
check "case n: end marker present" "$SC_GS_END" "$gi_content"
check "case n: fresh manifest ignore path written" ".claude/CHECKPOINT" "$gi_content"
check_absent "case n: stale block content removed" ".claude/OBSOLETE-PATH" "$gi_content"
origin_yaml_dummy="$(_sc_origin_project_yaml "$SCN/r")"
check "case n: origin still has valid project.yaml (unrelated content untouched)" "sc-fixture" "$origin_yaml_dummy"
rm -rf "$SCN"

echo "== sync-configs.py: mem013 gitignore rule, apply on a repo with no .gitignore at all (case o) =="
SCO="$(mktemp -d)"
_sc_mkrepo "$SCO/r" true no
out="$(python3 "$SYNCCFG" --repo "$SCO/r/work" --apply 2>&1)"
check "case o: mem013 rule applied" "mem013-gitignore-managed-block" "$out"
check "case o: reports push ok" "push: ok" "$out"
check_rc "case o: .gitignore created" 0 "$([[ -f "$SCO/r/work/.gitignore" ]] && echo 0 || echo 1)"
gi_content="$(cat "$SCO/r/work/.gitignore" 2>/dev/null)"
check "case o: start marker present" "$SC_GS_START" "$gi_content"
check "case o: fresh manifest ignore path written" ".claude/CHECKPOINT" "$gi_content"
rm -rf "$SCO"

echo "== sync-configs.py: mem013 gitignore rule, already-synced -> no-op (case p) =="
SCP="$(mktemp -d)"
_sc_mkrepo "$SCP/r" true no
_sc_sync_gitignore "$SCP/r/work"
before_head="$(_sc_head "$SCP/r/work")"
out="$(python3 "$SYNCCFG" --repo "$SCP/r/work" --apply 2>&1)"
check "case p: reports no-op" "route: no-op" "$out"
check_absent "case p: mem013 rule not named" "mem013-gitignore-managed-block" "$out"
after_head="$(_sc_head "$SCP/r/work")"
check_rc "case p: nothing committed" 0 "$([[ "$before_head" == "$after_head" ]] && echo 0 || echo 1)"
rm -rf "$SCP"
