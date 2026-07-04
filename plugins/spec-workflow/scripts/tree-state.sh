#!/usr/bin/env bash
# tree-state.sh — print a fingerprint of the working tree (HEAD + uncommitted changes).
# Shared by gate.sh (records it) and guard-board-move.sh (verifies it).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"
{
    git rev-parse HEAD 2>/dev/null || echo no-head
    git status --porcelain 2>/dev/null
    git diff HEAD 2>/dev/null
} | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
