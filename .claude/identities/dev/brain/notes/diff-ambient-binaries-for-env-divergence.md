---
tags: [ci, debugging, subprocess]
paths: []
strength: 1
source: "#408 root cause"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

For a bug that is 'deterministic in CI, absent locally', diff the AMBIENT BINARY availability first (argv[0] of the first traceback vs which/PATH locally), not config or dependency drift — PyYAML/python-version/tmpdir were all identical; the only divergence was the codex binary existing locally and not on the runner.

Related: [[hermetic-path-fixtures-for-cli-tests]] [[adapter-contracts-enumerate-os-failures]]
