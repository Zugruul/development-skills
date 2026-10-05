---
tags: [testing, process, tooling]
paths: []
strength: 1
source: "retro 2026-07-22"
graduated: false
created: 2026-07-22
---

Run long test suites in the background by redirecting FULL output to a log file and analyzing the file afterwards. Piping through grep/head buffers everything until process exit, which makes an empty output indistinguishable from a hung run, and a killed pipeline can leave the task tracker claiming "running" with no processes alive. The log file also preserves the failure context a filtered pipe throws away. Related: [[bisect-before-blaming-tracked-flakiness]].
