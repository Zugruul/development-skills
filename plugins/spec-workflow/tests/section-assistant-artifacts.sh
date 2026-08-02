#!/usr/bin/env bash
# section-assistant-artifacts.sh -- AST-068: /assistant/artifact streamed
# range endpoint (SPEC-ASSISTANT.md Sec12.2, issue #343). Sourced by
# run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant artifacts (AST-068: /assistant/artifact streamed range endpoint, SPEC-ASSISTANT.md Sec12.2) =="

AA_SCRIPTS="$PLUGIN/scripts"
NV="$AA_SCRIPTS/neural-view.py"

# aa_repo <dir> <main> -- same fixture shape section-assistant-tasks.sh's
# at_repo / section-assistant-engine.sh's ae_repo already use.
aa_repo() {
    local dir="$1" main="$2"
    mkdir -p "$dir/.claude"
    printf "%s\n" "# neural-network" >"$dir/.claude/.neural-network"
    printf "%s\n" \
        "schemaVersion: 2" \
        "assistant:" \
        "    version: 1" \
        "    enabled: true" \
        "    names: [$main]" \
        "    systemPrompt: |" \
        "        You are $main." \
        "    llm:" \
        "        provider: openai" \
        "        model: gpt-5.6-sol" \
        "    capabilities:" \
        "        codex:" \
        "            enabled: true" \
        "            provisioning:" \
        "                bin: codex" \
        >"$dir/.claude/project.yaml"
}

# aa_insert_task <root> <id> <state> <artifact_path-or-empty> -- writes a
# task row directly via tasks.py's own internal helpers, bypassing the
# worker/executor machinery entirely: this section tests the ARTIFACT
# RESOLUTION and streaming surface, not the queue state machine, which
# section-assistant-tasks.sh already covers end to end.
aa_insert_task() {
    local root="$1" task_id="$2" state="$3" artifact_path="$4"
    PYTHONPATH="$AA_SCRIPTS" ROOT="$root" TASK_ID="$task_id" STATE="$state" ARTIFACT_PATH="$artifact_path" python3 - <<'PY'
import os
from assistant import tasks

root = os.environ["ROOT"]
task_id = os.environ["TASK_ID"]
state = os.environ["STATE"]
artifact_path = os.environ["ARTIFACT_PATH"] or None

conn = tasks._open_conn(root)
try:
    tasks._insert(conn, task_id, "test-kind", {}, None)
    tasks._transition(conn, task_id, state, artifact_path=artifact_path)
finally:
    conn.close()
PY
}

# ------------------------------------------------------------------------
echo "-- unit: tasks.get_task -- single-row lookup by id, None for anything unusable --"
d0="$(mktemp -d)"
aa_insert_task "$d0" tid-a completed "clip.mp4"
out="$(PYTHONPATH="$AA_SCRIPTS" ROOT="$d0" python3 - <<'PY'
import os
from assistant import tasks
root = os.environ["ROOT"]
row = tasks.get_task(root, "tid-a")
print("STATE", row["state"] if row else None)
print("ARTIFACT_PATH", row["artifact_path"] if row else None)
print("MISSING_ROW", tasks.get_task(root, "no-such-id"))
print("MISSING_DB", tasks.get_task(root + "/does-not-exist", "tid-a"))
PY
)"
check "get_task: returns the right state" "STATE completed" "$out"
check "get_task: returns the right artifact_path" "ARTIFACT_PATH clip.mp4" "$out"
check "get_task: an unknown id returns None" "MISSING_ROW None" "$out"
check "get_task: a root with no tasks.sqlite returns None (never raises)" "MISSING_DB None" "$out"

# ------------------------------------------------------------------------
echo "-- unit: artifacts.resolve -- happy path returns the real file and its size --"
d="$(mktemp -d)"
aa_repo "$d" jarvis  # also gives this root's later engine._artifact tests a real, resolvable assistant
mkdir -p "$d/.claude/assistant/artifacts/videos"
printf '0123456789abcdef' >"$d/.claude/assistant/artifacts/videos/clip.mp4"
aa_insert_task "$d" tid-ok completed "videos/clip.mp4"
out="$(PYTHONPATH="$AA_SCRIPTS" ROOT="$d" python3 - <<'PY'
import os
from assistant import artifacts
root = os.environ["ROOT"]
path, size = artifacts.resolve(root, "tid-ok")
print("PATH_ENDS", path.endswith("videos/clip.mp4"))
print("SIZE", size)
PY
)"
check "resolve: happy path returns the correct file" "PATH_ENDS True" "$out"
check "resolve: happy path returns the correct size" "SIZE 16" "$out"

echo "-- unit: artifacts.resolve -- no such task raises ArtifactError --"
out="$(PYTHONPATH="$AA_SCRIPTS" ROOT="$d" python3 - <<'PY'
import os
from assistant import artifacts
root = os.environ["ROOT"]
try:
    artifacts.resolve(root, "no-such-id")
    print("RAISED", False)
except artifacts.ArtifactError:
    print("RAISED", True)
PY
)"
check "resolve: no such task raises ArtifactError" "RAISED True" "$out"

echo "-- unit: artifacts.resolve -- a task not yet completed raises ArtifactError --"
aa_insert_task "$d" tid-started started ""
out="$(PYTHONPATH="$AA_SCRIPTS" ROOT="$d" python3 - <<'PY'
import os
from assistant import artifacts
root = os.environ["ROOT"]
try:
    artifacts.resolve(root, "tid-started")
    print("RAISED", False)
except artifacts.ArtifactError:
    print("RAISED", True)
PY
)"
check "resolve: not-completed task raises ArtifactError" "RAISED True" "$out"

echo "-- unit: artifacts.resolve -- completed but no artifact recorded raises ArtifactError --"
aa_insert_task "$d" tid-noart completed ""
out="$(PYTHONPATH="$AA_SCRIPTS" ROOT="$d" python3 - <<'PY'
import os
from assistant import artifacts
root = os.environ["ROOT"]
try:
    artifacts.resolve(root, "tid-noart")
    print("RAISED", False)
except artifacts.ArtifactError:
    print("RAISED", True)
PY
)"
check "resolve: completed-but-no-artifact raises ArtifactError" "RAISED True" "$out"

# ------------------------------------------------------------------------
echo "-- adversarial: artifacts.resolve -- traversal defense (issue #343 review: treat this as a security surface) --"

echo "-- (1) a relative traversal escape is rejected --"
mkdir -p "$d/.claude/assistant/secret"
printf 'top secret' >"$d/.claude/assistant/secret/leak.txt"
aa_insert_task "$d" tid-trav completed "../secret/leak.txt"
out="$(PYTHONPATH="$AA_SCRIPTS" ROOT="$d" python3 - <<'PY'
import os
from assistant import artifacts
root = os.environ["ROOT"]
try:
    artifacts.resolve(root, "tid-trav")
    print("RAISED", False)
except artifacts.ArtifactError:
    print("RAISED", True)
PY
)"
check "resolve: a relative-traversal artifact_path is rejected" "RAISED True" "$out"

echo "-- (2) an absolute artifact_path is rejected BEFORE os.path.join can discard the root (a real Python footgun, not a hypothetical) --"
printf 'top secret' >"$d/absolute-secret.txt"
aa_insert_task "$d" tid-abs completed "$d/absolute-secret.txt"
out="$(PYTHONPATH="$AA_SCRIPTS" ROOT="$d" python3 - <<'PY'
import os
from assistant import artifacts
root = os.environ["ROOT"]
try:
    artifacts.resolve(root, "tid-abs")
    print("RAISED", False)
except artifacts.ArtifactError:
    print("RAISED", True)
PY
)"
check "resolve: an absolute artifact_path is rejected" "RAISED True" "$out"

echo "-- (3) a same-prefix SIBLING directory (artifacts-evil next to artifacts) is not treated as contained -- the exact bug a startswith() check WITHOUT the +os.sep guard would miss --"
mkdir -p "$d/.claude/assistant/artifacts-evil"
printf 'evil' >"$d/.claude/assistant/artifacts-evil/x.txt"
aa_insert_task "$d" tid-sibling completed "../artifacts-evil/x.txt"
out="$(PYTHONPATH="$AA_SCRIPTS" ROOT="$d" python3 - <<'PY'
import os
from assistant import artifacts
root = os.environ["ROOT"]
try:
    artifacts.resolve(root, "tid-sibling")
    print("RAISED", False)
except artifacts.ArtifactError:
    print("RAISED", True)
PY
)"
check "resolve: a same-prefix sibling directory escape is rejected" "RAISED True" "$out"

echo "-- (4) a symlink INSIDE the artifacts root pointing outside it is rejected -- a purely-lexical normpath check would miss this, realpath does not --"
mkdir -p "$d/.claude/assistant/artifacts/linked"
ln -s "$d/.claude/assistant/secret/leak.txt" "$d/.claude/assistant/artifacts/linked/escape.txt"
aa_insert_task "$d" tid-symlink completed "linked/escape.txt"
out="$(PYTHONPATH="$AA_SCRIPTS" ROOT="$d" python3 - <<'PY'
import os
from assistant import artifacts
root = os.environ["ROOT"]
try:
    artifacts.resolve(root, "tid-symlink")
    print("RAISED", False)
except artifacts.ArtifactError:
    print("RAISED", True)
PY
)"
check "resolve: a symlink escaping the artifacts root is rejected" "RAISED True" "$out"

echo "-- positive control: a legitimate nested subdirectory path is NOT rejected -- proves the containment check is not just always-reject --"
mkdir -p "$d/.claude/assistant/artifacts/deep/nested/dir"
printf 'legit' >"$d/.claude/assistant/artifacts/deep/nested/dir/ok.bin"
aa_insert_task "$d" tid-nested completed "deep/nested/dir/ok.bin"
out="$(PYTHONPATH="$AA_SCRIPTS" ROOT="$d" python3 - <<'PY'
import os
from assistant import artifacts
root = os.environ["ROOT"]
path, size = artifacts.resolve(root, "tid-nested")
print("PATH_ENDS", path.endswith("deep/nested/dir/ok.bin"))
print("SIZE", size)
PY
)"
check "resolve: a legitimate nested path resolves successfully (positive control)" "PATH_ENDS True" "$out"
check "resolve: positive control's size is correct" "SIZE 5" "$out"

# ------------------------------------------------------------------------
echo "-- unit: engine._artifact -- routing rejects a task id containing a slash before touching tasks.py or the filesystem --"
out="$(PYTHONPATH="$AA_SCRIPTS" ROOT="$d" python3 - <<'PY'
import os
from assistant import engine
root = os.environ["ROOT"]
state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
status, payload, ctype = e.handle("GET", "/assistant/artifact/../secret/leak.txt", query=None)
print("STATUS", status)
print("CTYPE", ctype)
print("HAS_ERROR", "error" in payload)
status2, payload2, _ = e.handle("GET", "/assistant/artifact/", query=None)
print("EMPTY_ID_STATUS", status2)
print("EMPTY_ID_HAS_ERROR", "error" in payload2)
PY
)"
check "engine._artifact: a slash-containing task id is rejected (404)" "STATUS 404" "$out"
check "engine._artifact: error responses are JSON" "CTYPE application/json" "$out"
check "engine._artifact: a slash-containing task id response carries an error" "HAS_ERROR True" "$out"
check "engine._artifact: an empty task id is rejected (404)" "EMPTY_ID_STATUS 404" "$out"
check "engine._artifact: an empty task id response carries an error" "EMPTY_ID_HAS_ERROR True" "$out"

echo "-- unit: engine._artifact -- unresolved assistant is the SAME generic 404, no extra signal --"
out="$(PYTHONPATH="$AA_SCRIPTS" python3 - <<'PY'
import tempfile
from assistant import engine
state_dir_u = tempfile.mkdtemp()
e = engine.AssistantEngine(lambda: [], state_dir_u)  # no candidates at all -> unresolvable
status, payload, ctype = e.handle("GET", "/assistant/artifact/tid-ok", query=None)
print("STATUS", status)
print("HAS_ERROR", "error" in payload)
PY
)"
check "engine._artifact: an unresolved assistant is a 404" "STATUS 404" "$out"
check "engine._artifact: an unresolved assistant carries an error" "HAS_ERROR True" "$out"

echo "-- integration: engine._artifact -- success returns (200, absolute path, octet-stream), never routes through _send as a literal body --"
out="$(PYTHONPATH="$AA_SCRIPTS" ROOT="$d" python3 - <<'PY'
import os
from assistant import engine
root = os.environ["ROOT"]
state_dir = os.path.join(root, ".claude", "assistant-engine-state-2")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
status, payload, ctype = e.handle("GET", "/assistant/artifact/tid-ok", query={"assistant": ["jarvis"]})
print("STATUS", status)
print("CTYPE", ctype)
print("PAYLOAD_IS_PATH", payload.endswith("videos/clip.mp4"))
print("PAYLOAD_IS_ABS", os.path.isabs(payload))
PY
)"
check "engine._artifact: success status is 200" "STATUS 200" "$out"
check "engine._artifact: success content-type is octet-stream (not JSON)" "CTYPE application/octet-stream" "$out"
check "engine._artifact: success payload is the resolved absolute file path" "PAYLOAD_IS_PATH True" "$out"
check "engine._artifact: success payload is absolute" "PAYLOAD_IS_ABS True" "$out"

# ------------------------------------------------------------------------
echo "-- static: local-state.manifest already covers the artifacts directory (Sec17 invariant 8: artifacts never committed to git) --"
# Sec17.8 check, same posture issue #447's BASE_CAPABILITIES coverage audit
# used: the manifest (SOURCE OF TRUTH, not the possibly-stale generated
# .gitignore) is queried directly via local-state.sh's own exec-mode.
manifest_ignore="$(bash "$AA_SCRIPTS/lib/local-state.sh" ignore)"
check "local-state.manifest: .claude/assistant/ (which now also holds artifacts) is an ignore entry" \
    ".claude/assistant/" "$manifest_ignore"
# a NEW subdirectory under an ALREADY directory-level-ignored path needs no
# new manifest line (unlike issue #447's BASE_CAPABILITIES entries, which
# each needed their own -- those were new TOP-LEVEL paths). Confirmed with a
# real git-ignore check in a throwaway repo whose .gitignore is freshly
# regenerated from the CURRENT manifest (not this repo's own committed
# .gitignore, which a live audit while building this task found IS
# currently behind the manifest by several entries -- a pre-existing gap,
# unrelated to and not touched by this task, flagged separately rather
# than silently fixed inline here).
d_gi="$(mktemp -d)"
(cd "$d_gi" && git init -q)
bash "$AA_SCRIPTS/lib/local-state.sh" ignore >"$d_gi/.gitignore"
mkdir -p "$d_gi/.claude/assistant/artifacts/videos"
touch "$d_gi/.claude/assistant/artifacts/videos/clip.mp4"
gi_code="$(cd "$d_gi" && git check-ignore -q .claude/assistant/artifacts/videos/clip.mp4; echo $?)"
check "gitignore (freshly regenerated from the current manifest): a nested artifacts file is ignored" "0" "$gi_code"
rm -rf "$d_gi"

# ------------------------------------------------------------------------
echo "-- integration: real server, video seek fixture -- streamed range serving over real HTTP (AST-068's own acceptance criterion) --"
_aa_root="$(mktemp -d)"
_aa_state="$(mktemp -d)"
_aa_scan_empty="$(mktemp -d)"
aa_repo "$_aa_root" jarvis

# a real fixture "video" with distinguishable byte content at every offset,
# built and inserted as a COMPLETED task BEFORE the server starts (no live
# worker race to coordinate with -- this section tests the artifact/
# streaming surface, not the queue).
mkdir -p "$_aa_root/.claude/assistant/artifacts"
printf '0123456789abcdef' >"$_aa_root/.claude/assistant/artifacts/clip.mp4"
aa_insert_task "$_aa_root" tid-http completed "clip.mp4"

export NEURAL_VIEW_STATE="$_aa_state" NEURAL_VIEW_SCAN="$_aa_scan_empty"
lifecycle_start "assistant artifact: neural-view starts" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_aa_root"'

_au="http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/artifact/tid-http"
hdrs="$(curl -s -D - -o /dev/null "$_au" | tr -d '\r')"
check "artifact route serves the file (200)" "200 OK" "$hdrs"
check "artifact route advertises Accept-Ranges: bytes" "Accept-Ranges: bytes" "$hdrs"
check "artifact route Content-Length matches the fixture size" "Content-Length: 16" "$hdrs"
body_full="$(curl -s "$_au")"
check "artifact route full body is the whole fixture" "0123456789abcdef" "$body_full"

hdrs="$(curl -s -D - -o /dev/null -H 'Range: bytes=4-7' "$_au" | tr -d '\r')"
check "artifact route answers a Range request with 206 (the video-seek path)" "206 Partial Content" "$hdrs"
check "artifact route 206 carries Content-Range" "Content-Range: bytes 4-7/16" "$hdrs"
body_range="$(curl -s -H 'Range: bytes=4-7' "$_au")"
check "artifact route 206 body is EXACTLY the requested slice" "4567" "$body_range"

hdrs="$(curl -s -D - -o /dev/null -H 'Range: bytes=-4' "$_au" | tr -d '\r')"
check "artifact route suffix range (last 4 bytes) answers 206" "206 Partial Content" "$hdrs"
body_suffix="$(curl -s -H 'Range: bytes=-4' "$_au")"
check "artifact route suffix range body is the last 4 bytes" "cdef" "$body_suffix"

hdrs="$(curl -s -D - -o /dev/null -H 'Range: bytes=999-' "$_au" | tr -d '\r')"
check "artifact route unsatisfiable range gets 416" "416" "$hdrs"
check "artifact route 416 carries Content-Range */size" "Content-Range: bytes */16" "$hdrs"

code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/artifact/no-such-task")"
check "artifact route: unknown task id is 404" "404" "$code"

# --path-as-is: curl otherwise collapses ../ CLIENT-SIDE before the request
# ever leaves the machine, which would test curl's own normalization, not
# this server's -- same convention section-neural-view-lifecycle.sh's own
# traversal probes already use.
code="$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/artifact/../secret/leak.txt")"
check "artifact route: a raw traversal-shaped path segment is never a 200" "404" "$code"

python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN

# ------------------------------------------------------------------------
echo "-- integration: real server, size cap -- an artifact past ASSISTANT_ARTIFACT_MAX_BYTES gets an honest 413, never hangs or truncates silently --"
_aa2_root="$(mktemp -d)"
_aa2_state="$(mktemp -d)"
_aa2_scan_empty="$(mktemp -d)"
aa_repo "$_aa2_root" jarvis
mkdir -p "$_aa2_root/.claude/assistant/artifacts"
printf '0123456789abcdef' >"$_aa2_root/.claude/assistant/artifacts/big.bin"
aa_insert_task "$_aa2_root" tid-big completed "big.bin"

export NEURAL_VIEW_STATE="$_aa2_state" NEURAL_VIEW_SCAN="$_aa2_scan_empty" ASSISTANT_ARTIFACT_MAX_BYTES=8
lifecycle_start "assistant artifact size cap: neural-view starts" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_aa2_root"'
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/artifact/tid-big")"
check "artifact route: an artifact past the size cap is 413" "413" "$code"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN ASSISTANT_ARTIFACT_MAX_BYTES

# ------------------------------------------------------------------------
echo "-- integration: real server, large artifact -- peak-RSS proof that a full download of a real multi-ten-MB fixture never loads the whole file into RAM (AST-068's own headline claim, SPEC-ASSISTANT.md Sec12.2) --"
# AST-068's REVIEW finding (issue #343 retro-review) was that every fixture
# above is 16 bytes, so replacing _send_file_streamed_ranged's chunked
# read()/write() loop with a single whole-file read() leaves the entire
# section green -- status codes, headers, and even byte-for-byte Range
# slices come out identical either way at 16 bytes. This is the ONE check
# in the section that can tell the two implementations apart: it needs a
# fixture large enough that "read it all before responding" is an
# observably different amount of memory than "read one 256KiB chunk at a
# time" (_ARTIFACT_CHUNK_SIZE, defined just above _send_file_streamed_ranged).
_aa3_root="$(mktemp -d)"
_aa3_state="$(mktemp -d)"
_aa3_scan_empty="$(mktemp -d)"
aa_repo "$_aa3_root" jarvis

# A real (non-sparse) fixture, generated at test time -- never committed as
# a binary fixture in the repo. Content is uniform (/dev/zero) rather than
# the distinguishable-per-offset bytes the Range-correctness tests above
# use: this test only cares about the BYTE COUNT the server has to move
# through memory, not which bytes they are (that's already covered). A
# real file (not one extended past its written length via seek, which some
# filesystems store as a sparse hole) still forces genuine page-cache-to-
# userspace copies on every read(), the same as it would for a real video.
_LARGE_MB=96
_expect_bytes=$((_LARGE_MB * 1048576))
mkdir -p "$_aa3_root/.claude/assistant/artifacts"
dd if=/dev/zero "of=$_aa3_root/.claude/assistant/artifacts/huge.bin" bs=1048576 "count=$_LARGE_MB" >/dev/null 2>&1
_dd_rc=$?
check_rc "large artifact: the ${_LARGE_MB}MB fixture is generated successfully (dd)" 0 "$_dd_rc"
aa_insert_task "$_aa3_root" tid-huge completed "huge.bin"

export NEURAL_VIEW_STATE="$_aa3_state" NEURAL_VIEW_SCAN="$_aa3_scan_empty"
lifecycle_start "large artifact: neural-view starts" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_aa3_root"'

_au3="http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/artifact/tid-huge"
_srv_pid="$(cat "$_aa3_state/pid" 2>/dev/null)"

# Sample PEAK RSS across the ENTIRE download, not a single before/after
# pair. A naive before/after comparison is flaky in the wrong direction: a
# single ~96MB allocation is large enough that CPython/glibc typically
# routes it through mmap and munmaps it again the instant the buffer is
# freed, so a sample taken strictly AFTER the download finishes can find
# the spike already gone -- even under the buggy whole-file-read()
# mutation. Polling in a tight loop for the whole request instead is safe
# either way: the buggy version holds the entire file in memory for as
# long as it takes to write the whole response (which takes real wall-clock
# time even over loopback), so the poll loop has that entire window to
# catch it, while the real streaming implementation never holds more than
# one _ARTIFACT_CHUNK_SIZE (256 KiB) chunk at a time, so its peak stays
# near baseline throughout.
_rss_kb() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' '; }
_base_rss="$(_rss_kb "$_srv_pid")"
[[ "$_base_rss" =~ ^[0-9]+$ ]] || _base_rss=0
# Round-1 review (dev-499): without this check the whole tripwire silently
# disarms if the instrument itself is broken -- an unreadable pidfile or a
# `ps` that can't be found makes every sample empty, so base=peak=0,
# delta=0, and the RSS check below reports a false PASS regardless of what
# the server actually did. Fail this LOUDLY and distinctly instead of
# letting a broken measurement masquerade as bounded memory.
if [ "$_base_rss" -gt 0 ]; then _base_ok_rc=0; else _base_ok_rc=1; fi
check_rc "large artifact: baseline RSS instrumentation reads a real positive number (pidfile+ps working, got ${_base_rss}KB)" 0 "$_base_ok_rc"
_peak_rss="$_base_rss"
_curl_meta="$(mktemp)"
curl -s --max-time 60 -o /dev/null -w '%{http_code} %{size_download}' "$_au3" >"$_curl_meta" &
_curl_pid=$!
_poll_deadline=$((SECONDS + 20))
while kill -0 "$_curl_pid" 2>/dev/null && [ "$SECONDS" -lt "$_poll_deadline" ]; do
    _cur="$(_rss_kb "$_srv_pid")"
    if [ -n "$_cur" ] && [ "$_cur" -gt "$_peak_rss" ]; then
        _peak_rss="$_cur"
    fi
done
wait "$_curl_pid" 2>/dev/null
read -r _http_code _dl_bytes <"$_curl_meta"
rm -f "$_curl_meta"
# Round-1 review (dev-499): without these two checks a FAILED download
# (404, connection reset, truncated body) also silently passes -- a short
# or empty response gives a small, comfortably-under-threshold RSS delta
# for the wrong reason (nothing was ever served), not because streaming
# worked. Pinning the exact byte count actually received closes that hole.
check "large artifact: the full download actually succeeded (HTTP 200)" "200" "$_http_code"
check "large artifact: the full download received every one of the ${_expect_bytes} fixture bytes" "$_expect_bytes" "$_dl_bytes"
_delta_kb=$((_peak_rss - _base_rss))
# 25% of the fixture size in KiB: comfortable headroom above a single
# 256KiB chunk plus interpreter/GC/ps-sampling noise, comfortably below the
# ~100% delta a whole-file read() shows (proven against the mutation
# below, before this test was committed).
_threshold_kb=$((_LARGE_MB * 1024 / 4))
if [ "$_delta_kb" -lt "$_threshold_kb" ]; then _rss_rc=0; else _rss_rc=1; fi
check_rc "large artifact: a full download's peak RSS delta (${_delta_kb}KB, base ${_base_rss}KB, peak ${_peak_rss}KB) stays under 25% of the ${_LARGE_MB}MB fixture (threshold ${_threshold_kb}KB) -- never loads the whole file into RAM" 0 "$_rss_rc"

python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_aa3_root" "$_aa3_state" "$_aa3_scan_empty"

rm -rf "$_aa_root" "$_aa_state" "$_aa_scan_empty" "$_aa2_root" "$_aa2_state" "$_aa2_scan_empty" "$d" "$d0"
