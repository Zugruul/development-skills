#!/usr/bin/env bash
# section-diff-symbols.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# Covers issue #86: diff-symbols.py maps diff hunks to their enclosing
# symbol in the NEW file version -- python (ast, nested Class.method), bash
# (brace-matched function bodies, both `name() {` and `function name {`),
# markdown (nearest preceding heading), and a "(file-level)" fallback for
# anything outside a recognized symbol. Every case below drives the real
# script against a hermetic temp git repo (never a canned diff string) so
# the NEW-file-content read path (disk in stdin mode, `git show` in --range
# mode) is genuinely exercised.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== diff-symbols.py (#86) =="

DS="$PLUGIN/scripts/diff-symbols.py"
DGT="$(mktemp -d)"
git -C "$DGT" init -q .
git -C "$DGT" config user.email test@example.com
git -C "$DGT" config user.name test

# --- (a) python nesting: method inside a class -> "Class.method" ---
cat > "$DGT/mod.py" <<'EOF'
class Greeter:
    def hello(self):
        return "hi"

    def bye(self):
        return "bye"


def standalone():
    return 1
EOF
git -C "$DGT" add mod.py
git -C "$DGT" commit -q -m "add mod.py"
python3 -c "
import re
with open('$DGT/mod.py') as f:
    text = f.read()
text = text.replace('return \"hi\"', 'return \"hi there\"')
with open('$DGT/mod.py', 'w') as f:
    f.write(text)
"
out="$(cd "$DGT" && git diff | python3 "$DS")"
check "(a) python nested method: Class.method" "$(printf 'mod.py\tGreeter.hello')" "$out"
check_absent "(a) python nested method: no file-level line for this change" "$(printf 'mod.py\t(file-level)')" "$out"

# --- (b) python module-level (top-level statement) change -> "(file-level)" ---
git -C "$DGT" checkout -q -- mod.py
python3 -c "
with open('$DGT/mod.py') as f:
    text = f.read()
text = text.replace('def standalone():', 'X = 1\ndef standalone():')
with open('$DGT/mod.py', 'w') as f:
    f.write(text)
"
out="$(cd "$DGT" && git diff | python3 "$DS")"
check "(b) python module-level change: (file-level)" "$(printf 'mod.py\t(file-level)')" "$out"
git -C "$DGT" checkout -q -- mod.py

# --- (c) bash: both function syntaxes, and a top-level (file-level) change ---
cat > "$DGT/script.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

greet() {
    echo "hello"
}

function farewell {
    echo "bye"
}

echo "top level"
EOF
git -C "$DGT" add script.sh
git -C "$DGT" commit -q -m "add script.sh"
python3 -c "
with open('$DGT/script.sh') as f:
    text = f.read()
text = text.replace('echo \"hello\"', 'echo \"hello there\"')
text = text.replace('echo \"bye\"', 'echo \"goodbye\"')
text = text.replace('echo \"top level\"', 'echo \"top level 2\"')
with open('$DGT/script.sh', 'w') as f:
    f.write(text)
"
out="$(cd "$DGT" && git diff | python3 "$DS")"
check "(c) bash 'name() {' syntax: greet" "$(printf 'script.sh\tgreet')" "$out"
check "(c) bash 'function name {' syntax: farewell" "$(printf 'script.sh\tfarewell')" "$out"
check "(c) bash top-level change: (file-level)" "$(printf 'script.sh\t(file-level)')" "$out"
git -C "$DGT" checkout -q -- script.sh

# --- (d) markdown: nearest preceding heading ---
cat > "$DGT/notes.md" <<'EOF'
# Title

Intro text.

## Section One

First paragraph.

## Section Two

Second paragraph.
EOF
git -C "$DGT" add notes.md
git -C "$DGT" commit -q -m "add notes.md"
python3 -c "
with open('$DGT/notes.md') as f:
    text = f.read()
text = text.replace('Second paragraph.', 'Second paragraph, edited.')
with open('$DGT/notes.md', 'w') as f:
    f.write(text)
"
out="$(cd "$DGT" && git diff | python3 "$DS")"
check "(d) markdown heading fallback: Section Two" "$(printf 'notes.md\tSection Two')" "$out"
git -C "$DGT" checkout -q -- notes.md

# --- (e) multi-hunk same-symbol dedupe: two separated edits in one function collapse to one line ---
cat > "$DGT/mod.py" <<'EOF'
class Greeter:
    def hello(self):
        a = 1
        b = 2
        c = 3
        d = 4
        e = 5
        f = 6
        g = 7
        h = 8
        i = 9
        j = 10
        return "hi"
EOF
git -C "$DGT" add mod.py
git -C "$DGT" commit -q -m "grow hello()"
python3 -c "
with open('$DGT/mod.py') as f:
    text = f.read()
text = text.replace('a = 1', 'a = 100')
text = text.replace('j = 10', 'j = 1000')
with open('$DGT/mod.py', 'w') as f:
    f.write(text)
"
diff_out="$(cd "$DGT" && git diff)"
hunks="$(grep -c '^@@' <<<"$diff_out")"
check "(e) setup sanity: edit produced 2+ hunks" "true" "$([[ $hunks -ge 2 ]] && echo true)"
out="$(cd "$DGT" && python3 "$DS" <<<"$diff_out")"
occurrences="$(grep -cF "$(printf 'mod.py\tGreeter.hello')" <<<"$out")"
check "(e) multi-hunk same-symbol: single deduped line" "1" "$occurrences"
git -C "$DGT" reset -q --hard HEAD~1

# --- (f) --range mode reads NEW file content via `git show`, not the worktree ---
BASE="$(git -C "$DGT" rev-parse HEAD)"
cat > "$DGT/mod.py" <<'EOF'
class Greeter:
    def hello(self):
        return "hi"

    def bye(self):
        return "bye there"

def standalone():
    return 1
EOF
git -C "$DGT" add mod.py
git -C "$DGT" commit -q -m "change bye()"
HEAD_REV="$(git -C "$DGT" rev-parse HEAD)"
echo "corrupted worktree state, should be ignored by --range" > "$DGT/mod.py"
out="$(cd "$DGT" && python3 "$DS" --range "$BASE..$HEAD_REV")"
check "(f) --range: resolves against git show, not the dirty worktree" "$(printf 'mod.py\tGreeter.bye')" "$out"
git -C "$DGT" checkout -q -- mod.py

# --- (g) deleted file -> "(deleted)" ---
rm "$DGT/notes.md"
out="$(cd "$DGT" && git diff -- notes.md | python3 "$DS")"
check "(g) deleted file: (deleted)" "$(printf 'notes.md\t(deleted)')" "$out"
git -C "$DGT" checkout -q -- notes.md

# --- (h) malformed diff input: clear error, non-zero exit ---
out="$(printf 'this is not a diff\njust some prose\n' | python3 "$DS" 2>&1; echo "rc=$?")"
check "(h) malformed diff: non-zero exit" "rc=1" "$out"
check "(h) malformed diff: clear error message" "malformed diff" "$out"

out="$(printf 'diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ garbage @@\n' | python3 "$DS" 2>&1; echo "rc=$?")"
check "(h2) unparsable hunk header: non-zero exit" "rc=1" "$out"
check "(h2) unparsable hunk header: clear error message" "malformed diff" "$out"

# --- (i) --json emits structured path/symbol pairs ---
python3 -c "
with open('$DGT/mod.py') as f:
    text = f.read()
text = text.replace('return \"hi\"', 'return \"hi2\"')
with open('$DGT/mod.py', 'w') as f:
    f.write(text)
"
out="$(cd "$DGT" && git diff | python3 "$DS" --json)"
check "(i) --json: valid JSON with path/symbol keys" '"symbol": "Greeter.hello"' "$out"
check "(i) --json: path key present" '"path": "mod.py"' "$out"
python3 -c "import json,sys; json.loads(sys.argv[1])" "$out"
check_rc "(i) --json: parses as valid JSON" 0 $?
git -C "$DGT" checkout -q -- mod.py

# --- (j) round-1 review finding: decorator-only edit must still map to the
# decorated function, not "(file-level)" -- ast's FunctionDef.lineno points
# at the `def` line, NOT the decorator line, so a naive [lineno, end_lineno]
# span misses a decorator-argument-only change. ---
cat > "$DGT/deco.py" <<'EOF'
@app.route("/old")
def view():
    return "ok"
EOF
git -C "$DGT" add deco.py
git -C "$DGT" commit -q -m "add deco.py"
python3 -c "
with open('$DGT/deco.py') as f:
    text = f.read()
text = text.replace('/old', '/new')
with open('$DGT/deco.py', 'w') as f:
    f.write(text)
"
out="$(cd "$DGT" && git diff | python3 "$DS")"
check "(j) decorator-arg-only change maps to the decorated function" "$(printf 'deco.py\tview')" "$out"
check_absent "(j) decorator-arg-only change: not (file-level)" "$(printf 'deco.py\t(file-level)')" "$out"
git -C "$DGT" checkout -q -- deco.py

# --- (k) round-1 review finding: deleting a function's TRAILING line must
# still map to that function, not the next surviving (module-scope) line. ---
cat > "$DGT/trail.py" <<'EOF'
def foo():
    a = 1
    b = 2


def bar():
    return 1
EOF
git -C "$DGT" add trail.py
git -C "$DGT" commit -q -m "add trail.py"
python3 -c "
with open('$DGT/trail.py') as f:
    text = f.read()
text = text.replace('    b = 2\n', '')
with open('$DGT/trail.py', 'w') as f:
    f.write(text)
"
out="$(cd "$DGT" && git diff | python3 "$DS")"
check "(k) deleting a function's trailing line maps to that function" "$(printf 'trail.py\tfoo')" "$out"
check_absent "(k) deleting a function's trailing line: not (file-level)" "$(printf 'trail.py\t(file-level)')" "$out"
git -C "$DGT" checkout -q -- trail.py

# --- (l) round-1 review finding: an unbalanced '{' inside a bash STRING must
# not cascade foo's perceived range past bar's declaration -- editing bar
# must map to bar, not foo. ---
cat > "$DGT/strbrace.sh" <<'EOF'
#!/usr/bin/env bash
foo() {
    local msg="opening brace: {"
    echo "$msg"
}

bar() {
    echo "bar"
}
EOF
git -C "$DGT" add strbrace.sh
git -C "$DGT" commit -q -m "add strbrace.sh"
python3 -c "
with open('$DGT/strbrace.sh') as f:
    text = f.read()
text = text.replace('echo \"bar\"', 'echo \"bar2\"')
with open('$DGT/strbrace.sh', 'w') as f:
    f.write(text)
"
out="$(cd "$DGT" && git diff | python3 "$DS")"
check "(l) brace inside a string doesn't cascade: edit in bar maps to bar" "$(printf 'strbrace.sh\tbar')" "$out"
check_absent "(l) brace inside a string doesn't cascade: not misattributed to foo" "$(printf 'strbrace.sh\tfoo')" "$out"
git -C "$DGT" checkout -q -- strbrace.sh

rm -rf "$DGT"
