#!/usr/bin/env bash
# Create a git worktree + tmux session and start an agent in it, or resume a stopped one.
#
# Usage: spawn.sh --branch <name> (--prompt-file <f> | --prompt <text>)      fresh launch
#        spawn.sh --branch <name> --resume [--prompt <text> | --prompt-file <f>]
#        spawn.sh --dir <path> …              a dir player: no branch, no worktree (below)
#                 [--repo <path>]             the repo to spawn into; defaults to the
#                                             cwd's repo. Any path inside it will do.
#                 [--agent claude|codex|gemini|copilot|opencode]  (fresh default claude)
#                 [--effort low|medium|high|xhigh|max] (Claude/Codex)
#                 [--model M]                 Claude: opus; Codex: gpt-6-astra
#                 [--permission-mode MODE]    Claude only; otherwise CLI settings apply
#                 [--cmd "COMMAND"]           custom harness; receives $PROMPT
#                 [--from REF]                base for a new branch; default origin/HEAD
#                 [--orchestrator TARGET]     claude:<session-id>, codex:<thread-id> or
#                                             tmux:<session>; auto: current Claude session,
#                                             then current Codex ID, then current tmux
#                 [--machine NAME]            beam peer label or peerId to spawn the player on;
#                                             default $ORCHESTRA_MACHINE, else this machine. A
#                                             remote --repo or --dir must be absolute or start
#                                             with ~/.
#                 [--no-node-modules] [--dry-run]
# Fresh defaults: Claude opus/high (fable/high for --model fable), Codex gpt-6-astra/medium,
# other Codex models high. --dry-run resolves local refs without fetching or writing.
#
# --resume restarts the player's conversation in its existing worktree; the session may be
# a dead pane or gone entirely. The launcher adds a restart note; give --prompt for a new
# assignment. The original task is never replayed. Harness: --agent, else the session's
# @orchestra-agent tag, else Claude --continue and, only when Claude reports "No conversation
# found to continue", Codex (the newest recorded Codex conversation whose cwd is this
# worktree). Any other failure stops with a dead pane for inspection; nothing starts a fresh
# conversation silently. --model/--effort are applied on resume only when given; otherwise the
# CLI's restored/configured settings apply.
#
# --dir starts a dir player in an existing directory (a reviewer, or work outside any repo) instead
# of a worktree; it takes no --branch, --repo or --from and creates nothing on disk. It is a player
# in every other respect, tagged @orchestra-session-type dir with its directory (resolved) in
# @orchestra-repo and no @orchestra-branch, labelled <basename of the directory>-dir, and addressed
# by that session name everywhere; --dir <path> --resume finds it again by its directory (see
# _launch.sh for which conversation it continues).
#
# The task is the new CLI's initial prompt argument (see _launch.sh), never typed and never
# queued: Claude Code does not run a skill invocation posted to its inbox socket, and a Codex
# conversation has no thread to queue to before its first turn. Messages after that go through
# send.sh, which queues where the agent allows it. Claude players are pre-trusted for their
# worktree and started with --strict-mcp-config, so no startup dialog stops them.
#
# Naming (see _lib.sh): worktree at <main checkout>/.claude/worktrees/<branch with / → ->;
# the tmux session is a label, <repo basename>-<branch> with "/", "." and ":" replaced by "-"
# and a -2, -3, … suffix when any session already has that name. The name is chosen once and
# never parsed: the session is found again through its tags (repo + branch), so --resume works
# whatever the label. Worktrees always land under the MAIN checkout, even when spawn.sh is
# invoked from inside another worktree.
#
# Session state lives on the tmux session as user options (see _routing.sh for the names):
# @orchestra-spawner/-repo/-session-type/-branch (identity, written once at creation),
# @orchestra-orchestrator (reporting target, with @orchestra-orchestrator-config for a Claude
# session), @orchestra-agent (harness) and
# @orchestra-launching (placeholder marker), all set before anything else sees the session. The task body is
# loaded into the paste buffer orchestra-prompt-<session> from stdin and read by _launch.sh
# inside the pane, so prompt size is not bounded by tmux's ~16 KiB command limit and nothing
# is written to disk. The launcher prefixes it with the player invocation: $player for Codex,
# and for Claude the plugin-namespaced skill (/<plugin>:player), with ORCHESTRA_CLAUDE_SKILL=/player
# for a standalone Claude skill install. The pane's environment is the tmux server's, not this
# process's: a local player is given this process's PATH, HOME, CLAUDE_CONFIG_DIR and CODEX_HOME
# (the last two set or unset, so it runs on the orchestrator's Claude and Codex accounts)
# explicitly; anything else, ANTHROPIC_API_KEY included, is whatever the server started with. Only
# the known parent-session markers are removed from it (see _lib.sh). The agent runs with TMUX unset and TMUX_TMPDIR on a scratch directory, so
# tests it runs cannot reach the user's tmux; ORCHESTRA_SOCKET names the real server for
# the launcher and report.sh.
. "$(dirname "$(realpath "$0")")/_lib.sh"
AGENT=""; MODEL=""; EFFORT=""; PERM=""; CMD=""; FROM=""; LINK_NM=1; DRY=0; RESUME=0; BRANCH=""; DIR=""; PROMPT=""; PFILE=""; ORCH=""
while [ $# -gt 0 ]; do case "$1" in
  --branch) BRANCH="$2"; shift;; --dir) DIR="$2"; shift;; --prompt-file) PFILE="$2"; shift;; --prompt) PROMPT="$2"; shift;;
  --agent) AGENT="$2"; shift;; --model) MODEL="$2"; shift;; --effort) EFFORT="$2"; shift;; --permission-mode) PERM="$2"; shift;;
  --cmd) CMD="$2"; shift;; --from) FROM="$2"; shift;; --no-node-modules) LINK_NM=0;;
  --orchestrator) ORCH="$2"; shift;; --repo) ORCH_REPO="$2"; shift;; --machine) ORCH_MACHINE="$2"; shift;;
  --dry-run) DRY=1;; --resume) RESUME=1;; -h|--help) sed -n '2,70p' "$0"; exit 0;;
  *) echo "spawn.sh: unknown argument $1" >&2; exit 2;; esac; shift; done
if [ -n "$DIR" ]; then
  [ -z "$BRANCH$ORCH_REPO$FROM" ] || { echo "spawn.sh: --dir starts a player without a worktree; it takes no --branch, --repo or --from" >&2; exit 2; }
  is_local_machine || case "$DIR" in /*|"~/"*) ;; *) echo "spawn.sh: --dir must be an absolute path or start with ~/ when --machine is set (got '$DIR')" >&2; exit 2;; esac
  TYPE="$SESSION_TYPE_DIR"; LINK_NM=0
else
  [ -n "$BRANCH" ] || { echo "spawn.sh: --branch (or --dir) is required" >&2; exit 2; }
  git check-ref-format --branch "$BRANCH" >/dev/null || exit 2
  require_valid_repo_for_machine || exit 2
  in_repo || { echo "spawn.sh: ${ORCH_REPO:-$PWD} is not inside a git repo; pass --repo <path>" >&2; exit 1; }
  TYPE="$SESSION_TYPE_WORKTREE"
fi
if [ -n "$PFILE" ]; then PROMPT="$(cat "$PFILE")" || exit 1; fi
if [ -z "$PROMPT" ] && [ $RESUME = 0 ]; then echo "spawn.sh: task prompt is required (--prompt or --prompt-file)" >&2; exit 2; fi
# tmux itself is only ever invoked through tmux_on/beam_exec; on a remote machine this process
# never runs it directly, so only the local case needs tmux on this PATH.
is_local_machine && { command -v tmux >/dev/null || { echo "spawn.sh: tmux is not installed" >&2; exit 1; }; }
case "$AGENT" in ""|claude|codex|gemini|copilot|opencode) ;; *) echo "spawn.sh: unknown --agent $AGENT (use --cmd for other harnesses)" >&2; exit 2;; esac
if [ -n "$EFFORT" ]; then
  case "$EFFORT" in low|medium|high|xhigh|max) ;; *) echo "spawn.sh: invalid --effort: $EFFORT" >&2; exit 2;; esac
  case "${AGENT:-claude}" in claude|codex) ;; *) echo "spawn.sh: --effort only supports claude and codex" >&2; exit 2;; esac
fi

# Resolve before stripping parent identity from the player's environment. A remote player cannot
# reach this orchestrator by a bare tmux:/codex: target (that is only meaningful on this machine),
# so it is qualified with this machine's own peerId, learned from `beam status --json` run here
# (never through the executor: "who am I" is always a local question). An already-qualified
# --orchestrator (an explicit handoff to some other beam-qualified target) is left as given.
ORCH="$(resolve_orchestrator "$ORCH")" || exit 2
case "$ORCH" in
  beam:*) ;;
  *) is_local_machine || { own_peer="$(beam_own_peer_id)" || exit 1; ORCH="beam:$own_peer/$ORCH"; };;
esac
# The socket the player's session will live on. Locally this is $TMUX's socket (the orchestrator's
# own pane) or the default per-user path. $TMUX describes only this process's own binding, so it
# never applies to a remote machine, and neither does a path built here: the target is asked which
# server it uses (machine_socket, _routing.sh), and the answer — cached, so this is the only round
# trip it costs — is the same one send.sh, kill.sh, screen.sh, adopt.sh and sessions.sh resolve, so
# the session this creates is the session they find.
if is_local_machine; then
  ORCH_SOCK="$(default_orchestrator_socket)"
else
  machine_socket || { echo "spawn.sh: could not determine which tmux socket to use on $ORCH_MACHINE" >&2; exit 1; }
  ORCH_SOCK="$MACHINE_SOCKET"
fi
t() { tmux_on "$ORCH_SOCK" "$@"; }        # -u -S: reads are exact in any locale
tag() { tag_set "$ORCH_SOCK" "$name" "$@"; }

LAUNCHER="$(realpath "$ORCH_SCRIPTS/_launch.sh")"
# The launcher runs inside the pane, so on ORCH_MACHINE, where this machine's absolute path
# means nothing. Claude Code installs the plugin under ~/.claude/plugins/cache/..., so the target
# is asked for the same $HOME-relative path under its own $HOME, and the spawn stops before
# anything is created when it is not there: a pane that dies with "No such file or directory"
# would leave a worktree and a dead session for a cause only screen.sh shows. A failed exec is
# the transport's answer, not the filesystem's, and is reported as such.
if ! is_local_machine; then
  rel="${LAUNCHER#"$HOME"/}"
  [ "$rel" != "$LAUNCHER" ] || { echo "spawn.sh: $LAUNCHER is outside \$HOME, so it cannot be located on $ORCH_MACHINE" >&2; exit 1; }
  remote_launcher="$(r sh -c '[ -f "$HOME/$1" ] && printf %s "$HOME/$1"; exit 0' sh "$rel")" \
    || { echo "spawn.sh: could not ask $ORCH_MACHINE whether ~/$rel exists" >&2; exit 1; }
  [ -n "$remote_launcher" ] || { echo "spawn.sh: ~/$rel does not exist on $ORCH_MACHINE; install the orchestra plugin there at the same version as here" >&2; exit 1; }
  LAUNCHER="$remote_launcher"
fi
CLAUDE_INVOCATION="$(claude_player_invocation)"
# root is what @orchestra-repo holds and workdir where the pane runs: the main checkout and its
# worktree, or for a dir player its directory, both times (resolved on ORCH_MACHINE, which also
# proves it exists there; r's --cwd expands a remote "~/").
if [ -n "$DIR" ]; then
  root="$(r --cwd "$DIR" pwd -P)" && [ -n "$root" ] || { echo "spawn.sh: $DIR is not a directory on $(machine_label); nothing was created" >&2; exit 1; }
  workdir="$root"
else
  root="$(repo_root)"
  dir="$(worktree_dir_for_branch "$BRANCH")"; workdir="$root/$dir"
fi
# Existence of the worktree directory is a question for ORCH_MACHINE, not this one, and asking
# another machine has three answers rather than two: there, not there, or the machine did not
# answer. A failed exec is not a statement about its filesystem, so the probe reports what it
# found in its OUTPUT and keeps its exit status for the transport; reading that status as "not
# there" would tell the user there is nothing to resume about a worktree that exists, and send a
# fresh spawn down a create path that is about to fail for the same reason.
if is_local_machine; then dir_probe() { [ -d "$root/$dir" ] && printf yes || printf no; }
else dir_probe() { r sh -c '[ -d "$1" ] && printf yes || printf no' sh "$root/$dir"; }
fi
dir_exists() {
  local answer
  answer="$(dir_probe)" || { echo "spawn.sh: could not reach $(machine_label) to check whether the worktree $root/$dir is there; nothing was created" >&2; exit 1; }
  case "$answer" in
    yes) return 0;;
    no) return 1;;
    *) echo "spawn.sh: unexpected answer from $(machine_label) when checking for the worktree $root/$dir: $answer" >&2; exit 1;;
  esac
}

# Resolve first: the session for (repo, branch) is whatever carries those tags, under any name.
# What already exists: a dead pane (resumable), a live placeholder from a failed launch
# (reusable), a running player (refuse), or nothing (a name is chosen at creation).
EXISTING=none
if name="$(find_player_session "$root" "$BRANCH")"; then      # before TMUX is unset: the same server ORCH_SOCK names
  tt="$(tmux_target "$name")"
  if [ "$(t display-message -p -t "$tt" '#{pane_dead}')" = 1 ]; then EXISTING=dead
  elif [ "$(tag_get "$ORCH_SOCK" "$name" "$TAG_LAUNCHING")" = 1 ]; then EXISTING=placeholder
  else EXISTING=running; fi
fi
case "$EXISTING" in
  running) echo "spawn.sh: session already exists and is running: $name (kill.sh it first, or adopt.sh it)" >&2; exit 1;;
  dead) [ $RESUME = 1 ] || { echo "spawn.sh: $name has a dead player; use --resume, or kill.sh it for a fresh start" >&2; exit 1; };;
esac
if [ $RESUME = 1 ] && [ -z "$DIR" ]; then
  dir_exists || { echo "spawn.sh: nothing to resume: worktree $root/$dir does not exist on $(machine_label)" >&2; exit 1; }
fi

# New branches start from the repository's default branch (freshly fetched), never
# from whatever the invoking checkout happens to have as HEAD — the orchestrator
# often runs inside a feature worktree whose commits must not leak into the agent's
# branch. --from overrides for deliberate stacking. Resume never creates a branch.
if [ -z "$DIR" ] && [ -z "$FROM" ] && [ $RESUME = 0 ] && ! dir_exists; then
  FROM="$(default_branch_ref)"
  [ -n "$FROM" ] || { echo "spawn.sh: could not resolve the default branch; pass --from <ref>" >&2; exit 1; }
fi

# Harness and settings. Fresh launches fill in the presets; resumes pass only what was given.
MODE=fresh; [ $RESUME = 1 ] && MODE=resume
HARNESS="$AGENT"
if [ $RESUME = 1 ] && [ -z "$HARNESS" ]; then
  [ "$EXISTING" = none ] || HARNESS="$(tag_get "$ORCH_SOCK" "$name" "$TAG_AGENT")"
  case "$HARNESS" in claude|codex|gemini|copilot|opencode) ;; *) HARNESS=auto;; esac
fi
[ $RESUME = 1 ] || HARNESS="${HARNESS:-claude}"
if [ $RESUME = 0 ]; then
  case "$HARNESS" in
    claude) MODEL="${MODEL:-opus}"; EFFORT="${EFFORT:-high}";;
    codex)  MODEL="${MODEL:-gpt-6-astra}"; EFFORT="${EFFORT:-$(case "$MODEL" in gpt-6-astra) echo medium;; *) echo high;; esac)}";;
  esac
fi
[ -n "$CMD" ] && HARNESS=custom
# A dir player's Claude conversation is known only from its session's tag (see _launch.sh), so once
# the session is gone there is nothing to resume for Claude, or for auto, which is Claude there.
if [ -n "$DIR" ] && [ $RESUME = 1 ] && [ "$EXISTING" = none ]; then
  case "$HARNESS" in claude|auto) echo "spawn.sh: nothing to resume: no Claude conversation is recorded for a dir player in $root (kill.sh removes the record with its session); spawn it fresh, or pass --agent codex for a Codex player" >&2; exit 1;; esac
fi
# The harness has to be on PATH where the player will actually run. On this machine that is
# checkable now; on another one there is no cheap way to ask without a round trip for a check
# that respawn-pane will make anyway (a missing binary there fails loudly, just later, with a dead
# pane rather than this message) — so the check is skipped rather than answered from this
# machine's PATH, which would refuse a harness that is perfectly installed on the target.
if is_local_machine; then
  case "$HARNESS" in
    auto) command -v claude >/dev/null || command -v codex >/dev/null || { echo "spawn.sh: neither claude nor codex is on PATH" >&2; exit 1; };;
    custom) ;;
    *) command -v "$HARNESS" >/dev/null || { echo "spawn.sh: $HARNESS is not on PATH" >&2; exit 1; };;
  esac
fi

# Environment: the launcher runs under env(1) with the parent-session markers removed and
# tmux redirected to the scratch server. Nothing user-controlled enters this command string.
strip=(); for v in "${PARENT_SESSION_MARKERS[@]}"; do strip+=(-u "$v"); done
# A local player runs on this process's Claude and Codex accounts: each selector is passed below
# when set, and removed here when not, since the tmux server may have started with another value.
ACCOUNT_VARS=(CLAUDE_CONFIG_DIR CODEX_HOME)
if is_local_machine; then for v in "${ACCOUNT_VARS[@]}"; do [ -n "${!v:-}" ] || strip+=(-u "$v"); done; fi
guard="$(printf '%q ' env -u TMUX -u TMUX_PANE "${strip[@]}" "TMUX_TMPDIR=$AGENT_TMUX_TMPDIR")"
shell_cmd="${guard}$(printf '%q' bash) $(printf '%q' "$LAUNCHER")"

desc="$HARNESS"
case "$HARNESS" in
  auto) desc="claude --continue, then codex resume if Claude finds no conversation";;
  custom) desc="$CMD";;
  *) [ $RESUME = 1 ] && desc="$HARNESS (resume)"; [ -n "$MODEL" ] && desc="$desc model=$MODEL"; [ -n "$EFFORT" ] && desc="$desc effort=$EFFORT"; [ -n "$PERM" ] && desc="$desc permission-mode=$PERM";;
esac
[ "$EXISTING" = none ] && name="$(session_label "$root" "$TYPE" "$BRANCH")"     # preferred label; the free one is picked at creation
{ if [ -n "$DIR" ]; then printf 'dir       %s\n' "$workdir"
  else printf 'repo      %s\nbranch    %s%s\nworktree  %s\n' "$root" "$BRANCH" "${FROM:+ (from $FROM)}" "$workdir"; fi
  printf 'tmux      %s (%s)\nreports   %s\nmode      %s\ncommand   %s\nprompt    %s\n' \
    "$name" "$EXISTING" "$ORCH" "$MODE" "$desc" "$(printf %s "$PROMPT" | head -c 80 | tr '\n' ' ')"; } | cut -c1-200
[ $DRY = 1 ] && exit 0

# Everything below that is not a tmux call (git, the node_modules copy, the scratch tmux
# directory) has to land on ORCH_MACHINE, never on this one just because this process happens to
# run here. Local behaviour is unchanged (still a plain `cd` and bare commands against this
# machine's filesystem); a remote machine has no shell of its own to `cd` for, so `g` and `r`
# carry an explicit --cwd/-C instead (see _lib.sh; D12 — no "$(id -u)", no "~" left for a shell).
# A dir player has nothing to create: its directory is used as it is.
if [ -n "$DIR" ]; then :
elif is_local_machine; then
  cd "$root" || exit 1
  if dir_exists; then
    [ "$(git -C "$dir" rev-parse --show-toplevel)" = "$root/$dir" ] &&
    [ "$(git -C "$dir" branch --show-current)" = "$BRANCH" ] || {
      echo 'spawn.sh: existing worktree does not match requested branch' >&2; exit 1;
    }
  else
    # New branch from FROM; if the branch already exists, check it out instead.
    git worktree add -b "$BRANCH" "$dir" "$FROM" 2>/dev/null || git worktree add "$dir" "$BRANCH" || exit 1
  fi
else
  if dir_exists; then
    [ "$(r --cwd "$root/$dir" git rev-parse --show-toplevel)" = "$root/$dir" ] &&
    [ "$(r --cwd "$root/$dir" git branch --show-current)" = "$BRANCH" ] || {
      echo "spawn.sh: existing worktree does not match requested branch on $ORCH_MACHINE" >&2; exit 1;
    }
  else
    r --cwd "$root" git worktree add -b "$BRANCH" "$dir" "$FROM" 2>/dev/null ||
    r --cwd "$root" git worktree add "$dir" "$BRANCH" || { echo "spawn.sh: could not create the worktree on $ORCH_MACHINE" >&2; exit 1; }
  fi
fi
# Independent copy (reflinks when available); dependency writes cannot affect another checkout.
# npm keeps version-conflicting deps in per-workspace node_modules (apps/x/node_modules,
# libs/y/node_modules); missing those reads as a broken library, so copy them too. The whole
# find/cp loop travels as one remote command (positional $1, not interpolation, carries the
# worktree dir across) so it runs as a unit on ORCH_MACHINE instead of one round trip per file.
if [ $LINK_NM = 1 ]; then
  nm_script='[ -d node_modules ] || exit 0
dir="$1"
while IFS= read -r nm; do
  [ -e "$dir/$nm" ] || { mkdir -p "$dir/$(dirname "$nm")"; cp -a --reflink=auto "$nm" "$dir/$nm"; }
done < <(find . -maxdepth 4 -type d -name node_modules -not -path "./node_modules/*" -not -path "./.claude/*" -not -path "*/node_modules/*/node_modules" | sed "s#^\./##")'
  r --cwd "$root" bash -c "$nm_script" bash "$dir" || echo "spawn.sh: could not copy node_modules on $(machine_label)" >&2
fi
r mkdir -p "$AGENT_TMUX_TMPDIR" || { echo "spawn.sh: could not create $AGENT_TMUX_TMPDIR on $(machine_label)" >&2; exit 1; }

unset TMUX TMUX_PANE
# Created DETACHED under the first free label. 220x50 is only the initial size; whatever
# attaches later resizes the pane. If no server is running, this call starts one — with the
# markers stripped, so nothing of the orchestrator's own agent session leaks into every future
# pane. The identity tags go on before anything else can observe the session; they are written
# by the creator only, so a resume never rewrites them. The placeholder exists so remain-on-exit
# is already set when the real command starts and catches startup failures.
CREATED=0
if [ "$EXISTING" = none ]; then
  label="$name"
  while :; do
    name="$(free_session_name "$ORCH_SOCK" "$label")"
    # The call that starts the tmux SERVER (when none is running yet) if one is needed: local
    # behaviour is unchanged, marker-stripped exactly as before. On a remote machine there is no
    # inherited orchestrator session to leak markers from in the first place, but the same strip
    # travels with it for consistency; -u matches every other tmux_on call there.
    if is_local_machine; then
      env "${strip[@]}" tmux -S "$ORCH_SOCK" new-session -d -s "$name" -c "$workdir" -x 220 -y 50 && break
    else
      beam_exec "$ORCH_MACHINE" env "${strip[@]}" tmux -u -S "$ORCH_SOCK" new-session -d -s "$name" -c "$workdir" -x 220 -y 50 && break
    fi
    # Lost a race for the name (it exists now): probe again from the preferred label, so a second
    # lost race yields -3, not -2-2. Anything else is fatal.
    t has-session -t "=$name" 2>/dev/null || { echo "spawn.sh: tmux could not create session $name" >&2; exit 1; }
  done
  CREATED=1
  tt="$(tmux_target "$name")"
  tag "$TAG_SPAWNER" orchestra && tag "$TAG_REPO" "$root" && tag "$TAG_SESSION_TYPE" "$TYPE" && { [ -z "$BRANCH" ] || tag "$TAG_BRANCH" "$BRANCH"; } ||
    { t kill-session -t "=$name" 2>/dev/null; echo "spawn.sh: could not tag session $name; removed" >&2; exit 1; }
fi
buf="$(prompt_buffer_name "$name")"
tag "$TAG_LAUNCHING" 1 || exit 1
set_orchestrator "$ORCH_SOCK" "$name" "$ORCH" || exit 1
case "$HARNESS" in auto) ;; *) tag "$TAG_AGENT" "$HARNESS";; esac
t set-option -t "$tt" status off
t set-option -t "$tt" remain-on-exit on
# The task body, from stdin. tmux never creates an empty buffer, so a newline is appended
# (the launcher's command substitution drops it again); an empty body is then still a buffer.
printf '%s\n' "$PROMPT" | t load-buffer -b "$buf" - || { echo "spawn.sh: tmux could not load the task prompt into buffer $buf" >&2; exit 1; }
# PATH, HOME and the account selectors are this (the orchestrator's) process's own values, only
# right for a local pane; on a remote machine they would overwrite the correct, already-remote-native
# values the target's own tmux server captured when beam_exec started it above, with this machine's —
# the harness would then not be found on what is now the wrong PATH. Left unset there, the pane
# keeps what its own server gave it, same as every other user option this call does not name.
path_env=(); is_local_machine && path_env=(-e "PATH=$PATH" -e "HOME=$HOME")
if is_local_machine; then for v in "${ACCOUNT_VARS[@]}"; do [ -z "${!v:-}" ] || path_env+=(-e "$v=${!v}"); done; fi
if ! t respawn-pane -k -t "$tt" -c "$workdir" \
  "${path_env[@]}" \
  -e "ORCHESTRA_SESSION=$name" -e "ORCHESTRA_SOCKET=$ORCH_SOCK" \
  -e "ORCHESTRA_MODE=$MODE" -e "ORCHESTRA_HARNESS=$HARNESS" -e "ORCHESTRA_MODEL=$MODEL" -e "ORCHESTRA_EFFORT=$EFFORT" \
  -e "ORCHESTRA_PERMISSION_MODE=$PERM" -e "ORCHESTRA_COMMAND=$CMD" -e "ORCHESTRA_CLAUDE_SKILL=$CLAUDE_INVOCATION" \
  -- /bin/bash -c "$shell_cmd"; then
  t delete-buffer -b "$buf" 2>/dev/null
  if [ $CREATED = 1 ]; then
    t kill-session -t "=$name" 2>/dev/null
    echo "spawn.sh: tmux could not launch $name; placeholder session removed, worktree kept. Fix the cause and rerun." >&2
  else
    echo "spawn.sh: tmux could not launch $name; the previous pane is left as is. Fix the cause and rerun with --resume." >&2
  fi
  exit 1
fi
tag_unset "$ORCH_SOCK" "$name" "$TAG_LAUNCHING"
echo "started   $name"
