#!/usr/bin/env bash
# changelog.sh [--from <ref>] [--to <ref>] [--write <file>] — generate a Markdown
# changelog section from local git history, grouped by conventional-commit type
# prefix. Pure `git log` over local history: no network calls, no `gh`.
#   --from <ref>   defaults to the most recent tag matching spec-workflow--v*
#                   (git describe --tags --match 'spec-workflow--v*' --abbrev=0),
#                   falling back to the repo's first commit if none exists.
#   --to <ref>     defaults to HEAD.
#   --write <file> prepend the generated section to the top of <file> instead of
#                   printing to stdout (creating it with a "# Changelog" H1 first
#                   if it doesn't exist yet).
set -uo pipefail

usage() { echo "usage: changelog.sh [--from <ref>] [--to <ref>] [--write <file>]" >&2; exit 1; }

FROM=""
TO="HEAD"
WRITE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) [[ $# -ge 2 ]] || usage; FROM="$2"; shift 2 ;;
        --to) [[ $# -ge 2 ]] || usage; TO="$2"; shift 2 ;;
        --write) [[ $# -ge 2 ]] || usage; WRITE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$FROM" ]]; then
    FROM="$(git describe --tags --match 'spec-workflow--v*' --abbrev=0 "$TO" 2>/dev/null || true)"
    if [[ -z "$FROM" ]]; then
        FROM="$(git rev-list --max-parents=0 "$TO" 2>/dev/null | tail -1)"
    fi
fi

HEADING="## $FROM..$TO"
if [[ "$TO" == "HEAD" ]] && ! git describe --tags --exact-match HEAD >/dev/null 2>&1; then
    HEADING="## Unreleased"
fi

BUCKETDIR="$(mktemp -d)"
trap 'rm -rf "$BUCKETDIR"' EXIT

LOG="$(git log "$FROM..$TO" --pretty=format:'%h%x09%s' 2>/dev/null || true)"

while IFS=$'\t' read -r sha subject; do
    [[ -z "$sha" ]] && continue
    matched=0
    for t in feat fix refactor docs chore retro; do
        if [[ "$subject" =~ ^${t}(\([^\)]*\))?:[[:space:]]*(.*)$ ]]; then
            echo "- ${BASH_REMATCH[2]} ($sha)" >> "$BUCKETDIR/$t"
            matched=1
            break
        fi
    done
    if [[ $matched -eq 0 ]] && [[ "$subject" =~ ^tests?(\([^\)]*\))?:[[:space:]]*(.*)$ ]]; then
        echo "- ${BASH_REMATCH[2]} ($sha)" >> "$BUCKETDIR/test"
        matched=1
    fi
    if [[ $matched -eq 0 ]]; then
        echo "- $subject ($sha)" >> "$BUCKETDIR/other"
    fi
done <<<"$LOG"

BODY="$HEADING"
for pair in feat:Feat fix:Fix refactor:Refactor docs:Docs test:Test chore:Chore retro:Retro other:Other; do
    key="${pair%%:*}"
    label="${pair#*:}"
    f="$BUCKETDIR/$key"
    if [[ -s "$f" ]]; then
        BODY="$BODY"$'\n\n'"### $label"$'\n'"$(cat "$f")"
    fi
done

if [[ -n "$WRITE" ]]; then
    OUTF="$(mktemp)"
    printf '# Changelog\n\n' > "$OUTF"
    printf '%s\n' "$BODY" >> "$OUTF"
    if [[ -f "$WRITE" ]]; then
        REST="$(cat "$WRITE")"
        # Strip a pre-existing leading "# Changelog" H1 (plus any blank lines
        # right after it) so re-running --write against its own output stays
        # idempotent: the H1 stays exactly once, always at the top.
        if [[ "$(head -1 <<<"$REST")" == "# Changelog" ]]; then
            REST="$(tail -n +2 <<<"$REST")"
            while [[ -n "$REST" ]] && [[ -z "$(head -1 <<<"$REST")" ]]; do
                REST="$(tail -n +2 <<<"$REST")"
            done
        fi
        if [[ -n "$REST" ]]; then
            printf '\n' >> "$OUTF"
            printf '%s\n' "$REST" >> "$OUTF"
        fi
    fi
    mv "$OUTF" "$WRITE"
else
    printf '%s\n' "$BODY"
fi
