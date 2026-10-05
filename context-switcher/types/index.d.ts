/** A context Claude has posted to, as the sidebar lists it. */
export type ContextEntry = {
  name: string
  /** Posts since the user last viewed the context. */
  unread: number
  /** Whether an unread post asks the user for input. */
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
      /** An assistant row (text or thinking) after a post into its own context's turn, with no tool call: it sums up the post. */
      isEcho: StateFamily<boolean>
    }
  }
}
