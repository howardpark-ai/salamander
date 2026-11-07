// `claude plugin test mod`: the mod's requests against the engine's own chain, the world beneath mocked (files in a map,
// mv as a rename in that map, the prompt box, the commands run).
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const DIR = '/run/user/test/sala/mod'

type World = {
  files: Map<string, string>
  commands: { command: string; args: string }[]
  draft: string
  replied: (reqid: string) => Promise<Record<string, unknown>>
}

function world(on: On, sessionId = 'S1'): World {
  const w: World = { files: new Map(), commands: [], draft: '', replied: async () => ({}) }
  const waiters = new Map<string, (v: Record<string, unknown>) => void>()
  mock.env(on, { XDG_RUNTIME_DIR: '/run/user/test', HOME: '/home/t' })
  on('session.id', () => ({ value: sessionId }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('prompt.read', () => ({ value: { text: w.draft, cursor: w.draft.length } }))
  on('fs.write', ($, e) => {
    w.files.set(e.path, e.text)
    return { value: undefined }
  })
  on('process.run', ($, e) => {
    const [cmd, , from, to] = e.argv
    if (cmd === 'mv' && from !== undefined && to !== undefined) {
      const text = w.files.get(from)
      if (text === undefined) return { value: { exitCode: 1, stdout: '', stderr: 'missing', isStdoutTruncated: false, isStderrTruncated: false } }
      w.files.delete(from)
      w.files.set(to, text)
      const m = /\.([A-Za-z0-9_-]+)\.reply\.json$/.exec(to)
      if (m?.[1]) waiters.get(m[1])?.(JSON.parse(text) as Record<string, unknown>)
      if (to.endsWith(`/${sessionId}.json`)) waiters.get('stamp')?.(JSON.parse(text) as Record<string, unknown>)
    }
    if (cmd === 'rm') w.files.delete(e.argv[2] ?? '')
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('classic.Stop', () => ({}))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.run', ($, e) => {
    w.commands.push({ command: e.command, args: e.args })
    waiters.get(`cmd:${e.command}`)?.({})
    return {}
  })
  w.replied = reqid =>
    new Promise(resolve => {
      waiters.set(reqid, resolve)
    })
  return w
}

const peer = (text: string) => ({ origin: { kind: 'peer' as const }, text })

test('draft: the prompt box text comes back, the line never reaches the transcript', async ($, on) => {
  const w = world(on)
  w.draft = 'half a thought'
  const reply = w.replied('r1')
  const got = await $.session.receive(peer('[sala-mod] draft r1\n(an automatic control line)'))
  expect(got).toEqual({ consumed: 'sala: draft request r1' })
  expect(await reply).toEqual({ reqid: 'r1', ok: true, text: 'half a thought' })
  expect(w.files.has(`${DIR}/S1.r1.reply.json`)).toBe(true)
})

test('exit: refused over a draft, refused while a background shell runs, else answered ok and /exit run', async ($, on) => {
  const w = world(on)
  w.draft = 'unsent words'
  let reply = w.replied('e1')
  await $.session.receive(peer('[sala-mod] exit e1'))
  expect(await reply).toEqual({ reqid: 'e1', ok: false, reason: 'draft', text: 'unsent words' })

  w.draft = ''
  await $.classic.Stop({
    stop_hook_active: false,
    background_tasks: [{ id: 't1', type: 'shell', status: 'running', description: 'sleep', command: 'sleep 600' }],
  })
  reply = w.replied('e2')
  await $.session.receive(peer('[sala-mod] exit e2'))
  expect(await reply).toEqual({ reqid: 'e2', ok: false, reason: 'background', tasks: ['shell running'] })

  await $.classic.Stop({ stop_hook_active: false, background_tasks: [] })
  reply = w.replied('e3')
  const exited = w.replied('cmd:exit')
  await $.session.receive(peer('[sala-mod] exit e3'))
  expect(await reply).toEqual({ reqid: 'e3', ok: true })
  await exited
  expect(w.commands.some(c => c.command === 'exit')).toBe(true)
  expect(w.commands.filter(c => c.command === 'exit').length).toBe(1)
})

test('exit: refused while a turn runs (a subagent turn too), answered ok once every turn has completed', async ($, on) => {
  const w = world(on)
  const done = (turnId: string) => ({ answer: '', durationMs: 1, isAborted: false, reason: 'answer' as const, turnId })
  await $.turn.start({ text: 'a message from a peer', turnId: 'T1' })
  await $.turn.start({ text: '', turnId: 'A1' })
  let reply = w.replied('t1')
  await $.session.receive(peer('[sala-mod] exit t1'))
  expect(await reply).toEqual({ reqid: 't1', ok: false, reason: 'turn' })

  await $.turn.complete(done('T1'))
  reply = w.replied('t2')
  await $.session.receive(peer('[sala-mod] exit t2'))
  expect(await reply).toEqual({ reqid: 't2', ok: false, reason: 'turn' })

  await $.turn.complete({ ...done('A1'), agentId: 'a1' })
  reply = w.replied('t3')
  const exited = w.replied('cmd:exit')
  await $.session.receive(peer('[sala-mod] exit t3'))
  expect(await reply).toEqual({ reqid: 't3', ok: true })
  await exited
  expect(w.commands.filter(c => c.command === 'exit').length).toBe(1)
})

test('exit: a turn a crashed process left open does not outlive a session start', async ($, on) => {
  const w = world(on)
  await $.turn.start({ text: '', turnId: 'T9' })
  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
  const reply = w.replied('s1')
  await $.session.receive(peer('[sala-mod] exit s1'))
  expect(await reply).toEqual({ reqid: 's1', ok: true })
})

// the description of the watch Claude Code arms by itself on publish (register.ts ARTIFACT_WATCH), and every
// label 2.1.296 writes for an artifact watch (zjt)
const WATCH_URL = 'https://claude.ai/artifact/EXAMPLEARTIFACTID'
const WATCH_LABELS = [
  'auto-armed on publish',
  'attached via /artifacts',
  'watch requested',
  'resume requested',
  're-armed on session resume',
  'presence while editing via MCP',
  'watch requested; auto-replies since stopped',
]
const watchTask = (id: string, url = WATCH_URL, label = 'auto-armed on publish') => ({
  id,
  type: 'monitor',
  status: 'running',
  description: `live updates for artifact ${url} (${label})`,
})

test('exit: the auto-armed artifact watch alone is not work in flight; beside any other task the exit is refused', async ($, on) => {
  const w = world(on)
  await $.classic.Stop({ stop_hook_active: false, background_tasks: [watchTask('a1'), watchTask('a2')] })
  let reply = w.replied('w1')
  const exited = w.replied('cmd:exit')
  await $.session.receive(peer('[sala-mod] exit w1'))
  expect(await reply).toEqual({ reqid: 'w1', ok: true })
  await exited
  expect(w.commands.filter(c => c.command === 'exit').length).toBe(1)

  await $.classic.Stop({
    stop_hook_active: false,
    background_tasks: [watchTask('a1'), { id: 't1', type: 'shell', status: 'running', description: 'sleep', command: 'sleep 600' }],
  })
  reply = w.replied('w2')
  await $.session.receive(peer('[sala-mod] exit w2'))
  expect(await reply).toEqual({ reqid: 'w2', ok: false, reason: 'background', tasks: ['shell running'] })

  // an unknown label on a monitor, or a real label on another type: work in flight, as before
  await $.classic.Stop({
    stop_hook_active: false,
    background_tasks: [
      { id: 'm1', type: 'monitor', status: 'running', description: `live updates for artifact ${WATCH_URL} (watch started)` },
      { ...watchTask('m2', WATCH_URL, 'watch requested'), type: 'shell' },
    ],
  })
  reply = w.replied('w3')
  await $.session.receive(peer('[sala-mod] exit w3'))
  expect(await reply).toEqual({ reqid: 'w3', ok: false, reason: 'background', tasks: ['monitor running', 'shell running'] })
  expect(w.commands.filter(c => c.command === 'exit').length).toBe(1)
})

test('exit: every label the CLI writes for an artifact watch is not work in flight; a near miss is', async ($, on) => {
  const w = world(on)
  let n = 0
  // a watch requested by the session, and the auto-armed one as it comes back after a relaunch, among them
  for (const label of WATCH_LABELS) {
    await $.classic.Stop({ stop_hook_active: false, background_tasks: [watchTask('a1', WATCH_URL, label)] })
    const id = `l${++n}`
    const reply = w.replied(id)
    const exited = w.replied('cmd:exit')
    await $.session.receive(peer(`[sala-mod] exit ${id}`))
    expect(await reply).toEqual({ reqid: id, ok: true })
    await exited
  }
  expect(w.commands.filter(c => c.command === 'exit').length).toBe(WATCH_LABELS.length)

  // a requested watch beside a shell: the shell refuses the exit, the watch is not named
  await $.classic.Stop({
    stop_hook_active: false,
    background_tasks: [
      watchTask('a1', WATCH_URL, 'watch requested'),
      { id: 't1', type: 'shell', status: 'running', description: 'sleep', command: 'sleep 600' },
    ],
  })
  let reply = w.replied('s1')
  await $.session.receive(peer('[sala-mod] exit s1'))
  expect(await reply).toEqual({ reqid: 's1', ok: false, reason: 'background', tasks: ['shell running'] })

  // more words after the label, a cut-off label, another case, two labels: each one work in flight
  const near = [
    `live updates for artifact ${WATCH_URL} (watch requested) and a build`,
    `live updates for artifact ${WATCH_URL} (watch requested; auto-replies)`,
    `live updates for artifact ${WATCH_URL} (Watch requested)`,
    `live updates for artifact ${WATCH_URL} (watch requested)(resume requested)`,
  ]
  for (const [i, description] of near.entries()) {
    await $.classic.Stop({
      stop_hook_active: false,
      background_tasks: [{ id: 'm1', type: 'monitor', status: 'running', description }],
    })
    reply = w.replied(`x${i}`)
    await $.session.receive(peer(`[sala-mod] exit x${i}`))
    expect(await reply).toEqual({ reqid: `x${i}`, ok: false, reason: 'background', tasks: ['monitor running'] })
  }
  expect(w.commands.filter(c => c.command === 'exit').length).toBe(WATCH_LABELS.length)
})

test('rename: /rename run with the name, then ok', async ($, on) => {
  const w = world(on)
  const reply = w.replied('n1')
  await $.session.receive(peer('[sala-mod] rename n1 demo-main'))
  expect(await reply).toEqual({ reqid: 'n1', ok: true })
  expect(w.commands).toEqual([{ command: 'rename', args: 'demo-main' }])
})

test('unmarked lines and other origins pass through; a malformed id is consumed', async ($, on) => {
  const w = world(on)
  on('session.receive', ($, e) => ({ text: e.text }))
  expect(await $.session.receive(peer('hello from a peer'))).toEqual({ text: 'hello from a peer' })
  expect(await $.session.receive({ origin: { kind: 'bridge' }, text: '[sala-mod] exit x1' })).toEqual({
    text: '[sala-mod] exit x1',
  })
  expect(await $.session.receive(peer('[sala-mod] exit ../../etc'))).toEqual({ consumed: 'sala: a malformed request' })
  expect(w.commands).toEqual([])
})

test('the presence stamp at session start', async ($, on) => {
  const w = world(on, 'S9')
  const stamped = w.replied('stamp')
  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
  expect(await stamped).toEqual({
    present: true,
    version: 1,
    sessionId: 'S9',
    at: 1_700_000_000_000,
  })
  expect(w.files.has(`${DIR}/S9.json`)).toBe(true)
})
