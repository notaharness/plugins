# Conversations

A busy Claude Code session interleaves everything in one chat: background commands finishing,
subagents reporting, CI results, messages from other sessions. Claude keeps up with all of it;
your attention is the limit. Conversations lets one session hold several smaller conversations,
so you read one topic at a time and switch when you choose.

It is still one session and one Claude. Claude sees everything and can post to any conversation
at any time. Only your view of the transcript changes.

## Requirements

- Claude Code 2.1.289 or later, in a terminal.
- [Fullscreen rendering](https://code.claude.com/docs/en/fullscreen). Turn it on with
  `/tui fullscreen`, or start Claude Code with `CLAUDE_CODE_NO_FLICKER=1`. The classic renderer
  keeps the transcript in the terminal's scrollback, which a mod cannot redraw, so
  `/conversations` refuses to start there and says how to switch.
- A terminal at least 110 columns wide shows the sidebar beside the transcript; a narrower one
  shows it above the prompt.

The Desktop app, the VS Code extension and the web are not supported.

## Install

```text
/plugin marketplace add notaharness/plugins
/plugin install conversations@notaharness
```

To try a checkout instead, start Claude Code with the plugin directory:

```bash
CLAUDE_CODE_NO_FLICKER=1 claude --plugin-dir ./conversations
```

## Use

Run `/conversations`. Until you do, the plugin does nothing: Claude gets no extra tool and no
extra instructions. Once it is on, it stays on for the rest of the session.

- **The sidebar** lists your conversations under `Conversations`: Main and each conversation
  Claude has started, with a count of unread posts and a `needs you` mark when a post asks for
  your input. Click one, or press `ctrl+x tab` and then the number shown beside it, to select
  it. With the sidebar holding the keys, the arrow keys move through the list. `Esc` returns the
  keys to the prompt.
- **Archived conversations** sit in a collapsed `Archived` section at the bottom of the sidebar.
  Claude archives a conversation when it wraps up (resolved, merged, answered, abandoned), which
  clears its `needs you` mark. Posts you haven't read stay counted, on the section and on the
  entry. Moving down with the arrow keys past the last active conversation opens the section,
  and moving back up folds it; a click on its header opens it too. An archived conversation
  still opens and reads like any other. You never manage conversations yourself.
- **Main** is your focus conversation. Traffic for another conversation shows there as one dim
  line per post, such as `→ CI flakes: Run 4812 failed on linux`.
- **A conversation** turns the transcript into that thread: Claude's posts read as its messages,
  along with your prompts there and the tool calls and notifications that belong to it.
  Everything else is hidden.
- **Write in a conversation** by selecting it and typing as usual. Claude answers there. Typing
  in an archived conversation brings it back to the active ones, as does a new post from Claude.
- **Close the sidebar** with its close mark, or with `ctrl+x x` while the sidebar has the keys
  (after `ctrl+x tab`). The transcript returns to Main. While the sidebar is closed and a
  conversation has unread posts, a status line under the prompt says so, such as
  `1 conversation needs you, 3 unread posts (/conversations to open the sidebar)`. Run
  `/conversations` to bring the sidebar back.

Claude names conversations itself, after the topic. Ask it to move something into its own
conversation ("track the CI run in its own conversation") or let it route updates on its own.
When Claude starts a new conversation while answering a prompt you typed in Main, your view
moves into it (the first one, if the turn starts several). It does not move when you are
reading another conversation, or for conversations started by turns you didn't type: task
notifications, background agents, messages from other sessions. Those show as unread.

## How it works

- `/conversations` registers one tool, `mcp__conversations__post` (`conversation`, `text`,
  `needsUser`, `archive`), listed up front rather than behind tool search, and adds a short
  section to the system prompt that explains conversations to Claude, asks it to treat your
  attention as a resource (one topic at a time, a conversation need not be tied to one task),
  and asks it to archive each one as soon as it wraps up. Both stay out of the session until you run the command.
- A prompt you type in a conversation carries a note, hidden from the transcript, that tells
  Claude which conversation it came from.
- Rows of a conversation's turn (Claude's text, its tool calls, the turn's duration line) belong
  to that conversation. A background task's notification belongs to the conversation of the
  call that started it; anything that cannot be traced belongs to Main.
- Every row draws in full in exactly one view, its conversation's or Main's, and as nothing in
  the others, so it takes no lines there. Nothing is hidden everywhere: a closing line Claude
  writes after a post shows in the turn's conversation, even when it repeats the post.
- A subagent's rows live in its own transcript, so its posts draw with the main loop's Agent
  call that started it: as Claude's message in the post's conversation, and as a pointer line in
  Main. A subagent started by a subagent is traced up through the Agent call that started it,
  recorded as it starts, so its posts find the first call even after the session's list of
  agents has dropped its parent. A subagent's completion notification belongs to that call's
  conversation too, by the agent id it names.
- The Archived section opens and folds on the sidebar's `ui.focus` event: the ring landing on
  its header or one of its conversations opens it, the ring landing on Main or an active one
  folds it.

## Limitations

- **Fullscreen only**, terminal only.
- **No off switch.** A mod cannot remove a tool it has registered, so Conversations stays on
  until the session ends. Closing the sidebar returns you to Main; start a new session to go
  without it.
- **No unfiltered view.** Main collapses other conversations' traffic to pointer lines, and the
  ctrl+o transcript shows the selected view too, except Claude's thinking, which shows there in
  every view.
- **Closing lines can repeat a post.** After Claude posts in a conversation, it often adds a
  short line saying so (Claude Code nudges a turn that ends on a tool call into writing one). It
  shows in that conversation under the post.
- **A subagent's posts draw where its Agent call is**, not where in time they were made, and
  only once the call has said which subagent it started (at once for a background agent, when
  it finishes for a foreground one).
- **Some rows show in every view**: slash-command echo lines (`❯ /clear`), notices and other rows
  Claude Code draws without a hook a mod can reach.
- **The sticky prompt header** at the top of a scrolled transcript can show a prompt from
  another conversation.
- **Work started from Main stays in Main.** Background work Claude starts in a Main turn
  notifies Main; Claude then posts the result to a conversation if it belongs to one.
- **A prompt typed while Claude is busy** with another conversation's turn reaches Claude with
  its note, but the rows of the running turn stay where they were.
- **Conversations last for the session.** `/clear` empties them. A resumed session starts with
  none and draws earlier posts as plain tool calls until you run `/conversations`; then they
  show as pointer lines in Main, and the rest of the earlier traffic stays in Main.
- **Claude routes the traffic.** It may sometimes answer in Main what belongs in another
  conversation, or the other way round.

## Observed behaviour it relies on

These are what Claude Code 2.1.289 does, not documented API. If an update changes one, that
part degrades as described and the rest keeps working:

- **The folded thinking line's id.** A thinking line is drawn as a tool group with no calls,
  whose id is `collapsed-<id of its assistant row>`. The mod reads its conversation from that
  id. If the shape changes, a conversation's thinking lines show in Main instead.
- **The task ids in a notification's text.** When a task notification arrives, the mod reads the
  id of the call that started the task from the `<tool-use-id>` in its text, or the subagent's
  id from its `<task-id>`, to put Claude's reply in that conversation and to tell Claude which
  conversation it is about. If the format changes, Claude's reply to the notification lands in
  Main. The notification row itself uses the documented `task.toolUseId` and `task.id` and
  keeps its conversation.
- **A turn's duration line is the `turn_duration` notice kept after the turn ends.** The mod
  ties the first notice of that name after a turn's `turn.complete` to the turn, and the line
  draws under that notice's id. If the name or the order changes, a conversation turn's
  duration line shows in Main.

## Tests

From the repository root:

```bash
claude plugin validate --strict ./conversations
claude plugin test ./conversations
```

The tests drive the mod's hooks with no model calls: the command and its fullscreen check,
staying on across a reload, the tool and the sidebar's counts, the rows each view draws
(prompts, replies, tool rows and groups, thinking and duration lines, notifications, subagent
posts, nested ones included), that every row draws in full in exactly one view, prompt notes,
Main's unread count, moving the view into a conversation started from a Main prompt (and not
otherwise), the Archived section (opening and folding with the focus ring, selecting,
and bringing a conversation back by typing or a new post) and the status line. Closing the
sidebar (which the test kit cannot raise) and `/clear` (which it cannot reset) are checked by
hand.
