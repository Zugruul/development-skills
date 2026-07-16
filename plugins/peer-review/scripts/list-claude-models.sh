#!/usr/bin/env bash
# list-claude-models.sh -- static catalog of Claude models /peer-review can
# select for the Claude backend (CDX-054; mirrors PRV-004's list-models.sh
# for the codex backend, same JSON output contract). Unlike codex, there is
# no CLI subcommand that enumerates Claude models dynamically -- this is a
# small, maintained static list, not a discovery call, so it never touches
# the network or requires `claude` on PATH.
#
# Sourced from this repo's own canonical Claude model list
# (plugins/spec-workflow/skills/pr-review-model/SKILL.md) -- this script is
# the single place those ids/descriptions are hand-maintained for the
# peer-review plugin; do not duplicate them a third place.
#
# Only full model ids are listed, never a bare alias like "haiku" --
# claude-review.sh's own manual verification found that `claude --model
# <alias>` does not reliably select the intended model, while a full model
# id does.
#
# Emits on stdout:
#   {"models":[{"slug","display_name","description"}, ...], "recommended":"<slug>"}
# recommended = claude-sonnet-5[1m] -- this repo's own stated default
# elsewhere (pr-review-model): a balanced default over reflexively picking
# the most powerful/expensive model, with the 1M context window able to
# hold a full diff + spec in one reviewer.
set -uo pipefail

python3 -c '
import json

models = [
    {
        "slug": "claude-sonnet-5[1m]",
        "display_name": "Claude Sonnet 5 (1M context)",
        "description": "Sonnet 5 with the 1M-token context window: holds a full diff + spec in one reviewer; the recommended default.",
    },
    {
        "slug": "claude-sonnet-5",
        "display_name": "Claude Sonnet 5",
        "description": "Standard-context Sonnet: cheaper; fine for small, focused diffs.",
    },
    {
        "slug": "claude-opus-4-8",
        "display_name": "Claude Opus 4.8",
        "description": "Strongest reviewer judgment; higher cost per round. Standard context -- very large diffs may need chunking.",
    },
    {
        "slug": "claude-haiku-4-5",
        "display_name": "Claude Haiku 4.5",
        "description": "Cheapest/fastest; only for mechanical changes -- not recommended as a review gatekeeper.",
    },
]
print(json.dumps({"models": models, "recommended": "claude-sonnet-5[1m]"}))
'
exit $?
