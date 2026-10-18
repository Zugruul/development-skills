---
name: comfyui-render
description: Queue a pinned ComfyUI image workflow on an explicitly provisioned SSH target, inspect task progress, or request safe cancellation of an owned assistant render. Uses the assistant task engine; excludes human remote-compute CLI jobs and workflow authoring.
---

# ComfyUI Render

Select an installed host and workflow name. Invoke the enabled capability with
`host`, `operation: render`, `workflow`, `values` (a JSON object encoded as a
string), and `task_id: ""`. Supply only the workflow's declared literal input
names. Missing inputs retain their pinned template values. Never request new
graphs, paths, endpoints, keys, timeout overrides, or model downloads.

Work is always queued. Report the assistant task state and its artifact when
completed. Native progress reflects observed node counts; absence of progress
does not establish completion. Unknown/orphaned submission must be inspected,
never automatically resubmitted. Keep its task ID for recovery.

To cancel, use `operation: cancel`, the same host/workflow, `values: "{}"`, and
the existing assistant `task_id`. Only pending owned work can be safely deleted.
Running cancellation remains unconfirmed; do not describe a closed SSH tunnel
as stopped GPU execution. This adapter never calls global `/interrupt`.

Installation is explicit, data-only, and separate from enablement. An operator
runs the plugin's `scripts/assistant/comfyui_render.py install --assistant-root`
with an absolute assistant root, then provisions the installed manifest and
separately enables the capability. Existing installations are refused.
The engine stays in the plugin. Registry membership grants no permission.

See `docs/assistant-comfyui-render.md` in the development-skills repository for
the policy schema, exact OpenSSH restrictions, endpoint trust, and recovery
limitations. Local checks cannot certify remote restrictions or GPU availability.
