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
# shell/agent (Kirby's terminal tabs): "<basename(repo)>-shell" / "-agent"; dir (a player with no
# worktree, which Kirby never creates; <repo> is its directory): "<basename(dir)>-dir", so a reviewer
# in .claude/worktrees/<branch> is never named like the branch it would otherwise shadow.
session_label() {
  case "$2" in
    worktree) cap_name "$(basename "$1")-$3";;
    dir) cap_name "$(basename "$1")-dir";;
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
# name, session_created, session_path, spawner, repo, session-type, branch, worktree path (tags expand to ""
# when unset; values never contain tabs). No tmux-side (-f) filter: matching is done here so the
# same rules work on every tmux Kirby supports.
TAB=$'\t'
list_sessions_tagged() {
  if uses_mux; then mux_sessions_tagged; return; fi
  tmux_on "" list-sessions -F "#{session_name}${TAB}#{session_created}${TAB}#{session_path}${TAB}#{$TAG_SPAWNER}${TAB}#{$TAG_REPO}${TAB}#{$TAG_SESSION_TYPE}${TAB}#{$TAG_BRANCH}${TAB}#{$TAG_WORKTREE_PATH}" 2>/dev/null || true
}
# Player sessions = spawner set, repo set AND session-type dir, or worktree with the checkout set,
# whoever created them (Kirby's worktree sessions included). Same tab-separated fields as above.
# This is the one definition of "ours" for listing, resolving, killing and adopting: a session whose
# name we would have chosen but that lacks any of these tags is foreign, never attached, killed,
# adopted or listed.
player_sessions() {
  list_sessions_tagged | awk -F "$TAB" -v wt="$SESSION_TYPE_WORKTREE" -v dir="$SESSION_TYPE_DIR" '$4 != "" && $5 != "" && (($6 == wt && $8 != "") || $6 == dir)'
}
all_player_sessions() { player_sessions | cut -f1; }
is_player_session() { player_sessions | cut -f1 | grep -qxF -- "$1"; }
# find_player_session <repo> <checkout>: the worktree session whose tags equal (repo, checkout),
# the checkout canonical as spawn.sh tags it; with an empty checkout, the dir player of <repo> (its
# directory). @orchestra-branch is never consulted: the checkout may have switched branch since.
# With several (should not happen) the one created first, the others named on stderr and left alone.
find_player_session() {
  local matches
  matches="$(player_sessions | awk -F "$TAB" -v repo="$1" -v path="${2:-}" -v wt="$SESSION_TYPE_WORKTREE" -v dir="$SESSION_TYPE_DIR" \
    '$5 == repo && (path == "" ? $6 == dir : $6 == wt && $8 == path)' | sort -t "$TAB" -k2,2n)"
  [ -n "$matches" ] || return 1
  if [ "$(printf '%s\n' "$matches" | grep -c .)" -gt 1 ]; then
    echo "warning: several sessions carry repo $1${2:+ checkout ${2:-}}; using the oldest: $(printf '%s\n' "$matches" | cut -f1 | tr '\n' ' ')" >&2
  fi
  printf '%s\n' "$matches" | head -n1 | cut -f1
}
# players_on_branch <branch> [repo]: "name<TAB>repo", oldest first, of each worktree player (of
# <repo> when given) whose checkout has <branch> checked out now, asked of git on ORCH_MACHINE.
players_on_branch() {
  local name repo path
  while IFS="$TAB" read -r name repo path; do
    [ "$(r --cwd "$path" git branch --show-current 2>/dev/null </dev/null)" = "$1" ] && printf '%s\t%s\n' "$name" "$repo"
  done < <(player_sessions | sort -t "$TAB" -k2,2n |
    awk -F "$TAB" -v wt="$SESSION_TYPE_WORKTREE" -v repo="${2:-}" '$6 == wt && (repo == "" || $5 == repo) { print $1 FS $5 FS $8 }')
  return 0
}
# resolve_session <arg>: an exact tmux name whose tags say it is a player (the only way to name a
# dir player, which has no branch), else <arg> is the branch a worktree player's checkout is on:
# in a repo (--repo or cwd) that repo's player (the oldest, if several claim it); outside one the
# unique such player across all repos, ambiguity listing the candidates. Never a foreign session.
resolve_session() {
  local arg="$1" root cand
  if is_player_session "$arg"; then printf %s "$arg"; return; fi
  if in_repo; then
    root="$(repo_root)"
    cand="$(players_on_branch "$arg" "$root" | cut -f1)"
    if [ -n "$cand" ]; then
      [ "$(printf '%s\n' "$cand" | grep -c .)" -gt 1 ] && echo "warning: several sessions are on branch $arg in $root; using the oldest: $(printf '%s\n' "$cand" | tr '\n' ' ')" >&2
      printf '%s\n' "$cand" | head -n1; return
    fi
    echo "resolve_session: no player session named $arg, and no player on branch $arg in $root on $(machine_label) (sessions.sh --all lists every repo's and, with more than one machine registered, every machine's; pass --repo, --machine, or the exact session name)" >&2; exit 1
  fi
  cand="$(players_on_branch "$arg" | awk -F "$TAB" '{ print $1 "  (repo " $2 ")" }')"
  case "$(printf '%s\n' "$cand" | grep -c .)" in
    1) printf %s "${cand%%  (repo *}";;
    0) echo "resolve_session: no player session named $arg and no player on branch $arg on $(machine_label)" >&2; exit 1;;
    *) echo "resolve_session: branch $arg is ambiguous on $(machine_label); pass --repo or the exact session name. Session names are only unique per machine, so once several machines are in play also pass --machine:" >&2; printf '  %s\n' "$cand" >&2; exit 1;;
  esac
}
# Exact-match check for a resolved name; prints a uniform error. Routed through tmux_on (not a
# bare `tmux`) so it honours ORCH_MACHINE like every other read here.
session_exists() {
  if uses_mux; then mux_find "$1" || { echo "no such session: $1" >&2; return 1; }; return; fi
  tmux_on "" has-session -t "=$1" 2>/dev/null || { echo "no such session: $1" >&2; return 1; }
}

# --- Per-session operations: one tmux command each, or its n10 equivalent ---------------------
# pane_dead <socket> <session>: 1 when the session's command has exited, 0 while it runs, empty
# when there is no such session.
pane_dead() {
  if uses_mux; then mux_find "$2" || return 0; [ "${MUX_F[$MUX_STATE]}" = running ] && echo 0 || echo 1; return; fi
  tmux_on "$1" display-message -p -t "$(tmux_target "$2")" '#{pane_dead}'
}
# capture_pane <session> <history>: the screen and that many lines of history above it.
capture_pane() {
  if uses_mux; then mux_capture "$1" "$2"; return; fi
  tmux_on "" capture-pane -p -t "$(tmux_target "$1")" -S "-$2"
}
# send_key <session> <key>: one keypress, by tmux's name for it (Enter, Escape, C-c, Up, …).
send_key() { if uses_mux; then mux_send "$1" key "$2" || { echo "$DELIVER_REASON" >&2; return 1; }; return; fi; tmux_on "" send-keys -t "$(tmux_target "$1")" "$2"; }
# type_line <session> <text>: the text typed as keystrokes, not pasted, then Enter.
type_line() {
  if uses_mux; then mux_send "$1" literal "$2" submit || { echo "$DELIVER_REASON" >&2; return 1; }; return; fi
  tmux_on "" send-keys -t "$(tmux_target "$1")" -l "$2" && sleep 0.3 && tmux_on "" send-keys -t "$(tmux_target "$1")" Enter
}

# Trailing whitespace trimmed, runs of blank lines collapsed.
normalize_screen() { sed -e 's/[[:space:]]*$//' | awk 'NF{blank=0} !NF{blank++} blank<2'; }
# Visible pane text, normalized.
screen_text() { tmux_on "" capture-pane -p -t "$1" 2>/dev/null | normalize_screen; }
# screen_digests: "<session><TAB><digest of its screen_text>" for every player session; with n10,
# every screen comes from one batched listing.
screen_digests() {
  local n
  if uses_mux; then mux_screen_digests; return; fi
  while IFS= read -r n; do printf '%s\t%s\n' "$n" "$(screen_text "=$n:" | md5sum)"; done < <(all_player_sessions)
}

# sh_quote <word>...: the words single-quoted for a POSIX sh command line, space-separated. The
# pane command runs under /bin/sh (the one shell path NixOS guarantees), where printf %q's bash-only
# $'...' form for control characters would not parse.
sh_quote() { local w sq="'" esc="'\\''" out=(); for w; do out+=("'${w//$sq/$esc}'"); done; local IFS=' '; printf '%s' "${out[*]}"; }

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
# these known markers are removed: credentials such as ANTHROPIC_API_KEY are deliberately left as
# the tmux server has them, and spawn.sh passes a local orchestrator's CLAUDE_CONFIG_DIR (selected
# per directory by the user's claude wrapper) and CODEX_HOME explicitly.
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

# Marking an orchestrator's own session: a tool reading the server (n10's tab strip) can tell
# which session a claude:/codex: target lives in — the target names none — only when that session
# says so. orchestrator_home, called right after resolve_orchestrator and before anything unsets
# $TMUX, remembers the session tmux itself says this pane is in ($TMUX, $TMUX_PANE; this machine
# whatever ORCH_MACHINE says), but only when the target is this process's own identity: resolved
# from it, or given explicitly and equal to it. An explicit target naming anyone else hands players
# to that orchestrator; a tmux:<session> target names its session already; a beam-qualified one is
# on another machine. Outside tmux there is nothing to mark.
ORCH_HOME_SOCK=""; ORCH_HOME_SESSION=""; ORCH_HOME_TARGET=""
# is_own_target <target>: is it this process's own Claude session or Codex thread? The same
# identities resolve_orchestrator reads, Codex's only outside Claude (an inherited Codex id is
# some ancestor's, not ours).
is_own_target() {
  case "$1" in
    claude:*) [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ "$1" = "claude:$CLAUDE_CODE_SESSION_ID" ];;
    codex:*) [ -z "${CLAUDECODE:-}" ] && [ -n "${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}" ] &&
      [ "$1" = "codex:${CODEX_THREAD_ID:-$CODEX_SESSION_ID}" ];;
    *) return 1;;
  esac
}
# In a session of n10's, that session is the one marked, by its owner (mux self).
# orchestrator_home <given --orchestrator> <resolved target>
orchestrator_home() {
  ORCH_HOME_SOCK=""; ORCH_HOME_SESSION=""; ORCH_HOME_TARGET=""
  if uses_mux; then
    case "$2" in claude:*|codex:*) ;; *) return 0;; esac
    [ -z "$1" ] || is_own_target "$2" || return 0
    mux_self || return 0
    ORCH_HOME_SESSION="${MUX_F[$MUX_LABEL]}"; ORCH_HOME_TARGET="$2"; return 0
  fi
  [ -n "${TMUX:-}" ] || return 0
  case "$2" in claude:*|codex:*) ;; *) return 0;; esac
  [ -z "$1" ] || is_own_target "$2" || return 0
  ORCH_HOME_SESSION="$(tmux_local display-message -p '#S' 2>/dev/null)" || ORCH_HOME_SESSION=""
  [ -n "$ORCH_HOME_SESSION" ] || return 0
  ORCH_HOME_SOCK="${TMUX%%,*}"; ORCH_HOME_TARGET="$2"
}
# mark_orchestrator_session: write the remembered local target (never beam-qualified: the session
# is on this machine) as the home session's @orchestra-target. One value: a later orchestrator in
# the same session replaces it. Any other session on that server holding the same value gives it up
# first — the conversation was resumed here — so one server never has two claimants (another
# server, or another machine, can still hold a stale one). Best effort — the player already points
# at its target, so a failure warns and spawning carries on.
mark_orchestrator_session() {
  [ -n "$ORCH_HOME_SESSION" ] || return 0
  if uses_mux; then mux_claim "$ORCH_HOME_TARGET" || echo "warning: could not set $TAG_TARGET on this orchestrator's session $ORCH_HOME_SESSION" >&2; return 0; fi
  local name value
  while IFS="$TAB" read -r name value; do
    [ "$value" = "$ORCH_HOME_TARGET" ] && [ "$name" != "$ORCH_HOME_SESSION" ] || continue
    tmux -u -S "$ORCH_HOME_SOCK" set-option -u -t "$(tmux_target "$name")" "$TAG_TARGET" 2>/dev/null || :
  done < <(tmux -u -S "$ORCH_HOME_SOCK" list-sessions -F "#{session_name}$TAB#{$TAG_TARGET}" 2>/dev/null)
  tmux -u -S "$ORCH_HOME_SOCK" set-option -t "$(tmux_target "$ORCH_HOME_SESSION")" "$TAG_TARGET" "$ORCH_HOME_TARGET" 2>/dev/null ||
    echo "warning: could not set $TAG_TARGET on this orchestrator's session $ORCH_HOME_SESSION" >&2
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
