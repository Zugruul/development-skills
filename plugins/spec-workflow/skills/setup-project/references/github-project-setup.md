# GitHub Project setup — exact commands

Create a Projects (v2) board and collect every id `.claude/project.yaml` needs. Replace `OWNER` (user/org) and `OWNER/REPO` throughout.

## 1. Create the project
Only on the EXPLICIT create path (setup-project Phase 3 — the user chose "Create a new Project" or asked for one). Default is wiring an existing Project: discover with `gh project list --owner OWNER --format json` and skip to §2.
```bash
gh project create --owner OWNER --title "My Platform Build"
# note the printed number, e.g. 3  -> boards[].projectNumber
```

## 2. Fields
Projects come with a single-select **Status** field. `gh project field-*` cannot edit an existing field's options, but the GraphQL API can — no web UI needed:

**A (GraphQL, recommended for Status):** get the Status field id from `gh project field-list <number> --owner OWNER --format json`, then replace its options in one mutation (this REPLACES the whole option set — list every option, in `statusFlow` order; the response carries each option's 8-char id → `fields.status.options`):
```bash
gh api graphql -f query='
mutation {
  updateProjectV2Field(input: {
    fieldId: "PVTSSF_..."
    singleSelectOptions: [
      {name: "Backlog", color: GRAY, description: ""}
      {name: "In progress", color: YELLOW, description: ""}
      {name: "In review", color: ORANGE, description: ""}
      {name: "QA", color: BLUE, description: ""}
      {name: "Ready", color: GREEN, description: ""}
      {name: "Deployed", color: PURPLE, description: ""}
    ]
  }) { projectV2Field { ... on ProjectV2SingleSelectField { options { id name } } } }
}'
```
Web-UI fallback: `https://github.com/users/OWNER/projects/<number>/settings/fields` (or `/orgs/OWNER/...`) — ask the human if needed.

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
