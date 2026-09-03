---
tags: [validation, python]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#80 retro"
graduated: false
created: 2026-07-08
---

"Key present" and "value present" are different claims: `"description" in node` accepts an empty string; `bool(node.get("description","").strip())` is the assertion you actually mean. For any permanent gate, test the boundary explicitly (empty string, whitespace-only), not just happy-path and fully-absent — and expect your own enforcement mechanism to contain the failure mode it enforces against.

Related: [[bool-excluded-before-int]] [[present-vs-demanding-policy-rules]]
