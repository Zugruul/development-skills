// herdr-graph.js -- the OpenCode side of hooks/hooks.json. OpenCode runs no command hooks: it
// loads JavaScript plugins. This one turns its events into the same calls of the plugin's bash
// scripts, so all the rules stay in the scripts.
//
//   OpenCode                          Claude Code and Codex hook      script
//   session.idle                      Stop                            hook.sh stop, then await.sh
//   chat.message                      UserPromptSubmit                hook.sh prompt
//   question.asked                    PreToolUse (question tool)      hook.sh ask
//   question.replied, .rejected       PostToolUse                     hook.sh ask-done
//   permission.asked                  PermissionRequest               hook.sh permission
//   session.error                     StopFailure                     hook.sh stop-failure
//   experimental.session.compacting   PreCompact                      resume.sh --hook pre-compact
//   session.compacted                 SessionStart (compact)          resume.sh --hook session-start
//
// The waiter (await.sh) runs beside the chat; when it ends with an event, the plugin sends the
// message through OpenCode's own API, so nothing is typed into the input box.
// Install: ./install-skills.sh opencode (it links this file into OpenCode's plugins folder).
// OpenCode calls every export as a plugin: keep exactly one.
import { spawn } from "node:child_process"
import { realpathSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

export const HerdrGraphEngineering = async ({ client, directory }) => {
  if (!process.env.HERDR_PANE_ID) return {}

  const scripts = join(dirname(realpathSync(fileURLToPath(import.meta.url))), "..", "scripts")
  const own = new Set() // texts this plugin sent: they are no message of the user's
  const continued = new Set() // sessions whose current turn a stop decision started
  const failed = new Set() // sessions whose turn ended in an error: its idle event is no turn end
  const subagent = new Map()
  const chats = new Map() // session -> {agent, model} of the user's latest message
  let waiter = null

  const start = (script, args, input) => {
    const child = spawn("bash", [join(scripts, script), ...args], {
      cwd: directory || process.cwd(),
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"],
    })
    let stdout = ""
    let stderr = ""
    child.stdout.on("data", (d) => (stdout += d))
    child.stderr.on("data", (d) => (stderr += d))
    child.stdin.on("error", () => {})
    child.stdin.end(JSON.stringify(input))
    const done = new Promise((resolve) => {
      child.on("error", () => resolve({ code: -1, stdout, stderr }))
      child.on("close", (code) => resolve({ code, stdout, stderr }))
    })
    return { child, done }
  }
  const run = (script, args, input) => start(script, args, input).done
  const hook = async (event, input) => parse((await run("hook.sh", [event], input)).stdout)
  const parse = (text) => {
    try {
      return JSON.parse(text)
    } catch {
      return null
    }
  }

  const isSubagent = async (id) => {
    if (!subagent.has(id)) {
      const res = await client.session.get({ path: { id } })
      subagent.set(id, Boolean(res?.data?.parentID))
    }
    return subagent.get(id)
  }

  const lastMessage = async (id) => {
    const res = await client.session.messages({ path: { id } })
    const last = (res?.data ?? []).filter((m) => m.info?.role === "assistant").pop()
    return (last?.parts ?? [])
      .filter((p) => p.type === "text")
      .map((p) => p.text)
      .join("\n")
  }

  const body = (id, text, extra) => ({
    path: { id },
    body: { ...chats.get(id), ...extra, parts: [{ type: "text", text, ...(extra?.noReply ? { synthetic: true } : {}) }] },
  })
  const send = async (id, text) => {
    own.add(text)
    await client.session.promptAsync(body(id, text))
  }

  // One waiter at a time: a newer one takes over, as await.sh itself does.
  const stopWaiter = () => {
    waiter?.kill()
    waiter = null
  }
  const arm = (id) => {
    stopWaiter()
    const { child, done } = start("await.sh", ["--hook", "--client", "opencode"], {})
    waiter = child
    done.then(async ({ code, stderr }) => {
      if (waiter === child) waiter = null
      if (code === 2 && stderr.trim()) await send(id, stderr.trim()).catch(() => {})
    })
  }
  process.once("exit", stopWaiter)

  const onEvent = async ({ type, properties: p = {} }) => {
    const id = p.sessionID
    switch (type) {
      case "session.idle": {
        if (await isSubagent(id)) return
        if (failed.delete(id)) return
        const active = continued.delete(id)
        const out = await hook("stop", { session_id: id, stop_hook_active: active, last_assistant_message: await lastMessage(id) })
        if (out?.decision === "block" && out.reason) {
          continued.add(id)
          await send(id, out.reason)
          return
        }
        arm(id)
        return
      }
      case "session.error": {
        const error = p.error ?? {}
        if (!id || error.name === "MessageAbortedError" || (await isSubagent(id))) return
        failed.add(id)
        await hook("stop-failure", { session_id: id, error: error.data?.message || error.name || "unknown error" })
        return
      }
      // a subagent's question or permission also stops the agent, so these count for any session
      case "question.asked":
        await hook("ask", { session_id: id, tool_name: "question", tool_input: { questions: p.questions ?? [] } })
        return
      case "question.replied":
      case "question.rejected":
        await hook("ask-done", { session_id: id, tool_name: "question" })
        return
      case "permission.asked": {
        const command = p.metadata?.command || (p.patterns ?? []).join(" ")
        await hook("permission", { session_id: id, tool_name: p.permission, tool_input: { command } })
        return
      }
      case "session.compacted": {
        if (await isSubagent(id)) return
        const out = parse((await run("resume.sh", ["--hook", "session-start"], {})).stdout)
        const text = out?.hookSpecificOutput?.additionalContext
        if (!text) return
        own.add(text)
        await client.session.prompt(body(id, text, { noReply: true }))
      }
    }
  }

  // OpenCode does not wait for one event before it sends the next: keep their order.
  let queue = Promise.resolve()
  const inOrder = (work) => (queue = queue.then(work).catch(() => {}))

  return {
    event: ({ event }) => inOrder(() => onEvent(event)),
    "chat.message": (input, output) =>
      inOrder(async () => {
        const id = input.sessionID
        const text = output.parts
          .filter((p) => p.type === "text")
          .map((p) => p.text)
          .join("\n")
        if (own.delete(text) || (await isSubagent(id))) return
        const chat = {}
        if (input.agent) chat.agent = input.agent
        if (input.model) chat.model = input.model
        chats.set(id, chat)
        failed.delete(id)
        const out = await hook("prompt", { session_id: id, prompt: text })
        const context = out?.hookSpecificOutput?.additionalContext
        if (!context) return
        output.parts.push({
          id: `prt_herdrgraph${Date.now().toString(36)}`,
          sessionID: id,
          messageID: output.message.id,
          type: "text",
          text: context,
          synthetic: true,
        })
      }),
    "experimental.session.compacting": () =>
      inOrder(async () => {
        await run("resume.sh", ["--hook", "pre-compact"], {})
      }),
    dispose: async () => stopWaiter(),
  }
}
