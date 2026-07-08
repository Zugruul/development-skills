#!/usr/bin/env python3
"""feedback.py — structured process feedback for the spec-workflow loop.

Feedback is a per-ITERATION process signal (what slowed this build-loop
iteration, which skill/protocol caused friction) — distinct from a retro
lesson (a per-PR insight minted into a role's brain). The feed is retro
INPUT: items routed `brain-note` are minted by the existing retro protocol
(`brain.py mint`), never by this script.

Config — `methodology.feedback` in `.claude/project.yaml`:
    feedback: true                    # shorthand for the defaults below
    feedback:                         # expanded form
        enabled: true
        feed: .claude/feedbacks/feed.yaml  # relative to repo root
        roles: [orchestrator]
        autoTriage: false             # routing creates board items -> explicit consent
Absent key = disabled. Unknown keys are rejected by validate-config.py.

The feed lives under `.claude/feedbacks/` (plural) — a tracked, orchestrator-
mediated archive: committed and pushed alongside code by default (opt out via
the repo's own .gitignore), and never read or written by dev/reviewer
subagents, same isolation as the identity brains. See the `feedback` skill
and plugin README for the archive statement; nothing in this module enforces
subagent access — that's a docs/process contract, not a runtime one.

Legacy-path migration guard: `.claude/feedback/` (singular) was the old,
gitignored home of the feed. WHEN the DEFAULT feed path is in effect (no
explicit `methodology.feedback.feed` override) AND the legacy path
`.claude/feedback/feed.yaml` exists AND the new default path does not, every
subcommand that touches the feed (emit/pending/route/status) refuses with a
migration message instead of silently starting a fresh, empty archive that
would orphan the old history. An explicit `feed` override bypasses the guard
entirely — the override is trusted at face value.

Feed format — `.claude/feedbacks/feed.yaml` is a sequence of `---`-separated
YAML documents, one per emitted record:

    schemaVersion: 1
    kind: loop-feedback
    ts: <ISO 8601, an input — never datetime.now() in tested paths>
    iteration:
        task: <task id>
        outcome: merged | in-review | blocked | abandoned
        reviewRounds: <int>
    source:
        role: <dev|reviewer|orchestrator|...>
        model: <full model id>
    items:
      - category: worked-well | friction | incident | recommendation
        area: board | briefing | review | merge | permissions | concurrency
              | testing | docs | brains | other
        component: <plugin path>            # optional
        severity: high | medium | low
        summary: <one line, project-agnostic>
        detail: <free text, MAY contain project specifics>   # optional
        evidence: [<project refs>]                            # optional
        generalized: <REQUIRED project-agnostic restatement — the ONLY text
                      allowed to leave the feed; '' marks the item local-only,
                      routable only as `ignore`>
        proposal: {target: ..., change: ...}                  # optional
        routing: {action: backlog|brain-note|graduate|upstream|ignore, ref: ...}
                                                                # filled at triage

Generalization contract (enforced at emit time; re-checked at triage): when
`generalized` is non-empty, neither it nor `summary` may contain the
iteration's own task id or a `#<digits>` issue/PR reference — restate
agnostically, or clear `generalized` to mark the item local-only. This is a
textual, not semantic, check: ordinary markdown like a `#1` heading in
`summary`/`generalized` also trips it — a safe failure mode (an over-eager
rejection, never a leak), but worth knowing if a clean-looking item bounces.

`ts` also doubles as the record's identity for `route` — two records sharing
a `ts` make routing ambiguous, so `emit` rejects a `ts` that already exists
in the feed.

Concurrency: the feed assumes a single writer (the orchestrator process,
serially) — there is no file locking. Concurrent `emit`/`route` calls against
the same feed can race.

CLI:
    feedback.py <root> emit <record.yaml>                 # validate + append
    feedback.py <root> pending                            # unrouted items
    feedback.py <root> route <ts> <item-index> <action> <ref>
    feedback.py <root> status                             # one-line summary
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config as C  # noqa: E402

CATEGORIES = {"worked-well", "friction", "incident", "recommendation"}
AREAS = {"board", "briefing", "review", "merge", "permissions", "concurrency", "testing", "docs", "brains", "other"}
SEVERITIES = {"high", "medium", "low"}
OUTCOMES = {"merged", "in-review", "blocked", "abandoned"}
ACTIONS = {"backlog", "brain-note", "graduate", "upstream", "ignore"}

DEFAULTS = {
    "enabled": False,
    "feed": ".claude/feedbacks/feed.yaml",
    "roles": ["orchestrator"],
    "autoTriage": False,
}

LEGACY_FEED = ".claude/feedback/feed.yaml"

_ISSUE_REF_RE = re.compile(r"#\d+")
_SEP = "---\n"


def _yaml():
    try:
        import yaml
        return yaml
    except ImportError:
        sys.stderr.write(C.YAML_MISSING + "\n")
        sys.exit(1)


def parse_feedback_cfg(cfg):
    """methodology.feedback (bool shorthand or expanded dict) -> the four-key dict.
    Also returns whether `feed` was an explicit override (vs the default),
    since the legacy-path migration guard only applies to the default path."""
    raw = C.dig(cfg, "methodology.feedback") if cfg else None
    out = dict(DEFAULTS)
    feed_overridden = False
    if raw is True:
        out["enabled"] = True
    elif isinstance(raw, dict):
        for k in ("enabled", "feed", "roles", "autoTriage"):
            if k in raw:
                out[k] = raw[k]
        feed_overridden = "feed" in raw
    return out, feed_overridden


def _legacy_guard_error(root, fcfg, feed_overridden):
    """None if OK to proceed; else the migration error message.
    Only fires for the DEFAULT feed path: an explicit override is trusted
    as-is, never second-guessed against the legacy location."""
    if feed_overridden:
        return None
    new_path = os.path.join(root, fcfg["feed"])
    legacy_path = os.path.join(root, LEGACY_FEED)
    if os.path.exists(legacy_path) and not os.path.exists(new_path):
        return (
            f"ERROR: legacy feedback feed found at {LEGACY_FEED} but the new default "
            f"path {fcfg['feed']} does not exist — refusing to start a fresh feed and "
            f"orphan the archive. migration: `mv {os.path.dirname(LEGACY_FEED)} "
            f"{os.path.dirname(fcfg['feed'])}` and drop the `{os.path.dirname(LEGACY_FEED)}/` "
            "line from .gitignore."
        )
    return None


def _feed_path(root, fcfg):
    """Resolve the feed path, refusing to leave the repo root (defense in depth —
    validate-config.py already rejects absolute/../ paths, but a config that
    bypassed validation must not make this script write outside root either)."""
    joined = os.path.join(root, fcfg["feed"])
    root_real = os.path.realpath(root)
    feed_real = os.path.realpath(joined)
    if os.path.commonpath([root_real, feed_real]) != root_real:
        return None
    return joined


def _project_specific_refs(text, task_id):
    hits = []
    if task_id and task_id in text:
        hits.append(task_id)
    hits.extend(_ISSUE_REF_RE.findall(text))
    return hits


def validate_record(rec):
    """Return a list of error strings; empty = valid."""
    errs = []
    if not isinstance(rec, dict):
        return ["record must be a mapping"]
    if rec.get("schemaVersion") != 1:
        errs.append(f"schemaVersion must be 1 (got {rec.get('schemaVersion')!r})")
    if rec.get("kind") != "loop-feedback":
        errs.append(f"kind must be 'loop-feedback' (got {rec.get('kind')!r})")
    if not rec.get("ts"):
        errs.append("ts is required")

    task_id = ""
    it = rec.get("iteration")
    if not isinstance(it, dict):
        errs.append("iteration must be a mapping")
    else:
        task_id = it.get("task") or ""
        if not task_id:
            errs.append("iteration.task is required")
        if it.get("outcome") not in OUTCOMES:
            errs.append(f"iteration.outcome must be one of {sorted(OUTCOMES)} (got {it.get('outcome')!r})")
        if not isinstance(it.get("reviewRounds"), int) or isinstance(it.get("reviewRounds"), bool):
            errs.append("iteration.reviewRounds must be an integer")

    src = rec.get("source")
    if not isinstance(src, dict) or not src.get("role") or not src.get("model"):
        errs.append("source.role and source.model are required")

    items = rec.get("items")
    if not isinstance(items, list) or not items:
        errs.append("items must be a non-empty list")
        items = []
    for i, item in enumerate(items):
        w = f"items[{i}]"
        if not isinstance(item, dict):
            errs.append(f"{w} must be a mapping")
            continue
        if item.get("category") not in CATEGORIES:
            errs.append(f"{w}.category must be one of {sorted(CATEGORIES)} (got {item.get('category')!r})")
        if item.get("area") not in AREAS:
            errs.append(f"{w}.area must be one of {sorted(AREAS)} (got {item.get('area')!r})")
        if item.get("severity") not in SEVERITIES:
            errs.append(f"{w}.severity must be one of {sorted(SEVERITIES)} (got {item.get('severity')!r})")
        if not item.get("summary"):
            errs.append(f"{w}.summary is required")
        if "generalized" not in item:
            errs.append(f"{w}.generalized is required (use '' to mark the item local-only)")
        else:
            gen = item.get("generalized") or ""
            if gen:
                text = f"{item.get('summary', '')} {gen}"
                hits = _project_specific_refs(text, task_id)
                if hits:
                    errs.append(
                        f"{w}.generalized/summary contains project-specific reference(s) {hits} — "
                        "restate agnostically (drop issue/PR numbers and the task id), or clear "
                        "generalized to mark the item local-only"
                    )
        routing = item.get("routing")
        if routing is not None and (not isinstance(routing, dict) or routing.get("action") not in ACTIONS):
            errs.append(f"{w}.routing.action must be one of {sorted(ACTIONS)}")
    return errs


def _load_feed(path):
    if not os.path.exists(path):
        return []
    yaml = _yaml()
    with open(path) as fh:
        return [d for d in yaml.safe_load_all(fh) if d]


def _dump_all(docs):
    yaml = _yaml()
    return _SEP.join(yaml.safe_dump(d, sort_keys=False, default_flow_style=False, allow_unicode=True) for d in docs)


def _unrouted(rec):
    for i, item in enumerate(rec.get("items", [])):
        routing = item.get("routing")
        if not routing or not routing.get("action"):
            yield i, item


def cmd_emit(root, record_path):
    yaml = _yaml()
    try:
        with open(record_path) as fh:
            rec = yaml.safe_load(fh)
    except Exception as e:  # noqa: BLE001
        print(f"INVALID: cannot parse {record_path}: {e}")
        return 1
    errs = validate_record(rec)
    if errs:
        for e in errs:
            print(f"INVALID: {e}")
        return 1

    cfg = C.load_config(root, warn=False)
    fcfg, feed_overridden = parse_feedback_cfg(cfg)
    guard_err = _legacy_guard_error(root, fcfg, feed_overridden)
    if guard_err:
        print(guard_err)
        return 1
    feed_path = _feed_path(root, fcfg)
    if feed_path is None:
        print(f"ERROR: methodology.feedback.feed {fcfg['feed']!r} resolves outside the repo root — refusing to write")
        return 1
    existing = _load_feed(feed_path)
    if any(r.get("ts") == rec.get("ts") for r in existing):
        print(f"INVALID: ts {rec.get('ts')!r} already exists in the feed — routing would become ambiguous; use a distinct ts")
        return 1

    os.makedirs(os.path.dirname(feed_path), exist_ok=True)
    doc_text = yaml.safe_dump(rec, sort_keys=False, default_flow_style=False, allow_unicode=True)
    exists = os.path.exists(feed_path) and os.path.getsize(feed_path) > 0
    with open(feed_path, "a") as fh:
        if exists:
            fh.write(_SEP)
        fh.write(doc_text)
    print(f"OK: emitted {len(rec.get('items', []))} item(s) -> {feed_path}")
    return 0


def cmd_pending(root):
    cfg = C.load_config(root, warn=False)
    fcfg, feed_overridden = parse_feedback_cfg(cfg)
    guard_err = _legacy_guard_error(root, fcfg, feed_overridden)
    if guard_err:
        print(guard_err)
        return 1
    feed_path = _feed_path(root, fcfg)
    if feed_path is None:
        print(f"ERROR: methodology.feedback.feed {fcfg['feed']!r} resolves outside the repo root")
        return 1
    for rec in _load_feed(feed_path):
        ts = rec.get("ts", "")
        for i, item in _unrouted(rec):
            print(f"{ts}\t{i}\t{item.get('category', '')}\t{item.get('severity', '')}\t{item.get('summary', '')}")
    return 0


def cmd_route(root, ts, idx_str, action, ref):
    if action not in ACTIONS:
        print(f"ERROR: unknown routing action {action!r} — must be one of {sorted(ACTIONS)}")
        return 1
    try:
        idx = int(idx_str)
    except ValueError:
        print(f"ERROR: item-index must be an integer (got {idx_str!r})")
        return 1

    cfg = C.load_config(root, warn=False)
    fcfg, feed_overridden = parse_feedback_cfg(cfg)
    guard_err = _legacy_guard_error(root, fcfg, feed_overridden)
    if guard_err:
        print(guard_err)
        return 1
    feed_path = _feed_path(root, fcfg)
    if feed_path is None:
        print(f"ERROR: methodology.feedback.feed {fcfg['feed']!r} resolves outside the repo root")
        return 1
    docs = _load_feed(feed_path)
    matches = [i for i, rec in enumerate(docs) if rec.get("ts") == ts]
    if len(matches) > 1:
        print(f"ERROR: ambiguous ts {ts!r} — {len(matches)} records in the feed share it; "
              "fix the feed (unique ts per record) before routing")
        return 1
    if not matches:
        print(f"ERROR: no record with ts {ts!r} in {feed_path}")
        return 1

    rec = docs[matches[0]]
    items = rec.get("items", [])
    if not (0 <= idx < len(items)):
        print(f"ERROR: item index {idx} out of range for record {ts}")
        return 1
    prior = (items[idx].get("routing") or {}).get("action")
    items[idx]["routing"] = {"action": action, "ref": ref}
    with open(feed_path, "w") as fh:
        fh.write(_dump_all(docs))
    suffix = f" (was: {prior})" if prior else ""
    print(f"OK: routed {ts} item {idx} -> {action} {ref}{suffix}")
    return 0


def cmd_status(root):
    cfg = C.load_config(root, warn=False)
    fcfg, feed_overridden = parse_feedback_cfg(cfg)
    guard_err = _legacy_guard_error(root, fcfg, feed_overridden)
    if guard_err:
        print(guard_err)
        return 1
    feed_path = _feed_path(root, fcfg)
    if feed_path is None:
        print(f"ERROR: methodology.feedback.feed {fcfg['feed']!r} resolves outside the repo root")
        return 1
    pending = sum(1 for rec in _load_feed(feed_path) for _ in _unrouted(rec))
    state = "enabled" if fcfg["enabled"] else "disabled"
    print(f"feedback: {state} feed={fcfg['feed']} pending={pending}")
    return 0


def _cli(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: feedback.py <root> {emit <record.yaml>|pending|route <ts> <idx> <action> <ref>|status}\n")
        return 2
    root, verb = argv[0], argv[1]
    if verb == "emit":
        if len(argv) < 3:
            sys.stderr.write("usage: feedback.py <root> emit <record.yaml>\n")
            return 2
        return cmd_emit(root, argv[2])
    if verb == "pending":
        return cmd_pending(root)
    if verb == "route":
        if len(argv) < 6:
            sys.stderr.write("usage: feedback.py <root> route <record-ts> <item-index> <action> <ref>\n")
            return 2
        return cmd_route(root, argv[2], argv[3], argv[4], argv[5])
    if verb == "status":
        return cmd_status(root)
    sys.stderr.write(f"feedback.py: unknown verb {verb!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
