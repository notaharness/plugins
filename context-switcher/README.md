# Context Switcher

A busy Claude Code session interleaves everything in one chat: background commands finishing,
subagents reporting, CI results, messages from other sessions. Claude keeps up with all of it;
your attention is the limit. Context Switcher lets one session hold several smaller
conversations, called contexts, so you read one topic at a time and switch when you choose.

It is still one session, one Claude and one conversation. Claude sees everything and can post to
any context at any time. Only your view of the transcript changes.

## Requirements

- Claude Code 2.1.289 or later, in a terminal.
- [Fullscreen rendering](https://code.claude.com/docs/en/fullscreen). Turn it on with
  `/tui fullscreen`, or start Claude Code with `CLAUDE_CODE_NO_FLICKER=1`. The classic renderer
  keeps the conversation in the terminal's scrollback, which a mod cannot redraw, so
  `/contexts` refuses to start there and says how to switch.
- A terminal at least 110 columns wide shows the sidebar beside the transcript; a narrower one
  shows it above the prompt.

The Desktop app, the VS Code extension and the web are not supported.

## Install

```text
/plugin marketplace add notaharness/plugins
/plugin install context-switcher@notaharness
```

To try a checkout instead, start Claude Code with the plugin directory:

```bash
CLAUDE_CODE_NO_FLICKER=1 claude --plugin-dir ./context-switcher
```

## Use

Run `/contexts`. Until you do, the plugin does nothing: Claude gets no extra tool and no extra
instructions. Once it is on, it stays on for the rest of the session.

- **The sidebar** lists Main chat and each context Claude has created, with a count of unread
  posts and a `needs you` mark when a post asks for your input. Click an entry, or press
  `ctrl+x tab` and then its number, to select it. `Esc` hands the keys back to the prompt.
- **Main chat** is your focus conversation. Traffic for a context shows there as one dim line per
  post, such as `→ CI flakes: Run 4812 failed on linux`.
- **A context** turns the transcript into that thread: Claude's posts read as its messages, along
  with your prompts there and the tool calls and notifications that belong to it. Everything
  else is hidden.
- **Write in a context** by selecting it and typing as usual. Claude answers into that context.
- **Close the sidebar** with its close mark or `ctrl+x x`. The transcript returns to Main chat.
  Run `/contexts` to bring the sidebar back.

Claude names contexts itself, after the topic. Ask it to move something into a context ("track
the CI run in its own context") or let it route updates on its own.

## How it works

- `/contexts` registers one tool, `mcp__context-switcher__post` (`context`, `text`,
  `needsUser`), listed up front rather than behind tool search, and adds a short section to the
  system prompt that explains contexts to Claude. Both stay out of the session until you run
  the command.
- A prompt you type in a context carries a note, hidden from the transcript, that tells Claude
  which context it came from.
- Rows of a context's turn (Claude's text, its tool calls, the turn's duration line) belong to
  that context. A background task's notification belongs to the context of the call that
  started it; anything that cannot be traced belongs to Main chat.
- Rows outside the selected view draw as nothing, so they take no lines.
- Text and thinking Claude writes after it has posted into the context of its own turn, with no
  further tool calls, is hidden: it restates the post.

## Limitations

- **Fullscreen only**, terminal only.
- **No off switch.** A mod cannot remove a tool it has registered, so Context Switcher stays on
  until the session ends. Closing the sidebar returns you to Main chat; start a new session to
  go without it.
- **No unfiltered view.** Main chat collapses context traffic to pointer lines, and the ctrl+o
  transcript shows the selected view too, except Claude's thinking, which shows there in every
  view.
- **Some rows show in every view**: slash-command echo lines (`❯ /clear`), notices and other rows
  Claude Code draws without a hook a mod can reach.
- **The sticky prompt header** at the top of a scrolled transcript can show a prompt from
  another context.
- **Work started from Main chat stays in Main chat.** Background work Claude starts in a Main
  chat turn notifies Main chat; Claude then posts the result to a context if it belongs to one.
- **A prompt typed while Claude is busy** with another context's turn reaches Claude with its
  note, but the rows of the running turn stay where they were.
- **Contexts last for the session.** `/clear` empties them, and a resumed session starts with
  none; earlier posts still show as pointer lines in Main chat.
- **Claude routes the traffic.** It may sometimes answer in Main chat what belongs in a context,
  or the other way round.

## Tests

From the repository root:

```bash
claude plugin validate --strict ./context-switcher
claude plugin test ./context-switcher
```

The tests drive the mod's hooks with no model calls: the command and its fullscreen check, the
tool and the sidebar's counts, the rows each view draws, prompt notes and notification mapping.
