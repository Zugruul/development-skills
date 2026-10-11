# Design: bounded ComfyUI workflow import (#526)

Grounded in owner comments on #526, docs/design/remote-compute-plan.md E7,
and SPEC-ASSISTANT section 14's separate job/control planes. This is a human
authoring utility, not an assistant invocation or a runtime graph editor.

## Components
- comfy-import.py: stdlib-only, standalone helper in the comfyui bundle.
- capability.yaml: ship the helper and expose an explicit import-workflow job.
- Existing comfy-run.py and render recipe: unchanged API-format execution.
- Focused unittest module and shell section: part of the existing local gate.

## Interface
`python3 comfy-import.py --workflow UI.json --output API.json --profile core-txt2img-v1 [--port 8188 | --object-info INFO.json]`

No implicit conversion in render. Required explicit profile acknowledges the
bounded serializer contract. Default schema source is GET /object_info on
127.0.0.1, with finite timeout, bounded response and redirects disabled.
Offline --object-info reads a previously captured trusted server response and
does no network I/O. It does not certify the current server.
Success writes a NEW file only; never replace a source, existing file or symlink.
All validation/serialization precedes publication; failures before publication
leave no final output. Successful exclusive publication is the commit point:
if temporary-file cleanup then fails, report the artifact and success with a
cleanup warning. Never report a committed artifact as a failed import or remove
it merely to hide a cleanup error.
Output is ordinary API JSON, accepted by existing --list-nodes and render.
Exit 0 success, 2 invalid/unsupported graph or usage, 1 service/I/O failure.
Errors name the node/field where applicable and Workflow -> Export (API).

## Supported profile and data
Only workflow version numeric 0.4, nonempty nodes array, six-field links array,
mode 0 nodes and the following core classes:
CheckpointLoaderSimple, CLIPTextEncode, EmptyLatentImage, KSampler, VAEDecode,
SaveImage, PreviewImage.
Static, reviewed widget layouts are used; never derive widget order by zipping
/object_info dictionary order. Validate current required/optional inputs,
primitive/enum/connection kinds and output signatures against the profile.
Additional required inputs, unsupported optional inputs and changed signatures
fail closed. Ordinary hidden server inputs such as prompt/extra_pnginfo are
not authored into the API graph.

Widget layouts:
- CheckpointLoaderSimple: ckpt_name
- CLIPTextEncode: text
- EmptyLatentImage: width, height, batch_size
- KSampler: seed, control_after_generate, steps, cfg, sampler_name, scheduler, denoise
- VAEDecode: no widgets
- SaveImage: filename_prefix
- PreviewImage: no widgets
KSampler accepts only control_after_generate=fixed and omits this UI-only
control from output. Reject dynamic-prompt syntax rather than inventing a
frontend expansion. Refuse SaveImage filename-prefix substitution tokens rather
than silently omitting the frontend's date/node-widget expansion. The two known
SaveImage/PreviewImage output variants (legacy [] and current [IMAGE]) are
accepted only when the saved graph and server schema agree; mismatch is refused.
Validate behavioral schema options at their specific node/input site (not only
their field names): reject dynamic-prompt flags on other inputs and invalid
option types/values. Reject dynamic-prompt escape forms as transformed syntax.
Check literal types (bool is not int), finite numbers,
server enums and advertised numeric bounds. Copy titles into _meta.title.

Validate IDs without coercion collisions and refuse reserved node IDs nodes/links
which the unchanged API runner treats as UI-format markers. Other supported
string IDs remain usable. Validate unique node/link/input identities,
all endpoint slot bounds and compatible types, and exact agreement between
top-level links and node input/output references. Every required input must
be supplied once; no links into profile widget inputs (converted widgets).
Reject cycles, dangling links and duplicate destination assignments.
Do not silently drop executable nodes or prune unreachable components.
Reject nonempty subgraph definitions, reroutes, virtual/custom nodes, modes
2/4 (mute/bypass), unexpected widget counts/shapes and extension-controlled
serialization indicators. Known custom package metadata must not masquerade
as a supported core node. Layout/position/group decoration may be ignored.

## Sequence and safety
1. Strictly parse bounded UTF-8 JSON (reject duplicate keys and nonfinite JSON).
2. Validate profile, graph, schema and value compatibility without executing code.
3. Convert existing edges to [string-source-id, output-index] and existing widget
   literals to named inputs. No generated nodes, links, defaults or prompt changes.
4. Serialize completely and publish exclusively with cleanup on failed writes.
Bound files/responses (4 MiB) and graph size (1024 nodes, 8192 links); use
iterative graph traversal. No POST /prompt, GPU work, shell execution, model
downloads, server installation, pip dependencies or changes to registrations.
Import recipe writes `{jobdir}/workflow_api.json`, reports it as an ARTIFACT,
and accepts workflow and port parameters; subsequent rendering is a separate
human-approved action. Existing job names/parameters remain compatible.

## Decisions and scope
This profile is a supported serialization shape, NOT universal compatibility
with every frontend/custom-node release. Exact shape checks catch drift, but
trusted extensions can alter semantics invisibly: use native API export in
those installations. No claim that all historically saved workflows import.
Unsupported graphs retain an actionable native-export fallback.
No assistant spec delta is expected: this helper never changes section 14
transport, grants, dispatch, trace or runtime override behavior.

## Evidence and tests
Primary upstream references inspected 2026-10-11:
- https://github.com/Comfy-Org/ComfyUI_frontend/blob/main/docs/WIDGET_SERIALIZATION.md
- https://github.com/Comfy-Org/ComfyUI/blob/master/nodes.py
- https://github.com/Comfy-Org/docs/blob/main/specs/workflow_json.mdx
- https://github.com/Comfy-Org/ComfyUI_frontend/blob/main/src/scripts/defaultGraph.ts
- https://github.com/Comfy-Org/ComfyUI_frontend/blob/main/src/extensions/core/saveImageExtraOutput.ts

Use a realistic paired core UI/API fixture with documented source/provenance,
plus a representative object_info snapshot. Test exact output including seed
and titles; reordered schema maps; links; all refusal categories; malformed/
oversized/duplicate-key JSON; offline no-network; local HTTP GET-only boundary;
redirect refusal; exclusive output (same path/existing file/symlink); no output
after failure; bundle payload and import recipe; unchanged API render behavior.
Commit failing tests BEFORE implementation. Full gate and both independent
review passes run locally, with no pipeline setup.
