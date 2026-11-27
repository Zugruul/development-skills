#!/usr/bin/env bash
# claude-review.sh [--label <name>] [--model <slug>] <diff-text-file> --
# invokes claude to review a diff and renders its findings under a label,
# "External review — Claude" by default (CDX-054, mirrors PRV-002's
# peer-review.sh for the codex backend). Pure/testable: given a diff-text
# file, embeds it in a prompt and shells out to `claude -p --output-format
# json --json-schema <schema> --permission-mode plan`. No flag or code path
# here ever weakens --permission-mode away from "plan" (the read-only
# equivalent of codex's --sandbox read-only; §9 invariant: a peer review
# NEVER writes).
#
# --json-schema takes the schema's INLINE JSON content as its argument
# value, not a file path (unlike codex's --output-schema <file>) -- the
# schema file is read and its contents passed as a string argument.
#
# --output-format json wraps the response in a larger envelope (session
# metadata, cost, usage, ...); the schema-conforming findings payload is
# nested at .structured_output, not the bare top-level JSON the way codex's
# --output-schema stdout is.
#
# --model <slug>: passes --model <slug> to claude, selecting which model
# reviews the diff. Manual verification found this reliably selects the
# requested model when given a FULL model id (e.g. claude-opus-4-8); a bare
# alias (e.g. "haiku") was observed to silently fall back to a different
# model instead. Callers must pass a full model id (list-claude-models.sh's
# catalog is full ids only). Omitted -> no --model flag, claude uses its
# own default. --permission-mode plan is always the first flag added,
# before any model selection, so --model has no way to influence it.
#
# The rendered label defaults to "External review — Claude" and can be
# overridden with --label <name> or the CLAUDE_REVIEW_LABEL env var
# (--label wins if both are given) -- same override pattern PRV-002
# established for peer-review.sh's PEER_REVIEW_LABEL, kept as its own env
# var here since PEER_REVIEW_LABEL is documented as the codex path's
# override and reusing it would force both providers to share one label.
#
# On success: parses claude's .structured_output against the findings
# schema. Valid -> rendered findings table. Invalid/missing/non-conforming
# -> raw stdout verbatim plus a parse-failure note, still exit 0 (a review
# happened, just unstructured).
# On failure -- claude exiting nonzero (auth/invocation failure), OR an
# is_error:true envelope even if the process happened to exit 0 -- claude's
# stderr and, when present, the envelope's own "result" explanation (the
# only place an API-level error like "model not found" surfaces; real
# stderr can be empty in that case) are surfaced verbatim, this script
# exits nonzero, claude's stdout is never parsed as findings, and no
# credential prompt is ever shown.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$HERE/../schema/peer-review-findings.json"

usage() {
    echo "usage: claude-review.sh [--label <name>] [--model <slug>] <diff-text-file>" >&2
}

LABEL="${CLAUDE_REVIEW_LABEL:-External review — Claude}"
MODEL=""
DIFF_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)
            [[ $# -ge 2 ]] || { echo "ERROR: --label requires a <name> argument" >&2; usage; exit 2; }
            LABEL="$2"
            shift 2
            ;;
        --model)
            [[ $# -ge 2 && "$2" != --* ]] || { echo "ERROR: --model requires a <slug> argument" >&2; usage; exit 2; }
            MODEL="$2"
            shift 2
            ;;
        *)
            if [[ -n "$DIFF_FILE" ]]; then
                usage
                exit 2
            fi
            DIFF_FILE="$1"
            shift
            ;;
    esac
done

if [[ -z "$DIFF_FILE" ]]; then
    usage
    exit 2
fi

if [[ ! -f "$DIFF_FILE" ]]; then
    echo "ERROR: diff file not found: $DIFF_FILE" >&2
    exit 2
fi

if [[ ! -f "$SCHEMA" ]]; then
    echo "ERROR: findings schema not found: $SCHEMA" >&2
    exit 2
fi

if ! command -v claude >/dev/null 2>&1; then
    {
        echo "ERROR: claude not found on PATH."
        echo "Install the Claude Code CLI (https://claude.com/claude-code) and ensure it is on PATH, then retry."
    } >&2
    exit 2
fi

diff_text="$(cat "$DIFF_FILE")"
schema_json="$(cat "$SCHEMA")"

prompt="You are reviewing the following diff as an independent, external code
reviewer. Report concrete, actionable findings only -- do not restate what
the diff does. For each finding, identify the file, the line (or null if the
finding is file-level, not line-anchored), a severity of info, warn, or
error, a one-sentence summary, and the concrete failure scenario it would
cause. Also give an overall one-sentence verdict.

--- BEGIN DIFF ---
$diff_text
--- END DIFF ---"

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "$stdout_file" "$stderr_file"' EXIT

# --permission-mode plan is non-negotiable and hardcoded: no argument or
# environment variable accepted by this script can change it (mirrors
# peer-review.sh's --sandbox read-only, §6.2). It is always the first flag
# added, before any model selection, so --model has no way to influence it.
claude_cmd=(claude -p --output-format json --json-schema "$schema_json" --permission-mode plan)
if [[ -n "$MODEL" ]]; then
    claude_cmd+=(--model "$MODEL")
fi
claude_cmd+=("$prompt")

"${claude_cmd[@]}" >"$stdout_file" 2>"$stderr_file"
claude_rc=$?

claude_stdout="$(cat "$stdout_file")"

# is_error:true inside the JSON envelope is a second failure signal
# independent of the process exit code (observed to always correlate with a
# nonzero exit in manual testing, but checked separately anyway -- an
# API-level error must never be silently treated as a successful review).
envelope_is_error="$(printf '%s' "$claude_stdout" | python3 -c '
import json
import sys
try:
    data = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(0)
if isinstance(data, dict) and data.get("is_error") is True:
    print("true")
' 2>/dev/null || true)"

if [[ $claude_rc -ne 0 || "$envelope_is_error" == "true" ]]; then
    if [[ $claude_rc -eq 0 ]]; then
        claude_rc=1
    fi
    echo "ERROR: claude exited nonzero ($claude_rc)." >&2
    stderr_text="$(cat "$stderr_file")"
    if [[ -n "$stderr_text" ]]; then
        printf '%s\n' "$stderr_text" >&2
    fi
    # On an API-level failure (e.g. an unrecognized --model id) claude
    # emits its JSON envelope on stdout with the explanation in .result
    # rather than writing anything to stderr at all -- surface that
    # verbatim too so the failure reason is never silently dropped.
    envelope_error="$(printf '%s' "$claude_stdout" | python3 -c '
import json
import sys
try:
    data = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(0)
if isinstance(data, dict) and isinstance(data.get("result"), str):
    print(data["result"])
' 2>/dev/null || true)"
    if [[ -n "$envelope_error" ]]; then
        printf '%s\n' "$envelope_error" >&2
    fi
    exit "$claude_rc"
fi

rendered="$(printf '%s' "$claude_stdout" | CLAUDE_REVIEW_RENDER_LABEL="$LABEL" python3 -c '
import json
import os
import sys

label = os.environ["CLAUDE_REVIEW_RENDER_LABEL"]
raw = sys.stdin.read()
try:
    envelope = json.loads(raw)
except ValueError:
    sys.exit(1)

if not isinstance(envelope, dict):
    sys.exit(1)
data = envelope.get("structured_output")
if not isinstance(data, dict):
    sys.exit(1)

findings = data.get("findings")
verdict = data.get("verdict")
if not isinstance(findings, list) or not isinstance(verdict, str):
    sys.exit(1)

required = ("file", "line", "severity", "summary", "failure_scenario")
for f in findings:
    if not isinstance(f, dict):
        sys.exit(1)
    for key in required:
        if key not in f:
            sys.exit(1)
    if not isinstance(f["file"], str):
        sys.exit(1)
    if f["line"] is not None and not isinstance(f["line"], int):
        sys.exit(1)
    if f["severity"] not in ("info", "warn", "error"):
        sys.exit(1)
    if not isinstance(f["summary"], str):
        sys.exit(1)
    if not isinstance(f["failure_scenario"], str):
        sys.exit(1)

print("## {}".format(label))
print()
if findings:
    for f in findings:
        line = f["line"] if f["line"] is not None else "-"
        print("- **{}:{}** [{}] {}".format(f["file"], line, f["severity"], f["summary"]))
        print("  Failure scenario: {}".format(f["failure_scenario"]))
else:
    print("No findings.")
print()
print("Verdict: {}".format(verdict))
'
)"
render_rc=$?

if [[ $render_rc -eq 0 ]]; then
    printf '%s\n' "$rendered"
else
    echo "## $LABEL"
    echo
    echo "(structured parsing failed -- claude's --json-schema output did not match"
    echo "the expected shape; showing raw claude output below verbatim)"
    echo
    printf '%s\n' "$claude_stdout"
fi

exit 0
