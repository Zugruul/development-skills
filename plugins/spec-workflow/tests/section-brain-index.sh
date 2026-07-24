#!/usr/bin/env bash
# section-brain-index.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: same as section-brain.sh (see its header comment).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain index (MEM-031 embedding index) =="
BIT="$(mktemp -d)"
BRAIN_IDX="$PLUGIN/scripts/brain.py"
brainidx() { python3 "$BRAIN_IDX" "$BIT" "$@"; }

# a tiny deterministic fake embedder stub: echoes a fixed-length JSON array
# per input line, varying by input length so different notes get different
# vectors (keeps assertions meaningful without a real model).
STUB="$BIT/.fake-embed.py"
cat >"$STUB" <<'PY'
import sys
for line in sys.stdin:
    line = line.rstrip("\n")
    n = len(line) % 7 + 1
    print("[" + ", ".join(str(n * 0.1) for _ in range(3)) + "]")
PY
STUB_CMD="python3 $STUB"

idx_table() { # role -> tab-separated rows: slug content_hash vector updated_at
    python3 - "$BIT/.claude/identities/$1/brain/index.sqlite3" <<'PY'
import sqlite3, sys
path = sys.argv[1]
conn = sqlite3.connect(path)
for row in conn.execute("SELECT slug, content_hash, vector, updated_at FROM notes ORDER BY slug"):
    print("\t".join(str(x) for x in row))
PY
}

db_exists() {
    [[ -f "$BIT/.claude/identities/$1/brain/index.sqlite3" ]] && echo yes || echo no
}

# ---- fresh build (no capability present, no BRAIN_EMBED_CMD) -----------
printf 'Body one.\n' | brainidx mint idx alpha --tags a >/dev/null
printf 'Body two.\n' | brainidx mint idx beta --tags b >/dev/null
unset BRAIN_EMBED_CMD
# empty CAPABILITY_HOME: absence must hold even where the capability is installed
BIT_NOCAP="$(mktemp -d)"
out="$(CAPABILITY_HOME="$BIT_NOCAP" brainidx index idx 2>&1 1>/dev/null)"
rc=$?
check_rc "fresh build (capability absent) exits 0" 0 "$rc"
check "fresh build (capability absent) prints one stderr notice" "embeddings capability unavailable" "$out"
check "fresh build (capability absent) db exists" "yes" "$(db_exists idx)"

# ---- capability-present path: fresh build with stub embedder -----------
BIT2="$(mktemp -d)"
brainidx2() { python3 "$BRAIN_IDX" "$BIT2" "$@"; }
printf 'Body one.\n' | brainidx2 mint idx alpha --tags a >/dev/null
printf 'Body two.\n' | brainidx2 mint idx beta --tags b >/dev/null
BRAIN_EMBED_CMD="$STUB_CMD" brainidx2 index idx >/dev/null 2>&1
idx_table_2() {
    python3 - "$BIT2/.claude/identities/idx/brain/index.sqlite3" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
for row in conn.execute("SELECT slug, content_hash, vector, updated_at FROM notes ORDER BY slug"):
    print("\t".join(str(x) for x in row))
PY
}
tbl="$(idx_table_2)"
check "fresh build row count" "$(printf 'alpha\n' && printf 'beta')" "$(cut -f1 <<<"$tbl")"
check "fresh build stores real vector for alpha" "alpha" "$(grep alpha <<<"$tbl")"
alpha_vector="$(grep '^alpha' <<<"$tbl" | cut -f3)"
if [[ -n "$alpha_vector" ]] && python3 -c "import json, sys; json.loads(sys.argv[1])" "$alpha_vector" >/dev/null 2>&1; then
    echo "ok   fresh build vector field is non-empty, valid-JSON (not an empty placeholder)"
else
    echo "FAIL fresh build vector field is non-empty, valid-JSON — got: $alpha_vector"
    fails=$((fails + 1))
fi

# hash-stable no-op: second run makes zero writes
before="$(idx_table_2)"
BRAIN_EMBED_CMD="$STUB_CMD" brainidx2 index idx >/dev/null 2>&1
after="$(idx_table_2)"
check "hash-stable no-op leaves table identical" "$before" "$after"

# ---- incremental update on changed note only ----------------------------
before_rows="$(idx_table_2)"
before_alpha="$(grep '^alpha' <<<"$before_rows")"
before_beta="$(grep '^beta' <<<"$before_rows")"
alpha_note="$BIT2/.claude/identities/idx/brain/notes/alpha.md"
# hand-edit the note body directly (evolve doesn't exist yet -- MEM-043)
python3 - "$alpha_note" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("Body one.", "Body one CHANGED.")
open(path, "w", encoding="utf-8").write(text)
PY
BRAIN_EMBED_CMD="$STUB_CMD" brainidx2 index idx >/dev/null 2>&1
after_rows="$(idx_table_2)"
after_alpha="$(grep '^alpha' <<<"$after_rows")"
after_beta="$(grep '^beta' <<<"$after_rows")"
if [[ "$after_alpha" != "$before_alpha" ]]; then
    echo "ok   incremental update changes only the edited note's row"
else
    echo "FAIL incremental update changes only the edited note's row — alpha row unchanged"
    fails=$((fails + 1))
fi
check "incremental update leaves unrelated note row byte-identical" "$after_beta" "$before_beta"

# ---- rebuild-equals-incremental -----------------------------------------
printf 'Body three.\n' | brainidx2 mint idx gamma --tags c >/dev/null
BRAIN_EMBED_CMD="$STUB_CMD" brainidx2 index idx >/dev/null 2>&1
incremental_slughash="$(idx_table_2 | cut -f1,2 | sort)"
BRAIN_EMBED_CMD="$STUB_CMD" brainidx2 index idx --rebuild >/dev/null 2>&1
rebuild_slughash="$(idx_table_2 | cut -f1,2 | sort)"
check "rebuild matches incremental (slug+content_hash, modulo updated_at)" "$incremental_slughash" "$rebuild_slughash"

# ---- stale cleanup: rebuild drops rows for deleted notes -----------------
rm -f "$BIT2/.claude/identities/idx/brain/notes/gamma.md"
BRAIN_EMBED_CMD="$STUB_CMD" brainidx2 index idx --rebuild >/dev/null 2>&1
check_absent "rebuild removes stale row for deleted note" "gamma" "$(idx_table_2)"

# ---- stale cleanup: a plain incremental run (no --rebuild) also drops ----
# stale rows -- a separate code path (row-by-row DELETE) from --rebuild's
# DROP TABLE, and must be verified independently.
BIT4="$(mktemp -d)"
brainidx4() { python3 "$BRAIN_IDX" "$BIT4" "$@"; }
idx_table_4() {
    python3 - "$BIT4/.claude/identities/idx/brain/index.sqlite3" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
for row in conn.execute("SELECT slug, content_hash, vector, updated_at FROM notes ORDER BY slug"):
    print("\t".join(str(x) for x in row))
PY
}
printf 'Keep me.\n' | brainidx4 mint idx keep --tags k >/dev/null
printf 'Delete me.\n' | brainidx4 mint idx doomed --tags d >/dev/null
BRAIN_EMBED_CMD="$STUB_CMD" brainidx4 index idx >/dev/null 2>&1
before_keep="$(idx_table_4 | grep '^keep')"
rm -f "$BIT4/.claude/identities/idx/brain/notes/doomed.md"
BRAIN_EMBED_CMD="$STUB_CMD" brainidx4 index idx >/dev/null 2>&1
after_tbl_4="$(idx_table_4)"
check_absent "incremental (non-rebuild) run removes stale row for deleted note" "doomed" "$after_tbl_4"
check "incremental (non-rebuild) run leaves other notes' rows untouched" "$before_keep" "$(grep '^keep' <<<"$after_tbl_4")"
rm -rf "$BIT4"

# ---- index absence never errors recall -----------------------------------
BIT3="$(mktemp -d)"
brainidx3() { python3 "$BRAIN_IDX" "$BIT3" "$@"; }
printf 'Never indexed.\n' | brainidx3 mint idx solo --tags s --paths "x/**" >/dev/null
out="$(brainidx3 recall idx --paths "x/**" --keywords "" 2>&1)"
rc=$?
check_rc "recall with no index.sqlite3 exits 0" 0 "$rc"
check "recall with no index.sqlite3 still returns note content" "Never indexed" "$out"
check "recall in BIT3 never created a db file" "no" "$([[ -f "$BIT3/.claude/identities/idx/brain/index.sqlite3" ]] && echo yes || echo no)"

rm -rf "$BIT" "$BIT2" "$BIT3"
