#!/usr/bin/env bash
# section-brain-atomic.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain atomic writes + cross-process flock (AST-004) =="

BA_SCRIPTS="$PLUGIN/scripts"

# ------------------------------------------------------------------------
# (1) API surface: brain.brain_lock exists, is a context manager, and is
# reentrant WITHIN one process -- a recall that internally calls
# save_links(), which itself acquires the same lock, must not deadlock
# itself. A 5s SIGALRM turns "the fix is missing or broken" into a clean
# FAIL instead of a hang.
# ------------------------------------------------------------------------
BA1="$(mktemp -d)"
out="$(python3 - "$BA1" "$BA_SCRIPTS" <<'PY'
import sys, os, signal
root, scripts = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import brain

def _on_alarm(signum, frame):
    raise SystemExit("TIMEOUT: brain_lock did not release or reenter within 5s")

signal.signal(signal.SIGALRM, _on_alarm)
signal.alarm(5)

identities = os.path.join(root, ".claude/identities")
os.makedirs(identities, exist_ok=True)

has_lock = hasattr(brain, "brain_lock")
print("HAS_BRAIN_LOCK:%s" % ("yes" if has_lock else "no"))
if has_lock:
    with brain.brain_lock(identities):
        with brain.brain_lock(identities):
            print("REENTRANT_OK:yes")
    print("RELEASED_OK:yes")
signal.alarm(0)
PY
)"
check "brain.brain_lock exists on the module" "HAS_BRAIN_LOCK:yes" "$out"
check "brain_lock is reentrant within one process (nested acquire does not hang)" "REENTRANT_OK:yes" "$out"
check "brain_lock releases cleanly after the outermost context exits" "RELEASED_OK:yes" "$out"
rm -rf "$BA1"

# ------------------------------------------------------------------------
# (1b) lock-key normalization (review r2 finding 1): the reentrancy dict
# used to key on the RAW identities string, so two spellings of the SAME
# directory (here: the canonical absolute path vs a symlink alias) hashed
# to two different dict entries -- the same process then flocks the same
# underlying directory twice, and the second flock() blocks forever on the
# first (a true self-deadlock, reproduced hanging by the reviewer). A 5s
# SIGALRM turns a regression back into a clean FAIL instead of a hang.
# ------------------------------------------------------------------------
BA1B="$(mktemp -d)"
out="$(python3 - "$BA1B" "$BA_SCRIPTS" <<'PY'
import sys, os, signal
root, scripts = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import brain

def _on_alarm(signum, frame):
    raise SystemExit("TIMEOUT: brain_lock self-deadlocked across two spellings of one directory")

signal.signal(signal.SIGALRM, _on_alarm)
signal.alarm(5)

identities = os.path.join(root, ".claude/identities")
os.makedirs(identities, exist_ok=True)
alias = os.path.join(root, ".claude/identities-alias")
os.symlink(os.path.realpath(identities), alias)

with brain.brain_lock(identities):
    with brain.brain_lock(alias):
        print("NESTED_ALIAS_OK:yes")
print("RELEASED_ALIAS_OK:yes")
signal.alarm(0)
PY
)"
check "brain_lock does not self-deadlock nesting through a symlink alias of the same dir" \
    "NESTED_ALIAS_OK:yes" "$out"
check "brain_lock releases cleanly after both aliased acquisitions exit" \
    "RELEASED_ALIAS_OK:yes" "$out"
rm -rf "$BA1B"

# ------------------------------------------------------------------------
# (1c) fd leak on flock failure (review r2 finding 2): if fcntl.flock()
# raises AFTER os.open() already succeeded (e.g. ENOLCK), the fd must be
# closed before the exception propagates, not leaked. fcntl.flock is
# monkeypatched to fail exactly once so the failure is deterministic
# rather than depending on a real out-of-locks condition; the open file
# descriptor count is compared before/after via /dev/fd.
# ------------------------------------------------------------------------
BA1C="$(mktemp -d)"
out="$(python3 - "$BA1C" "$BA_SCRIPTS" <<'PY'
import sys, os
root, scripts = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import brain
import fcntl

identities = os.path.join(root, ".claude/identities")
os.makedirs(identities, exist_ok=True)

real_flock = fcntl.flock
calls = {"n": 0}

def failing_flock(fd, op):
    calls["n"] += 1
    if calls["n"] == 1:
        raise OSError(37, "No locks available")
    return real_flock(fd, op)

fcntl.flock = failing_flock

def fd_count():
    return len(os.listdir("/dev/fd"))

before = fd_count()
raised = False
try:
    with brain.brain_lock(identities):
        pass
except OSError:
    raised = True
after_fail = fd_count()

print("RAISED:%s" % ("yes" if raised else "no"))
print("FD_LEAK:%s" % ("no" if after_fail <= before else "yes"))

fcntl.flock = real_flock
with brain.brain_lock(identities):
    print("SUBSEQUENT_LOCK_OK:yes")
PY
)"
check "brain_lock: a failing flock() still raises to the caller" "RAISED:yes" "$out"
check "brain_lock: the fd is closed (not leaked) when flock() fails after os.open() succeeds" \
    "FD_LEAK:no" "$out"
check "brain_lock: still usable after a prior failed attempt (no corrupted state left behind)" \
    "SUBSEQUENT_LOCK_OK:yes" "$out"
rm -rf "$BA1C"

# ------------------------------------------------------------------------
# (2) concurrent stress: N parallel mint() OS processes x M parallel
# recall() OS processes against ONE shared fixture brain -- deterministic
# slugs and disjoint mint targets so a lost update is unambiguous; K seed
# notes with outgoing wikilinks so the concurrent recalls all exercise the
# real link-bump read-modify-write path under contention. After every
# worker process exits: links.json must parse as valid JSON (no torn
# write) and every expected key/fires count must be exactly right (no
# lost update).
# ------------------------------------------------------------------------
BA2="$(mktemp -d)"
BA2_ROOT="$BA2/repo"
mkdir -p "$BA2_ROOT"

setup_rc=0
python3 - "$BA2_ROOT" "$BA_SCRIPTS" <<'PY' || setup_rc=$?
import sys, os
root, scripts = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import brain

identities = os.path.join(root, ".claude/identities")
for i in range(4):
    brain.mint(identities, "dev", "seed-%d" % i, root,
               "Seed note %d.\n\nSee: [[seed-target-%d]]\n" % (i, i),
               tags="atomic", paths="atomic/**", source="ast-004-fixture")
PY
check_rc "atomic stress fixture: seed mint setup succeeded" 0 "$setup_rc"

MINT_WORKER="$BA2/mint_worker.py"
cat > "$MINT_WORKER" <<'PY'
import sys, os
identities, root, slug = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.environ["BA_SCRIPTS"])
import brain
brain.mint(identities, "dev", slug, root,
           "New note %s.\n\nSee: [[target-%s]]\n" % (slug, slug),
           tags="fresh", paths="fresh/**", source="ast-004-fixture")
PY

RECALL_WORKER="$BA2/recall_worker.py"
cat > "$RECALL_WORKER" <<'PY'
import sys, os
identities, root = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.environ["BA_SCRIPTS"])
import brain
brain.recall(identities, "dev", root, paths="atomic/foo.sh", keywords="")
PY

driver_out="$(BA_SCRIPTS="$BA_SCRIPTS" python3 - "$BA2_ROOT" "$MINT_WORKER" "$RECALL_WORKER" <<'PY'
import sys, os, subprocess, json

root, mint_worker, recall_worker = sys.argv[1], sys.argv[2], sys.argv[3]
identities = os.path.join(root, ".claude/identities")
n_mint = 8
n_recall = 8

procs = []
for i in range(n_mint):
    procs.append(subprocess.Popen([sys.executable, mint_worker, identities, root, "new-%d" % i]))
for _i in range(n_recall):
    procs.append(subprocess.Popen([sys.executable, recall_worker, identities, root]))

rcs = [p.wait() for p in procs]
print("WORKER_RCS:%s" % ",".join(str(r) for r in rcs))

links_path = os.path.join(identities, "dev", "brain", "links.json")
try:
    with open(links_path, encoding="utf-8") as f:
        links = json.load(f)
    print("LINKS_JSON_VALID:yes")
except (OSError, ValueError):
    print("LINKS_JSON_VALID:no")
    links = {}

seed_ok = all(
    links.get("seed-%d->seed-target-%d" % (i, i), {}).get("fires") == n_recall
    for i in range(4)
)
print("SEED_FIRES_EXACT:%s" % ("yes" if seed_ok else "no"))

mint_ok = all("new-%d->target-new-%d" % (i, i) in links for i in range(n_mint))
print("MINT_KEYS_SURVIVED:%s" % ("yes" if mint_ok else "no"))

expected_count = 4 + n_mint
print("LINK_COUNT_EXACT:%s" % ("yes" if len(links) == expected_count else "no (%d)" % len(links)))
PY
)"
check "atomic stress: all worker processes exited cleanly" \
    "WORKER_RCS:0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0" "$driver_out"
check "atomic stress: links.json parses as valid JSON after concurrent writers (no torn write)" \
    "LINKS_JSON_VALID:yes" "$driver_out"
check "atomic stress: every seed link fired exactly once per concurrent recall (no lost update)" \
    "SEED_FIRES_EXACT:yes" "$driver_out"
check "atomic stress: every concurrent mint formed link key survived (no lost update)" \
    "MINT_KEYS_SURVIVED:yes" "$driver_out"
check "atomic stress: total link count matches seed+mint exactly (no duplicate/dropped keys)" \
    "LINK_COUNT_EXACT:yes" "$driver_out"

rm -rf "$BA2"

# ------------------------------------------------------------------------
# (3) cmd_prune --apply RMW (review r1 finding 1): prune's load_links ->
# candidate-compute -> save_links must be ONE critical section, or a
# concurrent mint() forming a brand-new link key between prune's read and
# its write gets silently erased by prune's stale in-memory snapshot when
# it saves.
#
# Raw process-launch timing is too tight for a 1-vs-1 race to interleave
# reliably by luck alone (confirmed empirically: mint routinely finishes
# before prune even starts its read). So the worker forces the interleave
# with a marker-file barrier instead of hoping the OS scheduler cooperates:
# prune_worker writes a marker right after its load_links() call returns,
# then sleeps 1s before proceeding; mint_worker polls for that marker
# before it starts, guaranteeing prune has already taken its snapshot when
# mint runs and completes. Under the FIX, load_links() executes inside the
# flock, so the sleep just holds the lock 1s longer -- mint blocks on
# acquiring the same lock and correctly observes prune's already-applied
# removal once it gets in. Without the fix, this ordering deterministically
# reproduces the clobber.
# ------------------------------------------------------------------------
BA3="$(mktemp -d)"
BA3_ROOT="$BA3/repo"
mkdir -p "$BA3_ROOT"

setup_rc=0
python3 - "$BA3_ROOT" "$BA_SCRIPTS" <<'PY' || setup_rc=$?
import sys, os
root, scripts = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import brain

identities = os.path.join(root, ".claude/identities")
brain.mint(identities, "dev", "prune-src", root,
           "Links to a target that never gets minted.\n\nSee: [[missing-target]]\n",
           tags="prunebait", paths="prunebait/**", source="ast-004-fixture")
# an EXISTING anchor note, so the concurrently-minted link (below) targets a
# real note and is never itself a "target missing" prune candidate -- the
# only thing under test here is whether prune's OWN stale snapshot can drop
# a key it never had a chance to see, not whether the new key is separately
# eligible for removal.
brain.mint(identities, "dev", "anchor-note", root, "Existing anchor target.\n",
           tags="prunebait", paths="prunebait/**", source="ast-004-fixture")
PY
check_rc "prune-RMW fixture: seed mint setup succeeded" 0 "$setup_rc"

PRUNE_WORKER="$BA3/prune_worker.py"
cat > "$PRUNE_WORKER" <<'PY'
import sys, os, time
root, marker = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.environ["BA_SCRIPTS"])
import brain
_real_load_links = brain.load_links
def _slow_load_links(identities, role):
    result = _real_load_links(identities, role)
    open(marker, "w", encoding="utf-8").write("ready\n")
    time.sleep(1.0)
    return result
brain.load_links = _slow_load_links
brain.main([root, "prune", "dev", "--apply"])
PY

MINT2_WORKER="$BA3/mint2_worker.py"
cat > "$MINT2_WORKER" <<'PY'
import sys, os, time
identities, root, marker = sys.argv[1], sys.argv[2], sys.argv[3]
deadline = time.time() + 5.0
while not os.path.isfile(marker):
    if time.time() > deadline:
        sys.exit("timed out waiting for the prune worker marker")
    time.sleep(0.02)
sys.path.insert(0, os.environ["BA_SCRIPTS"])
import brain
brain.mint(identities, "dev", "concurrent-note", root,
           "Minted at the same time prune runs.\n\nSee: [[anchor-note]]\n",
           tags="fresh", paths="fresh/**", source="ast-004-fixture")
PY

driver_out="$(BA_SCRIPTS="$BA_SCRIPTS" python3 - "$BA3_ROOT" "$PRUNE_WORKER" "$MINT2_WORKER" "$BA3/marker" <<'PY'
import sys, os, subprocess, json

root, prune_worker, mint_worker, marker = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
identities = os.path.join(root, ".claude/identities")

p1 = subprocess.Popen([sys.executable, prune_worker, root, marker], stdout=subprocess.DEVNULL)
p2 = subprocess.Popen([sys.executable, mint_worker, identities, root, marker])
rcs = [p1.wait(), p2.wait()]
print("WORKER_RCS:%s" % ",".join(str(r) for r in rcs))

links_path = os.path.join(identities, "dev", "brain", "links.json")
try:
    with open(links_path, encoding="utf-8") as f:
        links = json.load(f)
    print("LINKS_JSON_VALID:yes")
except (OSError, ValueError):
    print("LINKS_JSON_VALID:no")
    links = {}

print("PRUNED_KEY_GONE:%s" % ("yes" if "prune-src->missing-target" not in links else "no"))
print("CONCURRENT_KEY_SURVIVED:%s" % ("yes" if "concurrent-note->anchor-note" in links else "no"))
print("LINK_COUNT_EXACT:%s" % ("yes" if len(links) == 1 else "no (%d)" % len(links)))
PY
)"
check "prune-RMW: both worker processes exited cleanly" "WORKER_RCS:0,0" "$driver_out"
check "prune-RMW: links.json parses as valid JSON after the race (no torn write)" \
    "LINKS_JSON_VALID:yes" "$driver_out"
check "prune-RMW: the prune candidate was removed" "PRUNED_KEY_GONE:yes" "$driver_out"
check "prune-RMW: the concurrently-minted link key survived (not clobbered by prune's stale snapshot)" \
    "CONCURRENT_KEY_SURVIVED:yes" "$driver_out"
check "prune-RMW: final link count is exactly the surviving concurrent key (no lost update either way)" \
    "LINK_COUNT_EXACT:yes" "$driver_out"

rm -rf "$BA3"

# ------------------------------------------------------------------------
# (4) cmd_graduate RMW (review r1 finding 2): graduate's read-parse-mutate-
# write must be ONE critical section, or a concurrent mint() of the SAME
# slug that lands between graduate's read and its write gets its strength
# bump silently reverted when graduate's stale copy is written back
# (graduate never re-reads before writing, so a stale read stays stale).
#
# Same marker-file barrier as test (3), for the same reason (raw timing
# is not reliable for a 1-vs-1 race): graduate_worker signals a marker
# right after its parse_note() read returns, then sleeps 1s; mint_worker
# waits for the marker before it starts. Deterministic invariant, order
# forced by construction: after a first mint (strength 1), a concurrent
# second mint() (bumps to strength 2) that is guaranteed to run and finish
# WHILE graduate holds its stale read, then graduate writes last. Under
# the FIX, graduate's read executes inside the flock, so the sleep holds
# the lock and mint blocks until graduate's full cycle (including its
# write) completes -- mint's own read-modify-write then correctly starts
# from graduate's already-applied state. Without the fix, this ordering
# deterministically reverts mint's strength bump.
# ------------------------------------------------------------------------
BA4="$(mktemp -d)"
BA4_ROOT="$BA4/repo"
mkdir -p "$BA4_ROOT"

setup_rc=0
python3 - "$BA4_ROOT" "$BA_SCRIPTS" <<'PY' || setup_rc=$?
import sys, os
root, scripts = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import brain

identities = os.path.join(root, ".claude/identities")
brain.mint(identities, "dev", "grad-note", root, "First mint.\n",
           tags="gradbait", paths="gradbait/**", source="ast-004-fixture")
PY
check_rc "graduate-RMW fixture: first mint setup succeeded" 0 "$setup_rc"

GRADUATE_WORKER="$BA4/graduate_worker.py"
cat > "$GRADUATE_WORKER" <<'PY'
import sys, os, time
root, marker = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.environ["BA_SCRIPTS"])
import brain
_real_parse_note = brain.parse_note
def _slow_parse_note(text):
    result = _real_parse_note(text)
    open(marker, "w", encoding="utf-8").write("ready\n")
    time.sleep(1.0)
    return result
brain.parse_note = _slow_parse_note
brain.main([root, "graduate", "dev", "grad-note"])
PY

MINT3_WORKER="$BA4/mint3_worker.py"
cat > "$MINT3_WORKER" <<'PY'
import sys, os, time
identities, root, marker = sys.argv[1], sys.argv[2], sys.argv[3]
deadline = time.time() + 5.0
while not os.path.isfile(marker):
    if time.time() > deadline:
        sys.exit("timed out waiting for the graduate worker marker")
    time.sleep(0.02)
sys.path.insert(0, os.environ["BA_SCRIPTS"])
import brain
brain.mint(identities, "dev", "grad-note", root, "Second mint, same slug.\n",
           tags="gradbait", paths="gradbait/**", source="ast-004-fixture")
PY

driver_out="$(BA_SCRIPTS="$BA_SCRIPTS" python3 - "$BA4_ROOT" "$GRADUATE_WORKER" "$MINT3_WORKER" "$BA4/marker" <<'PY'
import sys, os, subprocess

root, graduate_worker, mint_worker, marker = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
identities = os.path.join(root, ".claude/identities")

p1 = subprocess.Popen([sys.executable, graduate_worker, root, marker], stdout=subprocess.DEVNULL)
p2 = subprocess.Popen([sys.executable, mint_worker, identities, root, marker])
rcs = [p1.wait(), p2.wait()]
print("WORKER_RCS:%s" % ",".join(str(r) for r in rcs))

note_path = os.path.join(identities, "dev", "brain", "notes", "grad-note.md")
sys.path.insert(0, os.environ["BA_SCRIPTS"])
import brain
fm, _body = brain.parse_note(open(note_path, encoding="utf-8").read())
print("FINAL_STRENGTH:%s" % fm.get("strength"))
PY
)"
check "graduate-RMW: both worker processes exited cleanly" "WORKER_RCS:0,0" "$driver_out"
check "graduate-RMW: concurrent mint strength bump survived graduate's RMW (not reverted by a stale write)" \
    "FINAL_STRENGTH:2" "$driver_out"

rm -rf "$BA4"
