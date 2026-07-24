#!/usr/bin/env bash
# capability.sh -- install & drive modular "capabilities" for the memory engine.
#
# A capability is a SELF-CONTAINED, isolated unit that owns its own heavy
# dependencies (a Python venv + downloaded model files) so the stdlib-only core
# scripts never grow a runtime dependency on them (SPEC-MEMORY §12). Its absence
# or ill-health degrades a feature, never breaks a flow (§9.1.1): every consumer
# gates on `capability.sh healthcheck <name>` returning 0 and, on a non-zero
# exit, falls back to today's behavior after printing at most one notice line.
#
# This is the FIRST capability and the TEMPLATE for future ones. The contract a
# new capability must satisfy:
#   * install    <name> [--dir DIR]  -- build the venv, fetch the model, write
#                                       manifest.json; idempotent + offline once
#                                       downloaded (a healthy dir is skipped, no
#                                       network).
#   * healthcheck <name> [--dir DIR] -- exit 0 healthy; exit 3 UNAVAILABLE
#                                       (absent OR broken), one stderr notice
#                                       line, empty stdout. This is the single
#                                       signal every consumer branches on.
#   * embed      <name> [--dir DIR]  -- (embeddings-specific) pipe stdin->stdout
#                                       through the capability's entrypoint.
#   * path       <name> [--dir DIR]  -- print the resolved install dir.
# manifest.json carries: name, version, entrypoint (venv python + script),
# healthcheck (the command above), model {id, revision, dim, pooling}, deps.
#
# Install location (OQ-2 resolved: shared, one venv/model for ALL repos):
#   default base = ${CAPABILITY_HOME:-$HOME/.claude/capabilities}
#   install dir  = <base>/<name>
#   --dir DIR    = full per-capability dir override (per-repo isolation / tests);
#                  takes precedence over CAPABILITY_HOME.
#
# Exit codes: 0 ok | 2 usage error | 3 capability unavailable (healthcheck).
#
# The only slow/networked path is `install`; the test suite exercises it behind
# RUN_SLOW_TESTS=1 (see tests/section-capability-embeddings.sh). Everything else
# is fast and hermetic.
set -uo pipefail

# --- embeddings capability pins (OQ-4: bge-small-en-v1.5, 384-dim ONNX) ------
# Pinned to an immutable HuggingFace commit so `install` is reproducible and,
# after the first download, fully offline. Xenova/bge-small-en-v1.5 is the
# transformers.js ONNX export of BAAI/bge-small-en-v1.5 (BertModel, hidden 384).
EMB_MODEL_ID="Xenova/bge-small-en-v1.5"
EMB_MODEL_REV="ea104dacec62c0de699686887e3f920caeb4f3e3"
EMB_MODEL_DIM=384
EMB_ONNXRUNTIME="onnxruntime==1.27.0"
EMB_TOKENIZERS="tokenizers==0.23.1"
EMB_NUMPY="numpy==2.5.1"
EMB_HF_BASE="https://huggingface.co/${EMB_MODEL_ID}/resolve/${EMB_MODEL_REV}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat >&2 <<'EOF'
usage: capability.sh <command> <name> [--dir DIR]
  install     <name>   build the venv, fetch the model, write manifest.json
  healthcheck <name>   exit 0 healthy / 3 unavailable (absent or broken)
  embed       <name>   pipe stdin text lines -> stdout JSON embedding arrays
  path        <name>   print the resolved install dir
Only the "embeddings" capability exists today.
Install location: --dir DIR, else ${CAPABILITY_HOME:-$HOME/.claude/capabilities}/<name>
EOF
}

# resolve_dir <name> <dir-override> -- echo the install dir for a capability.
resolve_dir() {
    local name="$1" override="$2"
    if [[ -n "$override" ]]; then
        printf '%s\n' "$override"
    else
        printf '%s\n' "${CAPABILITY_HOME:-$HOME/.claude/capabilities}/$name"
    fi
}

# healthcheck_embeddings <dir> -- exit 0 healthy; exit 3 unavailable, printing
# exactly one notice line to stderr. Distinguishes "not installed" (dir/manifest
# absent) from "unhealthy" (present but the venv can't import its deps or the
# model files are gone) so the operator sees which, while both map to the same
# graceful-absence signal (exit 3) for consumers.
healthcheck_embeddings() {
    local dir="$1"
    local py="$dir/venv/bin/python"
    if [[ ! -d "$dir" || ! -f "$dir/manifest.json" ]]; then
        echo "capability 'embeddings' not installed at $dir -- run: capability.sh install embeddings" >&2
        return 3
    fi
    if [[ ! -x "$py" ]] \
        || ! "$py" -c 'import onnxruntime, tokenizers, numpy' >/dev/null 2>&1 \
        || [[ ! -s "$dir/model/model.onnx" || ! -s "$dir/model/tokenizer.json" ]]; then
        echo "capability 'embeddings' at $dir is unhealthy (broken venv or missing model) -- reinstall: capability.sh install embeddings" >&2
        return 3
    fi
    return 0
}

# fetch <url> <dest> -- download to a temp path then move into place, so an
# interrupted download never leaves a truncated file that would pass a naive
# existence check. --fail turns an HTTP error into a non-zero exit.
fetch() {
    local url="$1" dest="$2" tmp
    tmp="$dest.part"
    if ! curl -fsSL --max-time 600 -o "$tmp" "$url"; then
        rm -f "$tmp"
        echo "capability.sh: download failed: $url" >&2
        return 1
    fi
    mv "$tmp" "$dest"
}

# pick_python -- echo an interpreter with onnxruntime wheel support. Honors
# CAPABILITY_PYTHON, else the newest of a known-good preference list, else
# python3. onnxruntime ships cp311..cp313 wheels; 3.14 wheels may not exist yet,
# so it is deliberately NOT in the preferred list (but CAPABILITY_PYTHON can
# force any interpreter the operator knows works).
pick_python() {
    if [[ -n "${CAPABILITY_PYTHON:-}" ]]; then
        printf '%s\n' "$CAPABILITY_PYTHON"; return
    fi
    local c
    for c in python3.13 python3.12 python3.11; do
        if command -v "$c" >/dev/null 2>&1; then printf '%s\n' "$c"; return; fi
    done
    printf '%s\n' python3
}

install_embeddings() {
    local dir="$1"
    # Idempotent + offline: a healthy install is a no-op (no venv rebuild, no
    # re-download, zero network). This is how the "offline after first download"
    # guarantee is met -- the second call never reaches curl/pip.
    if healthcheck_embeddings "$dir" 2>/dev/null; then
        echo "capability 'embeddings' already installed and healthy at $dir -- skipping (offline, no rebuild)."
        return 0
    fi

    local py model_dir
    py="$(pick_python)"
    model_dir="$dir/model"
    echo "capability.sh: installing 'embeddings' into $dir (python: $py)"
    mkdir -p "$model_dir"

    # 1. isolated venv + pinned deps.
    if [[ ! -x "$dir/venv/bin/python" ]]; then
        "$py" -m venv "$dir/venv" || { echo "capability.sh: venv creation failed" >&2; return 1; }
    fi
    "$dir/venv/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
    if ! "$dir/venv/bin/python" -m pip install --quiet \
        "$EMB_ONNXRUNTIME" "$EMB_TOKENIZERS" "$EMB_NUMPY"; then
        echo "capability.sh: pip install of pinned deps failed" >&2
        return 1
    fi

    # 2. pinned model files (skip any already fully present so a resumed install
    #    doesn't re-download).
    [[ -s "$model_dir/model.onnx" ]]     || fetch "$EMB_HF_BASE/onnx/model.onnx"  "$model_dir/model.onnx"     || return 1
    [[ -s "$model_dir/tokenizer.json" ]] || fetch "$EMB_HF_BASE/tokenizer.json"   "$model_dir/tokenizer.json" || return 1
    [[ -s "$model_dir/config.json" ]]    || fetch "$EMB_HF_BASE/config.json"      "$model_dir/config.json"    || return 1

    # 3. the embed entrypoint, copied in so the dir is self-contained.
    cp "$HERE/lib/capability-embed.py" "$dir/embed.py"

    # 4. manifest.json (name/version/entrypoint/healthcheck + model/deps).
    local created
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat >"$dir/manifest.json" <<EOF
{
  "name": "embeddings",
  "version": "bge-small-en-v1.5+onnxruntime-1.27.0",
  "entrypoint": "$dir/venv/bin/python $dir/embed.py",
  "healthcheck": "capability.sh healthcheck embeddings --dir $dir",
  "model": {
    "id": "$EMB_MODEL_ID",
    "revision": "$EMB_MODEL_REV",
    "dim": $EMB_MODEL_DIM,
    "pooling": "cls",
    "normalize": true
  },
  "deps": {
    "onnxruntime": "1.27.0",
    "tokenizers": "0.23.1",
    "numpy": "2.5.1"
  },
  "created": "$created"
}
EOF

    # 5. prove it: a fresh install must pass its own healthcheck.
    if ! healthcheck_embeddings "$dir" 2>/dev/null; then
        echo "capability.sh: install completed but healthcheck failed -- see above" >&2
        return 1
    fi
    echo "capability 'embeddings' installed and healthy at $dir"
}

embed_embeddings() {
    local dir="$1"
    if ! healthcheck_embeddings "$dir"; then
        return 3
    fi
    "$dir/venv/bin/python" "$dir/embed.py"
}

main() {
    local cmd="${1:-}"
    [[ -n "$cmd" ]] || { usage; return 2; }
    shift
    local name="${1:-}"
    [[ -n "$name" ]] || { echo "capability.sh: '$cmd' requires a capability name" >&2; usage; return 2; }
    shift

    local dir_override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir) shift; [[ $# -gt 0 ]] || { echo "capability.sh: --dir requires a value" >&2; return 2; }
                   dir_override="$1"; shift ;;
            --dir=*) dir_override="${1#--dir=}"; shift ;;
            *) echo "capability.sh: unknown option: $1" >&2; usage; return 2 ;;
        esac
    done

    if [[ "$name" != "embeddings" ]]; then
        echo "capability.sh: unknown capability: $name (only 'embeddings' exists)" >&2
        return 2
    fi
    local dir
    dir="$(resolve_dir "$name" "$dir_override")"

    case "$cmd" in
        install)     install_embeddings "$dir" ;;
        healthcheck) healthcheck_embeddings "$dir" ;;
        embed)       embed_embeddings "$dir" ;;
        path)        printf '%s\n' "$dir" ;;
        *) echo "capability.sh: unknown command: $cmd" >&2; usage; return 2 ;;
    esac
}

main "$@"
