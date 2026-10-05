// Context Switcher: one session, many contexts. Claude posts to named contexts
// with a tool; a sidebar lists them, and the transcript shows one at a time.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderInput } from 'claude-code'

import type { AgentPost, ContextEntry } from '../types'

const PANE = 'contexts'
const TOOL = 'mcp__context-switcher__post'
/** The view and row context of Main chat. */
const MAIN = ''

const isOn = atom({ plugin: 'context-switcher', key: 'isOn' } as const, false)
const view = atom({ plugin: 'context-switcher', key: 'view' } as const, MAIN)
const contexts = atom({ plugin: 'context-switcher', key: 'contexts' } as const, [] as ContextEntry[])
const mainUnread = atom({ plugin: 'context-switcher', key: 'mainUnread' } as const, 0)
const isDoneShown = atom({ plugin: 'context-switcher', key: 'isDoneShown' } as const, false)
const ROW = { plugin: 'context-switcher', key: 'rowContext' } as const
const AGENT_POSTS = { plugin: 'context-switcher', key: 'agentPosts' } as const
const AGENT_OF_CALL = { plugin: 'context-switcher', key: 'agentOfCall' } as const
const CALL_OF_AGENT = { plugin: 'context-switcher', key: 'callOfAgent' } as const
const PARENT_OF_AGENT = { plugin: 'context-switcher', key: 'parentOfAgent' } as const

const GUIDE = `# Context Switcher

The user turned on Context Switcher. The conversation now holds contexts: named threads the user reads one at a time from a sidebar, next to Main chat, their focus conversation. You still see everything; the user sees only the thread they selected, and Main chat shows a one-line pointer for each post to a context.

- Give each separate topic its own context, named with a short topic name of two or three words (for example "CI flakes"). Use the same name for the same topic.
- Post news about a topic with ${TOOL} instead of writing it in Main chat. This matters most for results that arrive on their own: task notifications, background commands, subagents, messages from other sessions.
- A prompt the user writes from inside a context says so in a note. Answer it with ${TOOL} into that context: the post is your reply, so put everything the user should read in it, and don't repeat it as text afterwards.
- Set needsUser on a post that asks the user for a decision or for input.
- Keep the sidebar tidy: the user never manages contexts, you do. As soon as a topic's conversation wraps up (resolved, merged, answered, abandoned), set done on your last post to it, and the sidebar moves it to Done. Don't leave stale contexts open. A later post without done reopens it.
- Prompts without such a note come from Main chat. Answer those as usual.`

const NOT_FULLSCREEN =
  'Context Switcher needs fullscreen rendering. Run `/tui fullscreen` (Claude Code relaunches with this conversation), or start Claude Code with `CLAUDE_CODE_NO_FLICKER=1`, then run /contexts again.'

const sameName = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase()

/** The prompt text to the context it was written in, read when its turn starts and its row is drawn. */
const promptContext = new Map<string, string>()
/**
 * The main loop's running turn: its context; whether the last tool to answer was a post (so
 * text now is about that post); and whether the turn wrote text of its own, for Main chat's
 * unread count. Then the context of the turn that just ended, for its duration line.
 */
let turnContext = MAIN
let isAfterPost = false
let hasOwnText = false
let endedContext: string | null = null
let isToolRegistered = false

function startTurn(context: string) {
  turnContext = context
  isAfterPost = false
  hasOwnText = false
}

function rememberPrompt(text: string, context: string) {
  promptContext.delete(text)
  promptContext.set(text, context)
  if (promptContext.size > 100) promptContext.delete(promptContext.keys().next().value!)
}

function withNote<E extends { context?: readonly string[] }>(e: E, note: string): E {
  return { ...e, context: [...(e.context ?? []), `[Context Switcher] ${note}`] }
}

/**
 * On once /contexts has run, for the rest of the session: the tool cannot be taken back. The
 * module flag outlives a /clear (which resets $.state), the state value a reload of the module.
 */
async function isActive($: EngineInterface) {
  return isToolRegistered || (await read($, isOn))
}

/** After a /clear, write the state value back, so a later reload of the module finds it on. */
async function keepOn($: EngineInterface) {
  if (isToolRegistered && !(await read($, isOn))) await update($, isOn, () => true)
}

async function turnOn($: EngineInterface) {
  if (!isToolRegistered) {
    await $.tool.register({
      name: 'post',
      description:
        "Post a message to a context: a named thread in the user's Context Switcher sidebar. " +
        'The user reads it as your message when they open that context, and as a one-line pointer in Main chat. ' +
        'A name not used before creates the context; keep names short and reuse them for the same topic. ' +
        'text is Markdown. Set needsUser when the post asks the user for a decision or input. ' +
        "Set done on the last post of a topic whose conversation has wrapped up: the sidebar moves it to Done, and a later post without done reopens it.",
      inputSchema: {
        type: 'object',
        properties: {
          context: { type: 'string', description: 'The context, a short topic name such as "CI flakes"' },
          text: { type: 'string', description: 'The message, in Markdown' },
          needsUser: { type: 'boolean', description: 'True when the post asks the user for a decision or input' },
          done: { type: 'boolean', description: "True when the topic's conversation has wrapped up with this post" },
        },
        required: ['context', 'text'],
      },
    })
    isToolRegistered = true
  }
  await update($, isOn, () => true)
}

async function select($: EngineInterface, name: string) {
  await update($, view, () => name)
  if (name === MAIN) await update($, mainUnread, () => 0)
  else
    await update($, contexts, list =>
      list.map(entry => (sameName(entry.name, name) ? { ...entry, unread: 0, needsUser: false } : entry)),
    )
}

/** The context a transcript row belongs to; Main chat when nothing ties it to one. */
async function contextOf($: EngineInterface, e: RenderInput): Promise<string> {
  const own = await read($, { ...ROW, id: e.requestId })
  if (own !== undefined) return own
  if (e.component === 'UserMessage') {
    const { task } = e.props
    if (task) return taskContext($, task.toolUseId, task.id)
    // A fresh prompt is drawn before its row is kept, under a placeholder id
    if (e.props.origin.kind === 'composer') return promptContext.get(e.props.text) ?? MAIN
  }
  if (e.component === 'ToolGroup') {
    const ids = e.props.calls.flatMap(call => (call.tool_use_id ? [call.tool_use_id] : []))
    if (ids.length > 0) {
      const found = await Promise.all(ids.map(async id => (await read($, { ...ROW, id })) ?? MAIN))
      return found.every(context => context === found[0]) ? found[0]! : MAIN
    }
    const row = thinkingRowOf(e.requestId)
    if (row) return (await read($, { ...ROW, id: row })) ?? MAIN
  }
  return MAIN
}

/**
 * The assistant row a folded thinking line (a ToolGroup with no calls) belongs to. Not part of
 * the documented API: observed as the id `collapsed-<uuid of that row>`. Any other id leaves the
 * line in Main chat.
 */
function thinkingRowOf(requestId: string) {
  return /^collapsed-(.+)$/.exec(requestId)?.[1]
}

/**
 * The context of a background task's notification: that of the call that started it, else, for
 * a subagent (whose task id is its agent id), that of the main loop's Agent call it works for.
 */
async function taskContext($: EngineInterface, toolUseId: string | undefined, taskId: string | undefined) {
  const byCall = toolUseId ? await read($, { ...ROW, id: toolUseId }) : undefined
  if (byCall !== undefined || !taskId) return byCall ?? MAIN
  const call = await read($, { ...CALL_OF_AGENT, id: await topAgentOf($, taskId) })
  return (call && (await read($, { ...ROW, id: call }))) ?? MAIN
}

/**
 * The subagent the main loop started that a subagent works for, itself or up its parents: those
 * recorded as each started, else the session's live list (which drops an agent once it is done).
 */
async function topAgentOf($: EngineInterface, agentId: string) {
  let id = agentId
  for (let depth = 0; depth < 16; depth++) {
    const parent =
      (await read($, { ...PARENT_OF_AGENT, id })) ?? (await $.agent.list()).find(agent => agent.id === id)?.parentId
    if (!parent) break
    id = parent
  }
  return id
}

type PostInput = { context?: unknown; text?: unknown; needsUser?: unknown; done?: unknown }

function postOf(input: unknown) {
  const { context, text, needsUser, done } = (input ?? {}) as PostInput
  return {
    context: typeof context === 'string' ? context.trim() : '',
    text: typeof text === 'string' ? text : '',
    needsUser: needsUser === true,
    isDone: done === true,
  }
}

/**
 * The status line under the prompt: while the sidebar is closed, how many contexts need the user
 * and how many posts wait unread; cleared while the sidebar is open or nothing waits.
 */
async function showPending($: EngineInterface) {
  const isOpen = (await $.ui.panes()).some(pane => pane.id === PANE)
  const list = await read($, contexts)
  const needing = list.filter(entry => entry.needsUser).length
  const unread = list.reduce((sum, entry) => sum + entry.unread, 0)
  if (isOpen || unread === 0) return $.ui.status(undefined)
  const parts = [
    ...(needing > 0 ? [needing === 1 ? '1 context needs you' : `${needing} contexts need you`] : []),
    unread === 1 ? '1 unread post' : `${unread} unread posts`,
  ]
  $.ui.status(`${parts.join(', ')} (/contexts to open the sidebar)`)
}

function firstLine(markdown: string) {
  const line = markdown.split('\n').find(one => one.trim() !== '') ?? ''
  return line.replace(/^[#>*\-\s]+/, '').replace(/\*\*|__|`/g, '').trim()
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'contexts',
      description: 'Turn on Context Switcher and open its sidebar',
      immediate: true,
    })
    // A fresh load of the module: stay on if the session turned it on (state), or if the
    // tool is still registered after a /clear reset the state
    const wasOn = (await read($, isOn)) || (await $.tool.list()).some(tool => tool.name === TOOL)
    if (wasOn) {
      await turnOn($)
      await showPending($)
    }
    return next(e)
  })

  // /clear starts the conversation over: its rows and contexts go with it
  on('session.end', async ($, e, next) => {
    promptContext.clear()
    startTurn(MAIN)
    $.ui.status(undefined)
    return next(e)
  })

  on('command.run', { command: 'contexts' }, async ($, e) => {
    if (!e.presentation.isFullscreen) return { text: NOT_FULLSCREEN }
    await turnOn($)
    await $.ui.open({ id: PANE, title: 'Contexts', columns: 30 })
    await showPending($)
    return {}
  })

  // Closing the sidebar returns the transcript to Main chat
  on('ui.close', { id: PANE }, async ($, e, next) => {
    const closed = await next(e)
    if (e.origin.kind === 'person') await select($, MAIN)
    await showPending($)
    return closed
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    if (!(await isActive($))) return composed
    return { sections: [...composed.sections, { id: 'context-switcher:guide', text: GUIDE, scope: 'session' }] }
  })

  // In the prompt's own tool list, so Claude calls it without searching for it
  on('tool.describe', { tool: TOOL }, async ($, e, next) => ({ ...(await next(e)), isDeferred: false }))

  on('tool.check', { tool: TOOL }, () => ({ decision: 'allow' }))

  // A pattern: the typed tool names are the ones connected when the engine last wrote the types
  on('tool.call', { tool: /^mcp__context-switcher__post$/ }, async ($, e) => {
    const post = postOf(e)
    if (!post.context || !post.text.trim()) return { deny: 'A post needs a context name and some text.' }
    const viewing = await read($, view)
    const unseen = !sameName(viewing, post.context)
    // A done context needs nothing of the user, but keeps the posts they have not read; a later
    // post without done reopens it
    const after = (entry: ContextEntry): ContextEntry => ({
      ...entry,
      unread: entry.unread + (unseen ? 1 : 0),
      needsUser: !post.isDone && (entry.needsUser || (unseen && post.needsUser)),
      isDone: post.isDone,
    })
    const list = await update($, contexts, entries => {
      const known = entries.find(entry => sameName(entry.name, post.context))
      if (!known) return [...entries, after({ name: post.context, unread: 0, needsUser: false, isDone: false })]
      return entries.map(entry => (entry === known ? after(entry) : entry))
    })
    const name = list.find(entry => sameName(entry.name, post.context))?.name ?? post.context
    if (e.agentId === undefined) {
      isAfterPost = true
    } else {
      // A subagent's rows live in its own transcript: keep its posts for the main loop's call that started it
      const agent = await topAgentOf($, e.agentId)
      const kept: AgentPost = { context: name, text: post.text, needsUser: post.needsUser }
      await update($, { ...AGENT_POSTS, id: agent }, posts => [...(posts ?? []), kept])
    }
    await showPending($)
    return { result: `Posted to "${name}".` }
  })

  // Which subagent each Agent call started: the main loop's, so its posts and notification find
  // that call; a subagent's, so a post of the one it started finds its way up
  on('tool.call', { tool: 'Agent' }, async ($, e, next) => {
    if (!(await isActive($))) return next(e)
    const ran = await next(e)
    // A teammate's record has no agent id: it runs no subagent loop here
    if (ran.deny !== undefined || ran.isError || !('agentId' in ran.result)) return ran
    const { agentId } = ran.result
    if (e.agentId === undefined) {
      await $.state.set({ ...AGENT_OF_CALL, id: e.tool_use_id }, agentId)
      await $.state.set({ ...CALL_OF_AGENT, id: agentId }, e.tool_use_id)
    } else {
      await $.state.set({ ...PARENT_OF_AGENT, id: agentId }, e.agentId)
    }
    return ran
  })

  on('prompt.submit', async ($, e, next) => {
    if (!(await isActive($))) return next(e)
    await keepOn($)
    if (e.origin.kind === 'task-notification') {
      // The notification belongs to the context of the call that started the task. Its ids are
      // read from the notification's text, a format the engine writes but does not document;
      // a notification without them stays in Main chat
      const tag = (name: string) => new RegExp(`<${name}>([^<]+)</${name}>`).exec(e.text)?.[1]
      const context = await taskContext($, tag('tool-use-id'), tag('task-id'))
      rememberPrompt(e.text, context)
      if (context === MAIN) return next(e)
      return next(withNote(e, `This notification is about the context "${context}". Post what the user should know with ${TOOL} into "${context}".`))
    }
    if (e.origin.kind !== 'composer') {
      rememberPrompt(e.text, MAIN)
      return next(e)
    }
    const context = await read($, view)
    rememberPrompt(e.text, context)
    if (context === MAIN) return next(e)
    return next(
      withNote(
        e,
        `The user wrote this prompt in the context "${context}". Reply by calling ${TOOL} with context "${context}"; the post is your reply, so don't repeat it as text.`,
      ),
    )
  })

  on('turn.start', async ($, e, next) => {
    startTurn(promptContext.get(e.text) ?? MAIN)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined && (await isActive($))) {
      if (turnContext === MAIN && hasOwnText && (await read($, view)) !== MAIN) await update($, mainUnread, n => n + 1)
      endedContext = turnContext
      startTurn(MAIN)
    }
    return next(e)
  })

  // Tie each kept row of a context's turn to that context, by the id its row is drawn under
  on('session.append', async ($, e, next) => {
    if (e.agentId !== undefined || !(await isActive($))) return next(e)
    await keepOn($)
    const { message } = e
    if (message.type === 'user' && e.door === 'prompt') {
      const first = message.content.find(block => block.type === 'text')?.text
      const context = typeof first === 'string' ? promptContext.get(first) : undefined
      if (context) await $.state.set({ ...ROW, id: e.uuid }, context)
    } else if (message.type === 'user' && e.door === 'tool-result') {
      // A result of another tool: what Claude writes next is about it, not a recap of a post
      if (e.origin.kind === 'tool' && e.origin.tool !== TOOL) isAfterPost = false
    } else if (message.type === 'system' && message.name === 'turn_duration' && endedContext !== null) {
      // The duration line Claude Code keeps when a turn ends: it draws under this row's id
      if (endedContext !== MAIN) await $.state.set({ ...ROW, id: e.uuid }, endedContext)
      endedContext = null
    } else if (message.type === 'assistant') {
      if (!isAfterPost && message.content.some(block => block.type === 'text')) hasOwnText = true
      if (turnContext !== MAIN) {
        await $.state.set({ ...ROW, id: e.uuid }, turnContext)
        for (const block of message.content)
          if (block.type === 'tool_use' && typeof block.id === 'string') await $.state.set({ ...ROW, id: block.id }, turnContext)
      }
    }
    return next(e)
  })

  on(
    'ui.render',
    { component: ['UserMessage', 'AssistantMessage', 'ToolUse', 'ToolResult', 'ToolGroup', 'TurnDuration'] },
    async ($, e, next) => {
      if (!(await isActive($))) return next(e)
      const { Box, Text, Markdown } = $.ui.resolve(e)
      const viewing = await read($, view)
      const nothing = <Box />

      // A post: Claude's message in its context, one pointer line in Main chat
      const drawPost = (post: AgentPost) => {
        if (viewing === MAIN)
          return (
            <Box flexDirection="row" marginTop={1}>
              <Box flexShrink={0}>
                <Text dimColor>→ {post.context}</Text>
                {post.needsUser && <Text color="warning"> needs you</Text>}
              </Box>
              <Text dimColor wrap="truncate">: {firstLine(post.text)}</Text>
            </Box>
          )
        if (!sameName(viewing, post.context)) return null
        return (
          <Box flexDirection="row" marginTop={1}>
            <Text>● </Text>
            <Box flexDirection="column" flexShrink={1}>
              <Markdown text={post.text.slice(0, 10000)} />
            </Box>
          </Box>
        )
      }

      if ((e.component === 'ToolUse' || e.component === 'ToolResult') && e.props.tool === TOOL) {
        if (e.component === 'ToolResult') return nothing
        if (e.props.isErrored) return next(e)
        const post = postOf(e.props.input)
        return (post.context && drawPost(post)) || nothing
      }

      const isOwn = sameName(await contextOf($, e), viewing)
      if (e.component === 'ToolUse' && e.props.tool === 'Agent') {
        // The posts of the subagent this call started draw with the call, each in its own view
        const agentId = await read($, { ...AGENT_OF_CALL, id: e.requestId })
        const posts = agentId ? ((await read($, { ...AGENT_POSTS, id: agentId })) ?? []) : []
        const drawn = posts.flatMap(post => drawPost(post) ?? [])
        if (drawn.length > 0)
          return (
            <Box flexDirection="column">
              {isOwn && (await next(e))}
              {drawn}
            </Box>
          )
      }
      return isOwn ? next(e) : nothing
    },
  )

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const viewing = await read($, view)
    const list = (await read($, contexts)).map((one, i) => ({ ...one, key: `context-${i + 1}` }))
    const mainCount = await read($, mainUnread)
    const isDoneOpen = await read($, isDoneShown)

    const entry = (name: string, label: string, key: string, hotkey: string | undefined, unread: number, needsUser: boolean) => {
      const isViewed = sameName(name, viewing)
      return (
        <Box flexDirection="row">
          <Text color="suggestion">{isViewed ? '▶ ' : '  '}</Text>
          <Button key={key} label={label} {...(hotkey ? { hotkey } : {})} plain dimColor={!isViewed} onPress={() => select($, name)} />
          {unread > 0 && <Text color="suggestion"> {String(unread)}</Text>}
          {needsUser && <Text color="warning"> needs you</Text>}
        </Box>
      )
    }

    // Open contexts first, then the Done group, numbered in the order they are listed
    const open = list.filter(one => !one.isDone)
    const done = list.filter(one => one.isDone)
    const shown = isDoneOpen ? [...open, ...done] : open
    const numbered = (one: (typeof list)[number]) => {
      const i = shown.indexOf(one)
      return entry(one.name, one.name, one.key, i < 9 ? String(i + 1) : undefined, one.unread, one.needsUser)
    }
    const isViewingDone = done.some(one => sameName(one.name, viewing))
    const doneUnread = done.reduce((sum, one) => sum + one.unread, 0)

    return (
      <Box flexDirection="column">
        <Text bold>Conversations</Text>
        {entry(MAIN, 'Main chat', 'main', '0', mainCount, false)}
        {open.map(numbered)}
        {done.length > 0 && (
          <Box flexDirection="row" marginTop={1}>
            <Text color="suggestion">{isViewingDone && !isDoneOpen ? '▶ ' : '  '}</Text>
            <Button
              key="done"
              label={`${isDoneOpen ? '▾' : '▸'} Done (${done.length})`}
              plain
              dimColor
              onPress={() => update($, isDoneShown, isShown => !isShown)}
            />
            {!isDoneOpen && doneUnread > 0 && <Text color="suggestion"> {String(doneUnread)}</Text>}
          </Box>
        )}
        {isDoneOpen && done.map(numbered)}
        {list.length === 0 && <Text dimColor>No contexts yet: Claude adds one when it posts about a topic.</Text>}
        <Box marginTop={1}>
          <Text dimColor>Click one, or press ctrl+x tab then its number. esc returns to the prompt.</Text>
        </Box>
      </Box>
    )
  })
}
