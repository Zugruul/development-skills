# Design — ast/E5: Voice — TTS/STT loop

Grounded in: SPEC-ASSISTANT.md §13 (voice), §12.5 (tasks announce via TTS when voice on),
§7.3/§7.4 + §17.9 (voice hard-gated off when no enabled assistant is selected), §10 (voice
spans join the same trace stream), §8 (turns stay text-in/text-out at the engine API).

## Components (epic-wide)
- neural-view template voice panel (AST-050/052) — the existing voice surface built by the
  #395/#397/#399/#402 series: IN/OUT audio-feedback bars, the assistant-name label/selector,
  and the pre-existing echo-guard (inbound level ducking while the page itself is speaking).
  TTS wiring (AST-050) attaches to the existing `speechSynthesis` pipeline already present
  for page announcements — replies become speakable through THAT path, never a new one.
- `assistant/engine.py` + `assistant/turns.py` — UNCHANGED API surface: text in, text out
  (§13.2 explicitly keeps the engine text-only regardless of the STT choice). E5 adds no
  engine routes for audio; the page speaks replies and (AST-051+) transcribes speech into
  the same `/assistant/chat` text calls.
- `assistant/observability.py` — TTS/STT spans (§13.3) are ordinary trace events emitted
  from the page via the existing event ingestion path; no new writer.

## Data models
- **Voice span** (§13.3): trace events `tts-start`/`tts-end` (chars spoken, voice used,
  duration) and later `stt-start`/`stt-end` — same envelope as existing turn events, tagged
  to the turn id they belong to.
- **Echo-guard state**: page-local only (never server state): `speaking: bool` drives input
  ducking; the guard's contract is that inbound level metering ducks while `speaking` and
  recovers on `tts-end`/cancel.

## Interfaces / contracts
- `speakReply(text, turnId)` (template): queues the reply through `speechSynthesis`,
  raising the echo-guard for the utterance's lifetime (including error/cancel paths — the
  guard must NEVER stay latched after a failed utterance), emitting the §13.3 span events.
  Voice-off or no-assistant-selected ⇒ no-op (§17.9 gate checked at the call site, same
  gate the voice panel already honors).
- Long replies: chunk at sentence boundaries to keep `speechSynthesis` reliable across
  engines (a known browser quirk with long utterances); the span covers the whole reply,
  not per-chunk.
- STT (AST-051, decision-gated): §13.2 — the choice between Web Speech API (zero-install;
  audio leaves the machine to the browser vendor) and a local whisper.cpp sidecar (fully
  local; heavier install, needs a capability entry) SHALL be recorded as a spec delta
  BEFORE implementation. Either way the engine API stays text-in/text-out.

## Key sequences
1. **Spoken reply** (AST-050): `/assistant/chat` response arrives → chat overlay renders
   text (unchanged) → if voice on + assistant selected: `speakReply()` → echo-guard up →
   OUT bar animates from the utterance → `tts-end` → guard down → span emitted.
2. **Task completion announce** (§12.5, consumed later by E6's queue): completion calls the
   same `speakReply()` hook — E5 owns the hook, E6 calls it.
3. **Voice-driven turn** (AST-052, after AST-051 lands its delta): mic capture → STT (per
   the recorded decision) → text into the SAME chat call → reply spoken via sequence 1 →
   chat overlay mirrors the whole exchange.

## Decisions
- **Reuse the page's existing speechSynthesis pipeline and echo-guard** — AST-050 is
  wiring, not a new speech stack; the acceptance criterion "echo guard ducks inbound during
  speech" refers to the guard that already exists on the voice panel.
- **Engine stays text-only** (§13.2) — no audio ever crosses the HTTP surface; STT/TTS are
  page concerns. This keeps E1's latency gates and the adapter contract untouched.
- **Spans from the page, not the engine** — the page knows utterance timing; it reports
  spans through the existing trace ingestion, keeping the single-writer rule intact.
- **Guard-never-latches invariant** — every utterance path (finish, error, cancel,
  page-hide) lowers the echo-guard; a latched guard mutes the user permanently and is the
  epic's worst failure mode.

## Out of scope for this epic
Capability-invoked audio artifacts (E6 owns artifacts), remote compute (E7), the queue
indicator (E6; E5 only exposes the announce hook). The sidebar/HUD markdown work (#117)
and voice-panel restyles (#395-#402 series) are separate tracks.
