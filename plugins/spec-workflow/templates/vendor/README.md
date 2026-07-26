# Vendored: three.js

Neural view's 3D renderer is three.js, vendored here and served same-origin
by `neural-view.py` (routes `/vendor/three.module.min.js` and
`/vendor/three.core.min.js`) — no CDN request at runtime, no build step.

As of r167, three.js splits its ES-module build in two: `three.module.min.js`
begins with `import{...}from"./three.core.min.js"`, a relative import the
browser resolves against the module's own same-origin URL. Both files must
be vendored AND allowlisted in `neural-view.py`'s `VENDOR_FILES`, or the
import 404s and the 3D scene never boots — a re-vendor that only updates
`three.module.min.js` will silently break the page. The test suite's
split-build guard (`section-neural-view-template.sh`) catches this: it greps
the vendored module file for every relative import target and asserts each
one is present on disk and allowlisted.

- **File**: `three.module.min.js`
- **Version**: r0.185.1 (npm `three@0.185.1`)
- **Source**: `https://unpkg.com/three@0.185.1/build/three.module.min.js`
- **Build**: the official ES-module minified build (loaded via `<script type="module">`
  and a same-origin `importmap` — no bundler/build step needed). No addons
  (e.g. `OrbitControls`) are vendored; neural-view.html hand-rolls its own
  minimal orbit/pan/zoom controller against the core `three` API to avoid a
  second vendored file.
- **License**: MIT, © three.js authors.
- **sha256**: `86bcee248b64f44bcfc23c331ae74619061957d59cab040171dcb6fb5900beb6`

- **File**: `three.core.min.js`
- **Version**: r0.185.1 (npm `three@0.185.1`)
- **Source**: `https://unpkg.com/three@0.185.1/build/three.core.min.js`
- **Build**: the core-build companion `three.module.min.js` imports relatively;
  not loaded directly by neural-view.html, only fetched by the browser as a
  side effect of resolving the module import.
- **License**: MIT, © three.js authors.
- **sha256**: `05b2609338c76cd65daf74f3ac515bc9a5045e1b3b33edc07d8c9bd55250fa90`

To re-vendor a newer release (fetch BOTH files — the split-build note above):

```bash
curl -sf https://unpkg.com/three@<version>/build/three.module.min.js \
  -o plugins/spec-workflow/templates/vendor/three.module.min.js
curl -sf https://unpkg.com/three@<version>/build/three.core.min.js \
  -o plugins/spec-workflow/templates/vendor/three.core.min.js
shasum -a 256 plugins/spec-workflow/templates/vendor/three.module.min.js \
  plugins/spec-workflow/templates/vendor/three.core.min.js
```

Then update the version/URL/sha256 for both files above and in
`plugins/spec-workflow/tests/section-neural-view-template.sh` (the
`NVVENDOR_SHA` / `NVCORE_SHA` integrity checks).

## Note-media 3D viewers (#289)

- **Files**: `GLTFLoader.js`, `BufferGeometryUtils.js`, `SkeletonUtils.js`
- **Version**: r0.185.1 (npm `three@0.185.1`, `examples/jsm/loaders` + `examples/jsm/utils`)
- **Source**: `https://unpkg.com/three@0.185.1/examples/jsm/...`
- **Local change**: GLTFLoader's two relative imports (`../utils/BufferGeometryUtils.js`,
  `../utils/SkeletonUtils.js`) are rewritten to same-dir (`./...`) so they resolve
  under the flat `/vendor/` route. Re-vendoring must re-apply that rewrite.
- **License**: MIT, © three.js authors.
- **sha256** (after rewrite):
  - `GLTFLoader.js`: `ad534a8e1545d8a4a55e4c400e22e69411a68dbcac1a8013026e56ee8ef4475d`
  - `BufferGeometryUtils.js`: `5c552223a9309883743b80538d6e9cdb45e3227f30d3ec56fb2c39b46e78d595`
  - `SkeletonUtils.js`: `b1632a703206c3d830de9fcbe515696770d04b71a15ee6b50afa6d2c3298c86f`
  Loaded lazily (dynamic import) only when a note embeds a .glb/.gltf file;
  .obj/.stl use hand-rolled parsers in the template, no addon needed.

## Note-media mermaid diagrams (#430)

- **File**: `mermaid.min.js`
- **Version**: 11.16.0 (npm `mermaid@11.16.0`)
- **Source**: `https://unpkg.com/mermaid@11.16.0/dist/mermaid.min.js`
- **Build**: the official browser IIFE bundle — a single self-contained file
  (esbuild output; assigns `globalThis.mermaid`, no relative imports and no
  split-build companion the way three.js needs). Loaded lazily via dynamic
  `import("/vendor/mermaid.min.js")`, only the first time a note actually has
  a fenced ` ```mermaid ` block — it's a large bundle (~3.4MB unminified
  library, dagre/cytoscape layout engines included) with no reason to pay for
  it on every note. `mermaid.initialize({securityLevel:"strict"})` is set
  before the first render so note-derived diagram source can't smuggle raw
  HTML through mermaid's own rendering (XSS discipline — see neural-view.py's
  `render_body`, which independently HTML-escapes the source for the
  text-mode `<pre><code>` fallback).
- **License**: MIT, © Mermaid contributors.
- **sha256**: `74d7c46dabca328c2294733910a8aa1ed0c37451776e8d5295da38a2b758fb9b`

To re-vendor a newer release:

```bash
curl -sfL https://unpkg.com/mermaid@<version>/dist/mermaid.min.js \
  -o plugins/spec-workflow/templates/vendor/mermaid.min.js
shasum -a 256 plugins/spec-workflow/templates/vendor/mermaid.min.js
```

Then update the version/URL/sha256 above.
