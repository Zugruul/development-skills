#!/usr/bin/env bash
# section-brain-staleness.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain staleness (GL-011: git-aware ⟳ stale — re-verify flag on recall) =="

ST_SCRIPTS="$PLUGIN/scripts"

# helper: count how many times "git" ... "log" appears as a real subprocess
# during a recall, via a fake `git` shim placed first on PATH that appends
# one line per invocation of the `log` subcommand to a counter file. Every
# other git subcommand (used by the shim's own bootstrap, none here) passes
# through untouched -- we only intercept `log`.
_stub_git_log_counter() { # <counter-file>
    local dir
    dir="$(mktemp -d)"
    cat >"$dir/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "log" ]]; then
    echo x >> "$1"
fi
PATH="$REAL_PATH" exec git "\$@"
EOF
    chmod +x "$dir/git"
    echo "$dir"
}

REAL_PATH="$PATH"

# ---------------------------------------------------------- (1) basic flagging
# A fixture git repo: a note glob'd to scripts/*.sh, created BEFORE a commit
# that touches scripts/x.sh -- must render the stale marker. A sibling note
# glob'd to only untouched paths must NOT be flagged.
ST_A="$(mktemp -d)"
git -C "$ST_A" init -q
git -C "$ST_A" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
sta() { python3 "$ST_SCRIPTS/brain.py" "$ST_A" "$@"; }
printf 'Stale-candidate lesson.\n' | sta mint dev stale-note --tags st --paths "scripts/*.sh" --source x >/dev/null
printf 'Untouched lesson.\n' | sta mint dev fresh-note --tags st --paths "docs/*.md" --source x >/dev/null
python3 - "$ST_A" <<'PY'
import os, re, sys
root = sys.argv[1]
d = os.path.join(root, ".claude/identities/dev/brain/notes")
for slug in ("stale-note", "fresh-note"):
    p = os.path.join(d, slug + ".md")
    s = open(p).read()
    s = re.sub(r"created: .*", "created: 2020-01-01", s)
    s = re.sub(r"last-touched: .*", "last-touched: 2020-01-01", s)
    open(p, "w").write(s)
PY
mkdir -p "$ST_A/scripts"
echo 'echo hi' > "$ST_A/scripts/x.sh"
git -C "$ST_A" add scripts/x.sh
GIT_AUTHOR_DATE="2020-06-01T00:00:00" GIT_COMMITTER_DATE="2020-06-01T00:00:00" \
    git -C "$ST_A" -c user.email=t@t -c user.name=t commit -q -m "touch scripts/x.sh"
out="$(sta recall dev --paths "scripts/x.sh,docs/y.md" --keywords "")"
check "stale note is flagged" "⟳ stale — re-verify" "$out"
lines_with_marker="$(grep -c '⟳ stale' <<<"$out" || true)"
check "exactly one note carries the stale marker" "1" "$lines_with_marker"
check "unaffected sibling note has no stale marker on its own block" "fresh-note" "$(grep -v 'stale-note' <<<"$out")"
if grep -A1 'fresh-note' <<<"$out" | grep -q '⟳ stale'; then
    echo "FAIL fresh-note (globs match only untouched files) must not be flagged"
    fails=$((fails + 1))
else
    echo "ok   fresh-note (globs match only untouched files) is not flagged"
fi
rm -rf "$ST_A"

# ------------------------------------------------- (1b) one-liner tier also flags
# Force the one-liner tier via a tiny budget so activation still clears 0.25
# but not the full-body threshold's char count -- re-use stale-note's setup
# by minting a low-strength note (activation 1.1) and a huge sibling body so
# only the one-liner fits.
ST_B="$(mktemp -d)"
git -C "$ST_B" init -q
git -C "$ST_B" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
stb() { python3 "$ST_SCRIPTS/brain.py" "$ST_B" "$@"; }
ST_B_LONG_BODY="This is a long lesson body used to overflow the full-body render tier. This is a long lesson body used to overflow the full-body render tier. This is a long lesson body used to overflow the full-body render tier."
printf '%s\n' "$ST_B_LONG_BODY" | stb mint dev stale-oneliner --tags st --paths "lib/*.sh" --source x >/dev/null
python3 - "$ST_B" <<'PY'
import os, re, sys
root = sys.argv[1]
p = os.path.join(root, ".claude/identities/dev/brain/notes/stale-oneliner.md")
s = open(p).read()
s = re.sub(r"created: .*", "created: 2020-01-01", s)
s = re.sub(r"last-touched: .*", "last-touched: 2020-01-01", s)
open(p, "w").write(s)
PY
mkdir -p "$ST_B/lib"
echo 'echo hi' > "$ST_B/lib/y.sh"
git -C "$ST_B" add lib/y.sh
GIT_AUTHOR_DATE="2020-06-01T00:00:00" GIT_COMMITTER_DATE="2020-06-01T00:00:00" \
    git -C "$ST_B" -c user.email=t@t -c user.name=t commit -q -m "touch lib/y.sh"
out="$(stb recall dev --paths "lib/y.sh" --keywords "" --budget 20)"
check "one-liner tier also renders the stale marker" "⟳ stale — re-verify" "$out"
check "one-liner tier used (no full body text present)" "tags: [st]" "$out"
rm -rf "$ST_B"

# ------------------------------------------------------ (2) re-mint clears the flag
ST_C="$(mktemp -d)"
git -C "$ST_C" init -q
git -C "$ST_C" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
stc() { python3 "$ST_SCRIPTS/brain.py" "$ST_C" "$@"; }
printf 'Re-mint clears staleness.\n' | stc mint dev remint-note --tags rm --paths "app/*.py" --source x >/dev/null
python3 - "$ST_C" <<'PY'
import os, re, sys
root = sys.argv[1]
p = os.path.join(root, ".claude/identities/dev/brain/notes/remint-note.md")
s = open(p).read()
s = re.sub(r"created: .*", "created: 2020-01-01", s)
s = re.sub(r"last-touched: .*", "last-touched: 2020-01-01", s)
open(p, "w").write(s)
PY
mkdir -p "$ST_C/app"
echo 'x = 1' > "$ST_C/app/m.py"
git -C "$ST_C" add app/m.py
GIT_AUTHOR_DATE="2020-06-01T00:00:00" GIT_COMMITTER_DATE="2020-06-01T00:00:00" \
    git -C "$ST_C" -c user.email=t@t -c user.name=t commit -q -m "touch app/m.py"
out1="$(stc recall dev --paths "app/m.py" --keywords "")"
check "before re-mint: flagged stale" "⟳ stale — re-verify" "$out1"
printf 'Re-mint clears staleness.\n' | stc mint dev remint-note --tags rm --paths "app/*.py" --source x >/dev/null
out2="$(stc recall dev --paths "app/m.py" --keywords "")"
check_absent "after re-mint (no git history change): no stale marker" "⟳ stale — re-verify" "$out2"
rm -rf "$ST_C"

# ------------------------------------------------- (3) one git subprocess per recall
ST_D="$(mktemp -d)"
git -C "$ST_D" init -q
git -C "$ST_D" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
std() { python3 "$ST_SCRIPTS/brain.py" "$ST_D" "$@"; }
i=0
while [[ $i -lt 12 ]]; do
    printf 'Bulk lesson %d.\n' "$i" | std mint dev "bulk-note-$i" --tags bulk --paths "bulk/*.sh" --source x >/dev/null
    i=$((i + 1))
done
python3 - "$ST_D" <<'PY'
import os, re, sys, glob
root = sys.argv[1]
d = os.path.join(root, ".claude/identities/dev/brain/notes")
for p in glob.glob(os.path.join(d, "bulk-note-*.md")):
    s = open(p).read()
    s = re.sub(r"created: .*", "created: 2020-01-01", s)
    s = re.sub(r"last-touched: .*", "last-touched: 2020-01-01", s)
    open(p, "w").write(s)
PY
mkdir -p "$ST_D/bulk"
echo 'echo hi' > "$ST_D/bulk/z.sh"
git -C "$ST_D" add bulk/z.sh
GIT_AUTHOR_DATE="2020-06-01T00:00:00" GIT_COMMITTER_DATE="2020-06-01T00:00:00" \
    git -C "$ST_D" -c user.email=t@t -c user.name=t commit -q -m "touch bulk/z.sh"

CNT_FILE="$(mktemp)"
GIT_SHIM_DIR="$(_stub_git_log_counter "$CNT_FILE")"
PATH="$GIT_SHIM_DIR:$REAL_PATH" python3 "$ST_SCRIPTS/brain.py" "$ST_D" recall dev --paths "bulk/z.sh" --keywords "" >/dev/null
subproc_count="$(wc -l < "$CNT_FILE" | tr -d ' ')"
check "exactly one git-log subprocess for a 12-note corpus" "1" "$subproc_count"
rm -rf "$GIT_SHIM_DIR" "$CNT_FILE"

# ---------------------------------------- (4) cache hit at same HEAD: zero subprocesses
CNT_FILE2="$(mktemp)"
GIT_SHIM_DIR2="$(_stub_git_log_counter "$CNT_FILE2")"
PATH="$GIT_SHIM_DIR2:$REAL_PATH" python3 "$ST_SCRIPTS/brain.py" "$ST_D" recall dev --paths "bulk/z.sh" --keywords "" >/dev/null
subproc_count2="$(wc -l < "$CNT_FILE2" | tr -d ' ')"
check "second recall at the same HEAD: zero git-log subprocesses (cache hit)" "0" "$subproc_count2"
rm -rf "$GIT_SHIM_DIR2" "$CNT_FILE2"

# moving HEAD invalidates the cache: another commit, expect a fresh subprocess
echo 'echo more' >> "$ST_D/bulk/z.sh"
git -C "$ST_D" add bulk/z.sh
git -C "$ST_D" -c user.email=t@t -c user.name=t commit -q -m "touch bulk/z.sh again"
CNT_FILE3="$(mktemp)"
GIT_SHIM_DIR3="$(_stub_git_log_counter "$CNT_FILE3")"
PATH="$GIT_SHIM_DIR3:$REAL_PATH" python3 "$ST_SCRIPTS/brain.py" "$ST_D" recall dev --paths "bulk/z.sh" --keywords "" >/dev/null
subproc_count3="$(wc -l < "$CNT_FILE3" | tr -d ' ')"
check "HEAD moved: cache invalidates, one fresh git-log subprocess" "1" "$subproc_count3"
rm -rf "$GIT_SHIM_DIR3" "$CNT_FILE3"
rm -rf "$ST_D"

# --------------------------------------------------- (5) git absent / non-repo dir
ST_E="$(mktemp -d)"
ste() { python3 "$ST_SCRIPTS/brain.py" "$ST_E" "$@"; }
printf 'No-repo lesson.\n' | ste mint dev norepo-note --tags nr --paths "any/*.sh" --source x >/dev/null
python3 - "$ST_E" <<'PY'
import os, re, sys
root = sys.argv[1]
p = os.path.join(root, ".claude/identities/dev/brain/notes/norepo-note.md")
s = open(p).read()
s = re.sub(r"created: .*", "created: 2020-01-01", s)
s = re.sub(r"last-touched: .*", "last-touched: 2020-01-01", s)
open(p, "w").write(s)
PY
err="$(ste recall dev --paths "any/x.sh" --keywords "" 2>&1 >/dev/null)"
if [[ -z "$err" ]]; then
    echo "ok   non-repo dir: no warnings printed"
else
    echo "FAIL non-repo dir: no warnings printed — got: $err"
    fails=$((fails + 1))
fi
out="$(ste recall dev --paths "any/x.sh" --keywords "" 2>/dev/null)"
check_absent "non-repo dir: no stale marker emitted, exit 0 output otherwise normal" "⟳ stale — re-verify" "$out"
check "non-repo dir: note still recalled normally" "norepo-note" "$out"
rm -rf "$ST_E"

# ------------------------------------------------------ (6) 200-note latency budget
ST_F="$(mktemp -d)"
git -C "$ST_F" init -q
git -C "$ST_F" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
stf() { python3 "$ST_SCRIPTS/brain.py" "$ST_F" "$@"; }
i=0
while [[ $i -lt 200 ]]; do
    printf 'Latency corpus lesson %d.\n' "$i" | stf mint dev "lat-note-$i" --tags lat --paths "lat/*.sh" --source x >/dev/null
    i=$((i + 1))
done
mkdir -p "$ST_F/lat"
echo 'echo hi' > "$ST_F/lat/w.sh"
git -C "$ST_F" add lat/w.sh
git -C "$ST_F" -c user.email=t@t -c user.name=t commit -q -m "touch lat/w.sh"
start_ns=$(python3 -c 'import time; print(time.time_ns())')
stf recall dev --paths "lat/w.sh" --keywords "" >/dev/null
end_ns=$(python3 -c 'import time; print(time.time_ns())')
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
if [[ "$elapsed_ms" -lt 2000 ]]; then
    echo "ok   §14 latency: 200-note recall with staleness completes well within budget (${elapsed_ms}ms)"
else
    echo "FAIL §14 latency: 200-note recall with staleness too slow (${elapsed_ms}ms)"
    fails=$((fails + 1))
fi
rm -rf "$ST_F"

# --------------------------------------------------- (7) linked worktree
# The build loop's own concurrency lanes run dev/reviewer agents inside
# linked git worktrees -- there `.git` is a FILE containing `gitdir: <path>`,
# not a directory. Staleness detection must still fire from inside one
# (reviewer-reported regression: a worktree's file-form `.git` was silently
# treated as "not a repo").
ST_G="$(mktemp -d)"
git -C "$ST_G" init -q
git -C "$ST_G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
ST_G_WT="$(mktemp -d)"
rm -rf "$ST_G_WT"
git -C "$ST_G" worktree add -q -b wt-staleness-branch "$ST_G_WT"
stg() { python3 "$ST_SCRIPTS/brain.py" "$ST_G_WT" "$@"; }
printf 'Worktree stale lesson.\n' | stg mint dev wt-note --tags wt --paths "wtdir/*.sh" --source x >/dev/null
python3 - "$ST_G_WT" <<'PY'
import os, re, sys
root = sys.argv[1]
p = os.path.join(root, ".claude/identities/dev/brain/notes/wt-note.md")
s = open(p).read()
s = re.sub(r"created: .*", "created: 2020-01-01", s)
s = re.sub(r"last-touched: .*", "last-touched: 2020-01-01", s)
open(p, "w").write(s)
PY
mkdir -p "$ST_G_WT/wtdir"
echo 'echo hi' > "$ST_G_WT/wtdir/v.sh"
git -C "$ST_G_WT" add wtdir/v.sh
GIT_AUTHOR_DATE="2020-06-01T00:00:00" GIT_COMMITTER_DATE="2020-06-01T00:00:00" \
    git -C "$ST_G_WT" -c user.email=t@t -c user.name=t commit -q -m "touch wtdir/v.sh"
out="$(stg recall dev --paths "wtdir/v.sh" --keywords "")"
check "linked worktree: stale marker renders (HEAD resolution works from a worktree's file-form .git)" "⟳ stale — re-verify" "$out"
git -C "$ST_G" worktree remove -f "$ST_G_WT" >/dev/null 2>&1 || true
rm -rf "$ST_G_WT" "$ST_G"
