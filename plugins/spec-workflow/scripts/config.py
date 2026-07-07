#!/usr/bin/env python3
"""config.py — the ONE shared config loader for the spec-workflow plugin.

Consumer repos declare config in `.claude/project.yaml` (schemaVersion 2). This
module finds it, parses it (PyYAML), and normalizes legacy `.claude/project.json`
(schemaVersion 1) to the v2 shape in memory so every script sees one shape.

Library:
    load_config(root=None, path=None) -> dict | None
        Resolution order: explicit `path` > $PROJECT_CONFIG > <root>/.claude/project.yaml
        > <root>/.claude/project.json. Returns None when no config file exists.
        Legacy json (or schemaVersion 1) is normalized to v2 and emits ONE
        deprecation line to stderr. Raises ConfigError on parse failure. If a
        .yaml file is present but PyYAML is not installed, prints the PREFLIGHT
        FAIL line and exits 1 (a hard environment failure, by design).
    find_config(root=None) -> str | None    # resolved path, no parse

CLI (for bash callers):
    config.py <root> path              # print resolved config path (empty if none)
    config.py <root> get <dot.path>    # print a value (empty if absent); list/dict -> JSON
    config.py <root> json              # print the whole normalized config as JSON
Dot paths index lists by integer segment, e.g. delegation.identities.dev.0.models.1.
"""
import json
import os
import sys

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
    base = os.path.join(root or ".", ".claude")
    for name in ("project.yaml", "project.yml", "project.json"):
        p = os.path.join(base, name)
        if os.path.exists(p):
            return p
    return None


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


def load_config(root=None, path=None, warn=True):
    """Load + normalize the config. None if no file. Raises ConfigError on parse error."""
    p = path or find_config(root)
    if not p or not os.path.exists(p):
        return None
    cfg = _parse(p)
    if is_legacy(p, cfg):
        cfg, warnings = normalize(cfg)
        if warn:
            rel = os.path.basename(p)
            sys.stderr.write(
                f"DEPRECATION: .claude/{rel} (schemaVersion 1) is legacy — migrate to "
                ".claude/project.yaml (schemaVersion 2); the setup-project skill converts it.\n"
            )
            for w in warnings:
                sys.stderr.write(f"  note: {w}\n")
    return cfg


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


def _cli(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: config.py <root> {path|get <dot.path>|json}\n")
        return 2
    root, verb = argv[0], argv[1]
    if verb == "path":
        p = find_config(root)
        if p:
            print(p)
        return 0
    try:
        cfg = load_config(root)
    except ConfigError as e:
        sys.stderr.write(f"PREFLIGHT FAIL: {e} — STOP: fix the config, then re-run.\n")
        return 1
    if cfg is None:
        return 3  # no config file
    if verb == "get":
        if len(argv) < 3:
            sys.stderr.write("usage: config.py <root> get <dot.path>\n")
            return 2
        val = dig(cfg, argv[2])
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
