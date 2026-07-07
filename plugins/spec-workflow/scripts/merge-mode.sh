#!/usr/bin/env bash
# merge-mode.sh — show or configure auto-merge for this project (.claude/project.yaml).
#   merge-mode.sh                 # or: status -> autoMerge / reviewer models / mergeMethod / reviewerTokenEnv
#   merge-mode.sh on|off          # sets methodology.autoMerge
#   merge-mode.sh model <model>[,<model>...]   # sets delegation.identities.reviewer.models (allowed set)
#   merge-mode.sh method <squash|merge|rebase>  # sets methodology.mergeMethod
# Unlike ui-mode (local flag), auto-merge is a project-wide, versioned config
# change: merging without a human is something every clone must agree on.
# Reads via the shared loader (yaml or legacy json); writes back in the file's own format.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="$(PYTHONPATH="$HERE" python3 "$HERE/config.py" "$ROOT" path)"
[[ -n "$CONFIG" && -f "$CONFIG" ]] || { echo "ERROR: no .claude/project.yaml (or legacy .json) — run the setup-project skill first" >&2; exit 1; }

jset() { # jset <dot.path> <json-value>  — edits ONLY the target key in place.
    # YAML: a surgical line-level edit (dependency-free) that leaves every other
    # byte — comments, blank lines, flow styles — untouched. JSON (legacy): rewritten.
    PYTHONPATH="$HERE" python3 - "$CONFIG" "$1" "$2" <<'EOF'
import json, sys

cfgfile, path, val = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
keys = path.split(".")
STEP = 4  # config indent unit


def literal(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, list):
        return "[" + ", ".join(json.dumps(x, ensure_ascii=False) for x in v) + "]"
    if isinstance(v, (int, float)):
        return json.dumps(v)
    return json.dumps(v, ensure_ascii=False)  # string -> double-quoted scalar


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_key(line, key):
    s = line.strip()
    return s == key + ":" or s.startswith(key + ": ") or s.startswith(key + ":\t")


def block_end(lines, start, parent_indent):
    # first real (non-blank, non-comment) line at indent <= parent_indent
    for j in range(start, len(lines)):
        s = lines[j].strip()
        if s and not s.startswith("#") and indent_of(lines[j]) <= parent_indent:
            return j
    return len(lines)


def find_child(lines, lo, hi, key, parent_indent):
    child_indent = None
    for j in range(lo, hi):
        s = lines[j].strip()
        if not s or s.startswith("#"):
            continue
        ind = indent_of(lines[j])
        if ind <= parent_indent:
            break
        if child_indent is None:
            child_indent = ind
        if ind == child_indent and is_key(lines[j], key):
            return j
    return None


def replace_value(lines, idx, value):
    ind = indent_of(lines[idx])
    key = lines[idx].strip().split(":", 1)[0]
    end = idx + 1  # drop any block-style continuation (deeper-indented value lines)
    while end < len(lines):
        s = lines[end].strip()
        if not s or s.startswith("#") or indent_of(lines[end]) <= ind:
            break
        end += 1
    return lines[:idx] + [f"{' ' * ind}{key}: {value}"] + lines[end:]


def insert(lines, hi, remaining, parent_indent, value):
    pos = hi  # insert before any trailing blank lines (keeps the file's final newline last)
    while pos > 0 and lines[pos - 1].strip() == "":
        pos -= 1
    base = parent_indent + STEP
    block = []
    for depth, k in enumerate(remaining):
        ind = base + depth * STEP
        block.append(f"{' ' * ind}{k}: {value}" if depth == len(remaining) - 1 else f"{' ' * ind}{k}:")
    return lines[:pos] + block + lines[pos:]


def yaml_set(text, keys, value):
    lines = text.split("\n")  # split/join by \n reproduces bytes exactly (incl. trailing newline)
    lo, hi, parent_indent = 0, len(lines), -STEP
    for depth, key in enumerate(keys):
        idx = find_child(lines, lo, hi, key, parent_indent)
        if idx is None:
            return "\n".join(insert(lines, hi, keys[depth:], parent_indent, value))
        if depth == len(keys) - 1:
            return "\n".join(replace_value(lines, idx, value))
        parent_indent = indent_of(lines[idx])
        lo, hi = idx + 1, block_end(lines, idx + 1, parent_indent)
    return text


if cfgfile.endswith((".yaml", ".yml")):
    new_text = yaml_set(open(cfgfile).read(), keys, literal(val))  # read BEFORE truncating
    with open(cfgfile, "w") as fh:
        fh.write(new_text)
else:
    cfg = json.load(open(cfgfile))
    node = cfg
    for k in keys[:-1]:
        nxt = node.get(k)
        if not isinstance(nxt, dict):
            nxt = {}
            node[k] = nxt
        node = nxt
    node[keys[-1]] = val
    with open(cfgfile, "w") as fh:
        json.dump(cfg, fh, indent=4, ensure_ascii=False)
        fh.write("\n")
EOF
}

jget() { PYTHONPATH="$HERE" python3 "$HERE/config.py" "$ROOT" get "$1"; }

case "${1:-status}" in
    status)
        am="$(jget methodology.autoMerge)"
        models="$(jget delegation.identities.reviewer.models)"
        method="$(jget methodology.mergeMethod)"
        tokenenv="$(jget delegation.reviewerTokenEnv)"
        [[ "$am" == "true" ]] && echo "autoMerge: ON (agent reviews, approves, merges — no human approval)" \
                              || echo "autoMerge: OFF (a human approves and merges every PR)"
        echo "reviewer models: ${models:-[\"claude-sonnet-5\", \"claude-sonnet-5[1m]\"] (default)}"
        echo "mergeMethod: ${method:-squash (default)}"
        if [[ -n "$tokenenv" ]]; then
            if [[ -n "${!tokenenv:-}" ]]; then echo "reviewerTokenEnv: $tokenenv (set in env — approvals appear as a distinct GitHub account)"
            else echo "reviewerTokenEnv: $tokenenv (NOT set in this env — approvals fall back to review comments)"; fi
        else
            echo "reviewerTokenEnv: unset (approvals are posted as review comments; branch protection requiring approvals will block)"
        fi ;;
    on)  jset methodology.autoMerge true;  echo "autoMerge: ON (methodology.autoMerge=true in $CONFIG — commit this change)" ;;
    off) jset methodology.autoMerge false; echo "autoMerge: OFF (methodology.autoMerge=false in $CONFIG — commit this change)" ;;
    model)
        [[ -n "${2:-}" ]] || { echo "usage: merge-mode.sh model <model>[,<model>...]" >&2; exit 1; }
        arr="$(python3 -c 'import json,sys; print(json.dumps([m.strip() for m in sys.argv[1].split(",") if m.strip()]))' "$2")"
        jset delegation.identities.reviewer.models "$arr"
        echo "reviewer models: $2 (delegation.identities.reviewer.models in $CONFIG — commit this change)" ;;
    method)
        case "${2:-}" in squash|merge|rebase) ;; *) echo "usage: merge-mode.sh method <squash|merge|rebase>" >&2; exit 1 ;; esac
        jset methodology.mergeMethod "\"$2\""
        echo "mergeMethod: $2 (methodology.mergeMethod in $CONFIG — commit this change)" ;;
    *) echo "usage: merge-mode.sh [status|on|off|model <model>[,<model>...]|method <squash|merge|rebase>]" >&2; exit 1 ;;
esac
