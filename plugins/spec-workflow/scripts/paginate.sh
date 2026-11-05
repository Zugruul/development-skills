#!/usr/bin/env bash
# paginate.sh — shared pagination helpers for board.sh and seed-board.sh (SPEC 7.4).
# Source this file; it is not meant to be executed directly.
#
#   gh_project_items_json  project items, via a cursor-paginated `gh api graphql` query
#                          (hasNextPage proves exhaustion; nothing is re-read).
#   gh_issues_json         issue lists, via `gh issue list`, which has no cursor flag
#                          (count-based proof; see the comment on that function).
set -uo pipefail

PAGINATE_BASE_LIMIT="${PAGINATE_BASE_LIMIT:-400}"  # gh_issues_json only
PAGINATE_HARD_CAP="${PAGINATE_HARD_CAP:-51200}"  # worst-case backstop (items for project reads; --limit for issues), not a real ceiling

# gh_project_items_json <project-number> <owner> [--strict] -> full {"items":[...],"totalCount":N}
# JSON in the shape `gh project item-list --format json` produces, all pages.
#
# Reads through slim `gh api graphql` queries (project_items.py), not `gh project item-list`:
# gh requests fieldValues(first:100) on every item (~101 GraphQL points per 100 items); the
# slim query costs about 1 point per 100 items, plus ONE extra point per read for the
# field-name query below. repositoryOwner + ProjectV2Owner resolves user- and
# organization-owned projects in the same call, so there is no owner-type lookup ("@me"
# owners use the viewer instead). hasNextPage is the exhaustion proof: every page is read
# exactly once and nothing is re-fetched.
#
# Field names: fieldValueByName is case-sensitive but init-config.sh (and gh) accept field
# names case-insensitively, so the project's real Status/Priority/Estimate names are
# resolved first (project_items.py fields-query / resolve). A project with no Status field
# cannot yield statuses: strict reads fail closed, other reads warn and return items
# without a status (what gh project item-list did). Several Status fields differing only
# by case are ambiguous (init-config may have written either id): strict fails closed,
# other reads warn and use the exact-case "Status" field if there is one.
#
# Nothing is written to stdout until every page has been read: an error on page N (a
# rate limit, auth, a malformed page) returns nonzero with an empty stdout, never the
# earlier pages. Errors are GitHub's own (a RATE_LIMIT payload is reported as such, with
# the reset time from the response headers, also saved to $PAGINATE_RESET_FILE for
# _rate_limit_reset_human) -- not gh project's "unknown owner type" masking.
#
# A read that cannot progress ends with an error: hasNextPage with an empty page, or any
# cursor seen twice in one read (a cycle).
#
# Return codes: 0 ok; 1 the read failed (error on stderr, stdout empty); 3 (--strict only)
# the read is not a complete, consistent snapshot: WIP BLOCKED. --strict additionally
# validates the merged snapshot with `wip.py page` (item identities, totalCount == items).
#
# PAGINATE_HARD_CAP (items) is only a backstop: reaching it with hasNextPage still true
# means exhaustion is unproven -- warn on stderr (non-strict) or return 3 (strict).
PAGINATE_PAGE_SIZE="${PAGINATE_PAGE_SIZE:-100}"  # GraphQL connection maximum

# Reset time of THIS process tree's last rejected read (X-Ratelimit-Reset / Retry-After header).
# One private file per invocation, removed on exit: another run's (or account's) rejection is never
# reported. Callers that install their own EXIT trap should also remove "$PAGINATE_RESET_FILE".
if [[ -z "${PAGINATE_RESET_FILE:-}" ]]; then
    PAGINATE_RESET_FILE="$(mktemp "${TMPDIR:-/tmp}/sw-gh-reset.XXXXXX")" || PAGINATE_RESET_FILE=""
    # shellcheck disable=SC2064  # expand now: the path is fixed for this process
    [[ -n "$PAGINATE_RESET_FILE" ]] && trap "rm -f '$PAGINATE_RESET_FILE'" EXIT
fi

gh_project_items_json() {
    local dir rc
    dir="$(mktemp -d)" || return 1
    [[ -n "$PAGINATE_RESET_FILE" ]] && : >"$PAGINATE_RESET_FILE"
    _gh_project_items_read "$dir" "$@"; rc=$?
    rm -rf "$dir"
    return "$rc"
}

_gh_project_items_read() {
    local dir="$1" pn="$2" owner_arg="$3" strict="${4:-}"
    local here="${BASH_SOURCE[0]%/*}" tool query fquery errf raw rc nrc names cursor="" seen=" " pages=0
    local has_next count total=0 meta merged
    local -a owner_flags=(-f "owner=$owner_arg") qflags=()
    tool="$here/project_items.py"
    if [[ "$owner_arg" == "@me" ]]; then owner_flags=(); qflags=(--viewer); fi
    errf="$dir/err"

    # 1. real field names (one cheap query)
    fquery="$(python3 "$tool" fields-query "${qflags[@]+"${qflags[@]}"}")" || return 1
    raw="$(gh api graphql -i -f "query=$fquery" -F "number=$pn" "${owner_flags[@]+"${owner_flags[@]}"}" 2>"$errf")"; rc=$?
    names="$(python3 "$tool" resolve --rc "$rc" --err "$errf" --reset-file "$PAGINATE_RESET_FILE" \
        --owner "$owner_arg" --number "$pn" <<<"$raw")"; nrc=$?
    case "$nrc" in
        0) ;;
        4)  if [[ "$strict" == "--strict" ]]; then
                echo "WIP BLOCKED: board has no Status field; cannot read statuses" >&2
                return 3
            fi ;;
        5)  if [[ "$strict" == "--strict" ]]; then
                echo "WIP BLOCKED: board has an ambiguous Status field (several differing only by case)" >&2
                return 3
            fi ;;
        *) return 1 ;;
    esac
    query="$(python3 "$tool" query "${qflags[@]+"${qflags[@]}"}" --names "$names")" || return 1

    # 2. the items, one cursor page at a time
    while :; do
        local -a after=()
        [[ -n "$cursor" ]] && after=(-f "after=$cursor")
        raw="$(gh api graphql -i -f "query=$query" -F "number=$pn" -F "first=$PAGINATE_PAGE_SIZE" \
            "${owner_flags[@]+"${owner_flags[@]}"}" "${after[@]+"${after[@]}"}" 2>"$errf")"; rc=$?
        pages=$((pages + 1))
        python3 "$tool" page --rc "$rc" --err "$errf" --reset-file "$PAGINATE_RESET_FILE" \
            --owner "$owner_arg" --number "$pn" <<<"$raw" >"$dir/$(printf '%05d' "$pages").json" || return 1
        meta="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("true" if d["hasNextPage"] else "false", len(d["items"]), d["endCursor"] or "-")
' "$dir/$(printf '%05d' "$pages").json")" || return 1
        read -r has_next count cursor <<<"$meta"
        total=$((total + count))
        # hasNextPage=false is the only proof of exhaustion.
        [[ "$has_next" == "false" ]] && break
        case "$seen" in
            *" $cursor "*)
                echo "ERROR: board read cycled (cursor $cursor seen twice); refusing a partial board" >&2
                return 1 ;;
        esac
        seen="$seen$cursor "
        if [[ "$total" -ge "$PAGINATE_HARD_CAP" ]]; then
            if [[ "$strict" == "--strict" ]]; then
                echo "WIP BLOCKED: pagination hard cap ($PAGINATE_HARD_CAP); board snapshot incomplete" >&2
                return 3
            fi
            echo "WARNING: hit pagination hard cap ($PAGINATE_HARD_CAP) fetching project items — results may be incomplete" >&2
            break
        fi
    done
    merged="$(python3 "$tool" merge "$dir")" || return 1
    if [[ "$strict" == "--strict" ]]; then
        python3 "$here/wip.py" page <<<"$merged" >/dev/null || return 3
    fi
    printf '%s' "$merged"
}

# gh_issues_json <repo> [gh issue list flags...] -> full JSON array, all pages
# (flags go after --limit, e.g.: gh_issues_json "$REPO" --state all --json title)
#
# `gh issue list` (gh 2.54, the version this plugin targets) exposes only a -L/--limit ceiling:
# there is no --after/cursor flag (see `gh issue list --help`). gh follows the cursor itself to
# satisfy whatever --limit is requested, so the only lever is to keep asking for more. This
# helper doubles --limit from PAGINATE_BASE_LIMIT and re-issues the call until gh returns fewer
# items than requested (proof the page wasn't full: nothing is left) or PAGINATE_HARD_CAP is hit
# (warned on stderr: no exhaustion proof). That trades redundant re-fetches for the invariant
# that callers never see a silently truncated page-1 ceiling. The "fewer than requested =>
# exhausted" check assumes gh never returns a short page on a zero exit; if that changes,
# count-based exhaustion would need a real cursor.

gh_issues_json() {
    local repo_arg="$1"; shift
    local limit="$PAGINATE_BASE_LIMIT" out count
    while :; do
        out="$(gh issue list -R "$repo_arg" --limit "$limit" "$@")" || return 1
        count="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"$out")"
        # count-based exhaustion proof, as described above.
        if [[ "$count" -lt "$limit" ]]; then
            printf '%s' "$out"
            return 0
        fi
        if [[ "$limit" -ge "$PAGINATE_HARD_CAP" ]]; then
            echo "WARNING: hit pagination hard cap ($PAGINATE_HARD_CAP) fetching issues — results may be incomplete" >&2
            printf '%s' "$out"
            return 0
        fi
        limit=$((limit * 2))
    done
}
