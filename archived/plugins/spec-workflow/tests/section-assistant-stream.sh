#!/usr/bin/env bash
# #523 incremental provider -> HTTP -> browser boundary regression tests.
declare -F check >/dev/null 2>&1 || { echo 'source via run-tests.sh' >&2; exit 2; }
echo '== assistant streaming (#523) =='
_stream_out="$(python3 "$HERE/test_chat_stream.py" 2>&1)"; _stream_rc=$?
check_rc 'stream provider, filtering and HTTP boundaries' 0 "$_stream_rc"
printf '%s\n' "$_stream_out"
_stream_out="$(node "$HERE/test_chat_stream.cjs" "$PLUGIN/templates/neural-view.html" 2>&1)"; _stream_rc=$?
check_rc 'browser streaming boundaries' 0 "$_stream_rc"
printf '%s\n' "$_stream_out"
_stream_out="$(node "$HERE/test_chat_stream.cjs" "$PLUGIN/templates/neural-view.html" --dispatch 2>&1)"; _stream_rc=$?
check_rc 'browser live dispatch, queue, speech and stale errors' 0 "$_stream_rc"
printf '%s\n' "$_stream_out"
_stream_out="$(node "$HERE/test_chat_stream_lifecycle.cjs" "$PLUGIN/templates/neural-view.html" 2>&1)"; _stream_rc=$?
check_rc 'browser actual switch ownership and rebuilt stream errors' 0 "$_stream_rc"
printf '%s\n' "$_stream_out"
