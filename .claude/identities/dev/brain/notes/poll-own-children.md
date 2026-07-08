---
tags: [subprocess, lifecycle, python]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#55 retro"
graduated: false
created: 2026-07-08
---

os.kill(pid, 0) — the textbook liveness check — LIES about your own direct children: a crashed-but-unreaped child is a zombie that still "exists". Only waitpid-family calls (Popen.poll()) reap and see the true exit status; pid_alive-style checks are for OTHER processes only. Corollary: any "starts and prints RUNNING" command is a health check in disguise — audit whether it verifies the claimed thing or just took the happy-path branch.

Related: [[stderr-suppression-hides-evidence]] [[second-order-after-concurrency-fix]]
