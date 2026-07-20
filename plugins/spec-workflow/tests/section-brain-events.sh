#!/usr/bin/env bash
# section-brain-events.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain-event feed (E2/MEM-020: emit_event schema + atomic emitter) =="

BE_SCRIPTS="$PLUGIN/scripts"

# ---------------------------------------------------------------- schema fields
# emit_event(root, obj) appends ONE line to <root>/.claude/brain-events.jsonl
# carrying the v1 baseline {v, ts, repo, role, type} plus the caller's payload.
BE="$(mktemp -d)"
# project.yaml present -> repo derives from project.name
mkdir -p "$BE/.claude"
cat >"$BE/.claude/project.yaml" <<'YAML'
schemaVersion: 2
project:
    name: acme/widgets
    mainBranch: main
YAML
out="$(PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 -c '
import json, os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
root = sys.argv[1]
brain.emit_event(root, {"role": "dev", "type": "NoteMinted", "slug": "yaml-key-order"})
lines = open(os.path.join(root, ".claude", "brain-events.jsonl"), encoding="utf-8").read().splitlines()
assert len(lines) == 1, "expected exactly one line, got %d" % len(lines)
ev = json.loads(lines[0])
print("V=%r" % ev.get("v"))
print("TS_TYPE=%s" % type(ev.get("ts")).__name__)
print("REPO=%s" % ev.get("repo"))
print("ROLE=%s" % ev.get("role"))
print("TYPE=%s" % ev.get("type"))
print("SLUG=%s" % ev.get("slug"))
' "$BE" 2>&1)"
check "schema: v is integer 1"       "V=1"                 "$out"
check "schema: ts is a string"       "TS_TYPE=str"         "$out"
check "schema: repo from project.name" "REPO=acme/widgets" "$out"
check "schema: role carried through" "ROLE=dev"            "$out"
check "schema: type carried through" "TYPE=NoteMinted"     "$out"
check "schema: payload carried through" "SLUG=yaml-key-order" "$out"
rm -rf "$BE"

# repo fallback: no project.yaml -> basename of root
BE="$(mktemp -d)"
reponame="$(basename "$BE")"
out="$(PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 -c '
import json, os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
root = sys.argv[1]
brain.emit_event(root, {"role": "reviewer", "type": "RecallPerformed"})
ev = json.loads(open(os.path.join(root, ".claude", "brain-events.jsonl")).readline())
print("REPO=%s" % ev.get("repo"))
' "$BE" 2>&1)"
check "schema: repo falls back to root basename" "REPO=$reponame" "$out"
rm -rf "$BE"

# ------------------------------------------------- single write() call contract
# Atomicity rests on ONE write syscall per line (O_APPEND). Patch os.write to
# count invocations across a single emit_event and assert exactly one.
BE="$(mktemp -d)"
out="$(PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 -c '
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
root = sys.argv[1]
calls = {"n": 0}
real_write = os.write
def counting_write(fd, data):
    calls["n"] += 1
    return real_write(fd, data)
os.write = counting_write
try:
    brain.emit_event(root, {"role": "dev", "type": "LinkFired", "key": "a->b"})
finally:
    os.write = real_write
print("WRITECALLS=%d" % calls["n"])
' "$BE" 2>&1)"
check "atomicity: exactly one os.write() call per emit" "WRITECALLS=1" "$out"
rm -rf "$BE"

# emitted line is newline-terminated (so appends never merge on one line)
BE="$(mktemp -d)"
out="$(PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 -c '
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
root = sys.argv[1]
brain.emit_event(root, {"role": "dev", "type": "NoteMinted", "slug": "a"})
brain.emit_event(root, {"role": "dev", "type": "NoteMinted", "slug": "b"})
data = open(os.path.join(root, ".claude", "brain-events.jsonl"), "rb").read()
print("ENDSNL=%s" % (data.endswith(b"\n")))
print("NLINES=%d" % data.count(b"\n"))
' "$BE" 2>&1)"
check "atomicity: each line newline-terminated" "ENDSNL=True" "$out"
check "atomicity: two emits -> two lines"       "NLINES=2"    "$out"
rm -rf "$BE"

# -------------------------------------------- warning-not-error on unwritable
# §8.1.1: an unwritable feed target must NOT raise; emit_event returns falsy and
# prints a warning, and the caller's own work continues unaffected.
BE="$(mktemp -d)"
# Make .claude a read-only regular file so <root>/.claude/brain-events.jsonl can
# neither be created nor its parent dir made -> the append is doomed.
printf '' >"$BE/.claude"
chmod 000 "$BE/.claude" 2>/dev/null || true
out="$(PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 -c '
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
root = sys.argv[1]
rv = brain.emit_event(root, {"role": "dev", "type": "NoteMinted", "slug": "x"})
# caller keeps running -> this print MUST be reached
print("AFTER_EMIT_REACHED")
print("RETVAL=%r" % rv)
' "$BE" 2>&1)"
check "non-blocking: caller continues after failed emit" "AFTER_EMIT_REACHED" "$out"
check "non-blocking: emit_event returns falsy on failure" "RETVAL=False" "$out"
check "non-blocking: a warning is printed" "warning" "$out"
check_absent "non-blocking: no traceback propagated" "Traceback" "$out"
chmod 755 "$BE/.claude" 2>/dev/null || true
rm -rf "$BE"

# ------------------------------------------------------- concurrency stress test
# N real PROCESSES (not threads -- the GIL would mask an OS-level atomicity bug)
# append concurrently to the SAME file. Assert exactly N intact JSON lines, no
# interleaving, no loss.
BE="$(mktemp -d)"
BE_WORKER="$BE/worker.py"
cat >"$BE_WORKER" <<PY
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
root, idx = sys.argv[1], int(sys.argv[2])
# padded payload keeps each line well under PIPE_BUF (~4KB) while being large
# enough that a non-atomic write would realistically interleave.
brain.emit_event(root, {"role": "dev", "type": "NoteMinted", "idx": idx, "pad": "x" * 200})
PY
BE_N=30
for i in $(seq 1 "$BE_N"); do
    PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 "$BE_WORKER" "$BE" "$i" &
done
wait
out="$(PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 -c '
import json, os, sys
root, n = sys.argv[1], int(sys.argv[2])
p = os.path.join(root, ".claude", "brain-events.jsonl")
lines = open(p, encoding="utf-8").read().splitlines()
valid = 0
idxs = set()
for ln in lines:
    ev = json.loads(ln)   # raises if any line is torn/interleaved
    valid += 1
    idxs.add(ev["idx"])
print("LINES=%d" % len(lines))
print("VALID=%d" % valid)
print("UNIQ=%d" % len(idxs))
print("EXPECT=%d" % n)
' "$BE" "$BE_N" 2>&1)"
check "concurrency: line count == N processes"   "LINES=$BE_N"  "$out"
check "concurrency: every line is valid JSON"    "VALID=$BE_N"  "$out"
check "concurrency: no lost writes (N unique idx)" "UNIQ=$BE_N" "$out"
rm -rf "$BE"

echo "== brain-event command wiring (MEM-021: emit from all brain.py commands) =="
BW_BRAIN="$PLUGIN/scripts/brain.py"

# bw_summary <feed> — print per-type counts + sorted unique key/slug/reason
# fields so tests can assert the event SEQUENCE (types + counts) a command emits.
bw_summary() {
    python3 - "$1" <<'PY'
import collections, json, os, sys
feed = sys.argv[1]
c = collections.Counter()
keys, slugs, reasons = [], [], []
if os.path.exists(feed):
    for ln in open(feed, encoding="utf-8"):
        ln = ln.strip()
        if not ln:
            continue
        e = json.loads(ln)   # raises on any torn line
        c[e.get("type")] += 1
        if "key" in e:
            keys.append(e["key"])
        if "slug" in e:
            slugs.append(e["slug"])
        if "reason" in e:
            reasons.append(e["reason"])
for t in ("NoteMinted", "LinkFormed", "RecallPerformed", "LinkFired",
          "ConsultPerformed", "NoteGraduated", "LinkPruned"):
    print("%s=%d" % (t, c.get(t, 0)))
print("KEYS=" + ",".join(sorted(set(keys))))
print("SLUGS=" + ",".join(sorted(set(slugs))))
print("REASONS=" + ",".join(sorted(set(reasons))))
PY
}

# ------------------------------------------------------------- mint: NoteMinted + LinkFormed
# minting a note with 2 genuinely-new wikilinks => exactly 1 NoteMinted + 2 LinkFormed.
BW="$(mktemp -d)"
bw() { python3 "$BW_BRAIN" "$BW" "$@"; }
printf 'alpha body\n\nrel: [[foo]] and [[bar]]\n' \
    | bw mint dev alpha --tags t --paths "p/**" --source "PR#1" >/dev/null
out="$(bw_summary "$BW/.claude/brain-events.jsonl")"
check "mint emits exactly one NoteMinted"        "NoteMinted=1"        "$out"
check "mint emits one LinkFormed per new wikilink" "LinkFormed=2"      "$out"
check "mint NoteMinted carries the slug"          "SLUGS=alpha"        "$out"
check "mint LinkFormed carries the new link keys" "KEYS=alpha->bar,alpha->foo" "$out"
# re-mint the SAME body: no genuinely-new wikilink => +1 NoteMinted, +0 LinkFormed.
printf 'alpha body\n\nrel: [[foo]] and [[bar]]\n' \
    | bw mint dev alpha --tags t --paths "p/**" --source "PR#1" >/dev/null
out="$(bw_summary "$BW/.claude/brain-events.jsonl")"
check "re-mint adds a NoteMinted"                 "NoteMinted=2"       "$out"
check "re-mint forms no new links (existing keys)" "LinkFormed=2"      "$out"
rm -rf "$BW"

# ------------------------------------------------------------- recall: RecallPerformed + LinkFired
# a seeds by path and links to b; recall traverses a->b once => 1 RecallPerformed + 1 LinkFired.
BW="$(mktemp -d)"
bw() { python3 "$BW_BRAIN" "$BW" "$@"; }
printf 'a body\n\nrel: [[b]]\n' | bw mint dev a --tags x --paths "p/**" >/dev/null
printf 'b body\n'               | bw mint dev b --tags y --paths "q/**" >/dev/null
: >"$BW/.claude/brain-events.jsonl"   # isolate recall events from the mint events above
bw recall dev --paths "p/foo" --keywords "" >/dev/null
out="$(bw_summary "$BW/.claude/brain-events.jsonl")"
check "recall emits exactly one RecallPerformed"  "RecallPerformed=1"  "$out"
check "recall emits one LinkFired per traversed link" "LinkFired=1"    "$out"
check "recall LinkFired carries the traversed key" "KEYS=a->b"         "$out"
# a second recall call fires the same link again (traversed is per-call) => +1 LinkFired.
: >"$BW/.claude/brain-events.jsonl"
bw recall dev --paths "p/foo" --keywords "" >/dev/null
out="$(bw_summary "$BW/.claude/brain-events.jsonl")"
check "2nd recall fires the link again (per-call)" "LinkFired=1"       "$out"
check "2nd recall emits one RecallPerformed"       "RecallPerformed=1" "$out"
rm -rf "$BW"

# ------------------------------------------------------------- consult: ConsultPerformed
BW="$(mktemp -d)"
bw() { python3 "$BW_BRAIN" "$BW" "$@"; }
printf 'reviewer rule body\n' | bw mint reviewer verify-tests --tags review --paths "**" >/dev/null
: >"$BW/.claude/brain-events.jsonl"
bw consult dev reviewer verify-tests >/dev/null
out="$(bw_summary "$BW/.claude/brain-events.jsonl")"
check "consult emits exactly one ConsultPerformed" "ConsultPerformed=1" "$out"
check "consult ConsultPerformed carries the slug"  "SLUGS=verify-tests" "$out"
rm -rf "$BW"

# ------------------------------------------------------------- graduate: NoteGraduated
BW="$(mktemp -d)"
bw() { python3 "$BW_BRAIN" "$BW" "$@"; }
printf 'gradbody\n' | bw mint dev gradme --tags g --paths "g/**" >/dev/null
: >"$BW/.claude/brain-events.jsonl"
bw graduate dev gradme >/dev/null
out="$(bw_summary "$BW/.claude/brain-events.jsonl")"
check "graduate emits exactly one NoteGraduated"  "NoteGraduated=1"    "$out"
check "graduate NoteGraduated carries the slug"   "SLUGS=gradme"       "$out"
# read-only failure: graduating a nonexistent slug must emit NOTHING.
: >"$BW/.claude/brain-events.jsonl"
bw graduate dev nope 2>/dev/null || true
out="$(bw_summary "$BW/.claude/brain-events.jsonl")"
check "graduate on missing slug emits no event"   "NoteGraduated=0"    "$out"
rm -rf "$BW"

# ------------------------------------------------------------- prune --apply: LinkPruned per removed link
BW="$(mktemp -d)"
bw() { python3 "$BW_BRAIN" "$BW" "$@"; }
# two links whose targets never exist => both are prune candidates (target missing).
printf 'src body\n\nrel: [[ghost-one]] and [[ghost-two]]\n' \
    | bw mint dev src --tags s --paths "s/**" >/dev/null
: >"$BW/.claude/brain-events.jsonl"
# read-only: prune WITHOUT --apply must emit nothing.
bw prune dev >/dev/null
out="$(bw_summary "$BW/.claude/brain-events.jsonl")"
check "prune without --apply emits no LinkPruned" "LinkPruned=0"       "$out"
# --apply removes both candidate links => exactly 2 LinkPruned.
: >"$BW/.claude/brain-events.jsonl"
bw prune dev --apply >/dev/null
out="$(bw_summary "$BW/.claude/brain-events.jsonl")"
check "prune --apply emits one LinkPruned per removed link" "LinkPruned=2" "$out"
check "prune LinkPruned carries the removed keys"  "KEYS=src->ghost-one,src->ghost-two" "$out"
check "prune LinkPruned carries a reason"          "target missing"     "$out"
rm -rf "$BW"

# ------------------------------------------------------------- byte-identity of legacy outputs (frozen §8.3)
# The new emit_event calls must NOT alter .activation.jsonl or links.json. Run the
# SAME sequence twice under frozen time: once with emit_event stubbed to a no-op
# (== pre-wiring), once real. The two legacy files must be byte-for-byte identical.
BW_OFF="$(mktemp -d)"; BW_ON="$(mktemp -d)"
out="$(PLUGIN_SCRIPTS="$PLUGIN/scripts" python3 - "$BW_OFF" "$BW_ON" <<'PY' 2>&1
import io, os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
brain.now_iso = lambda: "2020-01-01T00:00:00Z"
brain.today = lambda: "2020-01-01"
real_emit = brain.emit_event

def drive(root):
    def mint(slug, body, tags, paths):
        old = sys.stdin
        sys.stdin = io.StringIO(body)
        try:
            brain.main([root, "mint", "dev", slug, "--tags", tags, "--paths", paths])
        finally:
            sys.stdin = old
    mint("a", "a body\n\nrel: [[b]]\n", "x", "p/**")
    mint("b", "b body\n", "y", "q/**")
    brain.main([root, "recall", "dev", "--paths", "p/foo", "--keywords", ""])

off, on = sys.argv[1], sys.argv[2]
brain.emit_event = lambda *a, **k: False   # pre-wiring behaviour
drive(off)
brain.emit_event = real_emit               # post-wiring behaviour
drive(on)

def rd(root, rel):
    p = os.path.join(root, rel)
    return open(p, "rb").read() if os.path.exists(p) else b""

al = os.path.join(".claude", "identities", "dev", "brain", ".activation.jsonl")
lj = os.path.join(".claude", "identities", "dev", "brain", "links.json")
print("ACTIVATION_IDENTICAL=%s" % (rd(off, al) == rd(on, al)))
print("LINKS_IDENTICAL=%s" % (rd(off, lj) == rd(on, lj)))
PY
)"
check "byte-identity: .activation.jsonl unchanged by emit" "ACTIVATION_IDENTICAL=True" "$out"
check "byte-identity: links.json unchanged by emit"        "LINKS_IDENTICAL=True"      "$out"
rm -rf "$BW_OFF" "$BW_ON"

# ------------------------------------------------------------- feed unavailable breaks nothing (DoD)
# Make the feed path a DIRECTORY so the append is doomed, while .claude/identities
# stays writable. The command's real work (note + links.json) must complete, exit 0,
# and only a warning is printed.
BW="$(mktemp -d)"
bw() { python3 "$BW_BRAIN" "$BW" "$@"; }
mkdir -p "$BW/.claude/brain-events.jsonl"   # feed target unwritable
out="$(printf 'body\n\nrel: [[x]]\n' | bw mint dev survivor --tags t --paths "p/**" 2>&1)"; rc=$?
check_rc "feed-unwritable: mint still exits 0"     0 "$rc"
check "feed-unwritable: mint still reports minted" "minted dev/survivor" "$out"
check "feed-unwritable: a warning is printed"      "warning"             "$out"
check_absent "feed-unwritable: no traceback"       "Traceback"           "$out"
check "feed-unwritable: links.json still written"  "survivor->x" "$(cat "$BW/.claude/identities/dev/brain/links.json")"
rm -rf "$BW"

echo "== verify-feed (MEM-023: fold LinkFormed/LinkFired/LinkPruned, diff against links.json) =="

# vf_seed_feed <root> <line...> -- write one brain-events.jsonl line per arg
vf_seed_feed() {
    local root="$1"; shift
    mkdir -p "$root/.claude"
    : >"$root/.claude/brain-events.jsonl"
    for ln in "$@"; do
        printf '%s\n' "$ln" >>"$root/.claude/brain-events.jsonl"
    done
}

# vf_seed_links <root> <role> <json> -- write links.json verbatim for a role
vf_seed_links() {
    local root="$1" role="$2" json="$3"
    mkdir -p "$root/.claude/identities/$role/brain"
    printf '%s' "$json" >"$root/.claude/identities/$role/brain/links.json"
}

# ------------------------------------------------------- clean fold: exit 0
VF="$(mktemp -d)"
vf() { python3 "$BW_BRAIN" "$VF" "$@"; }
vf_seed_feed "$VF" \
    '{"v":1,"ts":"t","repo":"r","role":"dev","type":"LinkFormed","key":"a->b"}' \
    '{"v":1,"ts":"t","repo":"r","role":"dev","type":"LinkFired","key":"a->b"}' \
    '{"v":1,"ts":"t","repo":"r","role":"dev","type":"LinkFired","key":"a->b"}'
vf_seed_links "$VF" dev '{"a->b": {"weight": 0.5, "fires": 2, "last": "2026-01-01"}}'
out="$(vf verify-feed dev 2>&1)"; rc=$?
check_rc "verify-feed: clean fold exits 0"            0 "$rc"
check "verify-feed: clean fold prints a clean summary" "verify-feed: dev clean" "$out"
check_absent "verify-feed: clean fold reports no divergence" "DIVERGENCE" "$out"
rm -rf "$VF"

# ------------------------------------------------- missing-key divergence: exit 1
VF="$(mktemp -d)"
vf() { python3 "$BW_BRAIN" "$VF" "$@"; }
vf_seed_feed "$VF" \
    '{"v":1,"ts":"t","repo":"r","role":"dev","type":"LinkFormed","key":"a->b"}'
vf_seed_links "$VF" dev '{}'
out="$(vf verify-feed dev 2>&1)"; rc=$?
check_rc "verify-feed: missing key exits 1"                    1 "$rc"
check "verify-feed: missing key names the key"                 "a->b" "$out"
check "verify-feed: missing key divergence is reported"        "DIVERGENCE" "$out"
rm -rf "$VF"

# --------------------------------------------- fire-count-drift divergence: exit 1
VF="$(mktemp -d)"
vf() { python3 "$BW_BRAIN" "$VF" "$@"; }
vf_seed_feed "$VF" \
    '{"v":1,"ts":"t","repo":"r","role":"dev","type":"LinkFormed","key":"a->b"}' \
    '{"v":1,"ts":"t","repo":"r","role":"dev","type":"LinkFired","key":"a->b"}' \
    '{"v":1,"ts":"t","repo":"r","role":"dev","type":"LinkFired","key":"a->b"}'
vf_seed_links "$VF" dev '{"a->b": {"weight": 0.5, "fires": 1, "last": "2026-01-01"}}'
out="$(vf verify-feed dev 2>&1)"; rc=$?
check_rc "verify-feed: fire-count drift exits 1"                1 "$rc"
check "verify-feed: fire-count drift names the key"             "a->b" "$out"
check "verify-feed: fire-count drift reports fold count"        "fold=2" "$out"
check "verify-feed: fire-count drift reports links.json count"  "links.json=1" "$out"
rm -rf "$VF"

# ------------------------------------------------- empty feed: trivially green
VF="$(mktemp -d)"
vf() { python3 "$BW_BRAIN" "$VF" "$@"; }
vf_seed_links "$VF" dev '{"x->y": {"weight": 0.5, "fires": 99, "last": null}}'
out="$(vf verify-feed dev 2>&1)"; rc=$?
check_rc "verify-feed: no feed file exits 0"    0 "$rc"
check "verify-feed: no feed file is clean"      "verify-feed: dev clean" "$out"

: >"$VF/.claude/brain-events.jsonl"   # exists but empty
out="$(vf verify-feed dev 2>&1)"; rc=$?
check_rc "verify-feed: empty feed file exits 0" 0 "$rc"
check "verify-feed: empty feed file is clean"   "verify-feed: dev clean" "$out"
rm -rf "$VF"

# --------------------------------- links.json-only key is NOT a divergence
VF="$(mktemp -d)"
vf() { python3 "$BW_BRAIN" "$VF" "$@"; }
vf_seed_feed "$VF" \
    '{"v":1,"ts":"t","repo":"r","role":"dev","type":"LinkFormed","key":"a->b"}'
vf_seed_links "$VF" dev '{"a->b": {"weight": 0.5, "fires": 0, "last": null}, "pre-existing->link": {"weight": 0.5, "fires": 7, "last": "2020-01-01"}}'
out="$(vf verify-feed dev 2>&1)"; rc=$?
check_rc "verify-feed: pre-feed-history key exits 0"          0 "$rc"
check "verify-feed: pre-feed-history key is clean"            "verify-feed: dev clean" "$out"
check_absent "verify-feed: pre-feed-history key not flagged"  "pre-existing->link" "$out"
rm -rf "$VF"

# ------------------------------------------------- LinkPruned folds key away
VF="$(mktemp -d)"
vf() { python3 "$BW_BRAIN" "$VF" "$@"; }
vf_seed_feed "$VF" \
    '{"v":1,"ts":"t","repo":"r","role":"dev","type":"LinkFormed","key":"a->ghost"}' \
    '{"v":1,"ts":"t","repo":"r","role":"dev","type":"LinkPruned","key":"a->ghost","reason":"target missing"}'
vf_seed_links "$VF" dev '{}'
out="$(vf verify-feed dev 2>&1)"; rc=$?
check_rc "verify-feed: pruned-then-absent key exits 0"        0 "$rc"
check "verify-feed: pruned-then-absent key is clean"          "verify-feed: dev clean" "$out"
check_absent "verify-feed: pruned key not flagged as missing" "a->ghost" "$out"
rm -rf "$VF"
