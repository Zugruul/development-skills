"""capability.yaml schema + version negotiation (SPEC-ASSISTANT.md §11.1, §11.6, AST-060).

Per §11.1 a skill directory may carry a capability.yaml shaped
`{version, provisioning: {check, ttlSeconds}, permissions, invoke}`. Per
§11.6 `version` is checked against the engine's supported range and an
out-of-range (or otherwise malformed) capability.yaml is
unavailable-with-reason -- it is NEVER best-effort executed. This module
validates STRUCTURE + version only: it does not run `provisioning.check`
(AST-062), does not execute `invoke` (AST-063/AST-064), and does not compile
the per-turn roster (AST-061) -- those are later E6 tasks layered on top of
the `Capability`/`CapabilityError` values this module returns.

Library:
    SUPPORTED_VERSION_RANGE -- (lo, hi) inclusive `version` range the engine
        currently accepts. v1 ships exactly one supported version (1, 1);
        the range shape is future-proofing for §11.6's "supported range"
        wording, not present multi-version support.

    validate_capability(capability, where="capability.yaml") -> list[str]
        Structural validation of one parsed capability.yaml mapping.
        Returns a list of path-precise error strings (empty list == valid).
        Never raises on a malformed mapping -- matches
        `assistant.config.validate_assistant`'s check/record/continue style
        so callers can extend errs in place. Does NOT check `version`
        against SUPPORTED_VERSION_RANGE -- that is load_capability's job,
        since an out-of-range version is a distinct failure reason
        (unsupported, not malformed) per §11.6.

    Capability(version, provisioning, permissions, invoke) -- namedtuple,
        a structurally valid, version-supported capability.yaml.

    CapabilityError(reason) -- namedtuple, the "unavailable-with-reason"
        sentinel §11.6 requires: a human-readable reason string, nothing
        else. Never raised -- always returned.

    load_capability(skill_dir) -> Capability | CapabilityError
        Reads `<skill_dir>/capability.yaml`, validates its structure, then
        checks `version` against SUPPORTED_VERSION_RANGE. Any failure
        (unreadable file, unparseable YAML, malformed structure,
        out-of-range version) returns a CapabilityError -- this function
        never raises and never attempts to execute anything the capability
        declares.

AST-061 (SPEC-ASSISTANT.md Sec11.3, issue #336, docs/design/ast-E6.md) adds
the compiled per-turn index + bounded, relevance-filtered roster on top of
the schema/version-negotiation library above:

    CapabilityIndexEntry(name, one_liner, keywords, embedding, enabled,
        provisioned_ok, unavailable_reason) -- one compiled skill. Only
        skills that are BOTH enabled (Sec11.2) and version-compatible
        (Sec11.6, `load_capability` above) ever get an entry at all --
        disabled or version-incompatible skills are invisible: no entry,
        no roster, no prompt, never executed (design doc's "two
        invisibility tiers" decision). `provisioned_ok`/`unavailable_reason`
        model AST-062's provisioning-check outcome via an injectable
        `provisioning_checker` seam on `compile_index` -- defaulting to
        `assistant.provisioning.real_provisioning_checker` (AST-062, issue
        #337: a TTL-cached checker that actually runs `provisioning.check`
        via `adapters.invoke_cli`, imported lazily inside `compile_index`
        so this module stays a pure library with no subprocess dependency
        at import time). Tests (and any caller wanting a hermetic/
        synthetic outcome) override `provisioning_checker` explicitly;
        that seam itself is unchanged from AST-061.

    CapabilityIndex(entries) -- an immutable snapshot (a tuple of
        CapabilityIndexEntry, sorted by name for deterministic iteration)
        produced by ONE `compile_index` pass. `roster_for_turn` only ever
        READS an already-compiled CapabilityIndex -- it never compiles, so
        a per-turn roster read stays lock-cheap (Sec11.3: "never per-turn"
        recompute; Sec17 turns never block on index refresh).

    compile_index(skills_root, assistant_cfg, provisioning_checker=None,
        embed_fn=None) -> CapabilityIndex
        One pass over every immediate subdirectory of `skills_root`
        (`.claude/skills/<name>/`, Sec11.1) carrying a `capability.yaml`:
        enablement (`assistant_cfg["capabilities"][name]["enabled"]`,
        default False/absent -- Sec11.2) THEN version negotiation
        (`load_capability`, Sec11.6) THEN provisioning
        (`provisioning_checker(name, capability, skill_dir) ->
        (provisioned_ok, unavailable_reason)`, defaults to always-ok).
        `one_liner`/`keywords` are read from the skill's own `SKILL.md`
        frontmatter `description:` (the same frontmatter shape every
        installed skill in this repo already carries -- see
        plugins/*/skills/*/SKILL.md); a skill with no SKILL.md (or no
        `description`) still gets an entry, just with an empty one-liner
        and no keywords, never a compile failure. `embedding` is computed
        in ONE batched pass over every entry's `one_liner + " " +
        keywords` text via `embed_fn` (default: a lazy, degrading wrapper
        around brain.py's existing embeddings capability, `brain.
        _embed_texts` -- MEM-03x's ONNX venv capability, reused rather
        than re-implemented); when the embeddings capability is
        unavailable at runtime EVERY entry's `embedding` is `None`
        (never a crash, never a blocked turn -- Sec17) and
        `roster_for_turn` degrades to deterministic keyword-overlap
        scoring for that whole index.

    Query(keywords, embedding) -- a per-turn query representation built by
        `embed_query(text, embed_fn=None)`: extracted keywords always
        computed (cheap, pure), embedding computed via the SAME embed_fn
        seam as `compile_index` (None on any failure/unavailability).

    AskInsteadOfGuess(reason) -- the sentinel `roster_for_turn` returns
        instead of a list when the top-ranked candidates are TIED or the
        best score is below `LOW_CONFIDENCE_THRESHOLD` (see that function's
        docstring for the exact, deterministic rule) -- the turn pipeline
        (turns.py) reads this as "ask instead of guess" (Sec11.3) rather
        than silently picking a candidate.

    roster_for_turn(index, query, top_n) -> list[CapabilityIndexEntry] |
        AskInsteadOfGuess
        Relevance-filtered, HARD-capped top-`top_n` read of an already-
        compiled `index` -- never compiles, never does I/O (the embedding
        hop, if any, already happened when `query` was built via
        `embed_query`). See the function's own docstring for the precise
        scoring/tie/low-confidence rule.

AST-065 (SPEC-ASSISTANT.md Sec11.2, Sec17.2, issue #340, docs/design/
ast-E6.md) closes enablement gating end to end on top of the above:

    is_enabled(name, assistant_cfg) -> bool
        Sec11.2's enablement rule, extracted out of `compile_index` into
        its own function so `compile_index`'s index-compile-time filter
        and `invoke_capability`'s execution-time gate share ONE rule.

    _merge_provisioning_override(base_provisioning, override) ->
        provisioning dict
        Sec11.2 "project.yaml provisioning overrides localize the skill's
        defaults": `compile_index` now field-merges an enabled
        capability's `assistant.capabilities.<name>.provisioning`
        (project.yaml) over the skill's shipped capability.yaml
        `provisioning` block before running the provisioning check --
        see the function's own docstring for the exact merge rule and a
        flagged alternative reading this task's report also documents.

    CapabilityDisabledError(Exception), invoke_capability(name,
        capability, params, assistant_cfg, *, timeout=None, env=None,
        cwd=None)
        Sec17.2 "a disabled capability is never invoked by the engine":
        the single choke point a NAMED capability's invocation must pass
        through, gating on `is_enabled` before dispatching to
        `adapters.invoke_argv`/`invoke_mcp` (auto-detected from
        `capability.invoke`'s exec/mcp shape). See the function's own
        docstring for why the gate lives here rather than inside
        `adapters.py` itself (a flagged design call).
"""
import collections
import os
import re

SUPPORTED_VERSION_RANGE = (1, 1)

_TOP_LEVEL_KEYS = {"version", "provisioning", "permissions", "invoke"}

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
CapabilityError = collections.namedtuple("CapabilityError", ["reason"])


def _need(obj, key, typ, where, errs):
    if key not in obj:
        errs.append(f"{where}: missing required key '{key}'")
        return None
    val = obj[key]
    if typ and not isinstance(val, typ):
        errs.append(f"{where}.{key}: expected {typ.__name__}, got {type(val).__name__}")
        return None
    return val


def _check_argv(argv, where, errs):
    if not isinstance(argv, list) or not argv:
        errs.append(f"{where}: must be a non-empty argv array")
        return
    for i, arg in enumerate(argv):
        if not isinstance(arg, str):
            errs.append(f"{where}[{i}]: must be a string (got {type(arg).__name__})")


def _check_provisioning(prov, where, errs):
    check = _need(prov, "check", list, where, errs)
    if check is not None:
        _check_argv(check, f"{where}.check", errs)
    ttl = _need(prov, "ttlSeconds", int, where, errs)
    if ttl is not None and isinstance(ttl, bool):
        errs.append(f"{where}.ttlSeconds: expected int, got bool")


def _check_permissions(perms, where, errs):
    if not isinstance(perms, list):
        errs.append(f"{where}: must be a list")
        return
    for i, p in enumerate(perms):
        if not isinstance(p, str):
            errs.append(f"{where}[{i}]: must be a string (got {type(p).__name__})")


def _check_invoke(invoke, where, errs):
    has_exec = "exec" in invoke
    has_mcp = "mcp" in invoke
    if not has_exec and not has_mcp:
        errs.append(f"{where}: must have one of 'exec' or 'mcp' (§11.5, §11.7)")
        return
    if has_exec and has_mcp:
        errs.append(f"{where}: must have exactly one of 'exec' or 'mcp', got both")
        return
    if has_exec:
        _check_argv(invoke["exec"], f"{where}.exec", errs)
    else:
        if not isinstance(invoke["mcp"], dict):
            errs.append(f"{where}.mcp: must be a mapping")


def validate_capability(capability, where="capability.yaml"):
    errs = []
    if not isinstance(capability, dict):
        errs.append(f"{where}: must be a mapping")
        return errs

    for k in capability:
        if k not in _TOP_LEVEL_KEYS:
            errs.append(f"{where}.{k}: unknown key (allowed: {sorted(_TOP_LEVEL_KEYS)})")

    if "version" in capability:
        v = capability["version"]
        if isinstance(v, bool) or not isinstance(v, int):
            errs.append(f"{where}.version: must be an integer (got {v!r})")
    else:
        errs.append(f"{where}: missing required key 'version'")

    prov = _need(capability, "provisioning", dict, where, errs)
    if prov is not None:
        _check_provisioning(prov, f"{where}.provisioning", errs)

    perms = _need(capability, "permissions", list, where, errs)
    if perms is not None:
        _check_permissions(perms, f"{where}.permissions", errs)

    invoke = _need(capability, "invoke", dict, where, errs)
    if invoke is not None:
        _check_invoke(invoke, f"{where}.invoke", errs)

    return errs


def load_capability(skill_dir):
    path = os.path.join(skill_dir, "capability.yaml")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        return CapabilityError(f"cannot read {path}: {e}")

    import yaml  # local import: mirrors config.py's lazy PyYAML import

    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as e:
        return CapabilityError(f"cannot parse {path}: {e}")

    errs = validate_capability(data, where="capability.yaml")
    if errs:
        return CapabilityError("; ".join(errs))

    version = data["version"]
    lo, hi = SUPPORTED_VERSION_RANGE
    if not (lo <= version <= hi):
        return CapabilityError(
            f"capability.yaml version {version} is not supported "
            f"(engine supports {lo}-{hi}); unavailable, never executed"
        )

    return Capability(
        version=version,
        provisioning=data["provisioning"],
        permissions=data["permissions"],
        invoke=data["invoke"],
    )


# ------------------------------------------------------------------------
# AST-061 (Sec11.3): compiled index + bounded, relevance-filtered roster.
# ------------------------------------------------------------------------

CapabilityIndexEntry = collections.namedtuple(
    "CapabilityIndexEntry",
    ["name", "one_liner", "keywords", "embedding", "enabled", "provisioned_ok", "unavailable_reason"],
)
CapabilityIndex = collections.namedtuple("CapabilityIndex", ["entries"])
Query = collections.namedtuple("Query", ["keywords", "embedding"])
AskInsteadOfGuess = collections.namedtuple("AskInsteadOfGuess", ["reason"])

# Sec11.3 hard cap default -- engine.py's per-turn roster build uses this
# unless a caller overrides it; `roster_for_turn` itself takes `top_n`
# explicitly (no default) so tests can pin any N.
DEFAULT_ROSTER_TOP_N = 5

# roster_for_turn's normalized score (Jaccard for keyword-overlap fallback,
# clamped cosine for the embedding path -- both land in [0.0, 1.0], see
# `_score`'s docstring) below which the top candidate is "low confidence":
# ask instead of guessing rather than surfacing a shaky top-1. Chosen so a
# single shared keyword out of several (a weak, incidental overlap) does
# not clear the bar, but a clearly-matching capability does.
LOW_CONFIDENCE_THRESHOLD = 0.34

_WORD_RE = re.compile(r"[A-Za-z][A-Za-z'-]{2,}")
_STOPWORDS = frozenset({
    "the", "and", "for", "that", "this", "with", "from", "have", "has",
    "was", "were", "are", "you", "your", "our", "not", "but", "can", "will",
    "would", "could", "should", "into", "about", "then", "than", "when",
    "what", "which", "who", "how", "why", "there", "here", "just", "like",
    "also", "its", "it's", "them", "they", "their", "these", "those", "any",
    "all", "one", "two", "did", "does", "let", "get", "got", "use", "uses",
    "used", "capability", "skill",
})
_MAX_KEYWORDS = 8


def _extract_keywords(text, limit=_MAX_KEYWORDS):
    """Deterministic keyword extraction: lowercase word tokens, 3+ chars,
    stopwords dropped, ranked by (frequency desc, alpha asc) so identical
    input text always yields the identical ranked keyword list -- mirrors
    distill.py's `_extract_keywords` shape (same stopword-filter idea) but
    is kept as its own small copy here rather than importing distill.py,
    since capability_index.py has no other reason to depend on the
    distiller subsystem."""
    counts = {}
    for word in _WORD_RE.findall((text or "").lower()):
        if word in _STOPWORDS:
            continue
        counts[word] = counts.get(word, 0) + 1
    ranked = sorted(counts, key=lambda w: (-counts[w], w))
    return ranked[:limit]


def _read_skill_meta(skill_dir):
    """Reads `<skill_dir>/SKILL.md`'s frontmatter `description:` (the same
    `---\\nname: ...\\ndescription: ...\\n---` shape every installed skill in
    this repo already carries, e.g. plugins/*/skills/*/SKILL.md) and
    derives (one_liner, keywords) from it. Absent file, absent frontmatter,
    or absent `description` all degrade to `("", [])` -- a skill with no
    SKILL.md still compiles into the index, just with nothing to rank it
    by (Sec17: never a compile failure over missing, optional metadata)."""
    path = os.path.join(skill_dir, "SKILL.md")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return "", []

    if not text.startswith("---"):
        return "", []
    parts = text.split("---", 2)
    if len(parts) < 3:
        return "", []

    import yaml  # local import: mirrors load_capability's lazy PyYAML import

    try:
        front = yaml.safe_load(parts[1])
    except yaml.YAMLError:
        return "", []
    if not isinstance(front, dict):
        return "", []
    description = front.get("description")
    if not isinstance(description, str) or not description.strip():
        return "", []
    one_liner = description.strip()
    return one_liner, _extract_keywords(one_liner)


def default_provisioning_checker(name, capability, skill_dir):
    """AST-061's original "unknown/assumed ok" provisioning seam
    (`provisioned_ok=True, unavailable_reason=None`), NEVER executing
    `capability.provisioning.check`. No longer `compile_index`'s default
    (AST-062 replaced that with `assistant.provisioning.
    real_provisioning_checker`, which runs the real check) -- kept as a
    named, importable placeholder for any caller that deliberately wants
    the old always-ok behavior (e.g. a test exercising something upstream
    of provisioning that would rather not depend on a real subprocess)."""
    return True, None


def _default_embed_fn(texts):
    """Lazy, degrading wrapper around brain.py's existing embeddings
    capability (MEM-03x: ONNX venv capability, `brain._embed_texts`) --
    imported INSIDE this function, never at module top, so importing
    capability_index.py alone never imports brain.py (Sec17.1 isolation
    discipline, same lazy-import posture turns.py's `make_default_recall`
    and distill.py already use for brain.py). Returns None on ANY failure
    (brain.py not importable, the capability itself unavailable, a
    malformed response) -- callers treat None as "no embeddings this
    pass", never a crash and never a blocked turn (Sec17)."""
    try:
        import brain as brain_module
    except Exception:
        return None
    try:
        return brain_module._embed_texts(list(texts))
    except Exception:
        return None


def embed_query(text, embed_fn=None):
    """Builds a per-turn `Query(keywords, embedding)` from raw user-message
    text: keywords are always extracted (cheap, pure, deterministic);
    `embedding` is computed via `embed_fn` (default `_default_embed_fn`),
    `None` on any failure/unavailability -- `roster_for_turn` degrades to
    keyword-overlap scoring whenever either side (query or entry) has no
    embedding."""
    embed_fn = embed_fn or _default_embed_fn
    keywords = _extract_keywords(text)
    embedding = None
    try:
        vectors = embed_fn([text or ""])
        if vectors and len(vectors) == 1:
            embedding = vectors[0]
    except Exception:
        embedding = None
    return Query(keywords=keywords, embedding=embedding)


def _iter_skill_dirs(skills_root):
    """Immediate subdirectories of `skills_root` that carry a
    `capability.yaml` (Sec11.1: `.claude/skills/<name>/`), sorted by name
    for deterministic compile order. Returns `[]` for a missing/unreadable
    `skills_root` -- an assistant repo with no installed skills yet is not
    a compile failure."""
    try:
        names = sorted(os.listdir(skills_root))
    except OSError:
        return []
    out = []
    for name in names:
        skill_dir = os.path.join(skills_root, name)
        if os.path.isdir(skill_dir) and os.path.isfile(os.path.join(skill_dir, "capability.yaml")):
            out.append((name, skill_dir))
    return out


def is_enabled(name, assistant_cfg):
    """Sec11.2's exact enablement rule: `assistant.capabilities.<name>.
    enabled` must be literally `True` -- absent, missing, or any other
    (even truthy) value means disabled. Extracted as its own function
    (issue #340, AST-065) so `compile_index`'s index-compile-time filter
    and `invoke_capability`'s execution-time gate below share ONE
    enablement rule instead of two independently-maintained copies that
    could drift out of sync (Sec17.2 "a disabled capability is never
    invoked by the engine" only holds if every gate agrees on what
    'enabled' means)."""
    assistant_cfg = assistant_cfg or {}
    caps_cfg = assistant_cfg.get("capabilities")
    caps_cfg = caps_cfg if isinstance(caps_cfg, dict) else {}
    entry_cfg = caps_cfg.get(name)
    return isinstance(entry_cfg, dict) and entry_cfg.get("enabled") is True


# Provisioning-override keys this module understands, and the type each
# must satisfy to be accepted -- anything else (wrong type, or a key
# capability.yaml's own provisioning schema doesn't have) is silently
# IGNORED for that key rather than raising (Sec11.3/Sec17: an index
# compile never blocks/crashes over a malformed project.yaml override; a
# badly-typed override key just falls back to the skill's own shipped
# default for that key).
def _merge_provisioning_override(base_provisioning, override):
    """Field-level merge of project.yaml's `assistant.capabilities.<name>.
    provisioning` OVER the skill's shipped `capability.yaml` `provisioning`
    block (issue #340, AST-065, Sec11.2 "project.yaml provisioning
    overrides localize the skill's defaults"). Deliberately field-level,
    not a whole-block replace: 'localizes the skill's DEFAULTS' reads as
    "override the specific values that differ for this repo/machine (e.g.
    a locally-installed binary path, a shorter TTL) while the rest keeps
    inheriting the skill's own shipped default" -- a whole-block replace
    would instead require every project.yaml override to restate the
    entire provisioning block, which is not what "localize defaults"
    describes. (Flagged in this task's report as a two-way reading --
    see the PR description for the alternative "whole-block replace"
    interpretation this function deliberately does NOT implement.)

    `override.check`, if present, replaces `check` ONLY when it is itself
    a valid non-empty argv array of strings (matching capability_index.
    _check_argv's own shape rule) -- an override that fails that shape
    check is ignored for `check` (the skill's own shipped `check` wins),
    never a compile failure.

    `override.ttlSeconds`, if present, replaces `ttlSeconds` ONLY when it
    is a genuine int (bool-before-int-guard: `isinstance(True, int)` is
    `True`, so the bool check runs first, same house lesson `provisioning.
    _ttl_seconds` already applies) -- otherwise ignored, same
    fall-back-to-shipped-default posture as `check` above."""
    if not isinstance(override, dict):
        return base_provisioning
    merged = dict(base_provisioning)
    check = override.get("check")
    if isinstance(check, list) and check and all(isinstance(a, str) for a in check):
        merged["check"] = check
    if "ttlSeconds" in override:
        ttl = override["ttlSeconds"]
        if not isinstance(ttl, bool) and isinstance(ttl, int):
            merged["ttlSeconds"] = ttl
    return merged


def compile_index(skills_root, assistant_cfg, provisioning_checker=None, embed_fn=None):
    """One pass over `skills_root` -> `CapabilityIndex` (Sec11.3's "Index
    compile" sequence, docs/design/ast-E6.md). See the module docstring for
    the enablement -> version -> provisioning ordering and the two-
    invisibility-tiers rule (disabled/version-incompatible skills never get
    an entry at all)."""
    assistant_cfg = assistant_cfg or {}
    if provisioning_checker is None:
        # Local import (AST-062, issue #337): keeps capability_index.py free
        # of assistant.provisioning's adapters.py/subprocess dependency
        # chain at MODULE import time (design doc: "Pure library: no HTTP,
        # no subprocess spawning of its own"). `real_provisioning_checker`
        # is a module-level singleton in assistant.provisioning, so its TTL
        # cache persists across repeated compile_index calls within one
        # process -- import caching returns the SAME module object every
        # time, this local import never resets it.
        from assistant import provisioning as provisioning_module
        provisioning_checker = provisioning_module.real_provisioning_checker
    caps_cfg = assistant_cfg.get("capabilities")
    caps_cfg = caps_cfg if isinstance(caps_cfg, dict) else {}

    pending = []  # [(name, one_liner, keywords, capability, skill_dir), ...]
    for name, skill_dir in _iter_skill_dirs(skills_root):
        if not is_enabled(name, assistant_cfg):
            # Sec11.2: disabled (or never configured at all) -- invisible.
            # No entry, no roster, no prompt, never executed.
            continue

        capability = load_capability(skill_dir)
        if isinstance(capability, CapabilityError):
            # Sec11.6: version-incompatible/malformed -- also never added
            # to the index (design doc's "two invisibility tiers" decision:
            # this is stronger than "shown as unavailable").
            continue

        one_liner, keywords = _read_skill_meta(skill_dir)
        pending.append((name, one_liner, keywords, capability, skill_dir))

    embed_fn = embed_fn or _default_embed_fn
    embeddings = [None] * len(pending)
    if pending:
        texts = [f"{one_liner} {' '.join(keywords)}".strip() for _n, one_liner, keywords, _c, _d in pending]
        try:
            vectors = embed_fn(texts)
        except Exception:
            vectors = None
        if vectors and len(vectors) == len(pending):
            embeddings = vectors

    entries = []
    for (name, one_liner, keywords, capability, skill_dir), embedding in zip(pending, embeddings):
        # Sec11.2 "project.yaml provisioning overrides localize the skill's
        # defaults" (issue #340, AST-065): an ENABLED capability's own
        # project.yaml entry may carry a `provisioning` mapping that
        # field-merges over the skill's shipped capability.yaml
        # `provisioning` block -- see `_merge_provisioning_override`'s
        # docstring for the exact merge rule and why it's field-level, not
        # whole-block replace. Only reachable here because we're already
        # past the enablement filter above; a disabled capability's
        # override (if any) is simply never read, matching Sec11.2's
        # "invisible" contract for disabled skills.
        entry_cfg = caps_cfg.get(name)
        override = entry_cfg.get("provisioning") if isinstance(entry_cfg, dict) else None
        effective_capability = capability
        if override is not None:
            effective_capability = capability._replace(
                provisioning=_merge_provisioning_override(capability.provisioning, override)
            )
        provisioned_ok, unavailable_reason = provisioning_checker(name, effective_capability, skill_dir)
        entries.append(CapabilityIndexEntry(
            name=name,
            one_liner=one_liner,
            keywords=keywords,
            embedding=embedding,
            enabled=True,
            provisioned_ok=bool(provisioned_ok),
            unavailable_reason=unavailable_reason,
        ))

    entries.sort(key=lambda e: e.name)
    return CapabilityIndex(entries=tuple(entries))


def _cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a) ** 0.5
    nb = sum(x * x for x in b) ** 0.5
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def _score(entry, query):
    """Normalized relevance score in [0.0, 1.0], regardless of which path
    produced it -- so `LOW_CONFIDENCE_THRESHOLD` means the same thing on
    both:
      - embedding path (used when BOTH `entry.embedding` and
        `query.embedding` are present): cosine similarity, clamped to
        [0.0, 1.0] (a real embedding model's cosine can go slightly
        negative for unrelated text; this is relevance-filtering, not a
        signed-similarity report, so negative reads as "no relevance").
      - keyword-overlap fallback (used whenever either embedding is
        missing -- degraded, deterministic, never a crash, per the module
        docstring): Jaccard similarity of `entry.keywords` and
        `query.keywords` (both treated as sets). Two empty keyword sets
        score 0.0 (no signal), never a division by zero.
    """
    if entry.embedding is not None and query.embedding is not None:
        return max(0.0, min(1.0, _cosine(entry.embedding, query.embedding)))
    a = set(entry.keywords or [])
    b = set(query.keywords or [])
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def roster_for_turn(index, query, top_n):
    """Relevance-filtered, HARD-capped top-`top_n` read of an already-
    compiled `index` (Sec11.3). Never compiles, never does I/O -- pure,
    in-memory scoring over `index.entries` and the already-built `query`
    (see `embed_query`), so a per-turn roster read stays lock-cheap.

    Deterministic ranking: entries are scored via `_score` (normalized to
    [0.0, 1.0] on both the embedding and keyword-overlap paths), then
    sorted by (-score, name) -- name is the tie-break for ORDERING only,
    never for deciding whether an actual tie/low-confidence ask fires
    below.

    Precise tie/low-confidence rule (Sec11.3 "ties/low confidence -> the
    assistant asks instead of guessing" -- flagged per house lesson
    acceptance-criterion-outranks-test-spec-paraphrase, this is the exact
    constraint this task tests against):
      - No entries at all -> `[]` (nothing to be ambiguous about; an
        empty roster for a turn unrelated to any capability, or an
        assistant with none installed, is not "low confidence", it is
        "no candidates" -- AST-071's capability-gap handling, not this
        task).
      - The best score is exactly 0.0 (no entry has ANY relevance signal
        for this query) -> `[]`, same reasoning as above: nothing plausibly
        matched, so there is nothing to guess among either.
      - Two or more entries share the best (nonzero) score -> a genuine
        TIE -> `AskInsteadOfGuess("tie among N candidates: ...")`.
      - The single best score is nonzero but below
        `LOW_CONFIDENCE_THRESHOLD` -> `AskInsteadOfGuess("low confidence
        (score=...) for ...")`.
      - Otherwise -> the top `top_n` entries (by the sort above), a HARD
        cap -- exactly `min(top_n, len(entries))` entries are ever
        returned, never more.
    """
    entries = list(index.entries) if index else []
    if not entries:
        return []

    scored = [(entry, _score(entry, query)) for entry in entries]
    scored.sort(key=lambda pair: (-pair[1], pair[0].name))

    best_score = scored[0][1]
    if best_score <= 0.0:
        return []

    tied = [entry for entry, score in scored if score == best_score]
    if len(tied) >= 2:
        names = ", ".join(e.name for e in tied)
        return AskInsteadOfGuess(f"tie among {len(tied)} candidates: {names}")

    if best_score < LOW_CONFIDENCE_THRESHOLD:
        return AskInsteadOfGuess(
            f"low confidence (score={best_score:.2f}) for top match {scored[0][0].name!r}"
        )

    return [entry for entry, _score_val in scored[:top_n]]


def _index_signature(section, skills_root):
    """A cheap, comparable snapshot of "what would change compile_index's
    output": the section's `capabilities` config plus the sorted list of
    subdirectory names under `skills_root` that carry a `capability.yaml`
    (a skill's capability.yaml CONTENT changing -- e.g. version bump -- is
    NOT covered by this signature; a full content-hash walk is a
    heavier-weight future refinement, not required for AST-061's "compiled
    on start and on change" contract, which is about enablement/skill-set
    changes). Equality of two signatures is a reliable "nothing to
    recompile" signal; inequality always triggers a recompile -- never the
    reverse."""
    caps = section.get("capabilities") if isinstance(section, dict) else None
    caps = caps if isinstance(caps, dict) else {}
    try:
        skill_names = tuple(name for name, _dir in _iter_skill_dirs(skills_root))
    except OSError:
        skill_names = ()
    caps_signature = tuple(sorted(
        (name, entry.get("enabled") if isinstance(entry, dict) else None)
        for name, entry in caps.items()
    ))
    return (caps_signature, skill_names)


DEFAULT_INDEX_POLL_SECONDS = 2.0


def run_worker(repos_getter, stop_event, on_compile, skills_subpath=(".claude", "skills"),
                poll_interval=DEFAULT_INDEX_POLL_SECONDS, provisioning_checker=None, embed_fn=None):
    """The `index` worker body engine.py's `start()` binds into the
    AST-010 `index` slot, replacing the v1 heartbeat no-op (same
    replace-the-heartbeat-body pattern AST-030 used for `distiller`).

    On EVERY poll tick (including the very first, immediately on start --
    `last_signature` starts empty so every currently-discovered candidate
    root compiles at least once right away) this walks `repos_getter()`'s
    CURRENT roots, classifies each (`discovery.classify_repo`, the same
    classifier every other engine.py read-path already uses), and
    recompiles ONLY a root whose `_index_signature` changed since the last
    tick -- Sec11.3's "compiled on start and on change, never per-turn".
    `on_compile(root, index)` is called once per (re)compile so the caller
    (engine.py) can store the result wherever it holds per-root state;
    this function holds no engine state itself.

    `stop_event.wait(poll_interval)` (rather than a bare `sleep`) bounds
    the loop's responsiveness to `stop_event.set()` to at most one
    `poll_interval`, so `engine.stop()`'s bounded join stays prompt --
    same posture as `distill.run_worker`'s `q.get(timeout=...)`.

    Failure posture: a root that fails to classify or compile (any
    exception) is skipped for this tick, never crashes the worker thread
    -- the same "one broken sibling repo never takes down the others"
    discipline `discovery.scan` already applies to every other read-path.
    """
    from assistant import discovery  # local import: avoids a hard import-time
    # coupling from capability_index.py (a pure library, per the module
    # docstring) to the discovery/marker/config stack for callers that only
    # need compile_index/roster_for_turn.

    last_signature = {}
    while not stop_event.is_set():
        for _name, root in repos_getter():
            try:
                classification = discovery.classify_repo(root)
            except Exception:
                continue
            if classification.kind != "candidate":
                continue
            section = classification.section
            skills_root = os.path.join(root, *skills_subpath)
            try:
                signature = _index_signature(section, skills_root)
            except Exception:
                continue
            key = os.path.realpath(root)
            if last_signature.get(key) == signature:
                continue
            last_signature[key] = signature
            try:
                index = compile_index(skills_root, section,
                                       provisioning_checker=provisioning_checker,
                                       embed_fn=embed_fn)
            except Exception:
                continue
            try:
                on_compile(root, index)
            except Exception:
                continue
        stop_event.wait(poll_interval)


# ------------------------------------------------------------------------
# AST-065 (Sec11.2, Sec17.2): execution-time enablement gate.
# ------------------------------------------------------------------------


class CapabilityDisabledError(Exception):
    """Raised by `invoke_capability` when the named capability is not
    enabled (Sec17.2: "a disabled capability is never invoked by the
    engine"). Deliberately its own exception, not folded into `adapters.
    AdapterError` -- this is a POLICY-level refusal that fires BEFORE
    anything reaches `adapters.py`'s subprocess-execution taxonomy (which
    exists to classify failures of an ALREADY-authorized invocation, e.g.
    a timeout or a malformed response); a disabled capability is refused
    before that taxonomy is even relevant. (Flagged in this task's report:
    an alternative design would fold this into `adapters.py` as e.g.
    `adapters.CapabilityGatingError(AdapterError)` for a single catch
    surface -- not done here, see the report for the tradeoff.)"""


def invoke_capability(name, capability, params, assistant_cfg, *, timeout=None, env=None, cwd=None):
    """The SINGLE choke point every invocation of a NAMED capability must
    pass through (issue #340, AST-065) -- enforces Sec17.2 ("a disabled
    capability is never invoked by the engine") and then dispatches to
    `adapters.invoke_argv`/`adapters.invoke_mcp`.

    WHY the gate lives HERE and not inside `adapters.invoke_argv`/
    `invoke_mcp` themselves (flagged design call, see this task's report
    for the full writeup): those two functions take a bare `Capability`
    namedtuple with NO `name` and NO `enabled` field at all -- enablement
    is compile-time-filtered state that only `capability_index.py` (via
    `is_enabled`, the SAME rule `compile_index` already applies) knows how
    to evaluate; `adapters.py` is deliberately a name-agnostic, pure
    execution primitive shared by provisioning checks AND invoke (per
    docs/design/ast-E6.md's layering), and giving it capability-name/
    enablement awareness would blur that boundary and require changing
    AST-063/064's already-landed, already-reviewed signatures. Putting the
    gate in `capability_index.py` instead keeps ONE place owning "what
    does enabled mean" (shared with `compile_index`) and keeps
    `adapters.py` unchanged.

    Dispatch: auto-detects the invoke flavor from `capability.invoke`'s
    shape (`exec` vs `mcp` -- capability_index.validate_capability already
    guarantees exactly one is present for a structurally valid
    capability), so callers never have to pass a flavor flag themselves.
    `timeout=None` forwards to each adapter function's own default
    (`adapters.DEFAULT_TIMEOUT_SECONDS`) rather than duplicating that
    constant here.

    Raises `CapabilityDisabledError` (never touching `adapters.py` at all,
    including never spawning a subprocess) when `is_enabled(name,
    assistant_cfg)` is false; otherwise raises/returns exactly whatever
    the dispatched `adapters.invoke_argv`/`invoke_mcp` call raises/
    returns."""
    if not is_enabled(name, assistant_cfg):
        raise CapabilityDisabledError(
            f"capability {name!r} is disabled (assistant.capabilities.{name}.enabled is not "
            "true) -- SPEC-ASSISTANT.md Sec17.2: a disabled capability is never invoked"
        )

    from assistant import adapters  # local import: keeps this module's "pure library,
    # no subprocess dependency at import time" posture (same rationale as
    # compile_index's lazy provisioning-module import above) -- importing
    # capability_index.py alone never imports adapters.py's subprocess
    # dependency chain.

    invoke = capability.invoke if isinstance(capability.invoke, dict) else {}
    kwargs = {"env": env, "cwd": cwd}
    if timeout is not None:
        kwargs["timeout"] = timeout
    if "mcp" in invoke:
        return adapters.invoke_mcp(capability, params, **kwargs)
    return adapters.invoke_argv(capability, params, **kwargs)
