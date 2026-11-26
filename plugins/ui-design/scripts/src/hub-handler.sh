#!/usr/bin/env bash
# hub-handler.sh — answers ONE HTTP request for the decision hub.
# The listener (socat, started by ui-hub.sh) runs this once per connection with
# the connection on stdin and stdout. It reads the request, answers it, and
# exits; every response closes the connection (HTTP/1.0).
#
#   GET  /, /index...       the hub page (templates/hub.html)
#   GET  /api/state         {hubRev, pending[], answered[last 20]}
#   GET  /decision/<id>     the page asked for that card
#   GET  /vendor/axe.min.js the vendored axe-core the options page loads
#   POST /api/answer        {id, selection, keep?} — keep=true files partial
#                           feedback and leaves the card pending
#
# Needs: bash, jq, cksum, head. State dir: $UI_HUB_STATE_DIR (set by ui-hub.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/../.." && pwd)"
S="${UI_HUB_STATE_DIR:?UI_HUB_STATE_DIR must be set}"
INBOX="$S/inbox"; OUTBOX="$S/outbox"; ARCHIVE="$S/archive"; HTML="$S/html"
HUB_PAGE="$PLUGIN/templates/hub.html"
AXE="$PLUGIN/scripts/vendor/axe.min.js"

reason() {
    case "$1" in
        200) echo OK ;; 400) echo "Bad Request" ;; 404) echo "Not Found" ;;
        501) echo "Not Implemented" ;; *) echo Status ;;
    esac
}

# send_file <code> <content-type> <file>
send_file() {
    printf 'HTTP/1.0 %s %s\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' \
        "$1" "$(reason "$1")" "$2" "$(wc -c <"$3" | tr -d ' ')"
    cat "$3"
}

# send <code> <content-type> <body>
send() {
    printf 'HTTP/1.0 %s %s\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
        "$1" "$(reason "$1")" "$2" "$(printf '%s' "$3" | wc -c | tr -d ' ')" "$3"
}

send_json() { send "$1" "application/json" "$2"; }

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

state() {
    local f id rev hub_rev
    hub_rev="$(cksum <"$HUB_PAGE" | cut -d' ' -f1)"
    {
        # pending: oldest first; rev = the page's mtime, so an open hub tab
        # hot-reloads a card whose page was regenerated.
        for f in "$INBOX"/*.json; do
            [[ -f "$f" ]] || continue
            id="$(jq -r '.id' "$f")" || continue
            rev=0
            [[ -f "$HTML/$id.html" ]] && rev="$(mtime "$HTML/$id.html")"
            jq -c --argjson rev "${rev:-0}" '. + {rev: $rev}' "$f"
        done | jq -s 'sort_by(.created)'
        # answered: outbox + consumed answers, newest last, the last 20.
        for f in "$OUTBOX"/*.json "$ARCHIVE/answers"/*.json; do
            [[ -f "$f" ]] && cat "$f" && echo
        done | jq -s 'sort_by(.answered // 0) | .[-20:]'
    } | jq -s --arg rev "$hub_rev" '{hubRev: $rev, pending: .[0], answered: .[1]}'
}

answer() {
    local body="$1" did selection keep now meta req_file
    if ! jq -e 'type == "object" and has("id") and has("selection")' >/dev/null 2>&1 <<<"$body"; then
        send_json 400 '{"error": "expected JSON {id, selection}"}'
        return
    fi
    did="$(jq -r '.id | tostring' <<<"$body")"
    selection="$(jq -r '.selection | tostring' <<<"$body")"
    keep="$(jq -r '.keep | if . == null or . == false or . == 0 or . == "" or . == [] or . == {} then "no" else "yes" end' <<<"$body")"
    now="$(date +%s)"
    req_file="$INBOX/$did.json"
    if [[ -f "$req_file" ]]; then meta="$(cat "$req_file")"; else meta="$(jq -n --arg id "$did" '{id: $id}')"; fi
    meta="$(jq --indent 1 --arg s "$selection" --argjson t "$now" '. + {selection: $s, answered: $t}' <<<"$meta")"
    if [[ "$keep" == yes ]]; then
        # partial feedback (e.g. "fix these a11y issues") — deliver it to the
        # agent but keep the card pending so the human can still decide.
        printf '%s' "$meta" >"$OUTBOX/$did.fix-$now.json"
        send_json 200 '{"ok": true, "kept": true}'
        return
    fi
    printf '%s' "$meta" >"$OUTBOX/$did.json"
    [[ -f "$req_file" ]] && mv "$req_file" "$ARCHIVE/asked/$did.json"
    send_json 200 '{"ok": true}'
}

IFS= read -r line || exit 0
line="${line%$'\r'}"
method="${line%% *}"; rest="${line#* }"; path="${rest%% *}"
length=0
while IFS= read -r h; do
    h="${h%$'\r'}"
    [[ -z "$h" ]] && break
    name="$(tr '[:upper:]' '[:lower:]' <<<"${h%%:*}")"
    if [[ "$name" == content-length ]]; then
        length="${h#*:}"; length="${length//[^0-9]/}"
    fi
done

case "$method" in
    GET)
        if [[ "$path" == "/" || "$path" == /index* ]]; then
            send_file 200 "text/html; charset=utf-8" "$HUB_PAGE"
        elif [[ "$path" == "/api/state" ]]; then
            send_json 200 "$(state)"
        elif [[ "$path" == "/vendor/axe.min.js" ]]; then
            if [[ -f "$AXE" ]]; then send_file 200 "text/javascript; charset=utf-8" "$AXE"
            else send_json 404 '{"error": "axe.min.js not vendored"}'; fi
        elif [[ "$path" == /decision/* ]]; then
            p="${path%%\?*}"; did="${p##*/}"
            if [[ -n "$did" && -f "$HTML/$did.html" ]]; then send_file 200 "text/html; charset=utf-8" "$HTML/$did.html"
            else send_json 404 '{"error": "unknown decision"}'; fi
        else
            send_json 404 '{"error": "not found"}'
        fi ;;
    POST)
        body=""
        [[ "${length:-0}" -gt 0 ]] && body="$(head -c "$length")"
        if [[ "$path" == "/api/answer" ]]; then answer "$body"
        else send_json 404 '{"error": "not found"}'; fi ;;
    *)
        send_json 501 '{"error": "unsupported method"}' ;;
esac
