import { expect, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

const TOOL = 'mcp__context-switcher__post'
const ENGINE_ROW = 'ENGINE ROW'
const viewport = { columns: 160, rows: 50, isFullscreen: true }

type On = Parameters<TestBody>[1]
type Dollar = Engine

/** Stand in for the engine beneath the mod; collects what the mod asked of it. */
function engine(on: On) {
  const seen = { tools: [] as string[], panes: [] as string[], listed: [] as string[] }
  on('session.start', () => ({ cwd: '/work' }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('tool.register', ($, e) => {
    seen.tools.push(e.name)
    return { value: { tool: `mcp__context-switcher__${e.name}` } }
  })
  on('ui.open', ($, e) => {
    seen.panes.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.render', () => ({ type: 'Text', props: {}, children: [ENGINE_ROW] }))
  on('prompt.submit', ($, e) => ({ text: e.text, context: e.context }))
  on('prompt.compose', () => ({ sections: [{ id: 'intro', text: 'You are Claude Code.', scope: 'shared' }] }))
  on('tool.describe', ($, e) => ({ description: e.description, isDeferred: true }))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('tool.list', () => ({ value: seen.listed.map(name => ({ name, description: '', mcp: true })) }))
  on('tool.call', () => ({ result: 'ok' }))
  return seen
}

const contextsCommand = (isFullscreen = true) =>
  ({
    command: 'contexts',
    args: '',
    origin: { kind: 'composer' },
    presentation: { isFullscreen, columns: 200 },
  }) as const

async function turnOn($: Dollar) {
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
  return $.command.run(contextsCommand())
}

const post = ($: Dollar, context: string, text: string, needsUser = false) =>
  $.tool.call({ tool: TOOL, context, text, needsUser } as any)

const pane = ($: Dollar) =>
  $.ui.mount({
    plugin: 'context-switcher',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'contexts',
    viewport,
    props: {
      title: 'Contexts',
      isFocused: false,
      bodyColumns: 28,
      placement: 'dock',
      scroll: { offset: 0, bodyRows: 40 },
      view: {},
    },
  } as any)

async function show($: Dollar, key: string) {
  const ui = await pane($)
  await ui.press({ key })
  await ui.unmount()
}

const row = ($: Dollar, component: string, requestId: string, props: Record<string, unknown>) =>
  $.ui.mount({ plugin: 'context-switcher', surface: 'terminal', component, requestId, viewport, props } as any)

const postRow = ($: Dollar, id: string, context: string, text: string, needsUser = false) =>
  row($, 'ToolUse', id, {
    tool_use_id: id,
    tool: TOOL,
    input: { context, text, needsUser },
    isRunning: false,
    isErrored: false,
    isInterrupted: false,
    output: 'Posted.',
  })

const assistantRow = ($: Dollar, id: string) =>
  row($, 'AssistantMessage', id, { text: 'Some reply', isFirstOfReply: true })

/** What a mounted row drew: the engine's own row, nothing at all, or a tree of the mod's. */
async function drawn(mounted: Awaited<ReturnType<typeof row>>) {
  const isEngine = (await mounted.find({ type: 'Text', text: ENGINE_ROW })) !== undefined
  const isEmpty = (await mounted.find({ type: 'Text' })) === undefined && (await mounted.find({ type: 'Markdown' })) === undefined
  await mounted.unmount()
  return isEngine ? 'engine' : isEmpty ? 'nothing' : 'mod'
}

/**
 * Keeps a row as the session would. The kit has nothing beneath the plugins
 * that stores a row, so the call rejects after the mod's hook has tied the row.
 */
const keep = ($: Dollar, row: Record<string, unknown>) => $.session.append(row as any).catch(() => undefined)

let nextDuration = 1000

/** One turn of the main loop: a prompt, its kept rows, and its end. Resolves the submitted prompt and the turn's length. */
async function turn($: Dollar, prompt: string, rows: { uuid: string; toolUseIds?: string[] }[]) {
  const submitted = await $.prompt.submit({ text: prompt, origin: { kind: 'composer' }, wait: false } as any)
  await $.turn.start({ text: prompt, turnId: `turn-${prompt}` })
  await keep($, {
    message: { type: 'user', role: 'user', content: [{ type: 'text', text: prompt }] },
    door: 'prompt',
    origin: { kind: 'composer' },
    uuid: `prompt-${prompt}`,
  })
  for (const one of rows)
    await keep($, {
      message: {
        type: 'assistant',
        role: 'assistant',
        content: [
          { type: 'text', text: 'Working on it.' },
          ...(one.toolUseIds ?? []).map(id => ({ type: 'tool_use', id, name: 'Bash', input: {} })),
        ],
      },
      door: 'response',
      origin: { kind: 'model', model: 'claude-test' },
      uuid: one.uuid,
    })
  const durationMs = nextDuration++
  await $.turn.complete({ turnId: `turn-${prompt}`, answer: 'Done.', durationMs, isAborted: false, reason: 'answer' } as any)
  return { ...submitted, durationMs }
}

/** An assistant row of one block, kept as the engine keeps each block of a reply. */
const say = ($: Dollar, uuid: string, block: Record<string, unknown>, agentId?: string) =>
  keep($, {
    message: { type: 'assistant', role: 'assistant', content: [block] },
    door: 'response',
    origin: { kind: 'model', model: 'claude-test' },
    uuid,
    ...(agentId ? { agentId } : {}),
  })

const text = (value: string) => ({ type: 'text', text: value })

/** Starts a turn from a prompt the user typed in the view on screen. */
async function begin($: Dollar, prompt: string) {
  await $.prompt.submit({ text: prompt, origin: { kind: 'composer' }, wait: false } as any)
  await $.turn.start({ text: prompt, turnId: `turn-${prompt}` })
}

const end = ($: Dollar, prompt: string, durationMs = nextDuration++) =>
  $.turn.complete({ turnId: `turn-${prompt}`, answer: 'Done.', durationMs, isAborted: false, reason: 'answer' } as any)

const userRow = ($: Dollar, requestId: string, value: string) =>
  row($, 'UserMessage', requestId, { text: value, origin: { kind: 'composer' }, isExpanded: false })

const thinkingRow = ($: Dollar, requestId: string) => row($, 'ToolGroup', requestId, { calls: [], isActive: false, isExpanded: false })

const durationRow = ($: Dollar, requestId: string, durationMs: number) =>
  row($, 'TurnDuration', requestId, { word: 'Baked', durationMs })

const compose = ($: Dollar) =>
  $.prompt.compose({ model: 'claude-test', promptModel: 'claude-test', surfaces: ['terminal'], tools: [], outputStyle: null, traits: [] } as any)

/** The sidebar's unread count, or undefined with none: used where only one entry can have one. */
async function badge($: Dollar) {
  const ui = await pane($)
  const count = await ui.find({ type: 'Text', text: /^ \d+$/ })
  await ui.unmount()
  return count === undefined ? undefined : JSON.stringify(count).match(/ \d+/)?.[0]
}


test('until /contexts runs, the mod offers nothing and filters nothing', async ($, on) => {
  const seen = engine(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)

  expect(seen.tools).toEqual([])
  expect((await compose($)).sections.map(section => section.id)).toEqual(['intro'])
  const submitted = await $.prompt.submit({ text: 'hello', origin: { kind: 'composer' }, wait: false } as any)
  expect(submitted.context).toBeUndefined()
  expect(await drawn(await postRow($, 't1', 'CI flakes', 'Run failed'))).toBe('engine')
})

test('/contexts outside fullscreen explains how to turn fullscreen on and stays off', async ($, on) => {
  const seen = engine(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)

  const answer = await $.command.run(contextsCommand(false))
  expect(answer.text).toMatch(/\/tui fullscreen/)
  expect(seen.tools).toEqual([])
  expect(seen.panes).toEqual([])
  expect(await drawn(await assistantRow($, 'a1'))).toBe('engine')
})

test('/contexts registers the tool up front, opens the sidebar and adds the guide', async ($, on) => {
  const seen = engine(on)
  await turnOn($)

  expect(seen.tools).toEqual(['post'])
  expect(seen.panes).toEqual(['contexts'])
  const described = await $.tool.describe({ tool: TOOL, description: 'Post.', isDeferred: true, provider: { plugin: 'context-switcher', tier: 'user' } } as any)
  expect(described.isDeferred).toBe(false)
  const composed = await compose($)
  expect(composed.sections.map(section => section.id)).toEqual(['intro', 'context-switcher:guide'])
  expect(composed.sections[1]).toMatchObject({ scope: 'session' })
})

test('a fresh load of the module after /clear stays on while the tool is still registered', async ($, on) => {
  // /clear reset $.state, so only the registered tool says the session had turned it on
  const seen = engine(on)
  seen.listed.push(TOOL)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)

  expect(seen.tools).toEqual(['post'])
  expect((await compose($)).sections.map(section => section.id)).toContain('context-switcher:guide')
  const pointer = await postRow($, 'p1', 'Alpha', 'hello')
  expect(await pointer.find({ type: 'Text', text: '→ Alpha' })).toBeDefined()
})

test('a post creates its context and counts unread posts until the user opens it', async ($, on) => {
  engine(on)
  await turnOn($)

  expect(await post($, 'CI flakes', 'Run 4812 failed')).toEqual({ result: 'Posted to "CI flakes".' })
  await post($, 'ci FLAKES', 'Run 4813 failed too', true)
  await post($, 'Release notes', 'Draft ready')

  let ui = await pane($)
  expect(await ui.find({ key: 'context-1' })).toMatchObject({ props: { label: 'CI flakes', hotkey: '1' } })
  expect(await ui.find({ key: 'context-2' })).toMatchObject({ props: { label: 'Release notes', hotkey: '2' } })
  expect(await ui.find({ type: 'Text', text: ' 2' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: ' needs you' })).toBeDefined()

  await ui.press({ key: 'context-1' })
  await ui.unmount()
  ui = await pane($)
  expect(await ui.find({ type: 'Text', text: ' 2' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: ' needs you' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: ' 1' })).toBeDefined()

  // A post to the context on screen is read as it lands
  await post($, 'CI flakes', 'Fixed')
  await ui.unmount()
  ui = await pane($)
  expect(await ui.find({ type: 'Text', text: ' 1' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: ' 2' })).toBeUndefined()
})

test('a post without a context or text is refused', async ($, on) => {
  engine(on)
  await turnOn($)
  expect((await post($, '  ', 'text')).deny).toBe('A post needs a context name and some text.')
  expect((await post($, 'CI flakes', '')).deny).toBe('A post needs a context name and some text.')
})

test('Main chat draws its own rows and one pointer line per post', async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'CI flakes', 'x')
  await show($, 'context-1')
  await turn($, 'why is CI red', [{ uuid: 'ci-reply' }])
  await show($, 'main')
  await turn($, 'what next', [{ uuid: 'main-reply' }])

  expect(await drawn(await assistantRow($, 'main-reply'))).toBe('engine')
  expect(await drawn(await assistantRow($, 'ci-reply'))).toBe('nothing')
  expect(await drawn(await userRow($, 'prompt-why is CI red', 'why is CI red'))).toBe('nothing')

  const pointer = await postRow($, 'p1', 'CI flakes', '## Run 4812\nfailed on linux', true)
  expect(await pointer.find({ type: 'Text', text: '→ CI flakes' })).toBeDefined()
  expect(await pointer.find({ type: 'Text', text: ' needs you' })).toBeDefined()
  expect(await pointer.find({ type: 'Text', text: ': Run 4812' })).toBeDefined()
  expect(await pointer.find({ type: 'Markdown' })).toBeUndefined()
})

test('a context view draws that context in full and nothing else', async ($, on) => {
  engine(on)
  await turnOn($)
  await turn($, 'what next', [{ uuid: 'main-reply', toolUseIds: ['toolu_main'] }])
  await post($, 'CI flakes', 'x')
  await post($, 'Release notes', 'y')
  await show($, 'context-1')
  await turn($, 'why is CI red', [{ uuid: 'ci-reply', toolUseIds: ['toolu_ci'] }])

  const mine = await postRow($, 'p1', 'ci flakes', 'Run **4812** failed')
  expect(await mine.find({ type: 'Markdown' })).toMatchObject({ props: { text: 'Run **4812** failed' } })
  expect(await drawn(await postRow($, 'p2', 'Release notes', 'Draft ready'))).toBe('nothing')
  expect(await drawn(await assistantRow($, 'ci-reply'))).toBe('engine')
  expect(await drawn(await assistantRow($, 'main-reply'))).toBe('nothing')
  expect(await drawn(await userRow($, 'prompt-why is CI red', 'why is CI red'))).toBe('engine')

  const toolRow = (id: string) => row($, 'ToolUse', id, { tool_use_id: id, tool: 'Bash', input: {}, isRunning: false, isErrored: false, isInterrupted: false })
  expect(await drawn(await toolRow('toolu_ci'))).toBe('engine')
  expect(await drawn(await toolRow('toolu_main'))).toBe('nothing')
  const group = (requestId: string, ids: string[]) =>
    row($, 'ToolGroup', requestId, { calls: ids.map(id => ({ tool_use_id: id, tool: 'Read', input: {}, isRunning: false, isErrored: false, isInterrupted: false })), isActive: false, isExpanded: false })
  expect(await drawn(await group('g1', ['toolu_ci']))).toBe('engine')
  expect(await drawn(await group('g2', ['toolu_main']))).toBe('nothing')
  expect(await drawn(await group('g3', ['toolu_ci', 'toolu_main']))).toBe('nothing')
  expect(await drawn(await row($, 'ToolResult', 'p1', { tool_use_id: 'p1', tool: TOOL, output: 'Posted.', isErrored: false }))).toBe('nothing')
})

test("a folded thinking line follows its assistant row's context", async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'CI flakes', 'x')
  await show($, 'context-1')
  await begin($, 'think about it')
  await say($, 'ci-thought', { type: 'thinking', thinking: 'hmm' })
  await say($, 'ci-answer', text('An answer.'))
  await end($, 'think about it')

  expect(await drawn(await thinkingRow($, 'collapsed-ci-thought'))).toBe('engine')
  await show($, 'main')
  expect(await drawn(await thinkingRow($, 'collapsed-ci-thought'))).toBe('nothing')
  expect(await drawn(await thinkingRow($, 'collapsed-unknown'))).toBe('engine')
})

test("a context turn's duration line belongs to that context", async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'CI flakes', 'x')
  await show($, 'context-1')
  const { durationMs } = await turn($, 'rerun it', [{ uuid: 'ci-reply' }])
  await show($, 'main')
  const { durationMs: mainMs } = await turn($, 'what next', [{ uuid: 'main-reply' }])

  expect(await drawn(await durationRow($, 'd1', durationMs))).toBe('nothing')
  expect(await drawn(await durationRow($, 'd2', mainMs))).toBe('engine')
  await show($, 'context-1')
  expect(await drawn(await durationRow($, 'd1', durationMs))).toBe('engine')
  expect(await drawn(await durationRow($, 'd2', mainMs))).toBe('nothing')
})

test('a prompt written in a context carries a note naming it; one in Main chat does not', async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'CI flakes', 'x')

  expect((await turn($, 'in main', [])).context).toBeUndefined()
  await show($, 'context-1')
  const tagged = await turn($, 'rerun it', [])
  expect(tagged.text).toBe('rerun it')
  expect(tagged.context?.[0]).toMatch(/context "CI flakes".*mcp__context-switcher__post/)

  // A notification is not the user's prompt: the view on screen does not tag it
  const notified = await $.prompt.submit({ text: '<task-notification>done</task-notification>', origin: { kind: 'task-notification' }, wait: false } as any)
  expect(notified.context).toBeUndefined()
})

test('the same prompt text in two views keeps each row where it was typed', async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'Alpha', 'x')
  await show($, 'context-1')
  await begin($, 'ok')
  await keep($, { message: { type: 'user', role: 'user', content: [text('ok')] }, door: 'prompt', origin: { kind: 'composer' }, uuid: 'ok-in-alpha' })
  await end($, 'ok')
  await show($, 'main')
  await begin($, 'ok')
  await keep($, { message: { type: 'user', role: 'user', content: [text('ok')] }, door: 'prompt', origin: { kind: 'composer' }, uuid: 'ok-in-main' })
  await end($, 'ok')

  expect(await drawn(await userRow($, 'ok-in-alpha', 'ok'))).toBe('nothing')
  expect(await drawn(await userRow($, 'ok-in-main', 'ok'))).toBe('engine')
  await show($, 'context-1')
  expect(await drawn(await userRow($, 'ok-in-alpha', 'ok'))).toBe('engine')
})

test('a fresh prompt drawn before its row is kept shows in the view it was typed in', async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'Alpha', 'x')
  await show($, 'context-1')
  await $.prompt.submit({ text: 'look at this', origin: { kind: 'composer' }, wait: false } as any)

  expect(await drawn(await userRow($, 'placeholder', 'look at this'))).toBe('engine')
  await show($, 'main')
  expect(await drawn(await userRow($, 'placeholder', 'look at this'))).toBe('nothing')
})

test('/clear forgets which context a prompt text was typed in', async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'Alpha', 'x')
  await show($, 'context-1')
  await $.prompt.submit({ text: 'look at this', origin: { kind: 'composer' }, wait: false } as any)
  await $.session.end({ reason: 'clear', sessionId: 's', resume: {} } as any).catch(() => undefined)

  expect(await drawn(await userRow($, 'placeholder', 'look at this'))).toBe('nothing')
})

test('a task notification belongs to the context of the call that started the task', async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'CI flakes', 'x')
  await show($, 'context-1')
  await turn($, 'watch the run', [{ uuid: 'ci-reply', toolUseIds: ['toolu_watch'] }])
  await show($, 'main')
  await turn($, 'start the docs build', [{ uuid: 'main-reply', toolUseIds: ['toolu_docs'] }])

  const notice = '<task-notification><task-id>b1</task-id><tool-use-id>toolu_watch</tool-use-id><status>completed</status></task-notification>'
  const notified = await $.prompt.submit({ text: notice, origin: { kind: 'task-notification' }, wait: false } as any)
  expect(notified.context?.[0]).toMatch(/about the context "CI flakes"/)
  const unrelated = await $.prompt.submit({ text: notice.replace('toolu_watch', 'toolu_docs'), origin: { kind: 'task-notification' }, wait: false } as any)
  expect(unrelated.context).toBeUndefined()

  const notification = (id: string, toolUseId: string) =>
    row($, 'UserMessage', id, { text: 'Background command completed', origin: { kind: 'task-notification' }, isExpanded: false, task: { id: 'b1', status: 'completed', toolUseId } })
  expect(await drawn(await notification('n1', 'toolu_watch'))).toBe('nothing')
  expect(await drawn(await notification('n2', 'toolu_docs'))).toBe('engine')
  await show($, 'context-1')
  expect(await drawn(await notification('n1', 'toolu_watch'))).toBe('engine')
  expect(await drawn(await notification('n2', 'toolu_docs'))).toBe('nothing')

  // The turn the notification starts is that context's too
  await $.turn.start({ text: notice, turnId: 'turn-notified' })
  await say($, 'notified-reply', text('It passed.'))
  expect(await drawn(await assistantRow($, 'notified-reply'))).toBe('engine')
})

test("a subagent's turn ending does not end the context turn that started it", async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'Alpha', 'x')
  await show($, 'context-1')
  await begin($, 'research it')
  await $.turn.complete({ turnId: 'sub', agentId: 'agent-1', answer: 'found', durationMs: 5, isAborted: false, reason: 'answer' } as any)
  await say($, 'after-subagent', text('The subagent found it.'))

  expect(await drawn(await assistantRow($, 'after-subagent'))).toBe('engine')
})

test("Claude's closing recap of a post in its own context is hidden; the rest of the turn stays", async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'CI flakes', 'x')
  await show($, 'context-1')

  await begin($, 'rerun it')
  await say($, 'before', text('Rerunning now.'))
  await post($, 'CI flakes', 'Run 4813 started')
  await say($, 'recap-thought', { type: 'thinking', thinking: 'brief line' })
  await say($, 'recap', text('I posted the rerun to CI flakes.'))
  await end($, 'rerun it')

  expect(await drawn(await assistantRow($, 'before'))).toBe('engine')
  expect(await drawn(await assistantRow($, 'recap'))).toBe('nothing')
  expect(await drawn(await thinkingRow($, 'collapsed-recap-thought'))).toBe('nothing')
  await show($, 'main')
  expect(await drawn(await assistantRow($, 'recap'))).toBe('nothing')
})

test('text after a post and then another tool call is the answer, and stays', async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'Notes', 'x')
  await show($, 'context-1')

  await begin($, 'read the file')
  await post($, 'Notes', 'starting')
  await say($, 'between', text('Now reading notes.txt.'))
  await $.tool.call({ tool: 'Read', file_path: 'notes.txt' } as any)
  await say($, 'answer', text('FILE SAYS hello'))
  await end($, 'read the file')

  expect(await drawn(await assistantRow($, 'between'))).toBe('engine')
  expect(await drawn(await assistantRow($, 'answer'))).toBe('engine')
})

test("a subagent's post does not make the context turn's answer a recap", async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'Notes', 'x')
  await show($, 'context-1')

  await begin($, 'look into it')
  await $.tool.call({ tool: TOOL, context: 'Notes', text: 'from the subagent', agentId: 'agent-1' } as any)
  await say($, 'answer', text('Here is what I found.'))
  await end($, 'look into it')

  expect(await drawn(await assistantRow($, 'answer'))).toBe('engine')
})

test("a recap belongs to its own turn: the next turn's text stays", async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'Notes', 'x')
  await show($, 'context-1')

  await begin($, 'one')
  await post($, 'Notes', 'first')
  await end($, 'one')
  await begin($, 'two')
  await say($, 'second-answer', text('A plain answer.'))
  await end($, 'two')

  expect(await drawn(await assistantRow($, 'second-answer'))).toBe('engine')
})

test('Main chat counts its replies that land while the user is in a context, not its post recaps', async ($, on) => {
  engine(on)
  await turnOn($)
  await post($, 'CI flakes', 'x')
  await show($, 'context-1')

  await $.prompt.submit({ text: 'ping', origin: { kind: 'peer' }, wait: false } as any)
  await $.turn.start({ text: 'ping', turnId: 'peer' })
  await post($, 'CI flakes', 'from the peer')
  await say($, 'peer-recap', text('Posted to CI flakes.'))
  await end($, 'peer')
  expect(await badge($)).toBeUndefined()

  await $.prompt.submit({ text: 'ping again', origin: { kind: 'peer' }, wait: false } as any)
  await $.turn.start({ text: 'ping again', turnId: 'peer-2' })
  await say($, 'peer-answer', text('pong'))
  await end($, 'peer-2')
  expect(await badge($)).toBe(' 1')

  await show($, 'main')
  expect(await badge($)).toBeUndefined()
})

test('a pointer line shows the first line of the post without Markdown marks', async ($, on) => {
  engine(on)
  await turnOn($)
  const pointer = await postRow($, 'p1', 'Release notes', '\n# The **v0.3** draft of `notes.md`\nmore')
  expect(await pointer.find({ type: 'Text', text: ': The v0.3 draft of notes.md' })).toBeDefined()
})
