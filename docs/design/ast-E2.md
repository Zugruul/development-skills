# Design — ast/E2: Selection UX & chat overlay
Grounded in: SPEC-ASSISTANT.md §5 (surfaces), §6.1–§6.3 (config authority, marker grammar, local default), §7 (discovery, selection, gating), §8.5–§8.6 (overlay states, thinking state), §17 invariants 9–10.

## Components (epic-wide)
- `assistant/discovery.py` (AST-020) — full multi-repo discovery scan: per-repo classification + scan outcome. Pure library, no HTTP, no subprocesses.
- `assistant/default_store.py` — keeps §7.6 resolution + local-default store (AST-007); its minimal `discover_candidate` DELEGATES to discovery.py's classifier so there is exactly one classification code path.
- `engine.py` — E2 tasks extend `/assistant/*` routes for selection state (AST-021/022) and expose the scan result; discovery itself stays in discovery.py.
- neural-view page JS — startup picker / none-overlay / header name (AST-021), ask-again setting + ⚙ switcher (AST-022), T-key chat overlay (AST-023), switch flow + activation digest (AST-024).

## Data models
Classification (discovery.py): per repo root a `Classification` with
`kind` ∈ {`candidate`, `no-marker`, `marker-unreadable`, `no-config`, `config-invalid`, `no-assistant-section`, `section-invalid`, `disabled`};
`section` (the parsed `assistant:` dict, candidates only); `detail` (human string for non-candidates, e.g. the first validate_assistant error).
Scan result: `{repos: [(root, Classification)...], candidates: [(root, section)...], outcome: "one"|"multiple"|"none"}` — `outcome` is the §7.2–§7.4 branch selector AST-021 consumes.

## Interfaces / contracts
- `discovery.classify_repo(root) -> Classification` — marker presence (pure anchor, §6.1; tolerant grammar via assistant/marker.py, §6.2) then config authority: project.yaml must load, carry an `assistant:` section, pass `assistant.config.validate_assistant`, and have `enabled: true`. Any failure ⇒ the repo counts as NO assistant (§7.1 + AC "disabled/invalid counts as none") with the specific `kind`/`detail` preserved for preflight/UX honesty (§6.6 spirit).
- `discovery.scan(roots) -> ScanResult` — classify each root, dedupe preserved as given (callers pass neural-view's already-deduped repo list).
- `default_store.discover_candidate(root)` — behavior-identical wrapper: `classify_repo(root).kind == "candidate"` → `(root, section)` else `None`. Existing resolution tests must keep passing unchanged.

## Key sequences
1. Startup selection (AST-021): serve boot → `scan([root for _, root in REPOS])` → outcome `one` ⇒ silent select + header name (§7.2); `multiple` ⇒ picker w/ Skip (§7.3, Skip hard-gates voice+chat, §17.9); `none` ⇒ red overlay + hover explainer (§7.4).
2. Selection memory (AST-022): selection held server-side in engine state (page/tabs/terminal agree, §7.5); local default file stays AST-007's store.
3. Switch (AST-024): flush in-flight turn state → load target → both assistants' background work keeps running (§7.7) → activation digest from trace events (§7.8).

## Decisions
- **Own module, one classifier.** Discovery gets `discovery.py` (not more code in default_store): AST-021/022/024 all consume the scan, and preflight-style honesty needs rejection reasons that `discover_candidate`'s None can't carry. default_store delegates — never a second classification path.
- **Config-authoritative, marker = anchor only.** A repo without the marker is never classified further (not scanned, §6.1); marker CONTENT can never reject a repo (tolerant §6.2 grammar — even unreadable marker bytes ⇒ `marker-unreadable`, still "no assistant", never a crash).
- **Fail-closed per repo.** Every classification error path yields a non-candidate, never an exception out of `scan()` — one broken sibling repo must not take down discovery (mirrors neural-view `discover_repos`).
- **Outcome computed in the library**, not in JS: §7.2–§7.4 branching is testable in Python fixtures; the page just renders the branch.
- **No engine/route changes in AST-020.** `/assistant/status`'s existing candidate count keeps using default_store (now delegating); selection routes arrive with AST-021/022.

## Out of scope for this epic
Voice loop (E5 owns TTS/STT; E2 only gates voice off per §7.3/§7.4), distiller (E3), traces/metrics surfaces (E4) — AST-024's digest only READS trace events via whatever E4 has landed, degrading to "no activity recorded" if absent.
