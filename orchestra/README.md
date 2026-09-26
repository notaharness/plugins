# Orchestra

Orchestra lets one coding agent hand tasks to other coding agents and supervise them.

- The **orchestrator** is the agent you talk to. It splits your work into branch-sized
  tasks, starts a player for each, and relays their questions to you.
- Each **player** is a coding agent in its own tmux session, working on its own branch in a
  git worktree. It sends progress, questions and results back to the orchestrator.
- A **dir player** works in an existing directory instead, with no branch or worktree of its
  own: a reviewer reading a checkout, or work outside any repository.

You can attach to any player's tmux session to watch it or talk to it directly. The
orchestrator can be Claude Code or Codex. Players can be Claude Code, Codex, Gemini, Copilot
or OpenCode. With [beam](https://github.com/notaharness/beam), players can also run on your
other machines.

## Install

### Requirements

- Linux or macOS with Bash, Git, coreutils (`realpath`, `sha256sum`) and `ps`/`pgrep`.
  Tested on Linux.
- tmux 3.x (tested with 3.4).
- An authenticated `claude` or `codex` CLI for each kind of player you want to run. Codex
  players need Codex CLI 0.157 or later for the default model, `gpt-6-sol`.
- For a Claude Code orchestrator: Claude Code 2.1.224 or later, and `socat` or OpenBSD `nc`
  (with `-N -U`), which carry reports to its inbox. Without them, run the orchestrator inside
  tmux and have it spawn players with `--orchestrator tmux:<session>`.
- `python3`, to pre-trust Claude players' worktrees.
- util-linux `script`, to detect which CLI a player used when resuming it.

### Claude Code

```text
/plugin marketplace add notaharness/plugins
/plugin install orchestra@notaharness
```

This adds `/orchestra:orchestrator` and `/orchestra:player`.

### Codex and other agents

Install both skills with [Vercel's skills CLI](https://github.com/vercel-labs/skills)
(needs Node.js):

```bash
npx skills@latest add notaharness/plugins --global --agent codex --skill orchestrator player
```

Leave out `--agent codex` to choose agents from a list. Install globally: players start in
fresh worktrees, where project-level skills are not installed. Start a new session
afterwards; Codex invokes the skills as `$orchestrator` and `$player`.

Update skills installed this way with:

```bash
npx skills@latest update --global
```

Use one route per agent. If you install the skills for Claude Code through the skills CLI
rather than the plugin, they are called `/orchestrator` and `/player`; set
`ORCHESTRA_CLAUDE_SKILL=/player` in the orchestrator's environment so Claude players are
started and adopted with the right name.

## Use

Give the orchestrator a task in plain language:

```text
/orchestra:orchestrator Add search to this repo. Give the task to an Opus player and have it open a draft PR.
/orchestra:orchestrator Show me the status of my players.
```

In Codex, use `$orchestrator` with the same text. Keep each task to one branch and one PR;
one orchestrator can run players across several repositories.

When a player starts, the orchestrator is told its worktree and tmux session name. To watch
a player yourself:

```bash
tmux attach -t '=SESSION_NAME'
```

Detach with **Ctrl+B, then D**. Ctrl+C interrupts the player's agent.

Worktrees live in the repository's `.claude/worktrees/` directory, named after the branch
with `/` replaced by `-`: branch `feature/search` gets `.claude/worktrees/feature-search`.
A new worktree gets a copy of the main checkout's `node_modules` (reflinked where the
filesystem allows). Stopping a player leaves its branch and worktree in place; remove them
with `git worktree remove` once the PR is merged.

Keep a dir player out of a directory another player is changing.

## Communication and attention

The orchestrator is instructed to track what you've acknowledged, ask one decision at a
time, and keep the relevant state and recommendation beside each decision so you can answer
without rereading the thread. Ask for status to see open items and a roster of the players.

The proposed terminal style puts the answer or decision first, uses short paragraphs and
selective lists, and keeps recovery details after the decision context. [Read the
output-style research and controlled comparisons](docs/terminal-style.md) for sources,
examples and limitations; no local output-style installation is required.

The guidance draws on the research below. A small live benchmark and targeted follow-up are
described in [PR #8](https://github.com/notaharness/plugins/pull/8) and
[PR #9](https://github.com/notaharness/plugins/pull/9); they do not establish a proven effect
on attention or developer outcomes.

- **Working memory:** [Cowan (2001)](https://pubmed.ncbi.nlm.nih.gov/11515286/) on storage
  capacity; [Alderson et al. (2013)](https://pubmed.ncbi.nlm.nih.gov/23421528/) on
  working-memory load in adults with ADHD.
- **Planning and remembering:** [Fuermaier et al.
  (2013)](https://doi.org/10.1371/journal.pone.0058338) on distinct components of
  prospective memory in adults with ADHD.
- **Interruption costs:** [Mark, Gudith and Klocke
  (2008)](https://doi.org/10.1145/1357054.1357072), *The Cost of Interrupted Work: More
  Speed and Stress*.
- **Notification timing:** [Iqbal and Bailey
  (2008)](https://doi.org/10.1145/1357054.1357070), *Effects of Intelligent Notification
  Management on Users and Their Tasks*.
- **Returning to a task:** [Altmann and Trafton
  (2007)](https://pubmed.ncbi.nlm.nih.gov/18229478/) on recovery after interruptions.
- **External reminders:** [Gilbert (2015)](https://doi.org/10.1080/17470218.2014.972963) on
  offloading delayed intentions.
- **Shared initiative:** [Horvitz (1999)](https://www.erichorvitz.com/chi99horvitz.pdf) on
  uncertainty, timing and human control; [Amershi et al.
  (2019)](https://www.microsoft.com/en-us/research/articles/guidelines-for-human-ai-interaction-eighteen-best-practices-for-human-centered-ai-design/)
  on context-sensitive human–AI interaction.
- **Appropriate reliance:** [Buçinca et al. (2021)](https://arxiv.org/abs/2102.09692) on
  reducing over-reliance and the costs of added decision friction.

The skill targets capable frontier orchestrators: concise goals and reasons, with exact
constraints for authorization, routing and recovery. Its instruction structure draws on
[OpenAI’s GPT-6 skill
guidance](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)
and [Anthropic’s Fable/Mythos
guidance](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5);
their recommendations still need checking on the model and workload in use.

## Commands

The orchestrator runs these scripts from `skills/orchestrator/scripts/`; you can run them
yourself too. Every script except `relay.sh` accepts `--repo PATH` to act on another
repository and `--machine NAME` to act on another machine.

| Command | What it does |
| --- | --- |
| `sessions.sh` | List players in this repository (every player when run outside one): session, branch, state, agent, reporting target and last report. `--all` lists every repository, `--json` gives structured output, `--sample N` compares activity over time. |
| `spawn.sh --branch B --prompt "Task"` | Create a branch and worktree, open a tmux session and start a player. `--prompt-file FILE` reads the task from a file. |
| `spawn.sh --dir PATH --prompt "Task"` | Start a dir player in an existing directory. Takes no `--branch`, `--repo` or `--from`, and writes nothing there. |
| `spawn.sh --branch B --resume` | Restart a stopped player in its existing worktree (`--dir PATH --resume` for a dir player). |
| `screen.sh SESSION --history 200` | Print a player's screen and scrollback. `--lines N` limits the output. |
| `send.sh SESSION "Message"` | Send a player a message. `--raw` sends text as-is (a menu choice), `--key` a keypress, `--type` typed keystrokes (a slash command). |
| `adopt.sh SESSION ["New task"]` | Make the current agent the orchestrator of a running, idle player. |
| `kill.sh SESSION` | Stop a player's tmux session. Its branch and worktree remain. |
| `relay.sh` | Receive reports from players on other machines. See [Other machines](#other-machines). |

`spawn.sh` options:

- `--agent claude|codex|gemini|copilot|opencode` picks the player's CLI (default `claude`).
  `--cmd "COMMAND"` runs any other CLI instead, which receives the task in `$PROMPT`.
- New branches start from the freshly fetched default branch; `--from REF` picks another
  starting point.
- `--dry-run` shows what a spawn would do without fetching or writing.
- `--no-node-modules` skips copying `node_modules` into the worktree.

`SESSION` is the branch the player's worktree has checked out, or its tmux session name, as
shown by `sessions.sh`. A player stays tied to its worktree when it switches branch. A dir
player has no branch, so use its session name (`<directory>-dir`). A repository's
`sessions.sh` lists a dir player only when its directory is that repository's main checkout;
use `--all` to see the rest.

### Resume a player

```bash
spawn.sh --repo PATH --branch feature/search --resume
spawn.sh --repo PATH --branch feature/search --resume --prompt "Next, add keyboard navigation."
```

The player continues its previous conversation in the same worktree, with a note that it was
restarted. `--branch` is the branch the player was spawned for (the `BRANCH` column of
`sessions.sh`), not the one its checkout has now. `--prompt` or `--prompt-file` gives it a new message; the original task is not sent
again. It uses the CLI the player last ran unless you pass `--agent`. When that is unknown
because the session is gone, it tries Claude, and a Codex conversation only when Claude has
none to continue; a dir player needs `--agent codex` to resume a Codex conversation. If
resuming fails, the pane stays open with the error.

### Hand off a running player

`adopt.sh SESSION` works only on a player idle at its prompt. The player keeps its process,
conversation and worktree. With no task text, it sends a summary of its task, what is done,
what is left and any open questions (a finished player repeats its final report). With task
text, it takes on that task.

## Models and effort

| Player | Default model | Default effort |
| --- | --- | --- |
| Claude Code | `opus` | `high` |
| Claude Code with another model, such as `fable` | the model you pass | `high` |
| Codex | `gpt-6-sol` | `medium` |
| Codex with another `gpt-6-*` model, such as `gpt-6-astra` | the model you pass | `medium` |
| Codex with another model | the model you pass | `high` |

`opus` is the recommended Claude model; `fable` is available as an alternative.

Override with `--model` and `--effort` (`low`, `medium`, `high`, `xhigh` or `max`; the CLI
decides which combinations it accepts). `--permission-mode` applies to Claude Code only.

On resume, model and effort are passed only when you give them. Codex then uses its configured
default. Pass them explicitly when resuming a Claude player that needs a particular model.

## Other machines

With [beam](https://github.com/notaharness/beam) pairing your machines, `--machine NAME` runs
a script against another machine, where `NAME` is a beam peer label, alias or peer id. It
defaults to `$ORCHESTRA_MACHINE`, else this machine; `local` also means this machine. Set
`$ORCHESTRA_BEAM` if `beam` is not on `PATH`.

- Install the plugin on the other machine too, at the same path under `$HOME`.
- A remote `--repo` or `--dir` must be absolute or start with `~/`.
- Session names are unique per machine, so with several machines you may need `--machine`
  alongside a name.
- `sessions.sh --all` also lists every paired machine's players, with a MACHINE column.

A remote player sends its reports through beam. On the orchestrator's machine, `relay.sh`
receives them and delivers them to the orchestrator:

```bash
skills/orchestrator/scripts/relay.sh                          # deliver to the session that started it
skills/orchestrator/scripts/relay.sh --allow tmux:planning    # deliver to tmux session "planning" instead
```

With no `--allow`, `relay.sh` delivers only to the Claude Code session or tmux pane it runs
in. Each `--allow` names a target it may deliver to and replaces that default, so include your
own session if you still want reports there. It needs `socat` or an `nc` with `-U`. Restart it
after restarting beam; beam keeps any reports that arrive in between. Do not run it alongside
N10 Desktop, which does this itself.

## Reporting

Players report with one of four kinds:

| Kind | Meaning |
| --- | --- |
| `PROGRESS` | A meaningful milestone. |
| `QUESTION` | A decision that needs input. |
| `BLOCKED` | Something prevents further progress. |
| `DONE` | The task is complete, with results and any limitations. |

A report reaches a Claude Code orchestrator through its inbox socket, a Codex orchestrator as
its next queued turn, and anything else by being pasted into its tmux pane. `spawn.sh` and
`adopt.sh` detect the orchestrator from the agent running them, or take it from
`--orchestrator claude:<session-id>|codex:<thread-id>|tmux:<session>`.

An accepted report has not necessarily been read. A failed report is not retried: if a player
looks finished but nothing arrived, ask the orchestrator to check its screen.

Orchestra stores each player's state in `@orchestra-*` tmux session options; the full list is
in [the orchestrator skill](skills/orchestrator/SKILL.md).

## Recover after a crash

A power loss, reboot or dead tmux server removes every player session and its tags, and
Orchestra keeps no other record of its players. Resume the orchestrator's conversation
instead: its history holds each spawn command, and the orchestrator skill brings each player
back with `spawn.sh --resume` under the account it was spawned with. Each player resumes from
its last saved message with its worktree's files and commits intact; steps that were in
progress, background subagents and scheduled check-ins are lost. A Claude dir player cannot be
resumed after a crash; spawn it again.

## Limitations

- A local player gets the orchestrator's `PATH`, `HOME`, `CLAUDE_CONFIG_DIR` and `CODEX_HOME`;
  other variables, such as `ANTHROPIC_API_KEY`, come from the tmux server's environment. A
  player on another machine gets that machine's tmux server environment.
- A player's agent runs with `TMUX` unset and `TMUX_TMPDIR` pointed at a scratch directory,
  so its own tmux commands do not reach your sessions. This is not a security boundary; host
  permissions and sandboxes still apply.
- Claude players start without MCP servers.
- A remote spawn does not check that the agent CLI exists on the other machine; a missing CLI
  fails at launch.
- A report that `relay.sh` refuses is offered again on every retry. Clear it from beam's
  refused list (`beam msg queue --which refused`), or restart `relay.sh` with the `--allow` it
  needs.
- Codex resume cannot find conversations whose worktree path needs JSON escaping.
- A Claude dir player stopped with `kill.sh` cannot be resumed, and a Codex dir player may
  resume another agent's conversation in the same directory.
- OpenCode resume is untested; Gemini and Copilot cannot resume.
- Detecting a player's CLI on resume leaves a `script` transcript in `/tmp` for the life of
  the Claude session.
- Any non-shell program in a player's pane, such as an editor or pager, counts as an agent.
