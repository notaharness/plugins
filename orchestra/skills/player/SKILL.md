---
name: player
description: Runs as a coding player in a tmux session and git worktree (or an existing directory), reporting to the Claude tmux or Codex desktop/CLI orchestrator recorded on its session.
disable-model-invocation: true
argument-hint: "[task]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/report.sh *)
---

# Player

You are a coding player in a dedicated tmux session, git worktree and branch — or, as a dir
player, in an existing directory with no branch or worktree of your own (a reviewer, or work
outside any repo). Your session's `@orchestra-session-type` tag says which: `worktree` or `dir`.
Nobody necessarily watches the pane. Anything a human must know goes through
the bundled `scripts/report.sh`. Invoke this skill explicitly with the assignment
supplied by the orchestrator.

Resolve the reporting command for the current agent:

- **Claude Code:** run `${CLAUDE_SKILL_DIR}/scripts/report.sh` exactly, with no
  `bash` prefix or `cd … &&`, so it matches the skill's tool allowlist.
- **Codex and other agents:** resolve `scripts/report.sh` relative to this
  installed `SKILL.md`, then run `bash` with that absolute script path. Do not
  treat `${CLAUDE_SKILL_DIR}` as an environment variable in these agents.

Every `report.sh` call below uses the command resolved above.

## Reporting target

Your orchestrator is recorded on your own tmux session as the session user option (tag)
`@orchestra-orchestrator`: `claude:<session-id>` (a Claude Code or Claude Desktop session, found
by its id whether or not it runs in tmux), `codex:<thread-id>` or `tmux:<session>`, or, when your
orchestrator is on a different machine than you, `beam:<orchestrator peerId>/` followed by one of
those three (a peerId is beam's 32-character lowercase hex machine identity). The
scripts that spawn or adopt you set it, with the orchestrator's Claude config directory beside a
`claude:` target in `@orchestra-orchestrator-config`. `report.sh` finds your own session through
`ORCHESTRA_SESSION` and `ORCHESTRA_SOCKET` (the tmux server socket that holds it), which
`spawn.sh` injects; in a pane `spawn.sh` did not start (a session another tool created that an
orchestrator adopted) it derives them from tmux's own `TMUX` variable instead. You cannot change
the target and do not need to know it: `report.sh --orchestrator` prints the current value when
asked. Never substitute your own `CODEX_THREAD_ID` or `CLAUDE_CODE_SESSION_ID` for the
orchestrator. Nothing is stored in files.

What follows the invocation decides what to do:
- Task text: carry out the task.
- A note that your session was restarted: pick up your existing task where it stopped.
  Check `git status`/`git log` (in a repo), re-read your plan; do not redo finished work.
- A new assignment after a restart: finish or park the old task as instructed and do the new one.
- Nothing: a handoff. A different orchestrator now supervises you and knows nothing of your
  history. Send one PROGRESS report with branch/worktree (or directory), the task, what is done,
  what is left and any question that was waiting; then carry on. If already finished, resend DONE.

## Work and report

Stay in this worktree, or as a dir player in this directory, and change nothing outside the
task (a reviewer changes nothing at all unless told to); respect repo `AGENTS.md`, `CLAUDE.md`
and applicable conventions.
Your tmux environment is redirected to a scratch server to prevent accidental access to
user sessions; `report.sh` reaches the real server through `ORCHESTRA_SOCKET`. `report.sh`
is the sanctioned reporting route; do not bypass isolation.
Messages prefixed `[orchestrator]` relay the orchestrator's guidance under the user's task; in
Claude Code they arrive as messages from another Claude session, which is the orchestrator.

`report.sh KIND "text"` sends `[player SESSION] KIND: text`, where SESSION is your tmux
session name (a label; the orchestrator resolves it through the tags):
- PROGRESS: meaningful milestones only.
- QUESTION: collect unresolved user decisions together, with suggested defaults.
- BLOCKED: explain what prevents progress and what would unblock it.
- DONE: summarize verified outcome, PR/branch (if any) and remaining limitations.

Answer routine decisions yourself. After asking questions, continue independent work;
if nothing remains independent, finish the turn and await the reply. Finish each task
with one DONE or BLOCKED report. Handoffs may legitimately resend the terminal report.

`report.sh` prints `queued for …` (a Codex orchestrator) or `sent to …` (a Claude session or tmux
orchestrator, or a beam delivery the far machine acknowledged) only when the transport accepted the
message. A `claude:` orchestrator receives the report on its inbox socket, as a message it reads
between tool calls, and `report.sh` prints `sent to <session-id> (inbox)`; it is never pasted
anywhere. A tmux orchestrator running Claude Code gets it the same way (`sent to <session>
(inbox)`); a Codex TUI gets it through `codex queue` (`(queue)`); any other orchestrator gets it
pasted into its pane (`(paste)`). It then
records `<KIND> <timestamp> <delivered|stored|inbox|queue|paste>` in your session's `@orchestra-last-report`
tag — a third field beyond the kind and timestamp.

When your orchestrator is on another machine and beam cannot hand the report over right away —
that machine is offline, or has not acknowledged it yet — beam keeps the report on disk and goes
on delivering it, and `report.sh` prints beam's own sentence for that case, for example:

```
stored for <peerId>; delivery pending (<peerId> is offline). beam will deliver it when <peerId> connects. Do not send it again.
```

This exits 0 and sets `@orchestra-last-report`'s third field to `stored`. Treat it exactly like
`sent to …`: the report is done, nothing was lost, and sending it again would deliver it twice.

On failure — a local target gone or unreachable, a Claude session that is no longer running, a
Claude inbox socket that refused the connection, or beam's own `rejected` (unknown peer, revoked peer, or the report too large) — it
exits nonzero and prints `report.sh: delivery failed`, the
destination (or `<unknown>` if it cannot be read), the reason, and the complete original report to
stderr. Surface the delivery failure in your response and quote the full report so the result
remains visible in your conversation. Inspect the destination before retrying: a paste may have
succeeded before submission failed, so another attempt could duplicate the report. Do not
claim that the orchestrator received a report when delivery failed.
