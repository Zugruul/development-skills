#!/usr/bin/env python3
"""Validate a spec-workflow project config with actionable error messages.

Usage: validate-config.py <path-to-.claude/project.yaml (or legacy .json)>
Exit 0 = valid (prints a summary); exit 1 = invalid (prints every problem found).
YAML (schemaVersion 2) is the current format; legacy JSON (schemaVersion 1, with
the old delegation.devModel/reviewModel/prReviewModel keys) still validates as v1
with a deprecation line. Structural validation — stdlib + PyYAML.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config as C  # noqa: E402  (shared loader — reuse its shorthand-model detection)

errs = []

CODEX_CAPABILITIES = {"fast", "balanced", "deep-review", "large-context"}


def need(obj, key, typ, where):
    if key not in obj:
        errs.append(f"{where}: missing required key '{key}'")
        return None
    if typ and not isinstance(obj[key], typ):
        errs.append(f"{where}.{key}: expected {typ.__name__}, got {type(obj[key]).__name__}")
        return None
    return obj[key]


def _load(path):
    text = open(path).read()
    if path.endswith((".yaml", ".yml")):
        try:
            import yaml
        except ImportError:
            print("PREFLIGHT FAIL: PyYAML required — pip3 install pyyaml")
            sys.exit(1)
        return yaml.safe_load(text)
    return json.loads(text)


def main(path):
    try:
        cfg = _load(path)
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001
        print(f"INVALID: cannot parse {path}: {e}")
        return 1
    if not isinstance(cfg, dict):
        print(f"INVALID: {path}: top level must be a mapping")
        return 1

    # YAML is schemaVersion 2 (current); legacy .json is schemaVersion 1.
    legacy = path.endswith(".json")
    want_version = 1 if legacy else 2
    if cfg.get("schemaVersion") != want_version:
        errs.append(f"schemaVersion must be {want_version} (got {cfg.get('schemaVersion')!r})")

    proj = need(cfg, "project", dict, "$") or {}
    for k in ("name", "mainBranch", "branchPattern"):
        need(proj, k, str, "project")

    boards = need(cfg, "boards", list, "$") or []
    board_ids = set()
    for i, b in enumerate(boards):
        w = f"boards[{i}]"
        bid = need(b, "id", str, w)
        if bid in board_ids:
            errs.append(f"{w}: duplicate board id '{bid}'")
        board_ids.add(bid)
        for k in ("owner", "repo", "projectId"):
            need(b, k, str, w)
        need(b, "projectNumber", int, w)
        if b.get("provider") != "github-project":
            errs.append(f"{w}.provider must be 'github-project'")
        fields = need(b, "fields", dict, w) or {}
        for fname in ("status", "priority"):
            f = need(fields, fname, dict, f"{w}.fields") or {}
            need(f, "fieldId", str, f"{w}.fields.{fname}")
            opts = need(f, "options", dict, f"{w}.fields.{fname}") or {}
            if not opts:
                errs.append(f"{w}.fields.{fname}.options is empty")
        flow = need(b, "statusFlow", list, w) or []
        sopts = fields.get("status", {}).get("options", {})
        for st in flow:
            if sopts and st not in sopts:
                errs.append(f"{w}.statusFlow: '{st}' has no matching status option id")
        for v in ("PVT_replace_me", "PVTSSF_replace_me"):
            if v in json.dumps(b):
                errs.append(f"{w}: still contains template placeholder '{v}' — run 'board.sh fields' and fill real ids")

    specs = need(cfg, "specs", list, "$") or []
    prefixes = set()
    for i, s in enumerate(specs):
        w = f"specs[{i}]"
        need(s, "id", str, w)
        pref = need(s, "taskPrefix", str, w)
        if pref in prefixes:
            errs.append(f"{w}: duplicate taskPrefix '{pref}' (must be unique across specs)")
        prefixes.add(pref)
        if pref and not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", pref):
            errs.append(f"{w}.taskPrefix '{pref}' must be alphanumeric starting with a letter")
        bref = need(s, "board", str, w)
        if bref and bref not in board_ids:
            errs.append(f"{w}.board '{bref}' does not match any boards[].id")
        need(s, "specPath", str, w)
        epics = need(s, "epics", list, w) or []
        epic_ids = set()
        for j, e in enumerate(epics):
            ew = f"{w}.epics[{j}]"
            eid = need(e, "id", str, ew)
            if eid in epic_ids:
                errs.append(f"{ew}: duplicate epic id '{eid}'")
            epic_ids.add(eid)
            ranges = need(e, "taskRanges", list, ew) or []
            for r in ranges:
                if not (isinstance(r, list) and len(r) == 2 and all(isinstance(x, int) for x in r) and r[0] <= r[1]):
                    errs.append(f"{ew}.taskRanges: {r!r} must be [lo, hi] ints with lo<=hi")
        for j, e in enumerate(epics):
            for g in e.get("blockedBy", []):
                if g.get("epic") not in epic_ids:
                    errs.append(f"{w}.epics[{j}].blockedBy: unknown epic '{g.get('epic')}'")
                board = next((b for b in boards if b.get("id") == s.get("board")), None)
                if board and g.get("untilStatus") not in (board.get("statusFlow") or []):
                    errs.append(f"{w}.epics[{j}].blockedBy: untilStatus '{g.get('untilStatus')}' not in statusFlow")
        # overlapping ranges within a spec
        seen = {}
        for e in epics:
            for lo, hi in (r for r in e.get("taskRanges", []) if isinstance(r, list) and len(r) == 2):
                for (olo, ohi), oid in seen.items():
                    if lo <= ohi and olo <= hi:
                        errs.append(f"{w}: epic '{e.get('id')}' range [{lo},{hi}] overlaps epic '{oid}' [{olo},{ohi}]")
                seen[(lo, hi)] = e.get("id")

    cmds = need(cfg, "commands", dict, "$") or {}
    need(cmds, "gate", str, "commands")

    # delegation.identities: each role is null | dict | list-of-dicts; models are string lists.
    deleg = cfg.get("delegation")
    if isinstance(deleg, dict):
        idents = deleg.get("identities")
        if isinstance(idents, dict):
            for role, spec in idents.items():
                w = f"delegation.identities.{role}"
                variants = spec if isinstance(spec, list) else [spec]
                for i, v in enumerate(variants):
                    if v is None:
                        continue
                    if not isinstance(v, dict):
                        errs.append(f"{w}: each identity must be a mapping (name/email/models/covers)")
                        continue
                    models = v.get("models")
                    if isinstance(models, dict):
                        claude = models.get("claude")
                        if claude is not None and not (isinstance(claude, list) and all(isinstance(m, str) for m in claude)):
                            errs.append(f"{w}[{i}].models.claude must be a list of full model-id strings")
                        elif claude and not legacy:
                            for m in claude:
                                if C._shorthand(m):
                                    errs.append(f"{w}[{i}].models.claude: '{m}' is shorthand — v2 requires a full model-id (e.g. claude-sonnet-5, claude-sonnet-5[1m])")
                        codex = models.get("codex")
                        if codex is not None:
                            if not isinstance(codex, dict):
                                errs.append(f"{w}[{i}].models.codex must be a mapping")
                            else:
                                cap = codex.get("capability")
                                if cap is not None and cap not in CODEX_CAPABILITIES:
                                    errs.append(
                                        f"{w}[{i}].models.codex.capability: {cap!r} is not a recognized capability "
                                        f"(valid: {', '.join(sorted(CODEX_CAPABILITIES))})"
                                    )
                        unknown = set(models) - {"claude", "codex"}
                        if unknown:
                            errs.append(f"{w}[{i}].models: unknown key(s) {sorted(unknown)} (allowed: claude, codex)")
                    elif models is not None and not (isinstance(models, list) and all(isinstance(m, str) for m in models)):
                        errs.append(f"{w}[{i}].models must be a list of full model-id strings, or an object {{claude: [...], codex: {{capability: ...}}}}")
                    elif models and not legacy:
                        for m in models:
                            if C._shorthand(m):
                                errs.append(f"{w}[{i}].models: '{m}' is shorthand — v2 requires a full model-id (e.g. claude-sonnet-5, claude-sonnet-5[1m])")
                    covers = v.get("covers")
                    if covers is not None and not (isinstance(covers, list) and all(isinstance(c, str) for c in covers)):
                        errs.append(f"{w}[{i}].covers must be a list of path-glob strings")
        elif idents not in (None, False):
            errs.append("delegation.identities must be an object of roles, or false to disable all")

    # methodology.feedback: true (shorthand) | {enabled, feed, roles, autoTriage}
    feedback = (cfg.get("methodology") or {}).get("feedback") if isinstance(cfg.get("methodology"), dict) else None
    if feedback not in (None, True, False):
        if not isinstance(feedback, dict):
            errs.append("methodology.feedback must be true, false, or a mapping {enabled, feed, roles, autoTriage}")
        else:
            allowed = {"enabled", "feed", "roles", "autoTriage"}
            for k in feedback:
                if k not in allowed:
                    errs.append(f"methodology.feedback.{k}: unknown key (allowed: {sorted(allowed)})")
            if "enabled" in feedback and not isinstance(feedback["enabled"], bool):
                errs.append("methodology.feedback.enabled must be a boolean")
            if "feed" in feedback and not isinstance(feedback["feed"], str):
                errs.append("methodology.feedback.feed must be a string path")
            elif "feed" in feedback and feedback["feed"]:
                feed_path = feedback["feed"]
                if os.path.isabs(feed_path):
                    errs.append(f"methodology.feedback.feed must be repo-relative (got an absolute path: {feed_path!r})")
                else:
                    norm = os.path.normpath(feed_path)
                    if norm == os.pardir or norm.startswith(os.pardir + os.sep):
                        errs.append(f"methodology.feedback.feed must not escape the repo root (got {feed_path!r})")
            if "roles" in feedback and not (isinstance(feedback["roles"], list) and all(isinstance(r, str) for r in feedback["roles"])):
                errs.append("methodology.feedback.roles must be a list of strings")
            if "autoTriage" in feedback and not isinstance(feedback["autoTriage"], bool):
                errs.append("methodology.feedback.autoTriage must be a boolean")

    # methodology.maxInProgress / graduationThreshold: positive integers.
    # Mirrors schemas/project-config.schema.json's {type: integer, minimum: 1}
    # for these two keys — keep both in sync if either changes.
    methodology = cfg.get("methodology")
    if isinstance(methodology, dict):
        for key in ("maxInProgress", "graduationThreshold"):
            if key not in methodology:
                continue
            val = methodology[key]
            if isinstance(val, bool) or not isinstance(val, int):
                errs.append(f"methodology.{key}: must be an integer >= 1 (got {val!r})")
            elif val < 1:
                errs.append(f"methodology.{key}: must be >= 1 (got {val})")

    # methodology.entityKinds: object mapping kind -> role, both strings (#163).
    if isinstance(methodology, dict) and "entityKinds" in methodology:
        ek = methodology["entityKinds"]
        if not isinstance(ek, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in ek.items()):
            errs.append("methodology.entityKinds must be an object mapping kind (string) -> role (string)")

    # neuralView: visualization-only knobs (#163). Absent == today's defaults.
    neural_view = cfg.get("neuralView")
    if neural_view is not None:
        if not isinstance(neural_view, dict):
            errs.append("neuralView: must be a mapping")
        else:
            for k in neural_view:
                if k != "entityEdgeColor":
                    errs.append(f"neuralView.{k}: unknown key (allowed: ['entityEdgeColor'])")
            if "entityEdgeColor" in neural_view and not isinstance(neural_view["entityEdgeColor"], str):
                errs.append("neuralView.entityEdgeColor must be a string (\"gradient\" or a CSS color)")

    # work: PR-less local delivery (type) + board-sync batching policy (sync).
    # Absent == {type: pr}; sync is only meaningful (and only accepted) under
    # type: local -- see schemas/project-config.schema.json's `work` object.
    work = cfg.get("work")
    if work is not None:
        if not isinstance(work, dict):
            errs.append("work: must be a mapping with 'type' and optional 'sync'")
        else:
            for k in work:
                if k not in ("type", "sync"):
                    errs.append(f"work.{k}: unknown key (allowed: ['sync', 'type'])")
            wtype = work.get("type", "pr")
            if "type" in work and work["type"] not in ("pr", "local"):
                errs.append(f"work.type must be 'pr' or 'local' (got {work.get('type')!r})")
            sync = work.get("sync")
            if sync is not None:
                if wtype != "local":
                    errs.append("work.sync is only valid with work.type: local")
                if not isinstance(sync, dict):
                    errs.append("work.sync: must be a mapping with 'mode'")
                else:
                    for k in sync:
                        if k != "mode":
                            errs.append(f"work.sync.{k}: unknown key (allowed: ['mode'])")
                    modes = ("realtime", "task-close", "session-end", "manual")
                    if "mode" in sync and sync["mode"] not in modes:
                        errs.append(f"work.sync.mode must be one of {', '.join(modes)} (got {sync.get('mode')!r})")

    if errs:
        print(f"INVALID: {len(errs)} problem(s) in {path}:")
        for e in errs:
            print(f"  - {e}")
        return 1

    print(f"VALID: {path}")
    if legacy:
        print("  NOTE: legacy schemaVersion 1 JSON — still accepted, but migrate to "
              ".claude/project.yaml (schemaVersion 2); the setup-project skill converts it.")
    print(f"  project: {proj.get('name')}  main={proj.get('mainBranch')}  branches={proj.get('branchPattern')}")
    for b in boards:
        print(f"  board '{b['id']}': {b['repo']} project #{b['projectNumber']}  flow: {' -> '.join(b['statusFlow'])}")
    for s in specs:
        seq = " -> ".join(e["id"] for e in s["epics"])
        print(f"  spec '{s['id']}' [{s['taskPrefix']}] on board '{s['board']}': {s['specPath']}  epics: {seq}")
    print(f"  gate: {cmds.get('gate')}")
    return 0


if __name__ == "__main__":
    default = ".claude/project.yaml" if os.path.exists(".claude/project.yaml") else ".claude/project.json"
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else default))
