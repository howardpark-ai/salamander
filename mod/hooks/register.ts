// sala's in-session helper. Loaded into every pane sala launches or resumes, through CLAUDE_CODE_PLUGIN_DIRS
// (lib/common.sh, mod_env_prefix). It answers three requests sala sends over the session's own inbox, so sala no longer
// types /exit or /rename into the pane or reads the composer off the screen for them:
//
//   [sala-mod] exit <reqid>           refused while a draft sits in the prompt box, a turn is running or background
//                                     work is in flight (an artifact watch is none, whatever its label),
//                                     else answered ok and then /exit run as if typed. A refusal for a turn names what
//                                     runs, in `holders` ("subagent <type>: <description>", "the main loop")
//   [sala-mod] busy <reqid>           the same two gates (a turn, background work), nothing exited and the draft not
//                                     read: ok when the session could be left now, else the refusal an exit would give.
//                                     sala asks it before it tries a relaunch, so its idle check and this one agree
//   [sala-mod] rename <reqid> <name>  /rename <name> run as if typed, answered once it has run
//   [sala-mod] draft <reqid>          the prompt box's text
//
// The request is one line on the session's messaging socket (lib/common.sh session_push), which arrives here as a
// session.receive delivery from a peer; it is consumed, so it never reaches the transcript or the model. Anything not
// starting with the marker passes through untouched.
//
// Files, in one directory sala computes the same way (lib/common.sh, mod_run_dirs):
//   $XDG_RUNTIME_DIR/sala/mod, or ${XDG_STATE_HOME:-$HOME/.local/state}/salamander/mod when XDG_RUNTIME_DIR is unset
//   <sessionId>.json                    the presence stamp {present, version, sessionId, at}: written at session start,
//                                       again after a /clear (a new session id) and on a reload; removed at exit
//   <sessionId>.<reqid>.reply.json      one reply per request {reqid, ok, reason?, text?}; sala reads and removes it
// Every file is written whole to a temp name and renamed into place, so a reader never sees half of one.
import type { EngineInterface, Register } from 'claude-code'

import type { BgTask } from '../types'

const VERSION = 1
const MARK = '[sala-mod] '
const BG = { plugin: 'sala', key: 'bg' } as const
const STAMPED = { plugin: 'sala', key: 'stamped' } as const
const TURNS = { plugin: 'sala', key: 'turns' } as const
// an agent loop that has ended for good: its turns are not running, whatever turn.complete did or did not say
const AGENT_ENDED = new Set(['completed', 'failed', 'killed'])
const REQID = /^[A-Za-z0-9_-]{1,64}$/
// a background task in one of these states has ended; any other status (running, pending, one this build does not
// name yet) counts as in flight, so an unknown word refuses the exit rather than letting /exit stop the work
const ENDED = new Set(['completed', 'failed', 'killed', 'stopped', 'cancelled', 'canceled', 'done', 'error'])
// THE ARTIFACT WATCH. When the session publishes an
// artifact, Claude Code arms a watch for its new versions and comments by itself; the session also arms one when asked to
// watch an artifact. classic.Stop carries it as type 'monitor' with this description, for example:
//   live updates for artifact https://claude.ai/artifact/EXAMPLEARTIFACTID (auto-armed on publish)
// where the label in brackets says how it was armed. Claude Code 2.1.296 (zjt) writes one of seven:
//   auto-armed on publish · attached via /artifacts · watch requested · resume requested · re-armed on session resume ·
//   presence while editing via MCP · watch requested; auto-replies since stopped
// None is work in flight: the exit request does not refuse for it (the CLI's own exit dialog lists none either), and the
// CLI arms an auto-armed watch again when the session is resumed, labelled "re-armed on session resume" from then on.
// Matched on the exact wording, one of those labels and the type only: another label, or more words, is work in flight.
// The shell side keeps the same wording in lib/common.sh (SALA_ARTIFACT_WATCH_DESC).
const ARTIFACT_WATCH = /^live updates for artifact (https:\/\/claude\.ai\/(?:code\/)?artifact\/[A-Za-z0-9_-]+) \((?:auto-armed on publish|attached via \/artifacts|watch requested|resume requested|re-armed on session resume|presence while editing via MCP|watch requested; auto-replies since stopped)\)$/

type Turn = { id: string; agent?: string }
type Reply = { reqid: string; ok: boolean; reason?: string; text?: string; tasks?: string[]; holders?: string }

async function runDir($: EngineInterface): Promise<string> {
  const xdg = await $.env.get('XDG_RUNTIME_DIR')
  if (xdg) return `${xdg}/sala/mod`
  const state = await $.env.get('XDG_STATE_HOME')
  const home = await $.env.get('HOME')
  return `${state || `${home ?? ''}/.local/state`}/salamander/mod`
}

// writes the file whole under a temp name, then renames it into place; the rename falls back to a plain write
async function put($: EngineInterface, path: string, value: unknown): Promise<void> {
  const text = `${JSON.stringify(value)}\n`
  const tmp = `${path}.tmp-${Math.random().toString(36).slice(2, 10)}`
  await $.fs.write(tmp, text)
  const moved = await $.process.run(['mv', '-f', tmp, path]).catch(() => undefined)
  if (moved?.exitCode !== 0) await $.fs.write(path, text)
}

async function stamp($: EngineInterface): Promise<void> {
  const sessionId = await $.session.id()
  if (!sessionId) return
  const at = await $.clock.now()
  await put($, `${await runDir($)}/${sessionId}.json`, { present: true, version: VERSION, sessionId, at })
  await $.state.set(STAMPED, sessionId)
}

async function reply($: EngineInterface, r: Reply): Promise<void> {
  const sessionId = await $.session.id()
  await put($, `${await runDir($)}/${sessionId}.${r.reqid}.reply.json`, r)
}

// the tasks the last turn left running, the artifact watches left out: they are not work in flight
async function inFlight($: EngineInterface): Promise<BgTask[]> {
  const { value = [] } = await $.state.get(BG)
  return value.filter(t => !ENDED.has(String(t.status).toLowerCase()) && t.watch === undefined)
}

function artifactWatch(t: { type?: unknown; description?: unknown }): string | undefined {
  if (t.type !== 'monitor' || typeof t.description !== 'string') return undefined
  return ARTIFACT_WATCH.exec(t.description)?.[1]
}

// the turns running now (turn.start to turn.complete): an /exit run mid-turn is not run as a command, the CLI hands it
// to the turn as a queued prompt and the model reads it as text. Each entry is the turn and, for a subagent's or
// teammate's loop, its agent id (absent for the main loop)
async function turns($: EngineInterface): Promise<Turn[]> {
  const { value = [] } = await $.state.get(TURNS)
  return value
}

// the turns still running, after a turn that never completed has been taken off the list. An agent loop the engine's own
// list shows as ended for good (completed, failed, killed) has no running turn, whatever its turn.complete said; one the
// list does not show (its task dropped) is kept, since sala never cuts a subagent it cannot see end. `stopped`: the main
// loop has just stopped, so no main-loop turn runs (a Stop with other work attached still ends the turn that made it)
async function settle($: EngineInterface, stopped: boolean): Promise<Turn[]> {
  const list = await $.agent.list().catch(() => undefined)
  const ended = new Set((list ?? []).filter(a => AGENT_ENDED.has(a.status)).map(a => a.id))
  const kept = (await turns($)).filter(t => (t.agent === undefined ? !stopped : !ended.has(t.agent)))
  await $.state.set(TURNS, kept).catch(() => undefined)
  return kept
}

// what the running turns are, in words for a person: the main loop, and each agent by its type and description
async function holders($: EngineInterface, running: Turn[]): Promise<string> {
  const list = (await $.agent.list().catch(() => undefined)) ?? []
  const names: string[] = []
  if (running.some(t => t.agent === undefined)) names.push('the main loop')
  for (const id of new Set(running.flatMap(t => (t.agent === undefined ? [] : [t.agent])))) {
    const a = list.find(x => x.id === id)
    names.push(a === undefined ? `subagent ${id}` : `subagent ${a.type}: ${a.description}`.slice(0, 160))
  }
  return names.join('; ')
}

// the two gates an exit and a busy probe both go through: a turn running, background work in flight
async function gate($: EngineInterface, reqid: string): Promise<Reply | undefined> {
  const running = await settle($, false)
  if (running.length > 0) return { reqid, ok: false, reason: 'turn', holders: await holders($, running) }
  const busy = await inFlight($)
  if (busy.length > 0) return { reqid, ok: false, reason: 'background', tasks: busy.map(t => `${t.type} ${t.status}`) }
  return undefined
}

async function handle($: EngineInterface, verb: string, reqid: string, arg: string): Promise<void> {
  switch (verb) {
    case 'exit': {
      const { text } = await $.prompt.read()
      if (text.trim() !== '') return reply($, { reqid, ok: false, reason: 'draft', text })
      const refused = await gate($, reqid)
      if (refused !== undefined) return reply($, refused)
      // answered before the exit runs: once /exit has run there is no process left to answer
      await reply($, { reqid, ok: true })
      void $.command.run({ command: 'exit' }).catch(() => undefined)
      return
    }
    case 'busy': {
      // what an exit would be refused for, with nothing exited and the box not read
      return reply($, (await gate($, reqid)) ?? { reqid, ok: true })
    }
    case 'rename': {
      if (arg === '') return reply($, { reqid, ok: false, reason: 'usage' })
      try {
        await $.command.run({ command: 'rename', args: arg })
      } catch {
        return reply($, { reqid, ok: false, reason: 'error' })
      }
      return reply($, { reqid, ok: true })
    }
    case 'draft': {
      const { text } = await $.prompt.read()
      return reply($, { reqid, ok: true, text })
    }
    default:
      return reply($, { reqid, ok: false, reason: 'unknown' })
  }
}

export const register: Register = on => {
  // the presence stamp: sala uses the mod only for a session that has one written since its process started
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.state.set(TURNS, []).catch(() => undefined)   // a new process runs no turn, whatever a crashed one left
    void stamp($).catch(() => undefined)
    return started
  })

  // a /clear goes on under a new session id with no session.start: stamp the new id; an exit takes the stamp away
  on('session.end', async ($, e, next) => {
    const ending = await $.session.id().catch(() => '')
    const ended = await next(e)
    if (e.reason === 'clear') {
      void stamp($).catch(() => undefined)
    } else if (ending) {
      const path = `${await runDir($)}/${ending}.json`
      await $.process.run(['rm', '-f', path], { timeoutMs: 1000 }).catch(() => undefined)
    }
    return ended
  })

  // what is in flight when a turn ends; the exit request refuses while any of it runs (the CLI's own
  // "Background work is running" dialog would otherwise hold the /exit, and the mod cannot answer it)
  on('classic.Stop', async ($, e, next) => {
    const tasks: BgTask[] = (e.background_tasks ?? []).map(t => {
      const watch = artifactWatch(t)
      return watch === undefined ? { type: t.type, status: t.status } : { type: t.type, status: t.status, watch }
    })
    await $.state.set(BG, tasks).catch(() => undefined)
    // the main loop has just stopped: no main-loop turn runs, so one still on the list lost its turn.complete (a turn
    // folded into another) and would refuse every /exit until the next session start. With nothing in flight behind it
    // (a background subagent would be on the list above) no agent turn runs either. With a shell or a watch attached
    // at every stop, which is how a session that chains subagents and CI watches always ends its turns, "nothing in
    // flight" never comes: the agent turns are then judged by the engine's own list (settle)
    if ((await inFlight($)).length === 0) await $.state.set(TURNS, []).catch(() => undefined)
    else await settle($, true)
    const { value: stamped } = await $.state.get(STAMPED)
    if (stamped !== (await $.session.id())) void stamp($).catch(() => undefined)
    return next(e)
  }).catch(($, e, next) => next(e))

  // which turns are running, the main loop's and any subagent's: the exit request refuses while one is
  on('turn.start', async ($, e, next) => {
    const started = await next(e)
    const turn: Turn = e.agentId === undefined ? { id: e.turnId } : { id: e.turnId, agent: e.agentId }
    await $.state.set(TURNS, [...(await turns($)), turn]).catch(() => undefined)
    return started
  }).catch(($, e, next) => next(e))
  on('turn.complete', async ($, e, next) => {
    await $.state.set(TURNS, (await turns($)).filter(t => t.id !== e.turnId)).catch(() => undefined)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('session.receive', async ($, e, next) => {
    if (e.origin.kind !== 'peer' || e.agentId !== undefined || !e.text.startsWith(MARK)) return next(e)
    const line = e.text.slice(MARK.length).split('\n')[0]?.trim() ?? ''
    const [verb = '', reqid = '', ...rest] = line.split(' ')
    if (!REQID.test(reqid)) return { consumed: 'sala: a malformed request' }
    void handle($, verb, reqid, rest.join(' ').trim()).catch(() =>
      reply($, { reqid, ok: false, reason: 'error' }).catch(() => undefined),
    )
    return { consumed: `sala: ${verb} request ${reqid}` }
  }).catch(($, e, next) =>
    // a marked line is sala's even when the hook failed: never let it reach the transcript (sala falls back on its own)
    !next.called && e.origin.kind === 'peer' && e.text.startsWith(MARK) ? { consumed: 'sala: the request failed' } : next(e),
  )
}
