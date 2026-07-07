# GitHub Project setup — exact commands

Create a Projects (v2) board and collect every id `.claude/project.yaml` needs. Replace `OWNER` (user/org) and `OWNER/REPO` throughout.

## 1. Create the project
```bash
gh project create --owner OWNER --title "My Platform Build"
# note the printed number, e.g. 3  -> boards[].projectNumber
```

## 2. Fields
Projects come with a single-select **Status** field, but its options must be edited in the web UI (the CLI cannot edit options of an existing field). Two options:

**A (web UI, recommended for Status):** open `https://github.com/users/OWNER/projects/<number>/settings/fields` (or `/orgs/OWNER/...`) and edit **Status** so its options are exactly your intended `statusFlow`, e.g. `Backlog, In progress, In review, QA, Ready, Deployed`. Ask the human to do this if you cannot.

**B (CLI, for new fields):** Priority and Estimate can be created directly:
```bash
gh project field-create <number> --owner OWNER --name "Priority" --data-type SINGLE_SELECT \
    --single-select-options "P0,P1,P2"
gh project field-create <number> --owner OWNER --name "Estimate" --data-type NUMBER
```

## 3. Discover ids
With a minimal `.claude/project.yaml` in place (template values are fine for everything except `owner`, `repo`, `projectNumber` — set those real ones first):
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh" fields
```
This prints every field id and, for single-selects, each option's id. If it fails because `projectId` is still a placeholder, get it directly:
```bash
gh project view <number> --owner OWNER --format json -q .id     # -> "PVT_..." = boards[].projectId
gh project field-list <number> --owner OWNER --format json      # raw fields + options JSON
```

Map into `.claude/project.yaml`:
| json path | source |
|---|---|
| `boards[].projectId` | `gh project view ... -q .id` (starts `PVT_`) |
| `fields.status.fieldId` | the field named `Status` (starts `PVTSSF_`) |
| `fields.status.options` | each Status option name → its 8-char id, **in statusFlow order** |
| `fields.priority.fieldId` / `.options` | the `Priority` field, options highest-priority first |
| `fields.estimate.fieldId` | the `Estimate` field (starts `PVTF_`) |

## 4. Auto-add issues (optional, recommended)
In the project's web settings, enable the built-in **auto-add workflow** for `OWNER/REPO` so new issues (e.g. bugs filed by `board.sh bug`) join the board automatically. `board.sh` and `seed-board.sh` also `item-add` defensively, so this is a convenience, not a requirement.

## 5. Duplicate-option gotcha
If a single-select ends up with two options of the same name (it happens when editing), delete one in the web UI and keep exactly one id per name in the config — the scripts assume names are unique.
