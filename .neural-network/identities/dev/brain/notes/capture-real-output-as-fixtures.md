---
tags: [testing, fixtures, parsers, probes]
paths: ["plugins/spec-workflow/tests/fixtures/compute"]
strength: 1
source: "task-524"
confidence: direct
graduated: false
created: 2026-08-02
last-touched: 2026-08-02
---

# Capture real output as fixtures — never invent them

When writing parsers for a tool's output, capture the REAL output from the
real environment first and commit that as the fixture. An invented fixture
encodes your assumption twice (in the parser and in the test), so the tests
pass green while production reads null.

Observed live: the nvidia-smi fixture was written from memory with
`Driver Version:` / `CUDA Version:` headers. WSL's nvidia-smi actually prints
`KMD Version:` / `CUDA UMD Version:`. Tests passed; the real machine recorded
`cuda: null, driver: null` on a working RTX 5090. Same class of error hid a
truncated GPU name (the ASCII table elides long names — the CSV query
`--query-gpu=...--format=csv` is authoritative).

Rule: for any probe/parser, run the command on the target machine, paste the
output into a fixture file, and only then write the parser. If the environment
is unreachable, mark the parser unverified rather than guessing.
