/** A context Claude has posted to, as the sidebar lists it. */
export type ContextEntry = {
  name: string
  /** Posts since the user last viewed the context. */
  unread: number
  /** Whether an unread post asks the user for input. */
  needsUser: boolean
}

/** A post a subagent made, kept for the main loop's Agent call that started it. */
export type AgentPost = {
  context: string
  text: string
  needsUser: boolean
}

declare module 'claude-code' {
  interface PluginState {
    'context-switcher': {
      /** Turned on by /contexts; carries that over a reload of the mod. */
      isOn: boolean
      /** The context the transcript shows; '' is Main chat. */
      view: string
      contexts: ContextEntry[]
      /** Main chat replies since the user last viewed it. */
      mainUnread: number
      /** The context a transcript row belongs to, by row id; absent is Main chat. */
      rowContext: StateFamily<string>
      /** The posts a subagent made, by the id of the subagent the main loop started. */
      agentPosts: StateFamily<AgentPost[]>
      /** The subagent each of the main loop's Agent calls started, by the call's tool_use_id. */
      agentOfCall: StateFamily<string>
    }
  }
}
