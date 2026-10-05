---
tags: [testing, tooling]
paths: ["**"]
strength: 1
source: "PR#244 (#236) -- a session-documented lesson recurred later in the same session, hid 10 real failures behind a truncated tail -30"
graduated: false
created: 2026-07-20
---

Piping a full gate.sh run through `| tail -N` in the SAME background command truncates the log to only the last N lines system-wide -- a "N test(s) FAILED" summary line can survive while every individual FAIL line is truncated away, making a red gate look clean. This was already a documented lesson earlier in this session and still recurred later under time pressure. Fixed habit: always redirect full output to a file (`> logfile 2>&1`, no pipe-to-tail in the launch command itself) and grep the FULL file for ^FAIL afterward -- never pipe-to-tail a gate run you intend to trust.

Related: [[trust-completion-signal-not-early-log-read]]
