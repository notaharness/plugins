/** A conversation Claude has posted to, as the sidebar lists it. */
export type ConversationEntry = {
  name: string
  /** Posts since the user last viewed the conversation. */
  unread: number
  /** Whether an unread post asks the user for input. */
  needsUser: boolean
  /** Claude archived it as wrapped up; the sidebar lists it under Archived. */
  isArchived: boolean
}

/** A post a subagent made, kept for the main loop's Agent call that started it. */
export type AgentPost = {
  conversation: string
  text: string
  needsUser: boolean
}

declare module 'claude-code' {
  interface PluginState {
    conversations: {
      /** Turned on by /conversations; carries that over a reload of the mod. */
      isOn: boolean
      /** The conversation the transcript shows; '' is Main. */
      view: string
      conversations: ConversationEntry[]
      /** Main's replies since the user last viewed it. */
      mainUnread: number
      /** Whether the sidebar's Archived section is expanded. */
      isArchiveShown: boolean
      /** The conversation a transcript row belongs to, by row id; absent is Main. */
      rowConversation: StateFamily<string>
      /** The posts a subagent made, by the id of the subagent the main loop started. */
      agentPosts: StateFamily<AgentPost[]>
      /** The subagent each of the main loop's Agent calls started, by the call's tool_use_id. */
      agentOfCall: StateFamily<string>
      /** The other way round: the main loop's Agent call that started a subagent, by the subagent's id. */
      callOfAgent: StateFamily<string>
      /** The subagent that started a subagent, by the started one's id, recorded as it starts. */
      parentOfAgent: StateFamily<string>
    }
  }
}
