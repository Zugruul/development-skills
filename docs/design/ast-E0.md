# Design — ast/E0: Foundations — config, identity, brain library
Grounded in: SPEC-ASSISTANT.md §5a (structural contract), §6 (§6.1–§6.7 configuration & identity), §7.6 (terminal resolution order), §17 invariants 1–6, §16 (testing strategy).

## Components (epic-wide)
- `plugins/spec-workflow/scripts/assistant/` — the engine package (§5a). E0 creates it **library-first**: pure, importable modules with no server/thread/route code (that is AST-010, E1). E0 modules:
  - `__init__.py` — empty package anchor.
  - `marker.py` (AST-001) — `.neural-network` marker grammar (§6.2).
  - `config.py` (AST-002) — `assistant:` section schema + validation (§6.1, §6.5).
- `plugins/spec-workflow/scripts/brain.py` (AST-003/004) — gains importable `recall()`/`mint()` structured APIs and atomic+flocked write paths; the CLI delegates to the same functions **byte-identically** (existing tests stay green unchanged).
- `plugins/spec-workflow/skills/setup-assistant/` (AST-005) — scaffold skill.
- Preflight additions (AST-006) and the machine-local default store (AST-007) build on marker.py + config.py.
- Tests: one `plugins/spec-workflow/tests/section-assistant-*.sh` per component, run-tests.sh section style, merge-gating (§16 "Unit: config/marker parsing (incl. legacy tolerance)…").

## Decisions
**Marker parser contract (AST-001).** `parse_marker(text) -> dict[str, str]` plus a path convenience `read_marker(path)`. Grammar per §6.2:
- A line whose first non-whitespace char is `#` is a comment; blank/whitespace-only lines are ignored.
- Any other line containing `=` is a key=value pair: split at the FIRST `=`; key and value are `strip()`ed; later duplicate keys overwrite earlier ones (last-wins, documented).
- The parser returns ALL parsed keys; "ignoring unknown keys" (§6.2) is CALLER semantics — consumers pick the keys they know. This keeps the grammar forward-compatible without the parser needing a key registry.
- Legacy tolerance: comment-only content (today's shipped marker — one `#` comment line — is a verbatim fixture), empty content, and empty files are all valid and yield `{}`. A non-comment line WITHOUT `=` is tolerated and skipped (never a parse error): §6.1 makes the marker a pure discovery anchor carrying no assistant flags, so unparseable content must never break discovery. The parser raises on NO input content whatsoever; `read_marker` on a missing file raises `FileNotFoundError` (presence checks stay the caller's job, as in `neural-view.py` today).
- No inline (trailing) comments: `k=v # c` keeps `# c` in the value. Values may legitimately contain `#` and `=`; only full-line comments are grammar (matches §6.2's "key=value lines with `#` comments" reading and keeps values unrestricted).
- Stdlib-only, no PyYAML here; pure function, no I/O in `parse_marker`.

**Package is created in E0, populated incrementally.** AST-001 ships `__init__.py` + `marker.py` only. The §5a module roster {engine, adapters, store, distill, capability_index, observability, tasks} is AST-010's deliverable; E0 must not stub server modules it can't test (stay-in-scope rule).

**Existing marker consumers are NOT rewired in E0.** `neural-view.py` / `sync-configs.py` presence checks stay untouched; discovery switching to config-authoritative selection is §7.1 / AST-020 (E2, blocked behind E1 gates). AST-001 is grammar + fixtures only.

**brain.py changes stay surgical (AST-003/004).** Other lanes use brain.py concurrently; extraction is refactor-only behind the existing CLI surface, and the atomic-write/flock task covers recall's own link-bump writes (§5a bullet 4).

## Out of scope for this epic
Engine runtime (threads, routes, adapters) — E1. Discovery/selection UX — E2. Anything invoking an LLM CLI — E1+ (invariant 1 still applies to fixtures: stub binaries only, never real providers in tests).
