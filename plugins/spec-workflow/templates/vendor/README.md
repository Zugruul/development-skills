# Vendored: three.js

Neural view's 3D renderer is three.js, vendored here and served same-origin
by `neural-view.py` (routes `/vendor/three.module.min.js` and
`/vendor/three.core.min.js`) — no CDN request at runtime, no build step.

Two files, not one: since three.js r0.150+ the official ES-module minified
build is split — `three.module.min.js` ends with a relative import
(`from"./three.core.min.js"`), so the browser resolves and fetches the core
file at runtime. Both must be vendored and allowlisted in `neural-view.py`'s
`VENDOR_FILES`, or the browser 404s resolving the import graph and the whole
3D view fails to boot (this was bug #58 — only the module file was vendored).

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
- **Version**: r0.185.1 (npm `three@0.185.1`), same release as the module above
- **Source**: `https://unpkg.com/three@0.185.1/build/three.core.min.js`
- **Build**: the core implementation the ES-module build imports at runtime
  via a relative specifier; fetched and served same-origin so that import
  resolves without a CDN request.
- **License**: MIT, © three.js authors.
- **sha256**: `05b2609338c76cd65daf74f3ac515bc9a5045e1b3b33edc07d8c9bd55250fa90`

To re-vendor a newer release (fetch BOTH files — they're one release, kept in sync):

```bash
curl -sf https://unpkg.com/three@<version>/build/three.module.min.js \
  -o plugins/spec-workflow/templates/vendor/three.module.min.js
curl -sf https://unpkg.com/three@<version>/build/three.core.min.js \
  -o plugins/spec-workflow/templates/vendor/three.core.min.js
shasum -a 256 plugins/spec-workflow/templates/vendor/three.module.min.js
shasum -a 256 plugins/spec-workflow/templates/vendor/three.core.min.js
```

Then update the version/URL/sha256 above and in
`plugins/spec-workflow/tests/section-neural-view-template.sh` (the
vendored-file integrity check, `NVVENDOR_SHA` / `NVVENDOR_CORE_SHA`).
