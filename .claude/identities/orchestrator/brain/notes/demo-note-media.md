---
tags: [demo, media, neural-view]
paths: []
strength: 1
source: "PR#288 note-media dogfood (issue #289)"
graduated: false
created: 2026-07-21
---

# Note media — one example per supported entity type

Live demo AND feedback record for neural-view's note media (PR#288). Paths are relative to this brain's directory; served read-only via `/file/`, extension-allowlisted.

## Images — `![alt](path)` embeds inline; click opens the media viewer

Local PNG: ![Duck render](assets/demo/duck.png)

Remote image (http/https passes through untouched): ![glTF logo](https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/BoomBox/screenshot/screenshot.jpg)

Supported image extensions: `.png .jpg .jpeg .gif .webp .svg`

## Video — `[label](path.mp4)` becomes an inline player

[Sintel trailer](assets/demo/demo.mp4)

Supported: `.mp4 .webm .mov` (local files only — remote video links open as plain external links)

## 3D models — `[label](path)` becomes a live rotating viewer

GLB (vendored GLTFLoader): [Khronos duck](assets/demo/duck.glb)

OBJ (hand parser): [pyramid](assets/demo/pyramid.obj)

STL (hand parser, binary or ascii): [cube](assets/demo/cube.stl)

Supported: `.glb .gltf .obj .stl`

## Plain files — `[label](path)` opens raw in a new tab

[demo.txt](assets/demo/demo.txt) — also `.md .json .pdf`

## Other link types

External link (opens in new tab): [glTF sample models](https://github.com/KhronosGroup/glTF-Sample-Models)

Wikilink to another note in this brain: [[bisect-before-blaming-tracked-flakiness]]

## Feedback from building this demo

- Everything above embeds with plain markdown — no special syntax beyond `![]()` vs `[]()`.
- Video/3D embeds hang off ordinary links, so the note stays readable as raw markdown in any editor.
- Local ffmpeg was broken (missing x265 dylib), so the video sample is a fetched file — the feature never needs transcoding, any browser-playable file works.
- Remote video does NOT inline (only local files do); remote images DO. Asymmetry is deliberate for now.
## Feedback addendum: this demo caught a real bug — code-span examples (`![alt](path)`) were parsed as live media; fixed in sw/neural-view-synapse-clicks by protecting backtick spans in render_body.
