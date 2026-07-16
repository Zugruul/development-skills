#!/usr/bin/env bash
# peer-review.sh [--label <name>] [--model <slug>] <diff-text-file> --
# invokes codex to review a diff and renders its findings under a label,
# "External review — codex" by default (SPEC-PEER-REVIEW.md §6.2, §6.5,
# §6.6, §6.8). Pure/testable: given a diff-text file, embeds it in a prompt
# and shells out to `codex exec --sandbox read-only --output-schema
# <schema>`. No flag or code path here ever adds anything other than
# "read-only" to --sandbox (§6.2, §9 invariant: a peer review NEVER writes).
#
# --model <slug> (PRV-004, §6.11) passes -m <slug> to codex, selecting which
# model reviews the diff; omitted -> no -m flag, codex uses its own default.
# --sandbox read-only is always the first flag added, before any model
# selection is applied, so model choice has no way to touch it.
#
# The rendered label defaults to "External review — codex" and can be
# overridden with --label <name> or the PEER_REVIEW_LABEL env var (--label
# wins if both are given); this script has no notion of agent identities --
# it just accepts a caller-supplied string, keeping this plugin decoupled
# from spec-workflow's identity system (see docs/design/peer-E0.md).
#
# On success: parses codex's stdout against the findings schema. Valid ->
# rendered findings table. Invalid/malformed -> raw stdout verbatim plus a
# parse-failure note, still exit 0 (a review happened, just unstructured;
# known codex --output-schema rough edge, §6.6).
# On codex exiting nonzero (e.g. auth failure): codex's stderr is surfaced
# verbatim and this script exits nonzero; codex's stdout is never parsed and
# no credential prompt is ever shown (§6.8).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$HERE/../schema/peer-review-findings.json"

usage() {
    echo "usage: peer-review.sh [--label <name>] [--model <slug>] <diff-text-file>" >&2
}

LABEL="${PEER_REVIEW_LABEL:-External review — codex}"
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

if ! command -v codex >/dev/null 2>&1; then
    {
        echo "ERROR: codex not found on PATH."
        echo "Install the codex CLI (https://github.com/openai/codex) and ensure it is on PATH, then retry."
    } >&2
    exit 2
fi

diff_text="$(cat "$DIFF_FILE")"

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

# --sandbox read-only is non-negotiable and hardcoded: no argument or
# environment variable accepted by this script can change it (§6.2). It is
# always the first flag added, before any model selection, so -m/--model
# (PRV-004) has no way to influence it.
codex_cmd=(codex exec --sandbox read-only --output-schema "$SCHEMA")
if [[ -n "$MODEL" ]]; then
    codex_cmd+=(-m "$MODEL")
fi
codex_cmd+=("$prompt")

"${codex_cmd[@]}" >"$stdout_file" 2>"$stderr_file"
codex_rc=$?

if [[ $codex_rc -ne 0 ]]; then
    echo "ERROR: codex exited nonzero ($codex_rc). codex stderr follows verbatim:" >&2
    cat "$stderr_file" >&2
    exit "$codex_rc"
fi

codex_stdout="$(cat "$stdout_file")"

rendered="$(printf '%s' "$codex_stdout" | PEER_REVIEW_RENDER_LABEL="$LABEL" python3 -c '
import json
import os
import sys

label = os.environ["PEER_REVIEW_RENDER_LABEL"]
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except ValueError:
    sys.exit(1)

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
    echo "(structured parsing failed -- codex's --output-schema output did not match"
    echo "the expected shape; showing raw codex output below verbatim)"
    echo
    printf '%s\n' "$codex_stdout"
fi

exit 0
