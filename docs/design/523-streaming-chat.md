# Design — #523: streaming chat turns

Grounded in the human-directed issue #523 and SPEC-ASSISTANT.md §5a,
§7.7, §8, §11.5, §16 and §17. This extends the ast/E1 adapter/turn design
and ast/E2 chat design. The pending `docs/spec-deltas/523.md` supersedes
the old §3 NG2 non-goal and extends §8; canonical spec folding follows merge.

## Components

- `assistant/adapters.py` owns bounded CLI stream transport and optional
  streaming adapter discovery; existing `complete(context)` callers remain valid.
- `assistant/claude.py` consumes main-response text deltas and the authoritative
  final result. `assistant/codex.py` preserves its blocking JSONL parser when
  the installed exec protocol does not expose incremental assistant text.
- `assistant/turns.py` owns incremental public-text filtering and completion
  phases. Raw capability directives never cross the public event boundary.
- `assistant/engine.py` owns chat validation, serialization, capability execution,
  final state/transcript persistence, and the stream event contract.
- `neural-view.py` mounts the engine stream on the existing POST route and
  serializes/flushed SSE frames; it contains no turn or provider business logic.
- `templates/neural-view.html` consumes the response stream and updates the
  existing assistant reply row, preserving queue, switch, chips and voice behavior.

## Interfaces / contracts

`POST /assistant/chat` with `Accept: text/event-stream` negotiates streaming.
Requests without that header keep today's JSON response contract. The browser
also accepts a JSON response from an older or non-streaming server without a
second request. A stream has typed JSON events: `start` (turn identity), `text`
(completion phase plus cumulative sanitized text), `done` (authoritative final
existing chat payload), or `error` (specific bounded error). Exact field names
are documented beside implementation and tested from both ends. A successful
stream has one done event; failure has one error event; EOF without a terminal
event is a failed turn, never a successful partial reply. Heartbeats carry no
provider content. Events are emitted and flushed before provider completion.

The optional streaming adapter accepts a text-delta callback and otherwise
returns the same final `{text, usage, timings}` as `complete`. An unsupported
adapter or CLI uses `complete` exactly once. Support is determined before the
model invocation, from an actual supported protocol/CLI capability; failures,
timeouts or malformed output after invocation never retry the completion.
Registered/custom complete-only adapters continue to work.

The CLI pump uses argv arrays, the existing pinned sandbox/isolation flags,
an isolated working directory and (Codex) auth-only CODEX_HOME. It drains both
pipes, handles split UTF-8 and JSONL records, bounds buffered output and elapsed
time, and kills/reaps its owned process group on cancellation or failure.
File-output publication retains the existing hardened relay. A full stderr
pipe, descendant holding a pipe open, stalled client or silent provider must
not defeat the deadline. No API fallback or new dependency is introduced.

## Key sequences

1. Resolve/gate the selected assistant and validate input, retaining existing
   error statuses. Under its existing per-assistant chat lock, compose/recall
   once, invoke once, stream safe text, run the existing capability hook,
   persist the authoritative exchange once, then emit done. Different assistant
   locks remain independent. Background queues remain enqueue-only.
2. Each completion has a fresh incremental filter. It withholds possible
   line-anchored capability fence prefixes across arbitrary chunk boundaries,
   hides complete, malformed and unterminated directive blocks according to the
   existing parser, and emits ordinary text promptly. Only main assistant text
   is eligible: thinking, signatures, tools, subagent text, diagnostics and raw
   directive JSON never become public text. The first completion may display
   a safe preamble; the one allowed result follow-up streams as a new phase.
   Phase changes replace the provisional reply, and done replaces it with the
   final sanitized answer. This avoids duplicated content and preserves the
   existing final-transcript semantics.
3. A synchronous capability still runs at most once and receives schema-checked
   parameters. Its follow-up still runs at most once. Follow-up failure retains
   the existing result-bearing fallback. Disconnect must not be swallowed by
   the hook's broad exception handler or initiate another completion/effect;
   an already executed effect retains a recoverable, result-bearing transcript
   rather than inviting a duplicate invocation. Provider children and temporary
   directories are cleaned with bounded waits. No automatic HTTP retry occurs.
4. The browser replaces thinking with live text on the first safe text event,
   using textContent during streaming and the existing Markdown renderer on
   final success. It stores one completed exchange, attaches final recall chips,
   and calls TTS once with the final answer. Generation guards cover every delta,
   terminal event and error so an outgoing assistant cannot alter an incoming
   assistant's rows, queue, timer or in-flight state. Input remains open and
   queued messages run in order. Partial failed text is not cached as success.

## Decisions and evidence

- Preserve the current chat layout, row styling and artifact rail. The issue
  explicitly chooses spinner-to-live-text behavior. AST-083's stale registry
  entry governs the already-applied artifact/composer rail, not a new design
  applied by #523. No new layout or style decision is introduced here.
- Claude uses `--output-format stream-json --verbose --include-partial-messages`
  with its existing safe-mode/auth/isolation flags. Official protocol:
  <https://code.claude.com/docs/en/headless#stream-responses>.
- Codex exec JSONL's documented protocol and the installed CLI capture expose
  completed agent messages, not text deltas. Preserve an honest blocking
  fallback rather than simulating token streaming. Protocol reference:
  <https://learn.chatgpt.com/docs/non-interactive-mode>.
- Bounded isolated subscription probes on 2026-10-18: Claude first text at
  3.090s, final result at 3.251s; Codex completed message at 16.080s with no text
  deltas. Capture-derived fixtures must strip account/session/path/signature
  metadata. Tests may synthesize boundary splits and failures around real
  protocol shapes, with provenance distinguished from real capture evidence.
- The human's roughly two-second first-text target remains the objective.
  Deterministic integration tests must prove visible text within two seconds
  when the stub provider emits it promptly, and before final completion.
  Measure first-visible-text latency separately from total completion latency;
  report real cold-start measurements honestly, without a claimed guarantee
  for arbitrary provider startup or reasoning delays. Persistent warm sessions
  are a separately tracked follow-up requested in #523.

## Validation

Committed failing tests must cover the real provider protocol, transport flush
before EOF, both capability completions and directive non-disclosure for every
relevant chunk split, JSON fallback with exactly one invocation, timeout/auth/
nonzero/malformed/partial failures, pipe draining and child cleanup, client
disconnect, final persistence and usage, and browser queue/switch/TTS behavior.
Include deterministic browser stream-reader behavior and the real localhost
HTTP mount, not only mocked engine calls. Run the repository's complete gate
before review/merge; live CLI timing is additional evidence, not a CI dependency.

## Out of scope

Warm persistent CLI sessions, app-server transport, metered APIs, new model
defaults, capability chaining, artifact-rail redesign and token-by-token TTS.
