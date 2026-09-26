# Routing, session records and recovery

Read the relevant section when supervising remote players, diagnosing reporting, inspecting
session identity, or recovering a dead tmux server. Script paths follow [the main skill](../SKILL.md).

## Machines

The player-management scripts accept `--machine NAME`, defaulting to `$ORCHESTRA_MACHINE`, else this
machine. `NAME` is a beam peer label, alias or peerId — beam pairs machines and carries streams
and messages between them, the seam through which a player can run on a different machine than its orchestrator; the literal
`local` means this machine — with no beam installed, nothing here changes:
same commands, same tmux and git argv, same output. Naming a machine runs the same tmux/git
commands there instead,
through `beam exec <machine> -- <argv…>` (stdin forwarded, exit status propagated), resolving the
`beam` binary in order: `$ORCHESTRA_BEAM`, then `beam` on `PATH`. If neither resolves and a
machine was named, the script fails and names both — it never silently runs the command here,
which would create or act on a player on the wrong machine.

- `--repo` or `--dir` on a remote machine must be an absolute path or start with `~/`; a
  relative path is refused rather than resolved against this machine's working directory.
- The plugin must be installed on the remote machine at the same `$HOME`-relative path as here
  (Claude Code's plugin cache on both): the player's launcher runs in the pane, there. A spawn
  stops before creating anything when it is missing and says what to install.
- `sessions.sh --all` with no `--machine` lists the local machine plus, when beam resolves and
  peers are registered, every peer's players too — one listing call per machine. Rows then carry
  a MACHINE column (`--json`: a `"machine"` field); with no beam or no peers this is unchanged.
- A player spawned or adopted onto a remote machine reports back through beam: its
  `@orchestra-orchestrator` tag holds `beam:<this orchestrator's peerId>/claude:<session-id>` (or
  `codex:<thread-id>`, `tmux:<session>`) instead of the plain local form, learned from `beam status --json` run on
  this machine at spawn/adopt time. `report.sh`'s player-facing behavior for this is documented
  in the player `SKILL.md`.

### relay.sh

`relay.sh` (no `--machine`; it has none, and always acts on this, the orchestrator's, machine —
even if `$ORCHESTRA_MACHINE` is set in the environment it happens to inherit, which it ignores
unconditionally) subscribes to the `orchestra` topic on the local beam daemon's control socket and
delivers each arriving envelope to a local target, through the same delivery sequence and
`pane_owned_by_agent` check `report.sh` uses for a local report — a message that arrived from
another machine gets no more trust than one typed here. A `claude:` target is looked up in the
Claude session registry under `relay.sh`'s own `$CLAUDE_CONFIG_DIR` (else `~/.claude`). It needs
`socat` or an `nc` with `-U`.

Two things it does not do, on purpose:

- **It never trusts the envelope for *where* to deliver.** The envelope names a target, but the
  set of targets `relay.sh` may actually act on comes only from how it was started: with no
  argument, the single session it was started from — `claude:$CLAUDE_CODE_SESSION_ID` when a Claude
  session runs it (even inside tmux, where `$TMUX` can name someone else's session), else its tmux
  session; `--allow <target>` (repeatable) names others.
  An envelope naming anything outside that allowlist is refused, logged with the sending peer's
  id, and not delivered — any paired peer could otherwise paste arbitrary text into any tmux
  session on this machine that has an agent at the prompt, the user's own session included.
- **It only acks a message once delivery has actually succeeded.** An envelope the allowlist
  refuses, or whose delivery fails, is deferred with the reason instead: beam keeps it (`beam msg
  queue --which refused` lists it) and offers it again to the next subscription, which `relay.sh`
  makes itself 30 seconds after a failed delivery (`ORCHESTRA_RELAY_RETRY`). Acknowledging first
  and then failing to deliver would destroy a report the sender was already told had arrived.

Run it directly only when supervising remote players from a plain terminal with nothing
else already relaying that topic; N10 Desktop runs its own relay, so do not run this alongside it.

## Session tags

Everything the scripts know about a player is stored on its tmux session as session user
options (tags), never in files. Tags die with the session and are readable by anyone who can
reach the tmux server; Kirby reads and writes the same names. `sessions.sh` shows them;
`tmux show-options -qv -t '=SESSION:' @orchestra-agent` reads one directly.

| Tag | Value |
| --- | --- |
| `@orchestra-spawner` | `orchestra` or `kirby`: which program created the session |
| `@orchestra-repo` | absolute, symlink-resolved path of the main checkout; for a dir player, of its directory, which need not be a repo |
| `@orchestra-session-type` | `worktree` or `dir` for a player; `shell`/`agent` are Kirby terminal tabs, never players |
| `@orchestra-branch` | worktree players only: the branch the session was spawned under, unsanitized (`feature/x`) |
| `@orchestra-orchestrator` | reporting target: `claude:<session-id>`, `codex:<thread-id>` or `tmux:<session>`, or, when the orchestrator is on another machine, `beam:<orchestrator peerId>/` followed by one of those three |
| `@orchestra-orchestrator-config` | local `claude:` targets only: the orchestrator's Claude config directory, where `report.sh` looks the session up; unset for every other target |
| `@orchestra-agent` | harness in the pane: `claude`, `codex`, `gemini`, `copilot`, `opencode` or `custom` |
| `@orchestra-launching` | `1` only while the placeholder pane exists |
| `@orchestra-claude-session` | dir players running Claude: the id of the conversation the launcher started, which `--resume` continues |
| `@orchestra-last-report` | `<KIND> <ISO-8601 UTC> <delivered\|stored\|inbox\|queue\|paste>` of the last report a transport accepted — a third field appended to the older two-field form; a reader that splits on whitespace and takes only the first two still gets KIND and the timestamp |

The first four tags (three for a dir player, which has no branch) are a session's identity,
written once when it is created; the name is only a label. The pane environment carries
`ORCHESTRA_SESSION` (that label), `ORCHESTRA_SOCKET` (the tmux server socket that holds the
session; the player's own tmux environment is redirected to a scratch server), `ORCHESTRA_MODE`,
`ORCHESTRA_HARNESS`, `ORCHESTRA_MODEL`, `ORCHESTRA_EFFORT`, `ORCHESTRA_PERMISSION_MODE`,
`ORCHESTRA_COMMAND` and `ORCHESTRA_CLAUDE_SKILL`. The orchestrator target is not an environment variable: the player
reads the tag. Sessions created by earlier versions of these scripts are not recognised.

## Reporting destination

`spawn.sh` and `adopt.sh` resolve the destination automatically:
1. Explicit `--orchestrator claude:<session-id>`, `codex:<thread-id>` or `tmux:<session>`
   (already `beam:<peer>/…`-qualified, it is used exactly as given).
2. Current `CLAUDE_CODE_SESSION_ID`, as `claude:<session-id>`, whenever a Claude session runs the
   script — inside tmux too, where `$TMUX` may name some other session. It is accepted only when
   Claude's registry entry for `CLAUDE_PID` (`<config dir>/sessions/<pid>.json`) names that
   session, live and with an inbox socket; otherwise the script stops. This is how a Claude
   orchestrator outside tmux (a bare terminal, Claude Desktop) gets an address.
3. Current `CODEX_THREAD_ID` (or `CODEX_SESSION_ID`), only when this process is not a
   Claude session: a Claude orchestrator ignores inherited Codex IDs.
4. Current tmux session. Missing identity is an error; do not guess.

When the player is being spawned or adopted onto a `--machine` other than this one, that
resolved destination is then qualified with this machine's own peerId (from `beam status --json`,
run here) into `beam:<peerId>/<destination>`, since a bare `claude:`/`codex:`/`tmux:` target is
only meaningful on the machine that wrote it.

The destination is written to the player session's `@orchestra-orchestrator` tag at spawn
and adopt; a player cannot change it and never uses its own Codex ID as parent. A local `claude:`
destination also records this process's Claude config directory (`$CLAUDE_CONFIG_DIR`, else
`~/.claude`) in `@orchestra-orchestrator-config`, since the player may run with a different one.
A pane gets the tmux server's environment, not the orchestrator's, so a local player is given
this process's `CLAUDE_CONFIG_DIR` and `CODEX_HOME` explicitly (unset when they are unset) and runs
on the same Claude and Codex accounts; `ANTHROPIC_API_KEY` and the rest are whatever the tmux
server started with. Only
known parent-session markers (`CLAUDECODE`, `CLAUDE_CODE_*` session variables,
`CODEX_THREAD_ID`, …) are removed from it.

Player `report.sh` routes `claude:` to that session's inbox socket, found in Claude's registry
under `@orchestra-orchestrator-config` (else the player's `$CLAUDE_CONFIG_DIR`, else `~/.claude`)
and never pasted anywhere: a session that is not running, or a stale registry entry, is a delivery
failure. `codex:` goes via `codex queue`, `tmux:` via `ORCHESTRA_SOCKET` — to a Claude Code
session's inbox socket or a Codex TUI's queue when the pane has one, else as a paste — and
`beam:<peer>/…` via `beam msg send`. A Claude session in `bypassPermissions` mode holds inbox
messages for approval unless its settings set `"crossSessionInbound": "accept"`. It prints `queued for …` (Codex) or `sent to …` (Claude, tmux, or a
beam delivery the far side acknowledged) only when the transport accepted the message, and then
sets `@orchestra-last-report`. A beam send that comes back `stored` — the far machine is offline or
has not acknowledged it yet, and beam keeps delivering it — is also success and is worded to say so
plainly; see the player `SKILL.md` for the exact wording.
Otherwise it exits nonzero and prints `delivery failed`
with the destination, reason, and complete original report to stderr for the player to handle.
If a player looks finished but nothing arrived, inspect its pane with `screen.sh` and ask it
for the result. Inspect the destination before requesting a resend: a paste may have succeeded
before submission failed, so another attempt could duplicate the report.

## Recovering after a crash

A power loss, reboot or dead tmux server takes every player session and its tags with it. Nothing
else records the players: your own conversation is the record.

1. Resume your conversation (`claude --resume`, `codex resume`) on your own account.
2. From its history (the checkpoint rosters, the spawn commands), list how each player was spawned.
3. `sessions.sh` shows nothing, as expected: the tags died with the server, but the worktrees
   and conversations did not.
4. Resume each player with `spawn.sh --repo PATH --branch NAME --resume --agent AGENT` (or
   `--dir PATH`) under the account it was spawned with: set
   `CLAUDE_CONFIG_DIR` to its dir, or run with it unset (`env -u CLAUDE_CONFIG_DIR spawn.sh …`)
   for the default; `CODEX_HOME` likewise for a Codex player. An explicit
   `CLAUDE_CONFIG_DIR=~/.claude` is not the default: Claude reads `~/.claude/.claude.json` and
   opens its first-run screen. A resume that finds no conversation usually means the wrong config dir.
   Pass `--orchestrator tmux:<your session>` when your tmux session name changed, or when the
   player's config dir differs from yours (a `claude:` target is looked up under `spawn.sh`'s
   config dir). Pass `--model`/`--effort` again if they matter; resume adds none.
5. Check each player's screen (`screen.sh`) before sending anything.
6. Recreate scheduled check-ins; they lived in the dead session. Task files and helper scripts
   kept in `/tmp` may be gone after a reboot.

Resume restores the conversation up to its last saved message, and the worktree's files and
commits. It loses whatever was in flight: the step that was running, background subagents and
waits. A Claude dir player cannot be resumed after its session tag is lost: spawn it fresh with its task and
what it had already reported.
