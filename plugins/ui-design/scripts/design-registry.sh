#!/usr/bin/env bash
# design-registry.sh — find past UI designs by tag and record the human's pick.
#
# Every options page carries its own record, an inert JSON block in its head:
#   <script type="application/json" id="design-meta">{"designId": "...", "round": 1,
#     "tags": [...], "createdDate": "YYYY-MM-DD", "finalizedOption": null, "pickDate": null}</script>
# There is no separate index to go stale: each call rescans the pages.
#
#   design-registry.sh index                  every design: id, round, tags, pick, page
#   design-registry.sh find --tags a,b        designs carrying ANY of the tags
#   design-registry.sh pick <id>[-r<N>] <option> [--date YYYY-MM-DD]
#       record the final pick (finalizedOption, pickDate) in the page's block,
#       in place; a bare id means its highest round. A page that only lives in
#       the hub is also copied to docs/ui-options/ so the decision is tracked.
#
# Pages: <repo>/docs/ui-options/*.html (tracked, this checkout) and
# <main checkout>/.claude/ui-hub/html/*.html (the hub's copies, shared by every
# worktree). A tracked copy wins over the hub copy of the same design and round.
# Other keys in a block are kept as given. $DESIGN_REGISTRY_ROOT overrides the
# repository root. Needs: bash, jq, awk, git.
set -uo pipefail

usage() {
    echo "usage: design-registry.sh index | find --tags a,b | pick <id>[-r<N>] <option> [--date YYYY-MM-DD]"
}

canon() { (cd -P "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

if [[ -n "${DESIGN_REGISTRY_ROOT:-}" ]]; then
    ROOT="$(canon "$DESIGN_REGISTRY_ROOT")"
else
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    ROOT="$(canon "${top:-$PWD}")"
fi
# The main checkout, even when ROOT is a linked worktree: the hub's pages live there.
SHARED="$ROOT"
common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [[ -n "$common" && -d "$(dirname "${common%/}")" ]]; then
    SHARED="$(canon "$(dirname "${common%/}")")"
fi
UI_OPTIONS_DIR="$ROOT/docs/ui-options"
LIVE_HTML_DIR="$SHARED/.claude/ui-hub/html"

# relpath <abs> — <abs> relative to ROOT (with ../ when outside it).
relpath() {
    local target="$1" base="$ROOT" up=""
    while [[ "$target" != "$base"/* ]]; do
        [[ "$base" == / ]] && { printf '%s\n' "$target"; return; }
        base="$(dirname "$base")"; up="../$up"
    done
    printf '%s%s\n' "$up" "${target#"$base"/}"
}

# meta_of <html> — the design-meta block's JSON, or nothing (no block, or
# one that does not parse).
meta_of() {
    local raw
    raw="$(awk 'BEGIN { RS = "\001" }
        {
            if (!match($0, /<script[^>]*[^A-Za-z0-9_]id="design-meta"[^>]*>/)) exit 1
            rest = substr($0, RSTART + RLENGTH)
            end = index(rest, "</script>")
            if (!end) exit 1
            printf "%s", substr(rest, 1, end - 1)
            exit 0
        }' "$1" 2>/dev/null)" || return 0
    jq -ce 'select(type == "object")' <<<"$raw" 2>/dev/null || true
}

# write_meta <html> <json> — replace the block's JSON in place, keeping every
# other byte of the page.
write_meta() {
    local tmp
    tmp="$(mktemp "${1}.XXXXXX")" || return 1
    if NEW_BLOCK="<script type=\"application/json\" id=\"design-meta\">$2</script>" awk 'BEGIN { RS = "\001" }
        {
            if (!match($0, /<script[^>]*[^A-Za-z0-9_]id="design-meta"[^>]*>/)) exit 1
            start = RSTART
            rest = substr($0, RSTART + RLENGTH)
            end = index(rest, "</script>")
            if (!end) exit 1
            printf "%s%s%s", substr($0, 1, start - 1), ENVIRON["NEW_BLOCK"], substr(rest, end + 9)
        }' "$1" >"$tmp"; then
        mv "$tmp" "$1"
    else
        rm -f "$tmp"
        return 1
    fi
}

# discover — one JSON record per line, sorted by id then round:
# {designId, round, tags, finalizedOption, page, pageSource}
discover() {
    local dir source f meta
    for dir in "$UI_OPTIONS_DIR" "$LIVE_HTML_DIR"; do
        [[ -d "$dir" ]] || continue
        if [[ "$dir" == "$UI_OPTIONS_DIR" ]]; then source=tracked; else source=hub; fi
        for f in "$dir"/*.html; do
            [[ -f "$f" ]] || continue
            meta="$(meta_of "$f")"
            [[ -n "$meta" ]] || continue
            jq -c --arg page "$(relpath "$f")" --arg src "$source" '
                select(.designId != null and .designId != "")
                | {designId, round: (.round // 1), tags: (.tags // []),
                   finalizedOption, page: $page, pageSource: $src}' <<<"$meta"
        done
    done | jq -sc '
        # tracked pages come first; the first record for an id+round wins
        reduce .[] as $r ({}; ($r.designId + "\u0000" + ($r.round | tostring)) as $k
            | if has($k) then . else . + {($k): $r} end)
        | [.[]] | sort_by(.designId, .round) | .[]'
}

line_of() {
    jq -r '"\(.designId) r\(.round) tags=[\(.tags | join(","))] finalized=\(.finalizedOption // "DRAFT/UNDECIDED") page=\(.page)"
        + (if .finalizedOption and .pageSource == "hub" then " ANOMALY=hub-only-not-archived" else "" end)'
}

cmd_index() {
    local records
    records="$(discover)"
    if [[ -z "$records" ]]; then echo "design-registry: no designs discovered"; return 0; fi
    line_of <<<"$records"
}

cmd_find() {
    local tags="" wanted records
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tags) tags="${2:-}"; shift ;;
            --tags=*) tags="${1#--tags=}" ;;
        esac
        shift
    done
    wanted="$(jq -cn --arg t "$tags" '[$t | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(. != "")]')"
    if [[ "$wanted" == "[]" ]]; then
        echo "design-registry find: --tags must name at least one tag"
        return 2
    fi
    records="$(discover | jq -c --argjson w "$wanted" 'select([.tags[] | IN($w[])] | any)')"
    if [[ -z "$records" ]]; then
        echo "design-registry: no design matches tags [$(jq -r 'map("'"'"'" + . + "'"'"'") | join(", ")' <<<"$wanted")]"
        return 0
    fi
    line_of <<<"$records"
}

cmd_pick() {
    local id="" option="" date_="" round="" records rec page src abs meta dest note=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --date) date_="${2:-}"; shift ;;
            --date=*) date_="${1#--date=}" ;;
            *) if [[ -z "$id" ]]; then id="$1"; elif [[ -z "$option" ]]; then option="$1"; fi ;;
        esac
        shift
    done
    if [[ -z "$id" || -z "$option" ]]; then
        echo "usage: design-registry.sh pick <id>[-r<N>] <option> [--date YYYY-MM-DD]" >&2
        return 2
    fi
    [[ -n "$date_" ]] || date_="$(date +%F)"
    records="$(discover)"
    if [[ "$id" =~ ^(.*)-r([0-9]+)$ ]]; then
        id="${BASH_REMATCH[1]}"; round="${BASH_REMATCH[2]}"
    else
        round="$(jq -rs --arg id "$id" '[.[] | select(.designId == $id) | .round] | max // 1' <<<"$records")"
    fi
    rec="$(jq -c --arg id "$id" --argjson r "$round" 'select(.designId == $id and .round == $r)' <<<"$records" | head -1)"
    if [[ -z "$rec" ]]; then
        echo "design-registry: no page with a design-meta block for $id r$round -- nothing recorded"
        return 1
    fi
    page="$(jq -r .page <<<"$rec")"; src="$(jq -r .pageSource <<<"$rec")"
    if [[ "$page" == /* ]]; then abs="$page"; else abs="$ROOT/$page"; fi
    meta="$(meta_of "$abs" | jq -Sc --arg o "$option" --arg d "$date_" '. + {finalizedOption: $o, pickDate: $d}')"
    if [[ -z "$meta" ]] || ! write_meta "$abs" "$meta"; then
        echo "design-registry: could not rewrite the design-meta block in $page -- nothing recorded"
        return 1
    fi
    if [[ "$src" == hub ]]; then
        if [[ "$round" == 1 ]]; then dest="$UI_OPTIONS_DIR/$id.html"; else dest="$UI_OPTIONS_DIR/$id-r$round.html"; fi
        if [[ ! -f "$dest" ]]; then
            mkdir -p "$UI_OPTIONS_DIR" && cp "$abs" "$dest" \
                && note="; archived a tracked copy to $(relpath "$dest") (was hub-only)"
        fi
    fi
    echo "design-registry: recorded pick for $id r$round in page $page$note"
}

verb="${1:-}"
[[ $# -gt 0 ]] && shift
case "$verb" in
    index) cmd_index ;;
    find) cmd_find "$@" ;;
    pick) cmd_pick "$@" ;;
    *) usage >&2; exit 2 ;;
esac
