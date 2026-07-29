#!/usr/bin/env bash
# e2e-voice-loop.sh -- NON-HERMETIC end-to-end proof of the hands-free
# voice loop (2026-07-29, human-directed: "play a sound and have it
# respond to it"). Deliberately NOT registered in run-tests.sh's SECTIONS:
# it needs real Chrome, the real whisper sidecar, and macOS `say` -- the
# hermetic suite must never depend on any of those. Run standalone:
#
#   bash plugins/spec-workflow/tests/e2e-voice-loop.sh
#
# What it proves, against the REAL template served by a REAL neural-view
# server, with REAL audio through Chrome's fake-mic device and the REAL
# whisper.cpp sidecar (only POST /assistant/chat is stubbed, so no LLM
# engine is needed):
#   1. pressing the voice control turns the loop ON (dot bright, listening)
#   2. spoken audio is VAD-endpointed on a natural pause -- no button press
#   3. the utterance reaches the whisper sidecar and comes back as text
#   4. the transcript is sent to the chat path verbatim
#   5. after the turn the loop is STILL on (hands-free rounds)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SIDECAR_PORT="${WHISPER_SIDECAR_PORT:-8737}"
NV_PORT="${E2E_NV_PORT:-8911}"
CDP_PORT="${E2E_CDP_PORT:-9333}"

skip(){ echo "SKIP: $1"; exit 0; }
[ -x "$CHROME" ] || skip "Chrome not found at $CHROME"
command -v say >/dev/null 2>&1 || skip "macOS 'say' not available"
command -v node >/dev/null 2>&1 || skip "node not available"
curl -s -m 2 -o /dev/null "http://127.0.0.1:$SIDECAR_PORT/" || skip "whisper sidecar not running on :$SIDECAR_PORT (start it: python3 plugins/spec-workflow/skills/whisper-sidecar/whisper_sidecar.py start)"

TMP="$(mktemp -d)"
NV_PID=""
CHROME_PID=""
cleanup(){
    [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null
    [ -n "$NV_PID" ] && kill "$NV_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

# --- test audio: a spoken phrase + 2.5s of trailing silence so the looped
# fake-mic playback always contains a VAD-endpointable pause ---
say -o "$TMP/phrase.aiff" "can you hear me"
afconvert -f WAVE -d LEI16@44100 -c 1 "$TMP/phrase.aiff" "$TMP/phrase-raw.wav"
python3 - "$TMP/phrase-raw.wav" "$TMP/phrase.wav" <<'PYEOF'
import sys, wave
w = wave.open(sys.argv[1], 'rb')
params = w.getparams(); frames = w.readframes(w.getnframes()); w.close()
out = wave.open(sys.argv[2], 'wb'); out.setparams(params)
out.writeframes(frames + b'\x00\x00' * int(params.framerate * 2.5)); out.close()
PYEOF

# --- a private neural-view server over THIS checkout's template ---
NEURAL_VIEW_STATE="$TMP/nv-state" python3 "$PLUGIN/scripts/neural-view.py" serve \
    --port "$NV_PORT" --dir "$TMP/nv-state" --scan "$(cd "$PLUGIN/../.." && pwd)" \
    > "$TMP/nv-server.log" 2>&1 &
NV_PID=$!
for _ in $(seq 1 30); do
    curl -s -m 1 -o /dev/null "http://127.0.0.1:$NV_PORT/" && break
    sleep 0.5
done
curl -s -m 2 -o /dev/null "http://127.0.0.1:$NV_PORT/" || { echo "FAIL neural-view server never came up (see $TMP/nv-server.log)"; exit 1; }

# --- headless Chrome, fake mic fed the spoken WAV (looped; the baked-in
# trailing silence provides the endpointing pause). --no-sandbox is
# required for the fake device to READ the wav file. ---
"$CHROME" --headless=new --no-sandbox --remote-debugging-port="$CDP_PORT" \
    --user-data-dir="$TMP/chrome-profile" --no-first-run \
    --use-fake-ui-for-media-stream --use-fake-device-for-media-stream \
    "--use-file-for-fake-audio-capture=$TMP/phrase.wav" \
    --autoplay-policy=no-user-gesture-required about:blank \
    > "$TMP/chrome.log" 2>&1 &
CHROME_PID=$!
sleep 4

cat > "$TMP/driver.mjs" <<'DRIVEREOF'
const [cdpPort, nvPort] = [process.argv[2], process.argv[3]];
const list = await (await fetch(`http://127.0.0.1:${cdpPort}/json`)).json();
const page = list.find(t => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
function send(method, params){ return new Promise((res, rej) => { const i = ++id; pending.set(i, {res, rej}); ws.send(JSON.stringify({id: i, method, params})); }); }
ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result); } };
await new Promise(r => ws.onopen = r);
await send("Page.enable", {});
await send("Page.navigate", {url: `http://127.0.0.1:${nvPort}/`});
await new Promise(r => setTimeout(r, 3000));
async function evaljs(expr){
  const r = await send("Runtime.evaluate", {expression: expr, returnByValue: true, awaitPromise: true});
  if (r.exceptionDetails) throw new Error("page threw: " + JSON.stringify((r.exceptionDetails.exception && r.exceptionDetails.exception.description) || r.exceptionDetails.text));
  return r.result.value;
}
// open the gate + intercept ONLY /assistant/chat (no LLM in this test);
// voice-event/history/status are engine bookkeeping, stubbed to keep the
// page quiet. Everything audio-side runs for real.
await evaljs(`
  window.assistantGate = {gated:false};
  window.__assistantSelected = "e2e";
  window.__chatPosts = [];
  const orig = window.fetch.bind(window);
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith("/assistant/chat")) { window.__chatPosts.push(opts && opts.body); return Promise.resolve(new Response(JSON.stringify({text: "yes, loud and clear"}), {status: 200, headers: {"content-type": "application/json"}})); }
    if (u.startsWith("/assistant/voice-event") || u.startsWith("/assistant/history") || u.startsWith("/assistant/status")) return Promise.resolve(new Response(JSON.stringify({events: [], exchanges: [], gated: false}), {status: 200, headers: {"content-type": "application/json"}}));
    return orig(url, opts);
  };
  "patched";
`);
await evaljs(`(function(){ const b = document.getElementById("voice-stt"); b.disabled = false; b.click(); return true; })()`);
let result = null;
for (let i = 0; i < 60; i++) {
  await new Promise(r => setTimeout(r, 500));
  result = await evaljs(`({listening: !!window.__sttListening, loopOn: !!window.__voiceLoopOn, posts: window.__chatPosts, lastErr: window.__lastSttError || null, dot: document.getElementById("voice-stt").classList.contains("listening")})`);
  if (result.posts.length) break;
}
if (!result.posts.length) { console.log("E2E_FAIL no transcript ever reached the chat send path: " + JSON.stringify(result)); process.exit(1); }
const body = JSON.parse(result.posts[0]);
console.log("transcript sent to chat: " + JSON.stringify(body.message));
const norm = body.message.toLowerCase().replace(/[^a-z ]/g, "");
if (!norm.includes("can you hear me")) { console.log("E2E_FAIL transcript mismatch: " + norm); process.exit(1); }
if (!result.loopOn) { console.log("E2E_FAIL loop turned itself off after one turn -- hands-free rounds broken"); process.exit(1); }
if (!result.dot) { console.log("E2E_FAIL mic dot dark while the loop owns capture"); process.exit(1); }
console.log("E2E_OK spoken audio -> VAD pause endpoint -> whisper sidecar -> verbatim transcript -> chat send; loop still on, dot bright");
process.exit(0);
DRIVEREOF

if node "$TMP/driver.mjs" "$CDP_PORT" "$NV_PORT"; then
    echo "PASS e2e voice loop"
else
    echo "FAIL e2e voice loop (chrome log: $TMP/chrome.log)"
    trap - EXIT
    [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null
    [ -n "$NV_PID" ] && kill "$NV_PID" 2>/dev/null
    exit 1
fi
