# Design: Verified Installed Updates (#108)

Grounded in the remote-compute user-level registry and capability-bundle contract,
the existing install-cli/install-tools implementations, and issue #108's reviewed
scope. This is a documentation and verification task, not a new update service.

## Components
- Marketplace clients: refresh source snapshots and installed plugin caches.
- Host session: reload/restart only after the on-disk plugin has been updated.
- Standalone controller: install-cli copies a reviewed source tree to a prefix.
- Target helpers/controller: install-tools updates registered target tooling.
- Capability bundles: separately installed payloads and published job catalogs.

## Interfaces and Contracts
- Use existing commands and verify their current help; invent no update verb.
- Distinguish source revision, cached plugin version, running host session,
  standalone command path/version, target version/identity, and catalog readiness.
- Preserve legacy aliases, registry configuration, identity, jobs, custom payloads,
  model/workflow files and runtime data. No schema or API changes are planned.
- A merged commit, successful installer, or installed bundle alone is not proof
  of an upgraded running host or a ready capability.
- Tests are local. No pipeline configuration or CI gate is part of delivery.

## Sequences
1. Identify the installation path/scope and desired trusted source revision.
2. Capture current versions and back up the affected paths before replacement.
3. Update one layer at a time using its existing command. Reload the host only
   after the installed cache has changed; do not restart the user's app silently.
4. Verify command resolution/version, target identity, doctor output, and a
   suitable declared smoke job when prerequisites exist. Report missing assets
   or credentials honestly rather than treating them as an update success.
5. Publish legacy custom catalogs only from a reviewed bundle source. Preserve a
   complete backup; compare manifests/payloads and relocation of mutable data
   before reinstall. Never replace a custom bundle with a shipped same-name one
   merely to eliminate a legacy warning. Test the documented recovery path.

## Decisions
- Provide a dedicated guide linked from README, AGENTS, plugin README and skill
  instructions. Cite primary host documentation and date verification evidence.
- Commit failing documentation/recipe verification before filling the missing
  guide, and exercise real installers against temporary prefixes/state. Existing
  successful behavior does not need an artificial production change for TDD.
- Separate hermetic recipe verification from live deployment evidence. Read-only
  verification on 2026-10-11 found both WSL and storm590x commands at 0.1.0; no
  deployment has occurred as part of this task's preparation.

## Out of Scope
New background updater, package manager, SSH trust changes, registry migration,
automatic capability overwrite, real model downloads, and unrequested host restart.
