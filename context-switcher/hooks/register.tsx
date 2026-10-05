// Context Switcher: one session, many contexts. Claude posts to named contexts
// with a tool; a sidebar lists them, and the transcript shows one at a time.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderInput } from 'claude-code'

import type { ContextEntry } from '../types'

const PANE = 'contexts'
const TOOL = 'mcp__context-switcher__post'
/** The view and row context of Main chat. */
const MAIN = ''

const isOn = atom({ plugin: 'context-switcher', key: 'isOn' } as const, false)
const view = atom({ plugin: 'context-switcher', key: 'view' } as const, MAIN)
const contexts = atom({ plugin: 'context-switcher', key: 'contexts' } as const, [] as ContextEntry[])
const mainUnread = atom({ plugin: 'context-switcher', key: 'mainUnread' } as const, 0)
const ROW = { plugin: 'context-switcher', key: 'rowContext' } as const
const ECHO = { plugin: 'context-switcher', key: 'isEcho' } as const

const GUIDE = `# Context Switcher

The user turned on Context Switcher. The conversation now holds contexts: named threads the user reads one at a time from a sidebar, next to Main chat, their focus conversation. You still see everything; the user sees only the thread they selected, and Main chat shows a one-line pointer for each post to a context.

- Give each separate topic its own context, named with a short topic name of two or three words (for example "CI flakes"). Use the same name for the same topic.
- Post news about a topic with ${TOOL} instead of writing it in Main chat. This matters most for results that arrive on their own: task notifications, background commands, subagents, messages from other sessions.
- A prompt the user writes from inside a context says so in a note. Answer it with ${TOOL} into that context: the post is your reply, so put everything the user should read in it. Text you write after that post is hidden from the user; end the turn with one short line such as "Posted to CI flakes." rather than repeating the post.
- Set needsUser on a post that asks the user for a decision or for input.
- Prompts without such a note come from Main chat. Answer those as usual.`

const NOT_FULLSCREEN =
  'Context Switcher needs fullscreen rendering. Run `/tui fullscreen` (Claude Code relaunches with this conversation), or start Claude Code with `CLAUDE_CODE_NO_FLICKER=1`, then run /contexts again.'

const sameName = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase()

/** The prompt text to the context it was written in, read when its turn starts and its row is drawn. */
const promptContext = new Map<string, string>()
/** The context of the main loop's running turn, whether it has posted there yet, and the context of the turn that just ended (for its duration line). */
let turnContext = MAIN
let hasTurnPosted = false
let endedContext: string | null = null
let isToolRegistered = false

function rememberPrompt(text: string, context: string) {
  promptContext.delete(text)
  promptContext.set(text, context)
  if (promptContext.size > 100) promptContext.delete(promptContext.keys().next().value!)
}

function withNote<E extends { context?: readonly string[] }>(e: E, note: string): E {
  return { ...e, context: [...(e.context ?? []), `[Context Switcher] ${note}`] }
}

/**
 * On once /contexts has run, for the rest of the session. The tool cannot be taken back, so a
 * /clear (which resets $.state) leaves it on; the state value carries it over a reload of the mod.
 */
async function isActive($: EngineInterface) {
  return isToolRegistered || (await read($, isOn))
}

async function turnOn($: EngineInterface) {
  if (!isToolRegistered) {
    await $.tool.register({
      name: 'post',
      description:
        "Post a message to a context: a named thread in the user's Context Switcher sidebar. " +
        'The user reads it as your message when they open that context, and as a one-line pointer in Main chat. ' +
        'A name not used before creates the context; keep names short and reuse them for the same topic. ' +
        'text is Markdown. Set needsUser when the post asks the user for a decision or input.',
      inputSchema: {
        type: 'object',
        properties: {
          context: { type: 'string', description: 'The context, a short topic name such as "CI flakes"' },
          text: { type: 'string', description: 'The message, in Markdown' },
          needsUser: { type: 'boolean', description: 'True when the post asks the user for a decision or input' },
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
    const startedBy = e.props.task?.toolUseId
    if (startedBy) return (await read($, { ...ROW, id: startedBy })) ?? MAIN
    // A fresh prompt is drawn before its row is kept, under a placeholder id
    if (e.props.origin.kind === 'composer') return promptContext.get(e.props.text) ?? MAIN
  }
  if (e.component === 'ToolGroup') {
    const first = /^collapsed-(.+)$/.exec(e.requestId)?.[1]
    if (first) {
      const ofFirst = await read($, { ...ROW, id: first })
      if (ofFirst !== undefined) return ofFirst
    }
    const ids = e.props.calls.flatMap(call => (call.tool_use_id ? [call.tool_use_id] : []))
    const found = await Promise.all(ids.map(async id => (await read($, { ...ROW, id })) ?? MAIN))
    if (found.length > 0 && found.every(context => context === found[0])) return found[0]!
  }
  return MAIN
}

/** An assistant row, or the folded thinking line it opens, that only sums up a post of its turn. */
async function isEcho($: EngineInterface, e: RenderInput) {
  if (e.component === 'AssistantMessage') return (await read($, { ...ECHO, id: e.requestId })) === true
  const first = e.component === 'ToolGroup' ? /^collapsed-(.+)$/.exec(e.requestId)?.[1] : undefined
  return first !== undefined && (await read($, { ...ECHO, id: first })) === true
}

type PostInput = { context?: unknown; text?: unknown; needsUser?: unknown }

function postOf(input: unknown) {
  const { context, text, needsUser } = (input ?? {}) as PostInput
  return {
    context: typeof context === 'string' ? context.trim() : '',
    text: typeof text === 'string' ? text : '',
    needsUser: needsUser === true,
  }
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
    // A reload keeps $.state: put the tool back if the session had turned it on
    if (await read($, isOn)) await turnOn($)
    return next(e)
  })

  // /clear starts the conversation over: its rows and contexts go with it
  on('session.end', async ($, e, next) => {
    promptContext.clear()
    turnContext = MAIN
    endedContext = null
    return next(e)
  })

  on('command.run', { command: 'contexts' }, async ($, e) => {
    if (!e.presentation.isFullscreen) return { text: NOT_FULLSCREEN }
    await turnOn($)
    await $.ui.open({ id: PANE, title: 'Contexts', columns: 30 })
    return {}
  })

  // Closing the sidebar returns the transcript to Main chat
  on('ui.close', { id: PANE }, async ($, e, next) => {
    const closed = await next(e)
    if (e.origin.kind === 'person') await select($, MAIN)
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
    const list = await update($, contexts, entries => {
      const known = entries.find(entry => sameName(entry.name, post.context))
      if (!known) return [...entries, { name: post.context, unread: unseen ? 1 : 0, needsUser: unseen && post.needsUser }]
      if (!unseen) return entries
      return entries.map(entry =>
        entry === known
          ? { ...entry, unread: entry.unread + 1, needsUser: entry.needsUser || post.needsUser }
          : entry,
      )
    })
    const name = list.find(entry => sameName(entry.name, post.context))?.name ?? post.context
    if (turnContext !== MAIN && sameName(turnContext, name)) hasTurnPosted = true
    return { result: `Posted to "${name}".` }
  })

  on('prompt.submit', async ($, e, next) => {
    if (!(await isActive($))) return next(e)
    if (e.origin.kind === 'task-notification') {
      // The notification belongs to the context of the call that started the task
      const startedBy = /<tool-use-id>([^<]+)<\/tool-use-id>/.exec(e.text)?.[1]
      const context = startedBy ? ((await read($, { ...ROW, id: startedBy })) ?? MAIN) : MAIN
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
        `The user wrote this prompt in the context "${context}". Reply by calling ${TOOL} with context "${context}"; the post is your reply, and text after it is hidden from the user.`,
      ),
    )
  })

  on('turn.start', async ($, e, next) => {
    turnContext = promptContext.get(e.text) ?? MAIN
    hasTurnPosted = false
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      if (turnContext === MAIN && e.answer.trim() !== '' && (await read($, view)) !== MAIN)
        await update($, mainUnread, n => n + 1)
      endedContext = turnContext
      turnContext = MAIN
    }
    return next(e)
  })

  // Tie each kept row of a context's turn to that context, by the id its row is drawn under
  on('session.append', async ($, e, next) => {
    if (e.agentId !== undefined || !(await isActive($))) return next(e)
    const { message } = e
    if (message.type === 'user' && e.door === 'prompt') {
      const first = message.content.find(block => block.type === 'text')?.text
      const context = typeof first === 'string' ? promptContext.get(first) : undefined
      if (context) await $.state.set({ ...ROW, id: e.uuid }, context)
    } else if (message.type === 'assistant' && turnContext !== MAIN) {
      await $.state.set({ ...ROW, id: e.uuid }, turnContext)
      // Claude tends to sum up a post it just made; in the context that reads twice
      if (hasTurnPosted && !message.content.some(block => block.type === 'tool_use'))
        await $.state.set({ ...ECHO, id: e.uuid }, true)
      for (const block of message.content)
        if (block.type === 'tool_use' && typeof block.id === 'string') await $.state.set({ ...ROW, id: block.id }, turnContext)
    } else if (message.type === 'system' && e.door === 'notice' && endedContext !== null) {
      // The turn's duration line is the notice kept right after it ends
      if (endedContext !== MAIN) await $.state.set({ ...ROW, id: e.uuid }, endedContext)
      endedContext = null
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

      if ((e.component === 'ToolUse' || e.component === 'ToolResult') && e.props.tool === TOOL) {
        if (e.component === 'ToolResult') return nothing
        if (e.props.isErrored) return next(e)
        const post = postOf(e.props.input)
        if (!post.context) return nothing
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
        if (!sameName(viewing, post.context)) return nothing
        return (
          <Box flexDirection="row" marginTop={1}>
            <Text>● </Text>
            <Box flexDirection="column" flexShrink={1}>
              <Markdown text={post.text.slice(0, 10000)} />
            </Box>
          </Box>
        )
      }

      if (await isEcho($, e)) return nothing
      const context = await contextOf($, e)
      return sameName(context, viewing) ? next(e) : nothing
    },
  )

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const viewing = await read($, view)
    const list = await read($, contexts)
    const mainCount = await read($, mainUnread)

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

    return (
      <Box flexDirection="column">
        {entry(MAIN, 'Main chat', 'main', '0', mainCount, false)}
        {list.map((one, i) => entry(one.name, one.name, `context-${i + 1}`, i < 9 ? String(i + 1) : undefined, one.unread, one.needsUser))}
        {list.length === 0 && <Text dimColor>No contexts yet: Claude adds one when it posts about a topic.</Text>}
        <Box marginTop={1}>
          <Text dimColor>ctrl+x tab, then a number</Text>
        </Box>
      </Box>
    )
  })
}
