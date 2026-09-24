#!/usr/bin/env bash
# Runs inside the player's pane (started by spawn.sh): reads the task body from the session's
# paste buffer and starts or resumes the harness. Options arrive through the environment, so no
# prompt text ever passes through a tmux or shell command line. Environment (all injected by
# spawn.sh through respawn-pane -e):
#
#   ORCHESTRA_SESSION      this player's tmux session name (a label; the session is identified
#                          by its tags, so the name is used as is and never parsed)
#   ORCHESTRA_SOCKET       socket of the tmux server holding it (the pane's own tmux environment
#                          is redirected to a scratch server, so every call passes -S)
#   ORCHESTRA_MODE         fresh | resume
#   ORCHESTRA_HARNESS      claude | codex | gemini | copilot | opencode | custom | auto (resume only)
#   ORCHESTRA_MODEL, ORCHESTRA_EFFORT, ORCHESTRA_PERMISSION_MODE   empty = not given
#   ORCHESTRA_COMMAND      custom harness command; receives the composed prompt as $PROMPT
#   ORCHESTRA_CLAUDE_SKILL Claude player invocation (defaults to /orchestra:player)
#
# The task body is the paste buffer orchestra-prompt-<session>, deleted once read. The harness
# that actually starts is recorded in the session's @orchestra-agent tag. The orchestrator target
# is not part of the prompt: report.sh reads @orchestra-orchestrator from the session.
#
# Resume never starts a fresh conversation: a harness that cannot find one exits nonzero and the
# pane stays for inspection (spawn.sh sets remain-on-exit). In auto mode Claude runs first under
# script(1) so its output can be checked for the exact "No conversation found to continue"
# diagnostic; only then is Codex tried, with the newest recorded conversation for this worktree.
#
# The task reaches a fresh harness as its initial-prompt argument, never typed: the CLI submits
# it itself. Nothing can queue it instead — Claude Code never runs a skill invocation posted to its
# inbox socket, and a Codex conversation has no thread to queue to before its first turn. A dialog
# at Claude's startup still swallows keys (the trust dialog's default answer is "No, exit"), so
# every Claude launch here passes --strict-mcp-config (no "new MCP server found" prompt for the
# repo's .mcp.json; players run without MCP servers) and pre-accepts the workspace-trust dialog
# for this worktree first (claude_trust_here).
#
# A dir player (@orchestra-session-type dir) may share its directory with other conversations, the
# orchestrator's own included, so Claude's "newest conversation here" is not necessarily its own: a
# fresh Claude launch picks the conversation id itself (--session-id), records it in
# @orchestra-claude-session, and a resume continues that id. Without the tag (kill.sh removed it
# with the session) a Claude resume refuses rather than guess; so does auto mode, which for a dir
# player means Claude only.
set -u
. "$(dirname "$(realpath "$0")")/_lib.sh"
mode="${ORCHESTRA_MODE:-fresh}"; harness="${ORCHESTRA_HARNESS:-claude}"
model="${ORCHESTRA_MODEL:-}"; effort="${ORCHESTRA_EFFORT:-}"; perm="${ORCHESTRA_PERMISSION_MODE:-}"
session="${ORCHESTRA_SESSION:?ORCHESTRA_SESSION is required}"; sock="${ORCHESTRA_SOCKET:?ORCHESTRA_SOCKET is required}"
NO_CONVERSATION='No conversation found to continue'
stype="$(tag_get "$sock" "$session" "$TAG_SESSION_TYPE")"
where=worktree; [ "$stype" = "$SESSION_TYPE_DIR" ] && where=directory
RESTART_NOTE="Your session was restarted in this $where; files and commits are intact, so do not redo finished work."

fail() { echo "player launch: $*" >&2; exit 1; }
buf="$(prompt_buffer_name "$session")"
# show-buffer writes the bytes as they are; the command substitution drops the trailing newline
# spawn.sh adds (tmux never creates an empty buffer, and an empty body is allowed).
body="$(tmux -S "$sock" show-buffer -b "$buf" 2>/dev/null)" || fail "no task buffer $buf on $sock (rerun spawn.sh)"
tmux -S "$sock" delete-buffer -b "$buf" 2>/dev/null
remember() { tag_set "$sock" "$session" "$TAG_AGENT" "$1" 2>/dev/null; true; }
# <invocation> [restart note] <body>
preamble() {
  local inv; case "$1" in codex) inv='$player';; *) inv="${ORCHESTRA_CLAUDE_SKILL:-/orchestra:player}";; esac
  if [ "$mode" = resume ]; then
    printf '%s %s%s' "$inv" "$RESTART_NOTE" "${body:+$nl$nl$body}"
  else
    printf '%s%s' "$inv" "${body:+ $body}"
  fi
}
codex_effort_args() { [ -n "$effort" ] && printf '%s\n' -c "model_reasoning_effort=\"$effort\""; true; }
# claude_conversation_args: which Claude conversation to start or continue (see the header); fails
# for a dir player's resume with no recorded conversation.
claude_conversation_args() {
  local id=""
  if [ "$stype" != "$SESSION_TYPE_DIR" ]; then [ "$mode" = resume ] && printf '%s\n' --continue; return 0; fi
  if [ "$mode" = resume ]; then
    id="$(tag_get "$sock" "$session" "$TAG_CLAUDE_SESSION")"
    [ -n "$id" ] && printf '%s\n' --resume "$id"
    return
  fi
  id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)" || :
  id="$(printf %s "$id" | tr A-F a-f)"
  if [ -n "$id" ] && tag_set "$sock" "$session" "$TAG_CLAUDE_SESSION" "$id"; then printf '%s\n' --session-id "$id"
  else echo "player launch: could not record a Claude conversation id on $session; this dir player cannot be resumed" >&2; fi
  return 0
}
# claude_trust_here: record this worktree as trusted in Claude Code's global config
# ($CLAUDE_CONFIG_DIR/.claude.json, else ~/.claude.json), as answering its workspace-trust dialog
# would: projects[<path>].hasTrustDialogAccepted, for this exact path — a trusted ancestor is no
# substitute (a trusted /tmp still prompts for a directory under it). Nothing is written when the
# entry is already there; otherwise the file is replaced atomically, never written in place.
# Needs python3; without it, or without a config file (Claude never run here), nothing changes
# and the dialog may appear.
claude_trust_here() {
  local cfg
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then cfg="$CLAUDE_CONFIG_DIR/.claude.json"; else cfg="$HOME/.claude.json"; fi
  [ -f "$cfg" ] || return 0
  command -v python3 >/dev/null 2>&1 || { echo "player launch: python3 not found; Claude may ask whether to trust $PWD" >&2; return 0; }
  python3 - "$cfg" "$PWD" "$(pwd -P)" <<'PY' || echo "player launch: could not pre-accept Claude's workspace trust for $PWD" >&2
import json, os, sys, tempfile
cfg, paths = sys.argv[1], sorted(set(sys.argv[2:]))
with open(cfg) as f:
    data = json.load(f)
projects = data.setdefault('projects', {})
if all(projects.get(p, {}).get('hasTrustDialogAccepted') is True for p in paths):
    sys.exit(0)
for p in paths:
    projects.setdefault(p, {})['hasTrustDialogAccepted'] = True
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(cfg)), prefix='.claude.json.')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.chmod(tmp, os.stat(cfg).st_mode & 0o777)
os.replace(tmp, cfg)
PY
}

fresh() {
  local prompt; prompt="$(preamble "$1")"; remember "$1"
  case "$1" in
    claude)   claude_trust_here; exec claude $(claude_conversation_args) ${perm:+--permission-mode "$perm"} ${model:+--model "$model"} ${effort:+--effort "$effort"} --strict-mcp-config "$prompt";;
    codex)    exec codex ${model:+-m "$model"} $(codex_effort_args) "$prompt";;
    gemini)   exec gemini ${model:+-m "$model"} -i "$prompt";;
    copilot)  exec copilot ${model:+--model "$model"} -i "$prompt";;
    opencode) exec opencode ${model:+-m "$model"} --prompt "$prompt";;
  esac
  fail "unknown harness $1"
}

# Newest recorded Codex conversation whose cwd is this worktree (rollout files carry it in
# their session_meta line). Prints the UUID; fails when none exists.
codex_session_here() {
  local home="${CODEX_HOME:-$HOME/.codex}" here real f
  here="$PWD"; real="$(pwd -P)"
  while IFS= read -r f; do
    case "$(head -c 4096 "$f" | tr -d ' ')" in
      *"\"cwd\":\"$here\""*|*"\"cwd\":\"$real\""*)
        printf '%s\n' "$f" | sed -nE 's/.*-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl$/\1/p'
        return 0;;
    esac
  done < <(find "$home/sessions" -name 'rollout-*.jsonl' 2>/dev/null | sort -r)
  return 1
}

resume_codex() {
  local prompt id; prompt="$(preamble codex)"
  id="$(codex_session_here)" || fail "no Codex conversation is recorded for $PWD; nothing to resume (use a fresh spawn for a new task)"
  remember codex
  exec codex resume ${model:+-m "$model"} $(codex_effort_args) "$id" "$prompt"
}
resume_claude() {
  local prompt conv; prompt="$(preamble claude)"
  conv="$(claude_conversation_args)" || fail "no Claude conversation is recorded on this dir player's session (kill.sh removes it); nothing to resume. Spawn it fresh, or pass --agent codex for a Codex player"
  remember claude; claude_trust_here
  exec claude $conv ${perm:+--permission-mode "$perm"} ${model:+--model "$model"} ${effort:+--effort "$effort"} --strict-mcp-config "$prompt"
}
resume_auto() {
  [ "$stype" = "$SESSION_TYPE_DIR" ] && resume_claude
  command -v script >/dev/null || fail "cannot detect the harness without util-linux script(1); rerun with --agent claude or --agent codex"
  local log rc
  claude_trust_here
  log="$(mktemp /tmp/orchestra-resume-probe.XXXXXX)" || fail "cannot create a probe log in /tmp"
  # The prompt and options travel in the environment; the sh -c string contains no user text.
  # script(1) runs the command through $SHELL: pin /bin/sh so a login shell's rc files cannot
  # reorder PATH or otherwise change which claude binary starts.
  PROMPT="$(preamble claude)" SHELL=/bin/sh script -qefc \
    'exec claude --continue ${ORCHESTRA_PERMISSION_MODE:+--permission-mode "$ORCHESTRA_PERMISSION_MODE"} ${ORCHESTRA_MODEL:+--model "$ORCHESTRA_MODEL"} ${ORCHESTRA_EFFORT:+--effort "$ORCHESTRA_EFFORT"} --strict-mcp-config "$PROMPT"' "$log"
  rc=$?
  if [ $rc -ne 0 ] && grep -aq "$NO_CONVERSATION" "$log"; then
    rm -f "$log"
    echo "player launch: Claude has no conversation for this worktree; trying Codex" >&2
    resume_codex
  fi
  rm -f "$log"
  [ $rc = 0 ] && remember claude
  exit $rc
}

if [ "$harness" = custom ]; then
  PROMPT="$(preamble claude)"; export PROMPT; remember custom
  exec bash -c "${ORCHESTRA_COMMAND:?ORCHESTRA_COMMAND is required for the custom harness}"
fi
if [ "$mode" = fresh ]; then fresh "$harness"; fi
case "$harness" in
  claude)   resume_claude;;
  codex)    resume_codex;;
  auto)     resume_auto;;
  opencode) remember opencode; exec opencode --continue --prompt "$(preamble opencode)";;
  *)        fail "--resume is not supported for $harness; use a fresh spawn";;
esac
