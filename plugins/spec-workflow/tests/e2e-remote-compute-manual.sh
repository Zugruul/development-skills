#!/usr/bin/env bash
# e2e-remote-compute-manual.sh — MANUAL end-to-end for the remote-compute
# skill against a REAL machine + real ComfyUI. Deliberately NOT registered in
# run-tests.sh's SECTIONS (the gate stays hermetic — this touches the network
# and needs a human for ssh-copy-id / host-key ack). Pattern follows
# e0-smoke-manual.sh: run by a human (or an agent with the human present).
#
# Prerequisites on the remote machine (see `remote-compute.py setup-sheet`):
#   - sshd reachable on :22, key auth possible (script stops and tells you
#     the exact ssh-copy-id line otherwise)
#   - ComfyUI running bound to 127.0.0.1 (NEVER --listen 0.0.0.0)
#   - an API-format workflow exported to $RC_WORKFLOW (Dev mode -> Save (API))
#
# Usage:
#   RC_TARGET=user@host RC_NICK=gpubox \
#   RC_WORKFLOW='~/comfy-demos/txt2img_api.json' [RC_PORT=8188] \
#   [RC_PROMPT='a rubber duck wearing a top hat'] \
#   bash plugins/spec-workflow/tests/e2e-remote-compute-manual.sh
# shellcheck disable=SC2088  # quoted tildes are payloads for the REMOTE shell (bash -lc expands them there), never the local one
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="$(dirname "$HERE")/scripts/remote-compute.py"

: "${RC_NICK:?set RC_NICK (nickname for the machine, e.g. gpubox)}"
RC_PORT="${RC_PORT:-8188}"
RC_PROMPT="${RC_PROMPT:-a rubber duck wearing a top hat, studio lighting}"
JOB_ID="e2e$(date +%s)"

step() { printf '\n== %s ==\n' "$*"; }

step "1/7 register (converges; may stop for ssh-copy-id or host-key ack)"
if [[ -n "${RC_TARGET:-}" ]]; then
    python3 "$RC" register "$RC_NICK" "$RC_TARGET" --accept-hostkey || {
        rc=$?
        echo "register stopped (exit $rc) — follow the printed instruction, then re-run this script"
        exit "$rc"
    }
else
    python3 "$RC" register "$RC_NICK" --accept-hostkey || exit $?
fi

step "2/7 probe (live capabilities)"
python3 "$RC" probe "$RC_NICK" || exit 1

step "3/7 ComfyUI reachable on the REMOTE loopback (never LAN)"
python3 "$RC" exec "$RC_NICK" -- "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${RC_PORT}/system_stats" \
    | grep -q 200 || { echo "FAIL: ComfyUI not answering on remote 127.0.0.1:${RC_PORT}"; exit 1; }
echo "ok: ComfyUI answers on remote loopback :${RC_PORT}"

step "4/7 ship comfy-run.py + declare the demo job (pre-authored template only)"
: "${RC_WORKFLOW:?set RC_WORKFLOW (API-format workflow path on the remote)}"
SYNCDIR="$(mktemp -d)"; cp "$(dirname "$HERE")/scripts/remote-capabilities/comfyui/comfy-run.py" "$SYNCDIR/"
python3 "$RC" add-job "$RC_NICK" comfy-txt2img \
    --workdir "~/.remote-compute/tools" \
    --cmd "python3 ~/.remote-compute/tools/comfy-run.py --workflow ${RC_WORKFLOW} --port ${RC_PORT} --prompt {prompt}" \
    --description "txt2img via the pre-authored API-format workflow ${RC_WORKFLOW}" \
    --param "prompt:[A-Za-z0-9 ,._-]+" || exit 1

step "5/7 run the declared job (detached; state on files)"
python3 "$RC" run "$RC_NICK" comfy-txt2img --inputs "$SYNCDIR" \
    --param "prompt=${RC_PROMPT}" --job-id "$JOB_ID" || exit 1
rm -rf "$SYNCDIR"

step "6/7 poll to completion"
for _ in $(seq 1 60); do
    out="$(python3 "$RC" job-status "$JOB_ID")"
    echo "  $out"
    case "$out" in *completed*|*failed*) break ;; esac
    sleep 5
done
python3 "$RC" job-logs "$JOB_ID"

step "7/7 pull artifacts"
python3 "$RC" job-pull "$JOB_ID" --dest "./compute-artifacts/$JOB_ID"
echo "DONE — artifacts (if any) under ./compute-artifacts/$JOB_ID (gitignored territory: do not commit)"
