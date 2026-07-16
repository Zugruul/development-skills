---
name: changelog-generate
description: Generates a changelog section from git log grouped by conventional-commit type, since the last release tag. Use for '/changelog-generate', 'generate a changelog', 'what changed since the last release', or 'summarize commits since <tag>'.
allowed-tools: Bash
---

# Generate a changelog

**This skill is READ-ONLY.** It never touches the GitHub project board, and the only file it can write to is one you explicitly name via `--write` — no other git history mutation ever happens here.

```bash
bash "../../scripts/changelog.sh" [--from <ref>] [--to <ref>] [--write <file>]
```

- `--from <ref>` defaults to the most recent tag matching `spec-workflow--v*` (`git describe --tags --match 'spec-workflow--v*' --abbrev=0`); if no such tag exists yet, it falls back to the repo's first commit.
- `--to <ref>` defaults to `HEAD`.
- The script runs `git log <from>..<to>` locally — no network calls, no `gh` invocations. It groups commits by their conventional-commit type prefix (`feat`, `fix`, `chore`, `docs`, `test`/`tests`, `refactor`, `retro`, and an `Other` bucket for anything that doesn't match), and prints Markdown: a `## <from>..<to>` heading (or `## Unreleased` when `--to` defaults to an untagged `HEAD`), followed by one `### <Type>` subsection per non-empty bucket, each a bullet list of `- <subject> (<short-sha>)`. Any `(#123)` PR/issue reference at the end of a commit subject is preserved verbatim in the bullet.
- `--write <file>` prepends the generated section to the top of `<file>` instead of printing to stdout, creating the file with a `# Changelog` H1 first if it doesn't exist yet, and preserving any existing content below the new section.

## Usage

Run the script and show the result to the human. If they want it saved, re-run with `--write <file>` naming the changelog file they choose (e.g. `CHANGELOG.md`) — never write to a file without being told which one.
