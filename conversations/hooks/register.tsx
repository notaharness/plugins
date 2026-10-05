// Conversations: one session, many conversations. Claude posts to named conversations
// with a tool; a sidebar lists them, and the transcript shows one at a time.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderInput } from 'claude-code'

import type { AgentPost, ConversationEntry } from '../types'

const PANE = 'conversations'
const TOOL = 'mcp__conversations__post'
/** The view and row conversation of Main. */
const MAIN = ''

const isOn = atom({ plugin: 'conversations', key: 'isOn' } as const, false)
const view = atom({ plugin: 'conversations', key: 'view' } as const, MAIN)
const conversations = atom({ plugin: 'conversations', key: 'conversations' } as const, [] as ConversationEntry[])
const mainUnread = atom({ plugin: 'conversations', key: 'mainUnread' } as const, 0)
const isArchiveShown = atom({ plugin: 'conversations', key: 'isArchiveShown' } as const, false)
const ROW = { plugin: 'conversations', key: 'rowConversation' } as const
const AGENT_POSTS = { plugin: 'conversations', key: 'agentPosts' } as const
const AGENT_OF_CALL = { plugin: 'conversations', key: 'agentOfCall' } as const
const CALL_OF_AGENT = { plugin: 'conversations', key: 'callOfAgent' } as const
const PARENT_OF_AGENT = { plugin: 'conversations', key: 'parentOfAgent' } as const

const GUIDE = `# Conversations

The user turned on Conversations. This session now holds several conversations: named threads the user reads one at a time from a sidebar, next to Main, their focus conversation. You still see everything; the user sees only the conversation they selected, and Main shows a one-line pointer for each post to another conversation.

- Give each separate topic its own conversation, named with a short topic name of two or three words (for example "CI flakes"). Use the same name for the same topic.
- A conversation split does not need to be bound to a single issue, or pull request, or task, sometimes conversations span more than one and sometimes conversations happen without any work being performed, it can sometimes be useful to have a conversation outside the noise and incoming events of the main conversation. Evaluate when to start a new conversation on a topic and how the user wants their attention focused, think of the user's attention like a resource to be managed, humans are better at engaging with one topic at a time.
- When you start a new conversation while answering a prompt the user wrote in Main, the user's view moves into it.
- Post news about a topic with ${TOOL} instead of writing it in Main. This matters most for results that arrive on their own: task notifications, background commands, subagents, messages from other sessions.
- A prompt the user writes from inside a conversation says so in a note. Answer it with ${TOOL} into that conversation: the post is your reply, so put everything the user should read in it, and don't repeat it as text afterwards.
- Set needsUser on a post that asks the user for a decision or for input.
- Keep the sidebar tidy: the user never manages conversations, you do. As soon as a conversation wraps up (resolved, merged, answered, abandoned), set archive on your last post to it, and the sidebar moves it to Archived. Don't leave stale conversations active. A later post without archive, or a prompt the user writes there, brings it back.
- Prompts without such a note come from Main. Answer those as usual.`

const NOT_FULLSCREEN =
  'Conversations needs fullscreen rendering. Run `/tui fullscreen` (Claude Code relaunches with this conversation), or start Claude Code with `CLAUDE_CODE_NO_FLICKER=1`, then run /conversations again.'

const sameName = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase()

/** The prompt text to the conversation it was written in, read when its turn starts and its row is drawn. */
const promptConversation = new Map<string, string>()
/** The prompt texts the user typed in Main, as against those that arrived on their own. */
const typedInMain = new Set<string>()
/**
 * The main loop's running turn: its conversation; whether the user started it by typing in Main,
 * and whether it moved their view into a conversation it started; whether the last tool to
 * answer was a post (so text now is about that post); and whether the turn wrote text of its
 * own, for Main's unread count. Then the conversation of the turn that just ended, for its
 * duration line.
 */
let turnConversation = MAIN
let isTypedInMain = false
let hasMovedView = false
let isAfterPost = false
let hasOwnText = false
let endedConversation: string | null = null
let isToolRegistered = false

function startTurn(conversation: string, isTyped = false) {
  turnConversation = conversation
  isTypedInMain = isTyped && conversation === MAIN
  hasMovedView = false
  isAfterPost = false
  hasOwnText = false
}

function rememberPrompt(text: string, conversation: string, isTyped = false) {
  promptConversation.delete(text)
  promptConversation.set(text, conversation)
  if (isTyped) typedInMain.add(text)
  else typedInMain.delete(text)
  if (promptConversation.size > 100) {
    const oldest = promptConversation.keys().next().value!
    promptConversation.delete(oldest)
    typedInMain.delete(oldest)
  }
}

function withNote<E extends { context?: readonly string[] }>(e: E, note: string): E {
  return { ...e, context: [...(e.context ?? []), `[Conversations] ${note}`] }
}

/**
 * On once /conversations has run, for the rest of the session: the tool cannot be taken back. The
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
        "Post a message to a conversation: a named thread in the user's Conversations sidebar. " +
        'The user reads it as your message when they open that conversation, and as a one-line pointer in Main. ' +
        'A name not used before creates the conversation; keep names short and reuse them for the same topic. ' +
        'text is Markdown. Set needsUser when the post asks the user for a decision or input. ' +
        'Set archive on the last post of a conversation that has wrapped up: the sidebar moves it to Archived, and a later post without archive brings it back.',
      inputSchema: {
        type: 'object',
        properties: {
          conversation: { type: 'string', description: 'The conversation, a short topic name such as "CI flakes"' },
          text: { type: 'string', description: 'The message, in Markdown' },
          needsUser: { type: 'boolean', description: 'True when the post asks the user for a decision or input' },
          archive: { type: 'boolean', description: 'True when the conversation has wrapped up with this post' },
        },
        required: ['conversation', 'text'],
      },
    })
    isToolRegistered = true
  }
  await update($, isOn, () => true)
}

async function select($: EngineInterface, name: string) {
  await update($, view, () => name)
  if (name === MAIN) await update($, mainUnread, () => 0)
  const list = await update($, conversations, entries =>
    entries.map(entry => (sameName(entry.name, name) ? { ...entry, unread: 0, needsUser: false } : entry)),
  )
  // Choosing Main or an active conversation folds the Archived section away again
  if (!list.some(entry => entry.isArchived && sameName(entry.name, name))) await update($, isArchiveShown, () => false)
}

/** The sidebar's key for each conversation, by its place in the list. */
const keyOf = (index: number) => `conversation-${index + 1}`

/** The conversation a transcript row belongs to; Main when nothing ties it to one. */
async function conversationOf($: EngineInterface, e: RenderInput): Promise<string> {
  const own = await read($, { ...ROW, id: e.requestId })
  if (own !== undefined) return own
  if (e.component === 'UserMessage') {
    const { task } = e.props
    if (task) return taskConversation($, task.toolUseId, task.id)
    // A fresh prompt is drawn before its row is kept, under a placeholder id
    if (e.props.origin.kind === 'composer') return promptConversation.get(e.props.text) ?? MAIN
  }
  if (e.component === 'ToolGroup') {
    const ids = e.props.calls.flatMap(call => (call.tool_use_id ? [call.tool_use_id] : []))
    if (ids.length > 0) {
      const found = await Promise.all(ids.map(async id => (await read($, { ...ROW, id })) ?? MAIN))
      return found.every(conversation => conversation === found[0]) ? found[0]! : MAIN
    }
    const row = thinkingRowOf(e.requestId)
    if (row) return (await read($, { ...ROW, id: row })) ?? MAIN
  }
  return MAIN
}

/**
 * The assistant row a folded thinking line (a ToolGroup with no calls) belongs to. Not part of
 * the documented API: observed as the id `collapsed-<uuid of that row>`. Any other id leaves the
 * line in Main.
 */
function thinkingRowOf(requestId: string) {
  return /^collapsed-(.+)$/.exec(requestId)?.[1]
}

/**
 * The conversation of a background task's notification: that of the call that started it, else, for
 * a subagent (whose task id is its agent id), that of the main loop's Agent call it works for.
 */
async function taskConversation($: EngineInterface, toolUseId: string | undefined, taskId: string | undefined) {
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

type PostInput = { conversation?: unknown; text?: unknown; needsUser?: unknown; archive?: unknown }

function postOf(input: unknown) {
  const { conversation, text, needsUser, archive } = (input ?? {}) as PostInput
  return {
    conversation: typeof conversation === 'string' ? conversation.trim() : '',
    text: typeof text === 'string' ? text : '',
    needsUser: needsUser === true,
    isArchived: archive === true,
  }
}

/**
 * The status line under the prompt: while the sidebar is closed, how many conversations need the user
 * and how many posts wait unread; cleared while the sidebar is open or nothing waits.
 */
async function showPending($: EngineInterface) {
  const isOpen = (await $.ui.panes()).some(pane => pane.id === PANE)
  const list = await read($, conversations)
  const needing = list.filter(entry => entry.needsUser).length
  const unread = list.reduce((sum, entry) => sum + entry.unread, 0)
  if (isOpen || unread === 0) return $.ui.status(undefined)
  const parts = [
    ...(needing > 0 ? [needing === 1 ? '1 conversation needs you' : `${needing} conversations need you`] : []),
    unread === 1 ? '1 unread post' : `${unread} unread posts`,
  ]
  $.ui.status(`${parts.join(', ')} (/conversations to open the sidebar)`)
}

function firstLine(markdown: string) {
  const line = markdown.split('\n').find(one => one.trim() !== '') ?? ''
  return line.replace(/^[#>*\-\s]+/, '').replace(/\*\*|__|`/g, '').trim()
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'conversations',
      description: 'Turn on Conversations and open its sidebar',
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

  // /clear starts the conversation over: its rows and conversations go with it
  on('session.end', async ($, e, next) => {
    promptConversation.clear()
    typedInMain.clear()
    startTurn(MAIN)
    $.ui.status(undefined)
    return next(e)
  })

  on('command.run', { command: 'conversations' }, async ($, e) => {
    if (!e.presentation.isFullscreen) return { text: NOT_FULLSCREEN }
    await turnOn($)
    await $.ui.open({ id: PANE, title: 'Conversations', columns: 30 })
    await showPending($)
    return {}
  })

  // Closing the sidebar returns the transcript to Main
  on('ui.close', { id: PANE }, async ($, e, next) => {
    const closed = await next(e)
    if (e.origin.kind === 'person') await select($, MAIN)
    await showPending($)
    return closed
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    if (!(await isActive($))) return composed
    return { sections: [...composed.sections, { id: 'conversations:guide', text: GUIDE, scope: 'session' }] }
  })

  // In the prompt's own tool list, so Claude calls it without searching for it
  on('tool.describe', { tool: TOOL }, async ($, e, next) => ({ ...(await next(e)), isDeferred: false }))

  on('tool.check', { tool: TOOL }, () => ({ decision: 'allow' }))

  // A pattern: the typed tool names are the ones connected when the engine last wrote the types
  on('tool.call', { tool: /^mcp__conversations__post$/ }, async ($, e) => {
    const post = postOf(e)
    if (!post.conversation || !post.text.trim()) return { deny: 'A post needs a conversation name and some text.' }
    const viewing = await read($, view)
    const unseen = !sameName(viewing, post.conversation)
    // An archived conversation needs nothing of the user, but keeps the posts they have not read; a
    // later post without archive brings it back
    const after = (entry: ConversationEntry): ConversationEntry => ({
      ...entry,
      unread: entry.unread + (unseen ? 1 : 0),
      needsUser: !post.isArchived && (entry.needsUser || (unseen && post.needsUser)),
      isArchived: post.isArchived,
    })
    let isNew = false
    const list = await update($, conversations, entries => {
      const known = entries.find(entry => sameName(entry.name, post.conversation))
      isNew = !known
      if (!known) return [...entries, after({ name: post.conversation, unread: 0, needsUser: false, isArchived: false })]
      return entries.map(entry => (entry === known ? after(entry) : entry))
    })
    const name = list.find(entry => sameName(entry.name, post.conversation))?.name ?? post.conversation
    if (e.agentId === undefined) {
      isAfterPost = true
      // The first conversation a turn the user started from Main starts takes their view with it
      if (isNew && isTypedInMain && !hasMovedView && viewing === MAIN) {
        hasMovedView = true
        await select($, name)
      }
    } else {
      // A subagent's rows live in its own transcript: keep its posts for the main loop's call that started it
      const agent = await topAgentOf($, e.agentId)
      const kept: AgentPost = { conversation: name, text: post.text, needsUser: post.needsUser }
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
      // The notification belongs to the conversation of the call that started the task. Its ids are
      // read from the notification's text, a format the engine writes but does not document;
      // a notification without them stays in Main
      const tag = (name: string) => new RegExp(`<${name}>([^<]+)</${name}>`).exec(e.text)?.[1]
      const conversation = await taskConversation($, tag('tool-use-id'), tag('task-id'))
      rememberPrompt(e.text, conversation)
      if (conversation === MAIN) return next(e)
      return next(withNote(e, `This notification is about the conversation "${conversation}". Post what the user should know with ${TOOL} into "${conversation}".`))
    }
    if (e.origin.kind !== 'composer') {
      rememberPrompt(e.text, MAIN)
      return next(e)
    }
    const conversation = await read($, view)
    rememberPrompt(e.text, conversation, true)
    if (conversation === MAIN) return next(e)
    // A prompt written in an archived conversation brings it back to the active ones
    await update($, conversations, list =>
      list.map(entry => (entry.isArchived && sameName(entry.name, conversation) ? { ...entry, isArchived: false } : entry)),
    )
    return next(
      withNote(
        e,
        `The user wrote this prompt in the conversation "${conversation}". Reply by calling ${TOOL} with conversation "${conversation}"; the post is your reply, so don't repeat it as text.`,
      ),
    )
  })

  on('turn.start', async ($, e, next) => {
    startTurn(promptConversation.get(e.text) ?? MAIN, typedInMain.has(e.text))
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined && (await isActive($))) {
      if (turnConversation === MAIN && hasOwnText && (await read($, view)) !== MAIN) await update($, mainUnread, n => n + 1)
      endedConversation = turnConversation
      startTurn(MAIN)
    }
    return next(e)
  })

  // Tie each kept row of a conversation's turn to that conversation, by the id its row is drawn under
  on('session.append', async ($, e, next) => {
    if (e.agentId !== undefined || !(await isActive($))) return next(e)
    await keepOn($)
    const { message } = e
    if (message.type === 'user' && e.door === 'prompt') {
      const first = message.content.find(block => block.type === 'text')?.text
      const conversation = typeof first === 'string' ? promptConversation.get(first) : undefined
      if (conversation) await $.state.set({ ...ROW, id: e.uuid }, conversation)
    } else if (message.type === 'user' && e.door === 'tool-result') {
      // A result of another tool: what Claude writes next is about it, not a recap of a post
      if (e.origin.kind === 'tool' && e.origin.tool !== TOOL) isAfterPost = false
    } else if (message.type === 'system' && message.name === 'turn_duration' && endedConversation !== null) {
      // The duration line Claude Code keeps when a turn ends: it draws under this row's id
      if (endedConversation !== MAIN) await $.state.set({ ...ROW, id: e.uuid }, endedConversation)
      endedConversation = null
    } else if (message.type === 'assistant') {
      if (!isAfterPost && message.content.some(block => block.type === 'text')) hasOwnText = true
      if (turnConversation !== MAIN) {
        await $.state.set({ ...ROW, id: e.uuid }, turnConversation)
        for (const block of message.content)
          if (block.type === 'tool_use' && typeof block.id === 'string') await $.state.set({ ...ROW, id: block.id }, turnConversation)
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

      // A post: Claude's message in its conversation, one pointer line in Main
      const drawPost = (post: AgentPost) => {
        if (viewing === MAIN)
          return (
            <Box flexDirection="row" marginTop={1}>
              <Box flexShrink={0}>
                <Text dimColor>→ {post.conversation}</Text>
                {post.needsUser && <Text color="warning"> needs you</Text>}
              </Box>
              <Text dimColor wrap="truncate">: {firstLine(post.text)}</Text>
            </Box>
          )
        if (!sameName(viewing, post.conversation)) return null
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
        return (post.conversation && drawPost(post)) || nothing
      }

      const isOwn = sameName(await conversationOf($, e), viewing)
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

  // The sidebar's focus ring opens the Archived section as it moves onto it (onto its header or
  // one of its conversations), and folds it away as it moves back onto Main or an active one
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
    const moved = await next(e)
    if (moved.deny !== undefined || e.element === undefined) return moved
    const list = await read($, conversations)
    const index = list.findIndex((one, i) => keyOf(i) === e.element)
    const isArchive = e.element === 'archived' || list[index]?.isArchived === true
    if (isArchive || e.element === 'main' || index >= 0) await update($, isArchiveShown, () => isArchive)
    return moved
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const viewing = await read($, view)
    const list = (await read($, conversations)).map((one, i) => ({ ...one, key: keyOf(i) }))
    const mainCount = await read($, mainUnread)
    const isArchiveOpen = await read($, isArchiveShown)

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

    // Active conversations first, then the Archived section, numbered in the order they are listed
    const active = list.filter(one => !one.isArchived)
    const archived = list.filter(one => one.isArchived)
    const shown = isArchiveOpen ? [...active, ...archived] : active
    const numbered = (one: (typeof list)[number]) => {
      const i = shown.indexOf(one)
      return entry(one.name, one.name, one.key, i < 9 ? String(i + 1) : undefined, one.unread, one.needsUser)
    }
    const isViewingArchived = archived.some(one => sameName(one.name, viewing))
    const archivedUnread = archived.reduce((sum, one) => sum + one.unread, 0)

    return (
      <Box flexDirection="column">
        <Text bold>Conversations</Text>
        {entry(MAIN, 'Main', 'main', '0', mainCount, false)}
        {active.map(numbered)}
        {archived.length > 0 && (
          <Box flexDirection="row" marginTop={1}>
            <Text color="suggestion">{isViewingArchived && !isArchiveOpen ? '▶ ' : '  '}</Text>
            <Button
              key="archived"
              label={`${isArchiveOpen ? '▾' : '▸'} Archived (${archived.length})`}
              plain
              dimColor
              onPress={() => update($, isArchiveShown, () => true)}
            />
            {!isArchiveOpen && archivedUnread > 0 && <Text color="suggestion"> {String(archivedUnread)}</Text>}
          </Box>
        )}
        {isArchiveOpen && archived.map(numbered)}
        {list.length === 0 && <Text dimColor>No conversations yet: Claude adds one when it posts about a topic.</Text>}
        <Box marginTop={1}>
          <Text dimColor>Click one, or press ctrl+x tab then its number. esc returns to the prompt.</Text>
        </Box>
      </Box>
    )
  })
}
