#!/usr/bin/env bash
# section-neural-view-rescan.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== neural-view rescan_once() (pure unit, no server) =="
NV="$PLUGIN/scripts/neural-view.py"
_rusb="$(mktemp -d)"          # scan base
_ru_a="$_rusb/repo-a"; mkdir -p "$_ru_a/.claude"
: >"$_ru_a/.claude/.neural-network"   # anchored at "boot"

RUOUT="$(python3 - "$NV" "$_rusb" "$_ru_a" <<'PY'
import importlib.util, sys
from pathlib import Path
spec_path, scanbase, repoa = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("neural_view", spec_path)
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)

args = ["--scan", scanbase]
boot = nv.discover_repos(args)
print("BOOT", [n for n, _ in boot])

# tick 1: nothing new yet -- added must be empty and new_repos IS boot (no rebuild)
new1, added1 = nv.rescan_once(boot, args)
print("TICK1_ADDED", [n for n, _ in added1])
print("TICK1_SAME_OBJECT", new1 is boot)

# anchor a second repo AFTER "boot"
repob = Path(scanbase) / "repo-b"
(repob / ".claude").mkdir(parents=True)
(repob / ".claude" / ".neural-network").write_text("")
new2, added2 = nv.rescan_once(new1, args)
print("TICK2_ADDED", [n for n, _ in added2])
print("TICK2_NAMES", [n for n, _ in new2])
print("TICK2_EXISTING_PRESERVED_FIRST", new2[0] == boot[0])

# remove the repo-a marker -- it must stay registered (removal is boot-only)
(Path(repoa) / ".claude" / ".neural-network").unlink()
new3, added3 = nv.rescan_once(new2, args)
print("TICK3_ADDED", added3)
print("TICK3_NAMES", sorted(n for n, _ in new3))

# re-running with an identical set again adds nothing (idempotent, no dup)
new4, added4 = nv.rescan_once(new3, args)
print("TICK4_ADDED", added4)
print("TICK4_LEN", len(new4))
PY
)"
check "boot discovers only repo-a" "BOOT ['repo-a']" "$RUOUT"
check "tick with no new repo adds nothing" "TICK1_ADDED []" "$RUOUT"
check "no-op tick returns the SAME list object (no needless rebuild)" "TICK1_SAME_OBJECT True" "$RUOUT"
check "newly-anchored repo-b is added" "TICK2_ADDED ['repo-b']" "$RUOUT"
check "new_repos lists both repos, repo-a (existing) first" "TICK2_NAMES ['repo-a', 'repo-b']" "$RUOUT"
check "existing entry identity/position preserved (appended, not resorted)" "TICK2_EXISTING_PRESERVED_FIRST True" "$RUOUT"
check "removing repo-a's marker after boot adds nothing new" "TICK3_ADDED []" "$RUOUT"
check "repo-a stays registered after its marker is removed (no mid-flight removal)" "TICK3_NAMES ['repo-a', 'repo-b']" "$RUOUT"
check "repeated tick over an unchanged set adds nothing (idempotent)" "TICK4_ADDED []" "$RUOUT"
check "repeated tick does not duplicate entries" "TICK4_LEN 2" "$RUOUT"
rm -rf "$_rusb"

echo "== neural-view rescan (live server, --rescan flag) =="
_rlscan="$(mktemp -d)"
_rlstate="$(mktemp -d)"
_rlrepoA="$_rlscan/live-alpha"
mkdir -p "$_rlrepoA/.claude"
: >"$_rlrepoA/.claude/.neural-network"

export NEURAL_VIEW_STATE="$_rlstate" NEURAL_VIEW_SCAN="$_rlscan"
lifecycle_start "neural-view starts with a short --rescan tick" NEURAL_VIEW_PORT 'python3 "$NV" start --rescan 1'
out="$(python3 "$NV" status)"; check "boot: repos=1 (only live-alpha anchored so far)" "repos=1" "$out"

# anchor a second repo AFTER boot -- must appear within a couple of rescan ticks
_rlrepoB="$_rlscan/live-beta"
mkdir -p "$_rlrepoB/.claude"
: >"$_rlrepoB/.claude/.neural-network"
for _ in $(seq 1 40); do
    out="$(python3 "$NV" status)"
    grep -qF "repos=2" <<<"$out" && break
    sleep 0.25
done
check "post-boot repo is picked up by the rescan thread within ~10s" "repos=2" "$out"
check "repos.json reflects the union after rescan" "live-beta" "$(cat "$_rlstate/repos.json")"
out="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/graph")"
check "graph repos list includes the post-boot repo" '"live-beta"' "$out"

# remove live-alpha's marker while the server is up -- must NOT be dropped mid-flight
rm -f "$_rlrepoA/.claude/.neural-network"
sleep 2
out="$(python3 "$NV" status)"
check "removing a marker after boot never shrinks the registered repo count" "repos=2" "$out"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_rlscan" "$_rlstate"

echo "== neural-view rescan disabled (--rescan 0 / NEURAL_VIEW_RESCAN=0) =="
_rdscan="$(mktemp -d)"
_rdstate="$(mktemp -d)"
_rdrepoA="$_rdscan/dis-alpha"
mkdir -p "$_rdrepoA/.claude"
: >"$_rdrepoA/.claude/.neural-network"

export NEURAL_VIEW_STATE="$_rdstate" NEURAL_VIEW_SCAN="$_rdscan"
lifecycle_start "neural-view starts with --rescan 0" NEURAL_VIEW_PORT 'python3 "$NV" start --rescan 0'
_rdrepoB="$_rdscan/dis-beta"
mkdir -p "$_rdrepoB/.claude"
: >"$_rdrepoB/.claude/.neural-network"
sleep 2
out="$(python3 "$NV" status)"
check "rescan 0 disables the background thread -- post-boot repo never appears" "repos=1" "$out"
check_absent "rescan 0: disabled repo is absent from repos.json" "dis-beta" "$(cat "$_rdstate/repos.json")"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_rdscan" "$_rdstate"
