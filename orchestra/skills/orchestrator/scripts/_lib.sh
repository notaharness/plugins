# Shared helpers for the orchestrator scripts and the launcher. Harness-neutral: git + tmux +
# coreutils only. Tag names and tmux targeting come from the player skill's _routing.sh.
set -u

# The repo a script acts on: --repo <path> (parsed by each script into ORCH_REPO) or the
# current directory. Every git call goes through g so both cases behave the same. On the local
# machine (the default, and every user's behaviour until they name a --machine) this is exactly
# today's invocation, unchanged; ORCH_MACHINE and is_local_machine come from _routing.sh, sourced
# below. A remote --repo must be absolute or start with "~/": relative paths cannot be resolved
# against this machine's working directory on another machine, so g refuses rather than guessing.
ORCH_REPO="${ORCH_REPO:-}"
# A remote --repo must be absolute or start with "~/": a relative path cannot be resolved against
# this machine's working directory on another machine. Scripts call this right after parsing
# --repo/--machine so the error is specific rather than being swallowed by a later "not a git
# repo" check; g() calls it too, as a backstop for anything that reaches git without going
# through a script's own argument parsing.
require_valid_repo_for_machine() {
  is_local_machine && return 0
  case "$ORCH_REPO" in
    ""|/*|"~/"*) return 0;;
    *) echo "orchestra: --repo must be an absolute path or start with ~/ when --machine is set (got '$ORCH_REPO'); it cannot be resolved against this machine's working directory on $ORCH_MACHINE" >&2; return 1;;
  esac
}
g() {
  if is_local_machine; then
    if [ -n "$ORCH_REPO" ]; then git -C "$ORCH_REPO" "$@"; else git "$@"; fi
    return
  fi
  require_valid_repo_for_machine || return 1
  # git's -C does not itself expand "~/"; beam's own --cwd resolves it on the target machine
  # (beam/docs/04-streams.md), so the repo location travels as exec's cwd rather than as a literal -C
  # argument that a shell-less remote exec would never expand.
  if [ -n "$ORCH_REPO" ]; then
    beam_cmd || { echo "orchestra: $(beam_unresolved_message "$ORCH_MACHINE")" >&2; return 1; }
    "${BEAM_CMD[@]}" exec "$ORCH_MACHINE" --cwd "$ORCH_REPO" -- git "$@"
  else
    beam_exec "$ORCH_MACHINE" git "$@"
  fi
}
in_repo() { g rev-parse --git-dir >/dev/null 2>&1; }

# r [--cwd PATH] <argv…>: run one non-git command on ORCH_MACHINE — this machine, exactly as
# before, or the target machine through beam_exec. Unlike a bare invocation, this is never
# silently local when a machine is set: every non-tmux, non-git side effect a script has (cd,
# mkdir, cp, test -d, a small bash -c script) must go through this or g(), never a bare command,
# or "--machine" spawns/adopts/kills work against this machine while claiming to act on another.
# --cwd is the one thing a shell would otherwise give for free (`cd` then run): locally it is a
# subshell cd; remotely it becomes the same --cwd exec() itself accepts (beam expands "~/" there,
# see beam/docs/04-streams.md; a caller must not build "~/..." into argv[0] itself — see D12).
r() {
  local cwd=""
  if [ "${1:-}" = --cwd ]; then cwd="$2"; shift 2; fi
  if is_local_machine; then
    if [ -n "$cwd" ]; then (cd "$cwd" && "$@"); else "$@"; fi
  else
    if [ -n "$cwd" ]; then
      beam_cmd || { echo "orchestra: $(beam_unresolved_message "$ORCH_MACHINE")" >&2; return 1; }
      "${BEAM_CMD[@]}" exec "$ORCH_MACHINE" --cwd "$cwd" -- "$@"
    else
      beam_exec "$ORCH_MACHINE" "$@"
    fi
  fi
}

# Root of the MAIN checkout, even when run from inside a linked worktree: the common git dir
# lives in the main checkout, so its parent is the main root. Falling back to --show-toplevel
# covers repos too old for --path-format. Symlink-resolved: the string is compared for equality
# with the @orchestra-repo tag, which the contract defines as the resolved path — on a remote
# machine that means resolved there, since that is the machine the worktree lives on.
repo_root() {
  local common root
  if common="$(g rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    root="$(dirname "$common")"
  else
    root="$(g rev-parse --show-toplevel 2>/dev/null)" || { [ -n "$ORCH_REPO" ] && root="$ORCH_REPO" || root="$PWD"; }
  fi
  if is_local_machine; then
    realpath "$root" 2>/dev/null || printf %s "$root"
  else
    beam_exec "$ORCH_MACHINE" realpath "$root" 2>/dev/null || printf %s "$root"
  fi
}

# The tmux server an orchestrator's own session lives on: $TMUX's socket path when running inside
# tmux (spawn.sh, adopt.sh and relay.sh may all run from an orchestrator's own pane), else the
# default per-user socket tmux itself would pick. Shared so relay.sh (which is not necessarily
# started from inside tmux) resolves a local target's session on the same server spawn.sh used.
default_orchestrator_socket() {
  local sock="${TMUX:-}"; sock="${sock%%,*}"
  printf '%s' "${sock:-${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default}"
}

# The repository's default branch as a remote ref (origin/master, origin/main, …),
# freshly fetched when possible; empty string when it cannot be determined.
default_branch_ref() {
  local ref
  ref="$(g rev-parse --abbrev-ref origin/HEAD 2>/dev/null)" ||
    [ "${DRY:-0}" = 1 ] || ref="$(g remote show origin 2>/dev/null | sed -n 's/^ *HEAD branch: /origin\//p')"
  [ -n "${ref:-}" ] || for b in master main; do
    g rev-parse -q --verify "origin/$b" >/dev/null 2>&1 && { ref="origin/$b"; break; }
  done
  [ "${DRY:-0}" = 1 ] || [ -z "${ref:-}" ] || g fetch -q origin "${ref#origin/}" 2>/dev/null
  printf %s "${ref:-}"
}

# --- Session names are labels ------------------------------------------------------------------
# A tmux session's name is a human-readable label chosen once at creation and never parsed; its
# identity is its tags (resolver below). The label rules are shared with Kirby, which implements
# the same functions in TypeScript; the table in the repository CLAUDE.md pins inputs and outputs
# for both. Do not change them on one side only.
NAME_MAX=200; HASH_TAIL=4
# sanitize: every "/", "." and ":" becomes "-" (tmux rejects "." and ":" in names).
sanitize() { local s="${1//\//-}"; s="${s//./-}"; printf %s "${s//:/-}"; }
# cap_name <raw>: sanitize(raw), capped at NAME_MAX characters. On overflow the result is the
# first NAME_MAX-HASH_TAIL-1 characters, "-", and the first HASH_TAIL hex digits of sha256 over the
# UNSANITIZED string, so two long names that share a head still differ. printf %s hashes exactly
# the bytes createHash().update(raw) does (no newline).
cap_name() {
  local s; s="$(sanitize "$1")"
  if [ "${#s}" -le "$NAME_MAX" ]; then printf %s "$s"
  else printf '%s-%s' "${s:0:$((NAME_MAX - HASH_TAIL - 1))}" "$(printf %s "$1" | sha256sum | cut -c1-"$HASH_TAIL")"; fi
}
# session_label <repo> <type> [branch]: the preferred name. worktree: "<basename(repo)>-<branch>";
# shell/agent (Kirby's terminal tabs): "<basename(repo)>-shell" / "-agent".
session_label() {
  case "$2" in
    worktree) cap_name "$(basename "$1")-$3";;
    shell|agent) cap_name "$(basename "$1")-$2";;
    *) echo "session_label: unknown session type $2" >&2; return 2;;
  esac
}
# Worktree location under the main checkout (unchanged: only "/" is replaced).
worktree_dir_for_branch() { printf '.claude/worktrees/%s' "${1//\//-}"; }
# free_session_name <socket> <preferred>: the preferred label, else the first "-2", "-3", …
# suffix not taken by ANY session on that server (foreign ones included). Chosen at creation
# only; nothing reconstructs it later. A server that is not running has no sessions.
free_session_name() {
  local sock="$1" base="$2" n=1 cand="$2"
  while tmux_on "$sock" has-session -t "=$cand" 2>/dev/null; do n=$((n+1)); cand="$base-$n"; done
  printf %s "$cand"
}

# --- Resolver: identity is the tags ------------------------------------------------------------
# One list-sessions call gives every session with the fields the resolver needs, tab-separated:
# name, session_created, session_path, spawner, repo, session-type, branch (tags expand to ""
# when unset; values never contain tabs). No tmux-side (-f) filter: matching is done here so the
# same rules work on every tmux Kirby supports.
TAB=$'\t'
list_sessions_tagged() {
  tmux_on "" list-sessions -F "#{session_name}${TAB}#{session_created}${TAB}#{session_path}${TAB}#{$TAG_SPAWNER}${TAB}#{$TAG_REPO}${TAB}#{$TAG_SESSION_TYPE}${TAB}#{$TAG_BRANCH}" 2>/dev/null || true
}
# Player sessions = spawner set, repo set AND session-type worktree, whoever created them (Kirby's
# worktree sessions included). Same tab-separated fields as above. This is the one definition of
# "ours" for listing, resolving, killing and adopting: a session whose name we would have chosen
# but that lacks any of these tags is foreign, never attached, killed, adopted or listed.
player_sessions() {
  list_sessions_tagged | awk -F "$TAB" -v type="$SESSION_TYPE_WORKTREE" '$4 != "" && $5 != "" && $6 == type'
}
all_player_sessions() { player_sessions | cut -f1; }
is_player_session() { player_sessions | cut -f1 | grep -qxF -- "$1"; }
# find_player_session <repo> <branch>: the session whose tags equal (repo, branch); with several
# (should not happen) the one created first, the others named on stderr and left alone.
find_player_session() {
  local matches
  matches="$(player_sessions | awk -F "$TAB" -v repo="$1" -v branch="$2" '$5 == repo && $7 == branch' | sort -t "$TAB" -k2,2n)"
  [ -n "$matches" ] || return 1
  if [ "$(printf '%s\n' "$matches" | grep -c .)" -gt 1 ]; then
    echo "warning: several sessions carry repo $1 branch $2; using the oldest: $(printf '%s\n' "$matches" | cut -f1 | tr '\n' ' ')" >&2
  fi
  printf '%s\n' "$matches" | head -n1 | cut -f1
}
# resolve_session <arg>: an exact tmux name whose tags say it is a player, else <arg> is a branch:
# in a repo (--repo or cwd) the player of (that repo, branch); outside one the unique player of
# that branch across all repos, ambiguity listing the candidates. Never a foreign session.
resolve_session() {
  local arg="$1" root cand
  if is_player_session "$arg"; then printf %s "$arg"; return; fi
  if in_repo; then
    root="$(repo_root)"
    find_player_session "$root" "$arg" && return
    echo "resolve_session: no player session named $arg, and no player for branch $arg in $root on $(machine_label) (sessions.sh --all lists every repo's and, with more than one machine registered, every machine's; pass --repo, --machine, or the exact session name)" >&2; exit 1
  fi
  cand="$(player_sessions | awk -F "$TAB" -v branch="$arg" '$7 == branch { print $1 "  (repo " $5 ")" }')"
  case "$(printf '%s\n' "$cand" | grep -c .)" in
    1) printf %s "${cand%%  (repo *}";;
    0) echo "resolve_session: no player session named $arg and no player for branch $arg on $(machine_label)" >&2; exit 1;;
    *) echo "resolve_session: branch $arg is ambiguous on $(machine_label); pass --repo or the exact session name. Session names are only unique per machine, so once several machines are in play also pass --machine:" >&2; printf '  %s\n' "$cand" >&2; exit 1;;
  esac
}
# Exact-match check for a resolved name; prints a uniform error. Routed through tmux_on (not a
# bare `tmux`) so it honours ORCH_MACHINE like every other read here.
session_exists() { tmux_on "" has-session -t "=$1" 2>/dev/null || { echo "no such session: $1" >&2; return 1; }; }

# Visible pane text, trailing whitespace trimmed, runs of blank lines collapsed.
screen_text() { tmux_on "" capture-pane -p -t "$1" 2>/dev/null | sed -e 's/[[:space:]]*$//' | awk 'NF{blank=0} !NF{blank++} blank<2'; }

# Every agent runs with TMUX unset and TMUX_TMPDIR on a scratch dir, so nothing it runs —
# tests included — can reach the socket that hosts the user's live sessions.
AGENT_TMUX_TMPDIR=/tmp/orchestra-agent-tmux

# Parent-session markers that must not reach a player. A Claude started under its parent's
# CLAUDECODE/CLAUDE_CODE_CHILD_SESSION treats itself as a nested child and stops saving its
# transcript (so --continue later finds nothing); CODEX_THREAD_ID would masquerade as the player's
# parent. ORCHESTRA_MACHINE (the documented way to default --machine) must not reach a player
# either: report.sh and relay.sh run there, and it would send their local "what is my orchestrator"
# lookup over beam instead of asking their own machine (see _routing.sh's ORCHESTRA_FORCE_LOCAL,
# which is the other half of this fix — that one covers a value inherited any other way, this one
# stops it being captured into the tmux server's global environment in the first place). Only
# these known markers are removed: configuration and credentials such as ANTHROPIC_API_KEY and
# CODEX_HOME are deliberately left as the tmux server has them, and spawn.sh passes a local
# orchestrator's CLAUDE_CONFIG_DIR (selected per directory by the user's claude wrapper) explicitly.
PARENT_SESSION_MARKERS=(CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_SESSION_ATTENDED
  CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_EXECPATH
  CLAUDE_CODE_NO_FLICKER CLAUDE_PID CLAUDE_EFFORT CODEX_THREAD_ID CODEX_SESSION_ID ORCHESTRA_MACHINE)

# set_orchestrator <socket> <session> <target>: point a player's reports at <target>. A local
# claude: target is found through the orchestrator's Claude config dir, which the player's own
# environment need not share, so it goes on beside the target (first: report.sh never sees the
# target without it); every other target drops it. A beam-qualified one leaves the lookup to the
# far side's relay, with its own environment.
set_orchestrator() {
  case "$3" in
    claude:*) tag_set "$1" "$2" "$TAG_ORCH_CONFIG" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" || return 1;;
    *) tag_unset "$1" "$2" "$TAG_ORCH_CONFIG" 2>/dev/null || :;;
  esac
  tag_set "$1" "$2" "$TAG_ORCHESTRATOR" "$3"
}

# Deliver multi-line text to a pane as one bracketed paste on the default/current server, like
# every other orchestrator-side call here, so it honours ORCH_MACHINE too (paste_into_pane,
# _routing.sh). Usage: paste_into <session> <text>
paste_into() { paste_into_pane "" "$1" "$2"; }

# Resolve links created by skills installers before finding the sibling player skill.
# Both skills must be installed together under the same skills directory.
ORCH_SCRIPTS="$(dirname "$(realpath "$0")")"
PLAYER_SCRIPTS="$ORCH_SCRIPTS/../../player/scripts"
[ -f "$PLAYER_SCRIPTS/_routing.sh" ] || { echo "orchestrator: the player skill's scripts are missing at $PLAYER_SCRIPTS (install both skills)" >&2; exit 1; }
. "$PLAYER_SCRIPTS/_routing.sh"

# The task body travels from spawn.sh to the launcher inside the pane as a paste buffer on the
# same server (loaded from stdin, so it is not subject to the ~16 KiB command-line cap), never
# as a file. One buffer per session, named after it.
prompt_buffer_name() { printf 'orchestra-prompt-%s' "$1"; }

# Claude players use the recommended plugin installation even when their orchestrator
# was installed as standalone skills. Override for standalone Claude with
# ORCHESTRA_CLAUDE_SKILL=/player. Codex players always use the $player mention.
claude_player_invocation() {
  if [ -n "${ORCHESTRA_CLAUDE_SKILL:-}" ]; then
    printf '%s' "$ORCHESTRA_CLAUDE_SKILL"
    return
  fi
  local manifest="$ORCH_SCRIPTS/../../../.claude-plugin/plugin.json" name=""
  [ -f "$manifest" ] && name="$(sed -nE 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$manifest" | head -n1)"
  printf '/%s:player' "${name:-orchestra}"
}
