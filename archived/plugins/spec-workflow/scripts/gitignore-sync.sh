#!/usr/bin/env bash
# gitignore-sync.sh — write the plugin's `ignore`-policy paths (from
# scripts/local-state.manifest, via lib/local-state.sh) into a target
# .gitignore as a managed block (SPEC-MEMORY.md §7.2/§7.2.1):
#
#   # >>> spec-workflow managed
#   <ignore paths, one per line, in manifest order>
#   # <<< spec-workflow managed
#
# Replaces ONLY the block's interior if the markers already exist; appends the
# block (with markers) if absent; NEVER touches any line outside the markers.
# Warns (path + matching rule) when a `track`-policy path is already ignored by
# some OTHER, non-managed rule in the target. `--dry-run` prints the unified
# diff without editing the target. Idempotent: a second run is a no-op.
#
# Usage: gitignore-sync.sh [--dry-run] [target]   (target defaults to .gitignore)
#
# bash 3.2-compatible (no bash-4-only constructs).
set -uo pipefail

GS_HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=plugins/spec-workflow/scripts/lib/local-state.sh
. "$GS_HERE/lib/local-state.sh"

GS_START="# >>> spec-workflow managed"
GS_END="# <<< spec-workflow managed"

gs_usage() {
    cat <<EOF
usage: gitignore-sync.sh [--dry-run] [target]
  Sync the spec-workflow managed block of ignore paths into <target>
  (default: .gitignore). --dry-run prints the diff without writing.
EOF
}

# _gs_rule_matches <rule> <path> — rc 0 if the gitignore <rule> would ignore
# <path>. Pragmatic subset of gitignore semantics: skips comments/blanks/
# negations; supports an anchored (slash-bearing) rule as an exact or
# ancestor-directory match, an unanchored rule as a match on any path
# component, and shell globs in either form.
_gs_rule_matches() {
    local rule="$1" p="$2"
    case "$rule" in ''|'#'*|'!'*) return 1 ;; esac
    rule="${rule%/}"; rule="${rule#/}"
    p="${p%/}"
    [ -n "$rule" ] || return 1
    case "$rule" in
        */*)
            [ "$p" = "$rule" ] && return 0
            # shellcheck disable=SC2254  # unquoted $rule is intentional: honor gitignore globs
            case "$p" in "$rule"/* | $rule | $rule/*) return 0 ;; esac
            ;;
        *)
            [ "$p" = "$rule" ] && return 0
            # shellcheck disable=SC2254  # unquoted $rule is intentional: honor gitignore globs
            case "$p" in "$rule"/* | */"$rule" | */"$rule"/* | $rule | $rule/* | */$rule | */$rule/*) return 0 ;; esac
            ;;
    esac
    return 1
}

gs_dry_run=0
gs_target=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) gs_dry_run=1 ;;
        -h|--help) gs_usage; exit 0 ;;
        -*) echo "gitignore-sync: unknown option: $1" >&2; gs_usage >&2; exit 2 ;;
        *)
            if [ -z "$gs_target" ]; then gs_target="$1"
            else echo "gitignore-sync: unexpected extra argument: $1" >&2; exit 2; fi
            ;;
    esac
    shift
done
[ -n "$gs_target" ] || gs_target=".gitignore"

gs_ignore="$(spec_workflow_local_state_paths ignore)" || {
    echo "gitignore-sync: cannot read ignore paths from manifest" >&2; exit 1; }
gs_track="$(spec_workflow_local_state_paths track)" || {
    echo "gitignore-sync: cannot read track paths from manifest" >&2; exit 1; }

# Fresh managed block (no trailing newline; added when composing the file).
gs_block="$GS_START
$gs_ignore
$GS_END"

# Own one private directory and remove only that directory on every handled
# exit. Explicit template honors TMPDIR on GNU and BSD mktemp alike.
gs_tmpdir=""
trap 'if [ -n "$gs_tmpdir" ] && ! rm -rf -- "$gs_tmpdir"; then
    echo "gitignore-sync: cannot remove owned temporary directory $gs_tmpdir" >&2
    exit 1
fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
gs_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gitignore-sync.XXXXXXXX")" || {
    echo "gitignore-sync: mktemp failed" >&2; exit 1; }
gs_tmp="$gs_tmpdir/rendered"
# Byte-oriented composition preserves even CRLF user rules and a final line
# without a newline. Malformed markers and unreadable/non-file targets are
# inspection errors, never an absent/current managed block.
if ! python3 - "$gs_target" "$gs_tmp" "$gs_tmpdir/nonmanaged" "$gs_block" <<'PY_RENDER'
import io
import os
from pathlib import Path
import sys

target, rendered, outside, block = sys.argv[1:]
try:
    if os.path.lexists(target) and not Path(target).is_file():
        raise ValueError("target is not a readable regular file")
    old = Path(target).read_bytes() if os.path.lexists(target) else b""
    # Git ignore records are LF-delimited; a bare CR is user data. Remove
    # exactly one supported terminator, never an arbitrary run of CR/LF.
    lines = io.BytesIO(old).readlines()
    def record_content(line):
        if line.endswith(b"\r\n"):
            return line[:-2]
        if line.endswith(b"\n"):
            return line[:-1]
        return line
    starts = [i for i, line in enumerate(lines) if record_content(line) == b"# >>> spec-workflow managed"]
    ends = [i for i, line in enumerate(lines) if record_content(line) == b"# <<< spec-workflow managed"]
    if starts or ends:
        if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
            raise ValueError("malformed managed markers; restore one complete start/end pair")
        before = b"".join(lines[:starts[0]])
        after = b"".join(lines[ends[0] + 1:])
    else:
        before, after = old, b""
    separator = b"\n" if before and not before.endswith(b"\n") else b""
    Path(rendered).write_bytes(before + separator + block.encode() + b"\n" + after)
    Path(outside).write_bytes(before + after)
except (OSError, ValueError) as exc:
    print(f"gitignore-sync: cannot inspect/render {target}: {exc}", file=sys.stderr)
    sys.exit(1)
PY_RENDER
then
    exit 1
fi
gs_nonmanaged="$(cat "$gs_tmpdir/nonmanaged")" || exit 1

# §7.2.1: warn (to stderr) for any track path already ignored by a non-managed
# rule — i.e. any line outside the markers.
while IFS= read -r gs_tp; do
    [ -n "$gs_tp" ] || continue
    while IFS= read -r gs_rule; do
        [ -n "$gs_rule" ] || continue
        if _gs_rule_matches "$gs_rule" "$gs_tp"; then
            printf 'gitignore-sync: WARNING: track path %s is ignored by non-managed rule %s\n' \
                "$gs_tp" "$gs_rule" >&2
            break
        fi
    done <<EOF
$gs_nonmanaged
EOF
done <<EOF
$gs_track
EOF

if [ "$gs_dry_run" -eq 1 ]; then
    gs_old="$gs_target"
    [ -e "$gs_old" ] || gs_old=/dev/null
    diff -u "$gs_old" "$gs_tmp"
    gs_rc=$?
    case "$gs_rc" in
        0|1) exit 0 ;;  # a diff is a successful inspection, not an I/O error
        *) echo "gitignore-sync: comparison failed for $gs_target (diff exit $gs_rc)" >&2; exit "$gs_rc" ;;
    esac
fi

mv "$gs_tmp" "$gs_target" || {
    echo "gitignore-sync: cannot publish $gs_target" >&2; exit 1; }
exit 0
