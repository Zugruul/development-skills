// opencode-driver.mjs -- loads the OpenCode adapter as OpenCode would, with a fake SDK client,
// and plays the events of a JSON script. Prints one line per call the adapter makes to the
// client: "CALL <method> <session> <json body>".
// Usage: node opencode-driver.mjs PLUGIN_FILE SCRIPT_JSON
// SCRIPT_JSON: {sessions: {id: {parentID?, last?}}, steps: [{event} | {chat: {session, text}}
//   | {compacting: id} | {waitCall: ms}]}
import { pathToFileURL } from "node:url"

const [file, scriptJson] = process.argv.slice(2)
const script = JSON.parse(scriptJson)
const sessions = script.sessions ?? {}
let calls = 0
const log = (method, id, body) => {
  calls++
  console.log(`CALL ${method} ${id} ${JSON.stringify(body)}`)
}
let hooks
// OpenCode runs chat.message for every message, the adapter's own too, and session.prompt returns
// only after that hook has returned (promptAsync returns at once)
const deliver = (id, body) =>
  hooks["chat.message"]?.({ sessionID: id, agent: body.agent }, { message: { id: "msg_own", sessionID: id }, parts: structuredClone(body.parts) })
setTimeout(() => { console.log("DEADLOCK: the adapter never returned"); process.exit(1) }, 40000)

const client = {
  session: {
    get: async ({ path }) => ({ data: { id: path.id, parentID: sessions[path.id]?.parentID } }),
    messages: async ({ path }) => ({
      data: [
        { info: { role: "user" }, parts: [{ type: "text", text: "brief" }] },
        { info: { role: "assistant" }, parts: [{ type: "reasoning", text: "NODE investigate RESULT: pass thought" }, { type: "text", text: sessions[path.id]?.last ?? "" }] },
      ],
    }),
    promptAsync: async ({ path, body }) => { log("promptAsync", path.id, body); setTimeout(() => deliver(path.id, body), 0); return {} },
    prompt: async ({ path, body }) => { await deliver(path.id, body); log("prompt", path.id, body); return {} },
  },
}

const mod = await import(pathToFileURL(file).href)
const exported = Object.keys(mod)
console.log(`EXPORTS ${exported.join(",")}`)
hooks = await mod[exported[0]]({ client, directory: process.cwd(), worktree: process.cwd() })
console.log(`HOOKS ${Object.keys(hooks).sort().join(",")}`)
for (const step of script.steps ?? []) {
  if (step.event) await hooks.event?.({ event: step.event })
  else if (step.chat) {
    const output = { message: { id: "msg_1", sessionID: step.chat.session }, parts: [{ type: "text", text: step.chat.text }] }
    await hooks["chat.message"]?.({ sessionID: step.chat.session, agent: "build" }, output)
    console.log(`PARTS ${JSON.stringify(output.parts)}`)
  } else if (step.compacting) await hooks["experimental.session.compacting"]?.({ sessionID: step.compacting }, { context: [] })
  else if (step.waitCall) {
    const before = calls
    const end = Date.now() + step.waitCall
    while (calls === before && Date.now() < end) await new Promise((r) => setTimeout(r, 100))
  }
}
await hooks.dispose?.()
process.exit(0)
