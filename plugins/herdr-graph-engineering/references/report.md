# Report

Every time the orchestrator reports on the lanes (after a change, when the user asks, when it stops), it prints the output of `bash "<plugin>/scripts/status.sh" --text` unchanged inside one fenced code block, then at most a few lines of prose.

```text
NEEDS YOU (1)
  why-sync-slow  investigate  investigate ?
    ? Which environment, staging or production?
    last: 2026-11-26T10:42:07Z question from investigate: Which environment, staging or production?
WORKING (1)
  task-rate-limit  solo  impl ✓ → tests ⟳ retry 1/3
    last: 2026-11-26T10:40:12Z tests failed, retry impl 1/3
```

- Sections in this order: `NEEDS YOU`, `WORKING`, `DONE`, each with its count; empty sections are left out.
- One entry per lane: name, pattern, the node chain (`✓` done, `⟳` running, `✗` failed, `?` waiting on a person, `·` waiting), retries as `retry n/max`, the open question, file references, and the last history line.
- Below the block, in prose: what changed since the last report, and for each `NEEDS YOU` lane the exact question and what the user can answer.
- Facts come from the lane files and Herdr. A lane is `DONE` only after its done checks passed, never because an agent said so. Say "claimed" for anything you did not check.
