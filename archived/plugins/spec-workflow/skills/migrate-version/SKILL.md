---
name: migrate-version
description: Migrates a consumer repo's spec-workflow files (project.yaml, specs, knowledge bases, feeds) from one schemaVersion to the current one, chapter by chapter — detects the repo's version (missing or integer schemaVersion reads as 1.0.0), then applies each registry chapter in order, verifying after every step. Use for '/migrate-version', 'migrate my config', 'upgrade schema version', or when validate-config/preflight prints a schemaVersion deprecation note.
allowed-tools: Bash
---

# Migrate a repo between schema versions

You migrate ONE consumer repo to the current schema version, one chapter at a time, verifying as you go. `config.py` = `python3 "../../scripts/config.py"`; run everything from the target repo's root.

## 1. Detect where the repo is

```bash
config.py <root> schema-version     # prints the semver, e.g. 1.0.0
```

- Missing `schemaVersion`, or the legacy integers (`1` json era, `2` pre-cutover yaml era), all read as **1.0.0** — that is by design, so every un-versioned repo has a defined starting point.
- Already at the current version (`2.0.0`)? Report "nothing to migrate" and stop.

## 2. Apply the chapters, in order

`references/migrations.md` is the version-by-version registry — one chapter per hop (e.g. `## 1.0.0 → 2.0.0`). Apply every chapter between the detected version and the current one, IN ORDER, following each chapter's own steps exactly. Every step is idempotent: a re-run after a partial migration continues instead of breaking.

## 3. Verify after every chapter

```bash
python3 "../../scripts/validate-config.py" <root>/.neural-network/project.yaml
bash "../../scripts/preflight.sh" --spec
```

Both must be clean (no FAIL lines; deprecation notes gone once the chapter that removes them is applied) before starting the next chapter. Finish by reporting: starting version, chapters applied, final `config.py <root> schema-version` output, and anything you deliberately left for the human (e.g. committing the result — never commit unless asked).

## Maintaining the registry (for THIS repo's developers)

Any breaking change to a schema'd file (project.yaml, specs/*.yaml, feed/knowledge layouts) MUST, in the same PR: bump `SCHEMA_SEMVER` in `scripts/config.py` (major bump for breaking), add a new `## <old> → <new>` chapter to `references/migrations.md` with idempotent steps, and update validate-config/schema acceptance. See AGENTS.md §Schema versioning.
