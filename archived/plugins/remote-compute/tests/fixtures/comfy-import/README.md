# core-txt2img-v1 evidence

These three JSON fixtures are synthetic, hand-authored behavioral test data,
not captured exports or a captured server response. `api.json` is the separately
written expected result for `ui.json`; tests never derive it from the importer.
The schema fixture models the seven core definitions with deliberately small
checkpoint/sampler enums. No model is downloaded or certified by these files.

Primary sources inspected 2026-10-11:
- [Workflow v0.4 schema](https://github.com/Comfy-Org/docs/blob/main/specs/workflow_json.mdx): node arrays and six-field link tuples.
- [Frontend default graph](https://github.com/Comfy-Org/ComfyUI_frontend/blob/main/src/scripts/defaultGraph.ts): saved widget positions, including the secondary seed control. Boolean legacy controls are not supported.
- [Widget serialization](https://github.com/Comfy-Org/ComfyUI_frontend/blob/main/docs/WIDGET_SERIALIZATION.md): UI persistence and API serialization differ; the seed control is UI-only.
- [Core nodes](https://github.com/Comfy-Org/ComfyUI/blob/master/nodes.py): required inputs, numeric bounds, hidden inputs and output signatures. Current SaveImage returns IMAGE; PreviewImage inherits it. Tests also cover legacy empty outputs, requiring exact agreement with the selected schema.
- [SaveImage frontend serialization](https://github.com/Comfy-Org/ComfyUI_frontend/blob/main/src/extensions/core/saveImageExtraOutput.ts) and [replacements](https://github.com/Comfy-Org/ComfyUI_frontend/blob/main/src/utils/searchAndReplace.ts): filename tokens can expand before API submission and must be refused here.

The fixture uses an explicit fixed seed, two encoders, shared checkpoint outputs,
fan-out from VAEDecode, SaveImage and PreviewImage, titles, an empty negative
prompt and normal layout metadata. Its current output shape is intentional:
historical UI saves with empty SaveImage outputs cannot be paired with a current
IMAGE-output schema. This profile is a serializer contract, not a claim that
every frontend version or extension has equivalent behavior.

R2 escape regressions use reviewer-supplied static inspection of
[formatUtil.ts](https://github.com/Comfy-Org/ComfyUI_frontend/blob/main/packages/shared-frontend-utils/src/formatUtil.ts#L226):
its final replacement removes backslashes before braces and pipes, and
`handleEscape` consumes the next character without a terminal-character guard.
Escaped pipes and odd trailing backslash runs are therefore refused. The latter
is a conservative source-derived boundary, not an upstream-runtime-verified
claim. Ordinary backslashes and even trailing runs are preserved. No upstream
code is fetched or executed by these tests.
