#!/usr/bin/env python3
"""config.py — the ONE shared config loader for the spec-workflow plugin.

Consumer repos declare config in `.neural-network/project.yaml` (schemaVersion 2)
at the repo root — the `.neural-network/` directory is also the discovery marker
and holds the repo's knowledge bases (identities/, feedbacks/, brain-events.jsonl,
plus the gitignored project.local.yaml overlay). This module finds the config,
parses it (PyYAML), and normalizes legacy `project.json` (schemaVersion 1) to the
v2 shape in memory so every script sees one shape.

Monorepo nesting: a NATIVE subfolder (one with no .git of its own between it and
the root — externally cloned-in repos are never nested) may carry its own
`.neural-network/` with a PARTIAL project.yaml. The root config is the source of
truth; for work under that subtree the nested keys deep-merge OVER the root
(dicts merge per key, nested wins on scalars/lists), everything else inherited.

Library:
    load_config(root=None, path=None, for_path=None) -> dict | None
        Resolution order: explicit `path` > $PROJECT_CONFIG >
        <root>/.neural-network/project.yaml > .../project.json. Returns None when
        no config file exists. `for_path` (repo-relative) additionally deep-merges
        the nearest native nested anchor's fragment over the root config.
        Legacy json (or schemaVersion 1) is normalized to v2 and emits ONE
        deprecation line to stderr. Raises ConfigError on parse failure. If a
        .yaml file is present but PyYAML is not installed, prints the PREFLIGHT
        FAIL line and exits 1 (a hard environment failure, by design).
    find_config(root=None) -> str | None    # resolved path, no parse
    find_anchors(root) -> [relpath, ...]    # native nested .neural-network dirs
    anchor_for(root, relpath) -> str | None # deepest native anchor covering relpath
    deep_merge(base, over) -> dict          # per-key dict merge, `over` wins on leaves

CLI (for bash callers):
    config.py <root> path                        # print resolved config path (empty if none)
    config.py <root> get <dot.path> [--for <p>]  # print a value (empty if absent); list/dict -> JSON
    config.py <root> set <dot.path> <json-value> # surgically set a key (YAML: only that key's
                                                 #   line changes — comments/formatting survive)
    config.py <root> json [--for <p>]            # print the whole normalized config as JSON
    config.py <root> anchors                     # print native nested anchor dirs, one per line
Dot paths index lists by integer segment, e.g. delegation.identities.dev.0.models.1.
`--for <repo-relative path>` resolves through the nested anchor covering that path.
"""
import json
import os
import sys

# The one canonical name for the config/knowledge directory AND discovery marker.
CONFIG_DIR = ".neural-network"

YAML_MISSING = "PREFLIGHT FAIL: PyYAML required — pip3 install pyyaml"


class ConfigError(Exception):
    """Raised when a config file exists but cannot be parsed."""


def _die_yaml_missing():
    sys.stderr.write(YAML_MISSING + "\n")
    sys.exit(1)


def find_config(root=None):
    """Resolve the config file path without parsing it. None if none exists."""
    env = os.environ.get("PROJECT_CONFIG")
    if env:
        return env if os.path.exists(env) else None
    base = os.path.join(root or ".", CONFIG_DIR)
    for name in ("project.yaml", "project.yml", "project.json"):
        p = os.path.join(base, name)
        if os.path.exists(p):
            return p
    return None


# --- monorepo nesting (native folders only) ---------------------------------
# A nested anchor is a subdirectory carrying its own .neural-network/ dir.
# NATIVE means no .git boundary between the root and the anchor: a repo cloned
# INSIDE the monorepo (its own .git dir or file) is a separate project and is
# never treated as nested — its subtree is skipped entirely.
_WALK_PRUNE = {".git", "node_modules", ".claude", CONFIG_DIR}


def find_anchors(root):
    """Repo-relative dirs (sorted) of native nested .neural-network anchors."""
    root = root or "."
    anchors = []
    for dirpath, dirnames, filenames in os.walk(root):
        if dirpath != root and (".git" in dirnames or ".git" in filenames):
            dirnames[:] = []  # non-native subtree: never descend
            continue
        if dirpath != root and CONFIG_DIR in dirnames:
            anchors.append(os.path.relpath(dirpath, root))
        dirnames[:] = [d for d in dirnames if d not in _WALK_PRUNE]
    return sorted(anchors)


def anchor_for(root, relpath):
    """Deepest native anchor whose dir contains `relpath`. None if none does."""
    if not relpath:
        return None
    norm = os.path.normpath(relpath)
    if os.path.isabs(norm) or norm.startswith(os.pardir):
        return None
    best = None
    node = os.path.dirname(norm)
    parts = [p for p in node.split(os.sep) if p and p != "."]
    # Walk root -> deeper; stop at the first .git boundary (non-native below it).
    cur = root or "."
    rel = ""
    for part in parts:
        cur = os.path.join(cur, part)
        rel = os.path.join(rel, part) if rel else part
        if os.path.isdir(os.path.join(cur, ".git")) or os.path.isfile(os.path.join(cur, ".git")):
            break  # cloned-in repo: nothing at or below this dir is native
        if os.path.isdir(os.path.join(cur, CONFIG_DIR)):
            best = rel
    return best


def deep_merge(base, over):
    """Per-key recursive dict merge; `over` wins on scalars and lists."""
    if not isinstance(base, dict) or not isinstance(over, dict):
        return over
    out = dict(base)
    for k, v in over.items():
        out[k] = deep_merge(base[k], v) if k in base and isinstance(base.get(k), dict) and isinstance(v, dict) else v
    return out


def _parse(path):
    with open(path) as fh:
        text = fh.read()
    if path.endswith((".yaml", ".yml")):
        try:
            import yaml
        except ImportError:
            _die_yaml_missing()
        try:
            data = yaml.safe_load(text)
        except Exception as e:  # noqa: BLE001
            raise ConfigError(f"cannot parse {path}: {e}")
    else:
        try:
            data = json.loads(text)
        except Exception as e:  # noqa: BLE001
            raise ConfigError(f"cannot parse {path}: {e}")
    if not isinstance(data, dict):
        raise ConfigError(f"{path}: top level must be a mapping")
    return data


def is_legacy(path, cfg):
    """A .json file, or any config declaring schemaVersion 1, is legacy v1."""
    return path.endswith(".json") or cfg.get("schemaVersion") == 1


def _shorthand(model):
    """True for a non-full model id (v2 wants full nomenclature, e.g. claude-sonnet-5)."""
    return isinstance(model, str) and not model.startswith("claude-")


def normalize(cfg):
    """Map a legacy v1 delegation block to the v2 identities-with-models shape.

    devModel -> identities.dev.models=[devModel]; reviewModel+prReviewModel ->
    identities.reviewer.models=[...] (deduped, order kept). Old identity objects
    keep name/email. Returns (normalized_cfg, warnings[]).
    """
    warnings = []
    deleg = cfg.get("delegation")
    if not isinstance(deleg, dict):
        return cfg, warnings

    dev_model = deleg.pop("devModel", None)
    review_model = deleg.pop("reviewModel", None)
    pr_review_model = deleg.pop("prReviewModel", None)
    if not any(m is not None for m in (dev_model, review_model, pr_review_model)):
        return cfg, warnings  # already v2 (no legacy model keys)

    identities = deleg.get("identities")
    if identities is False:
        # Explicit opt-out kept as-is; legacy models can't attach to a disabled roster.
        return cfg, warnings
    if not isinstance(identities, dict):
        identities = {}  # absent/null roster -> synthesize the default roles

    def with_models(role, models):
        models = [m for m in models if m]
        seen, deduped = set(), []
        for m in models:
            if m not in seen:
                seen.add(m)
                deduped.append(m)
        node = identities.get(role)
        if not isinstance(node, dict):
            node = {}
        if deduped and "models" not in node:
            node["models"] = deduped
        identities[role] = node

    if dev_model is not None:
        with_models("dev", [dev_model])
    if review_model is not None or pr_review_model is not None:
        with_models("reviewer", [review_model, pr_review_model])

    for m in (dev_model, review_model, pr_review_model):
        if _shorthand(m):
            warnings.append(
                f"legacy model id {m!r} is shorthand — v2 expects full nomenclature "
                "(e.g. claude-sonnet-5, claude-sonnet-5[1m])"
            )
            break

    deleg["identities"] = identities
    cfg["delegation"] = deleg
    return cfg, warnings


# --- per-spec files: .neural-network/specs/<id>.yaml -------------------------
# project.yaml holds CONFIGURATION; the work-plan (a spec's specPath,
# taskPrefix, epics, invariants, ...) lives one-file-per-spec next to it.
# The loader merges them into cfg["specs"] so consumers keep reading
# cfg.specs unchanged. Inline `specs:` in project.yaml is DEPRECATED but
# still honored when no spec files exist; the specs/ dir wins when both are
# present. A file's `id` defaults to its basename (core.yaml -> core).
SPECS_DIRNAME = "specs"


def _load_specs_dir(cfg_path):
    d = os.path.join(os.path.dirname(cfg_path), SPECS_DIRNAME)
    if not os.path.isdir(d):
        return None
    specs = []
    for name in sorted(os.listdir(d)):
        if not name.endswith((".yaml", ".yml")):
            continue
        doc = _parse(os.path.join(d, name))
        if isinstance(doc, dict):
            doc.setdefault("id", os.path.splitext(name)[0])
            specs.append(doc)
    return specs or None


# .neural-network/project.local.yaml — OPTIONAL machine-local overlay, gitignored
# (see local-state.manifest). Only the keys listed here are read from it,
# local winning over project.yaml; every other key in the local file is
# deliberately ignored so a gitignored file can never silently override
# committed configuration. Today the overlay carries exactly one thing:
# `compute` — the remote machines THIS clone has access to (written by
# remote-compute.py / the remote-compute skill; availability is per-machine,
# not per-repo, so it must never be committed).
LOCAL_OVERLAY_KEYS = ("compute",)


def _apply_local_overlay(cfg, cfg_path):
    lp = os.path.join(os.path.dirname(cfg_path), "project.local.yaml")
    if not os.path.exists(lp):
        return cfg  # missing file is the normal case, never an error
    local = _parse(lp)
    if isinstance(local, dict):
        for k in LOCAL_OVERLAY_KEYS:
            if k in local:
                cfg[k] = local[k]
    return cfg


def load_config(root=None, path=None, warn=True, for_path=None):
    """Load + normalize the config. None if no file. Raises ConfigError on parse error.

    `for_path` (repo-relative): deep-merge the nearest native nested anchor's
    partial config over the root config for work under that subtree.
    """
    p = path or find_config(root)
    if not p or not os.path.exists(p):
        return None
    cfg = _parse(p)
    if is_legacy(p, cfg):
        cfg, warnings = normalize(cfg)
        if warn:
            rel = os.path.basename(p)
            sys.stderr.write(
                f"DEPRECATION: {CONFIG_DIR}/{rel} (schemaVersion 1) is legacy — migrate to "
                f"{CONFIG_DIR}/project.yaml (schemaVersion 2); the setup-project skill converts it.\n"
            )
            for w in warnings:
                sys.stderr.write(f"  note: {w}\n")
    cfg = _apply_local_overlay(cfg, p)
    ext_specs = _load_specs_dir(p)
    if ext_specs is not None:
        cfg["specs"] = ext_specs  # specs/ dir is the source of truth over inline specs
    if for_path and not path:  # explicit `path` bypasses nesting (caller chose the file)
        anchor = anchor_for(root, for_path)
        if anchor:
            for name in ("project.yaml", "project.yml", "project.json"):
                fp = os.path.join(root or ".", anchor, CONFIG_DIR, name)
                if os.path.exists(fp):
                    fragment = _apply_local_overlay(_parse(fp), fp)
                    cfg = deep_merge(cfg, fragment)
                    break
    return cfg


# work.type / work.sync.mode / work.checkout: the only dotted paths with a
# script-side default resolved by `get` itself (so bash callers never
# special-case "key absent" -- config.py get work.type always prints a value
# when a config file exists). See work-mode.sh, which resolves the same set
# when NO config file exists at all (this map is only consulted once cfg is
# already loaded).
WORK_DEFAULTS = {
    "work.type": "pr",
    "work.sync.mode": "realtime",
    "work.checkout": "worktree",
}


def get_with_default(cfg, dotpath):
    """dig() a dotpath, falling back to WORK_DEFAULTS when the value is absent."""
    val = dig(cfg, dotpath)
    if val is None and dotpath in WORK_DEFAULTS:
        return WORK_DEFAULTS[dotpath]
    return val


def dig(cfg, dotpath):
    """Navigate a dot path; integer segments index lists. None if absent."""
    node = cfg
    for key in dotpath.split("."):
        if isinstance(node, dict):
            node = node.get(key)
        elif isinstance(node, list):
            try:
                node = node[int(key)]
            except (ValueError, IndexError):
                return None
        else:
            return None
        if node is None:
            return None
    return node


# --- surgical config writes (the ONE place that edits a config file) --------------
# YAML: a dependency-free line-level edit that changes ONLY the target key, leaving
# every other byte — comments, blank lines, flow styles, trailing newline — untouched.
# JSON (legacy): rewritten with json.dump (no comments to preserve).
_STEP = 4  # config indent unit


def _yaml_literal(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, list):
        return "[" + ", ".join(json.dumps(x, ensure_ascii=False) for x in v) + "]"
    if isinstance(v, (int, float)):
        return json.dumps(v)
    return json.dumps(v, ensure_ascii=False)  # string -> double-quoted scalar


def _indent_of(line):
    return len(line) - len(line.lstrip(" "))


def _is_key(line, key):
    s = line.strip()
    return s == key + ":" or s.startswith(key + ": ") or s.startswith(key + ":\t")


def _block_end(lines, start, parent_indent):
    for j in range(start, len(lines)):
        s = lines[j].strip()
        if s and not s.startswith("#") and _indent_of(lines[j]) <= parent_indent:
            return j
    return len(lines)


def _find_child(lines, lo, hi, key, parent_indent):
    child_indent = None
    for j in range(lo, hi):
        s = lines[j].strip()
        if not s or s.startswith("#"):
            continue
        ind = _indent_of(lines[j])
        if ind <= parent_indent:
            break
        if child_indent is None:
            child_indent = ind
        if ind == child_indent and _is_key(lines[j], key):
            return j
    return None


def _replace_value(lines, idx, value):
    ind = _indent_of(lines[idx])
    key = lines[idx].strip().split(":", 1)[0]
    end = idx + 1  # drop any block-style continuation (deeper-indented value lines)
    while end < len(lines):
        s = lines[end].strip()
        if not s or s.startswith("#") or _indent_of(lines[end]) <= ind:
            break
        end += 1
    return lines[:idx] + [f"{' ' * ind}{key}: {value}"] + lines[end:]


def _insert(lines, hi, remaining, parent_indent, value):
    pos = hi  # insert before any trailing blank lines (keeps the file's final newline last)
    while pos > 0 and lines[pos - 1].strip() == "":
        pos -= 1
    base = parent_indent + _STEP
    block = []
    for depth, k in enumerate(remaining):
        ind = base + depth * _STEP
        block.append(f"{' ' * ind}{k}: {value}" if depth == len(remaining) - 1 else f"{' ' * ind}{k}:")
    return lines[:pos] + block + lines[pos:]


def set_yaml_text(text, keys, value_literal):
    """Return `text` with the dotted `keys` set to the preformatted `value_literal`."""
    lines = text.split("\n")  # split/join by \n reproduces bytes exactly (incl. trailing newline)
    lo, hi, parent_indent = 0, len(lines), -_STEP
    for depth, key in enumerate(keys):
        idx = _find_child(lines, lo, hi, key, parent_indent)
        if idx is None:
            return "\n".join(_insert(lines, hi, keys[depth:], parent_indent, value_literal))
        if depth == len(keys) - 1:
            return "\n".join(_replace_value(lines, idx, value_literal))
        parent_indent = _indent_of(lines[idx])
        lo, hi = idx + 1, _block_end(lines, idx + 1, parent_indent)
    return text


def set_config(path, dotpath, value):
    """Set dotpath=value in the config file at `path`, preserving its format."""
    keys = dotpath.split(".")
    if path.endswith((".yaml", ".yml")):
        new_text = set_yaml_text(open(path).read(), keys, _yaml_literal(value))  # read BEFORE truncating
        with open(path, "w") as fh:
            fh.write(new_text)
    else:
        cfg = json.load(open(path))
        node = cfg
        for k in keys[:-1]:
            nxt = node.get(k)
            if not isinstance(nxt, dict):
                nxt = {}
                node[k] = nxt
            node = nxt
        node[keys[-1]] = value
        with open(path, "w") as fh:
            json.dump(cfg, fh, indent=4, ensure_ascii=False)
            fh.write("\n")


def _cli(argv):
    # --for <repo-relative path>: nested-anchor resolution for get/json (stripped
    # here so verb parsing below stays positional).
    for_path = None
    if "--for" in argv:
        i = argv.index("--for")
        if i + 1 >= len(argv):
            sys.stderr.write("config.py: --for requires a repo-relative path\n")
            return 2
        for_path = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if len(argv) < 2:
        sys.stderr.write("usage: config.py <root> {path|get <dot.path>|set <dot.path> <json-value>|json|anchors} [--for <path>]\n")
        return 2
    root, verb = argv[0], argv[1]
    if verb == "path":
        p = find_config(root)
        if p:
            print(p)
        return 0
    if verb == "anchors":
        for a in find_anchors(root):
            print(a)
        return 0
    if verb == "set":
        if len(argv) < 4:
            sys.stderr.write("usage: config.py <root> set <dot.path> <json-value>\n")
            return 2
        p = find_config(root)
        if not p or not os.path.exists(p):
            sys.stderr.write("config.py set: no config file found\n")
            return 3
        try:
            value = json.loads(argv[3])
        except ValueError as e:
            sys.stderr.write(f"config.py set: value must be JSON ({e})\n")
            return 2
        set_config(p, argv[2], value)
        return 0
    try:
        cfg = load_config(root, for_path=for_path)
    except ConfigError as e:
        sys.stderr.write(f"PREFLIGHT FAIL: {e} — STOP: fix the config, then re-run.\n")
        return 1
    if cfg is None:
        return 3  # no config file
    if verb == "get":
        if len(argv) < 3:
            sys.stderr.write("usage: config.py <root> get <dot.path>\n")
            return 2
        val = get_with_default(cfg, argv[2])
        if val is None:
            return 0
        if isinstance(val, (dict, list)):
            print(json.dumps(val))
        elif isinstance(val, bool):
            print("true" if val else "false")
        else:
            print(val)
        return 0
    if verb == "json":
        print(json.dumps(cfg, indent=2, ensure_ascii=False))
        return 0
    sys.stderr.write(f"config.py: unknown verb {verb!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
