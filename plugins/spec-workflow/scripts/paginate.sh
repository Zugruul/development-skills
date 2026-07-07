#!/usr/bin/env bash
# paginate.sh — shared pagination helpers for board.sh and seed-board.sh (SPEC 7.4).
#
# `gh project item-list` and `gh issue list` (gh 2.54, the version this plugin targets)
# expose only a -L/--limit ceiling — there is no --after/cursor flag on either subcommand
# (see `gh project item-list --help`, `gh issue list --help`). Internally gh follows the
# GraphQL/REST cursor itself to satisfy whatever --limit is requested, so the only lever
# callers have to "paginate" is to keep asking for more.
#
# The helpers below escalate --limit (doubling from a base) and re-issue the call until gh
# returns fewer items than requested (proof the page wasn't full — nothing left to fetch)
# or a hard safety cap is hit. This trades a few redundant re-fetches (cheap; boards/issue
# lists are not huge) for the invariant that callers never see a silently truncated page-1
# ceiling. Source this file; it is not meant to be executed directly.
#
# The "fewer than requested ⇒ exhausted" check assumes gh never returns a partial page on a
# zero exit (i.e. it doesn't stop short of --limit while more items remain, short of an
# error). That holds for gh's own GraphQL/REST cursor-following; if gh's behavior ever
# changes, count-based exhaustion would need a real cursor instead.
set -uo pipefail

PAGINATE_BASE_LIMIT="${PAGINATE_BASE_LIMIT:-400}"
PAGINATE_HARD_CAP="${PAGINATE_HARD_CAP:-51200}"  # 400 * 2^7 — worst-case backstop, not a real ceiling

# gh_project_items_json <project-number> <owner> -> full {"items":[...]} JSON, all pages
gh_project_items_json() {
    local pn="$1" owner_arg="$2" limit="$PAGINATE_BASE_LIMIT" out count
    while :; do
        out="$(gh project item-list "$pn" --owner "$owner_arg" --format json --limit "$limit")" || return 1
        count="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items",[])))' <<<"$out")"
        # count < limit is the only proof of exhaustion (gh returned less than a full page).
        # Hitting the hard cap with a still-full page means we stopped WITHOUT that proof —
        # that is a real truncation risk, not silent: warn on stderr (SPEC 7.4).
        if [[ "$count" -lt "$limit" ]]; then
            printf '%s' "$out"
            return 0
        fi
        if [[ "$limit" -ge "$PAGINATE_HARD_CAP" ]]; then
            echo "WARNING: hit pagination hard cap ($PAGINATE_HARD_CAP) fetching project items — results may be incomplete" >&2
            printf '%s' "$out"
            return 0
        fi
        limit=$((limit * 2))
    done
}

# gh_issues_json <repo> [gh issue list flags...] -> full JSON array, all pages
# (flags go after --limit, e.g.: gh_issues_json "$REPO" --state all --json title)
gh_issues_json() {
    local repo_arg="$1"; shift
    local limit="$PAGINATE_BASE_LIMIT" out count
    while :; do
        out="$(gh issue list -R "$repo_arg" --limit "$limit" "$@")" || return 1
        count="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"$out")"
        # same exhaustion proof as gh_project_items_json() above.
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
