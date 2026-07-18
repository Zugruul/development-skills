#!/usr/bin/env bash
# section-brain-hybrid-recall.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: same as section-brain.sh (see its header comment).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain hybrid recall (MEM-032 embedding + keyword union) =="
BRAIN_HR="$PLUGIN/scripts/brain.py"

# Fake embedder stub: a fixed small vocabulary maps words to one-hot-ish
# direction components, so cosine similarity between two texts genuinely
# discriminates by shared vocabulary (unlike section-brain-index.sh's stub,
# which produces collinear [x,x,x] vectors that are always cosine-1.0 with
# each other -- useless for testing top-K ranking).
HRSTUB_DIR="$(mktemp -d)"
HRSTUB="$HRSTUB_DIR/.fake-embed-hr.py"
cat >"$HRSTUB" <<'PY'
import json, sys

VOCAB = {"cats": 0, "dogs": 1, "birds": 2, "fish": 3}

def vec(text):
    v = [0.0, 0.0, 0.0, 0.0]
    for w in text.lower().split():
        w = w.strip(".,!?")
        if w in VOCAB:
            v[VOCAB[w]] += 1.0
    return v

for line in sys.stdin:
    print(json.dumps(vec(line.rstrip("\n"))))
PY
HRSTUB_CMD="python3 $HRSTUB"

# ---- test 1: keyword search misses a semantically-related note; hybrid finds it
HR1="$(mktemp -d)"
hr1() { python3 "$BRAIN_HR" "$HR1" "$@"; }
printf 'Widget config info.\n' | hr1 mint idx kw-note --tags widget --paths "src/**" >/dev/null
printf 'All about cats and dogs together.\n' | hr1 mint idx sem-note --tags other --paths "other/**" >/dev/null
BRAIN_EMBED_CMD="$HRSTUB_CMD" hr1 index idx >/dev/null 2>&1
out="$(BRAIN_EMBED_CMD="$HRSTUB_CMD" hr1 recall idx --paths "" --keywords "cats,dogs")"
check "hybrid recall: keyword search alone would miss sem-note (no tag/path overlap)" "sem-note" "$out"
check "hybrid recall: embedding-similar note is surfaced" "cats and dogs together" "$out"
rm -rf "$HR1"

# ---- test 2: keyword-only path is golden-identical when sidecar absent
HR2A="$(mktemp -d)"
HR2B="$(mktemp -d)"
hr2a() { python3 "$BRAIN_HR" "$HR2A" "$@"; }
hr2b() { python3 "$BRAIN_HR" "$HR2B" "$@"; }
for d in hr2a hr2b; do
    printf 'Widget config info.\n' | $d mint idx kw-note --tags widget --paths "src/**" >/dev/null
    printf 'All about cats and dogs together.\n' | $d mint idx sem-note --tags other --paths "other/**" >/dev/null
done
# HR2A never runs `index` at all (no sidecar, ever). HR2B DOES build the
# index sidecar (BRAIN_EMBED_CMD stub wired in), but is recalled with empty
# --keywords -- no query text to embed, so the hybrid block's own
# `if query_text:` guard skips it (nothing "relevant" to find because there
# is nothing to search for). Comparing the two proves recall's output is
# unchanged by hybrid seeding even when the sidecar genuinely exists, not
# merely when `index` was never run at all.
BRAIN_EMBED_CMD="$HRSTUB_CMD" hr2b index idx >/dev/null 2>&1
out_a="$(hr2a recall idx --paths "src/**" --keywords "")"
out_b_with_index="$(BRAIN_EMBED_CMD="$HRSTUB_CMD" hr2b recall idx --paths "src/**" --keywords "")"
check "golden-identical: sidecar-present-but-no-query output matches sidecar-absent output" "$out_b_with_index" "$out_a"
check_absent "golden-identical: sidecar-absent recall never surfaces the embedding-only note" "sem-note" "$out_a"
db_before="$([[ -f "$HR2A/.claude/identities/idx/brain/index.sqlite3" ]] && echo yes || echo no)"
check "golden-identical: recall never creates a db file when sidecar absent" "no" "$db_before"
rm -rf "$HR2A" "$HR2B"

# ---- test 3: the --k flag is respected (top-K neighbor cap)
HR3="$(mktemp -d)"
hr3() { python3 "$BRAIN_HR" "$HR3" "$@"; }
printf 'Widget config info.\n' | hr3 mint idx kw-note --tags widget --paths "src/**" >/dev/null
printf 'cats dogs\n' | hr3 mint idx sem-strong --tags other --paths "other/**" >/dev/null
printf 'cats only here\n' | hr3 mint idx sem-medium --tags other --paths "other/**" >/dev/null
printf 'birds and fish\n' | hr3 mint idx sem-irrelevant --tags other --paths "other/**" >/dev/null
BRAIN_EMBED_CMD="$HRSTUB_CMD" hr3 index idx >/dev/null 2>&1
out_k1="$(BRAIN_EMBED_CMD="$HRSTUB_CMD" hr3 recall idx --paths "" --keywords "cats,dogs" --k 1)"
out_k3="$(BRAIN_EMBED_CMD="$HRSTUB_CMD" hr3 recall idx --paths "" --keywords "cats,dogs" --k 3)"
check "k=1: strongest neighbor is seeded" "sem-strong" "$out_k1"
check_absent "k=1: second-best neighbor not seeded" "sem-medium" "$out_k1"
check "k=3: strongest neighbor still seeded" "sem-strong" "$out_k3"
check "k=3: second-best neighbor now seeded" "sem-medium" "$out_k3"
rm -rf "$HR3"

# ---- test 4: budget is still respected when hybrid seeding adds more candidates
HR4="$(mktemp -d)"
hr4() { python3 "$BRAIN_HR" "$HR4" "$@"; }
printf 'Widget config info.\n' | hr4 mint idx kw-note --tags widget --paths "src/**" >/dev/null
for i in 1 2 3 4 5 6 7 8; do
    printf 'cats dogs note %s\n' "$i" | hr4 mint idx "hb$i" --tags other --paths "other/**" >/dev/null
done
BRAIN_EMBED_CMD="$HRSTUB_CMD" hr4 index idx >/dev/null 2>&1
out="$(BRAIN_EMBED_CMD="$HRSTUB_CMD" hr4 recall idx --paths "" --keywords "cats,dogs" --k 8 --budget 5 \
    | python3 -c 'import sys; s=sys.stdin.read().rstrip("\n"); print("WITHIN" if len(s) <= 20 else "OVER:"+str(len(s)))')"
check "budget still capped when hybrid seeding adds more candidates than budget allows" "WITHIN" "$out"
rm -rf "$HR4"

# ---- test 5: a graduated embedding-neighbor still bridges link activation
# (§9.3 "then rank as today" -- the keyword/glob seed loop never filters
# graduated notes at seed time, only at the final emit stage; the hybrid
# seed loop must match that, or a graduated neighbor can never spread
# activation to a linked non-graduated note).
HR5="$(mktemp -d)"
hr5() { python3 "$BRAIN_HR" "$HR5" "$@"; }
printf 'Nothing marker here.\n' | hr5 mint idx sem-grad-target --tags other2 --paths "other2/**" >/dev/null
printf 'cats dogs marker text.\n\nRelated: [[sem-grad-target]]\n' \
    | hr5 mint idx sem-grad-src --tags other --paths "other/**" >/dev/null
python3 - "$HR5" <<'PY'
import os, re, sys
p = os.path.join(sys.argv[1], ".claude/identities/idx/brain/notes/sem-grad-src.md")
s = open(p).read()
open(p, "w").write(re.sub(r"graduated: .*", "graduated: true", s))
PY
BRAIN_EMBED_CMD="$HRSTUB_CMD" hr5 index idx >/dev/null 2>&1
# --k 1: sem-grad-src (cosine ~1.0 vs the query) is the sole top-K neighbor;
# sem-grad-target (cosine 0.0, no shared vocabulary) is excluded from the
# neighbor set outright, so its only possible path into the output is link
# spread FROM sem-grad-src -- never direct embedding seeding.
out="$(BRAIN_EMBED_CMD="$HRSTUB_CMD" hr5 recall idx --paths "" --keywords "cats,dogs" --k 1)"
check_absent "graduated embedding-neighbor is not injected directly" "cats dogs marker text" "$out"
check "graduated embedding-neighbor still bridges activation to its linked note" "sem-grad-target" "$out"
rm -rf "$HR5"

rm -rf "$HRSTUB_DIR"
