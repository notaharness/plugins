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
- Every row draws in full in exactly one view, its context's or Main chat's, and as nothing in
  the others, so it takes no lines there. Nothing is hidden everywhere: a closing line Claude
  writes after a post shows in the turn's context, even when it repeats the post.
- A subagent's rows live in its own transcript, so its posts draw with the Agent call that
  started it: as Claude's message in the post's context, and as a pointer line in Main chat.

## Limitations

- **Fullscreen only**, terminal only.
- **No off switch.** A mod cannot remove a tool it has registered, so Context Switcher stays on
  until the session ends. Closing the sidebar returns you to Main chat; start a new session to
  go without it.
- **No unfiltered view.** Main chat collapses context traffic to pointer lines, and the ctrl+o
  transcript shows the selected view too, except Claude's thinking, which shows there in every
  view.
- **Closing lines can repeat a post.** After Claude posts in a context, it often adds a short
  line saying so (Claude Code nudges a turn that ends on a tool call into writing one). It shows
  in that context under the post.
- **A subagent's posts draw where its Agent call is**, not where in time they were made, and
  only once the call has said which subagent it started (at once for a background agent, when
  it finishes for a foreground one).
- **Some rows show in every view**: slash-command echo lines (`❯ /clear`), notices and other rows
  Claude Code draws without a hook a mod can reach.
- **The sticky prompt header** at the top of a scrolled transcript can show a prompt from
  another context.
- **Work started from Main chat stays in Main chat.** Background work Claude starts in a Main
  chat turn notifies Main chat; Claude then posts the result to a context if it belongs to one.
- **A prompt typed while Claude is busy** with another context's turn reaches Claude with its
  note, but the rows of the running turn stay where they were.
- **Contexts last for the session.** `/clear` empties them. A resumed session starts with none
  and draws earlier posts as plain tool calls until you run `/contexts`; then they show as
  pointer lines in Main chat, and the rest of the earlier traffic stays in Main chat.
- **Claude routes the traffic.** It may sometimes answer in Main chat what belongs in a context,
  or the other way round.

## Observed behaviour it relies on

These are what Claude Code 2.1.289 does, not documented API. If an update changes one, that
part degrades as described and the rest keeps working:

- **The folded thinking line's id.** A thinking line is drawn as a tool group with no calls,
  whose id is `collapsed-<id of its assistant row>`. The mod reads its context from that id.
  If the shape changes, a context's thinking lines show in Main chat instead.
- **The task id in a notification's text.** When a task notification arrives, the mod reads the
  id of the call that started the task from the `<tool-use-id>` in its text, to put Claude's
  reply in that context and to tell Claude which context it is about. If the format changes,
  Claude's reply to the notification lands in Main chat. The notification row itself uses the
  documented `task.toolUseId` and keeps its context.
- **A turn's duration line is the `turn_duration` notice kept after the turn ends.** The mod
  ties the first notice of that name after a turn's `turn.complete` to the turn, and the line
  draws under that notice's id. If the name or the order changes, a context turn's duration
  line shows in Main chat.

## Tests

From the repository root:

```bash
claude plugin validate --strict ./context-switcher
claude plugin test ./context-switcher
```

The tests drive the mod's hooks with no model calls: the command and its fullscreen check,
staying on across a reload, the tool and the sidebar's counts, the rows each view draws
(prompts, replies, tool rows and groups, thinking and duration lines, notifications, subagent
posts), that every row draws in full in exactly one view, prompt notes and Main chat's unread
count. Closing the sidebar (which the test kit cannot
raise) and `/clear` (which it cannot reset) are checked by hand.
