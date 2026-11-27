#!/usr/bin/env bash
# AST-081 native API and real ephemeral SSH forwarding lifecycle.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh" >&2; exit 2; }
echo "== assistant ComfyUI rendering (AST-081) =="
_comfy_out="$(python3 "$HERE/test_comfyui_render.py" 2>&1)"; _comfy_rc=$?
printf '%s\n' "$_comfy_out"
check_rc "ComfyUI engine/SQLite/native HTTP/WS/SSH lifecycle" 0 "$_comfy_rc"
