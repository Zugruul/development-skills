# Vendored: three.js

Neural view's 3D renderer is three.js, vendored here and served same-origin
by `neural-view.py` (route `/vendor/three.module.min.js`) — no CDN request at
runtime, no build step.

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

To re-vendor a newer release:

```bash
curl -sf https://unpkg.com/three@<version>/build/three.module.min.js \
  -o plugins/spec-workflow/templates/vendor/three.module.min.js
shasum -a 256 plugins/spec-workflow/templates/vendor/three.module.min.js
```

Then update the version/URL/sha256 above and in
`plugins/spec-workflow/tests/run-tests.sh` (the vendored-file integrity check).
