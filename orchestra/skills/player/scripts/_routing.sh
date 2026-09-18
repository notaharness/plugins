# Shared by the orchestrator scripts, the launcher and report.sh. Harness-neutral: bash + tmux
# + coreutils only. Owns the names of the tmux session user options ("tags") and the exact
# targeting rules; every other script reads the names from here.

# --- Session user options: the contract shared with Kirby ------------------------------------
# Every fact about a player session lives on the session itself, as a user option that dies with
# the session and is readable by anyone who can reach the server: no files. Set with
# `set-option -t '=name:' @orchestra-agent claude`; read with `show-options -qv` (empty when unset)
# or as #{@orchestra-agent} in a format. Absent means unset; no sentinels. Values contain no
# tabs or newlines.
TAG_SPAWNER=@orchestra-spawner            # kirby | orchestra: whichever program created the session
TAG_REPO=@orchestra-repo                  # main checkout, absolute and symlink-resolved
TAG_SESSION_TYPE=@orchestra-session-type  # worktree (players) | shell | agent (Kirby's terminal tabs)
TAG_BRANCH=@orchestra-branch              # worktree sessions: the branch, unsanitized (feature/x)
TAG_ORCHESTRATOR=@orchestra-orchestrator  # reporting target: codex:<uuid> | tmux:<session>
TAG_AGENT=@orchestra-agent                # claude | codex | gemini | copilot | opencode | custom
TAG_LAUNCHING=@orchestra-launching        # 1 while the placeholder pane exists; unset once the harness started
TAG_LAST_REPORT=@orchestra-last-report    # "<KIND> <ISO-8601 UTC>" of the last report a transport accepted
SESSION_TYPE_WORKTREE=worktree            # a session's name is a label; spawner + session-type say whose it is
nl=$'\n'                                  # assigned once: ANSI-C quoting inside ${x:+...} is not portable

# Exact tmux targeting. `=name` is exact for has-session, but pane/window commands (send-keys,
# display-message, respawn-pane, set-option, capture-pane) reject it; `=name:` is exact for all.
tmux_target() { printf '=%s:' "$1"; }

# --- Machine selection ---------------------------------------------------------------------
# ORCH_MACHINE selects which machine tmux_on and g (_lib.sh) act on. Unset, empty, or the literal
# "local" means this machine — exactly the behaviour every script had before beam existed, byte
# for byte. Anything else is a beam peer label or peerId, and every tmux/git call below is run
# there through `beam exec` instead of run here. Scripts set this from --machine, defaulting to
# $ORCHESTRA_MACHINE.
#
# report.sh and relay.sh never set it — a player and the relay always act on their own machine —
# but $ORCHESTRA_MACHINE is an ordinary environment variable, and the documented way to set a
# default is to export it. If a user's shell (or the tmux server's captured global environment;
# see PARENT_SESSION_MARKERS in _lib.sh, which strips it from a spawned player's pane too) leaks
# it in, ORCH_MACHINE must not pick it up there: the orchestrator's own reporting lookup would
# silently go over beam instead of asking this machine, and tag_get's "never fails" swallows the
# result into an opaque "orchestrator target is unset or unreachable". report.sh and relay.sh set
# ORCHESTRA_FORCE_LOCAL=1 before sourcing this file, which pins ORCH_MACHINE to this machine
# unconditionally — the player and the relay need no machine awareness at all beyond parsing a
# beam-qualified target tag.
if [ -n "${ORCHESTRA_FORCE_LOCAL:-}" ]; then
  ORCH_MACHINE=""
else
  ORCH_MACHINE="${ORCH_MACHINE:-${ORCHESTRA_MACHINE:-}}"
fi
is_local_machine() { [ -z "$ORCH_MACHINE" ] || [ "$ORCH_MACHINE" = local ]; }
machine_label() { is_local_machine && printf 'this machine' || printf '%s' "$ORCH_MACHINE"; }

# --- beam executor ---------------------------------------------------------------------------
# beam_cmd: resolve how to invoke beam into the BEAM_CMD array (so a two-word form like "n10 beam"
# is never re-split by a shell). First hit wins: $ORCHESTRA_BEAM, `beam` on PATH, `n10 beam`.
# Fails, leaving BEAM_CMD unset, when none resolve — callers must not fall back to running
# anything locally on that failure, which would silently act on the wrong machine.
beam_cmd() {
  if [ -n "${ORCHESTRA_BEAM:-}" ]; then BEAM_CMD=("$ORCHESTRA_BEAM"); return 0; fi
  if command -v beam >/dev/null 2>&1; then BEAM_CMD=(beam); return 0; fi
  if command -v n10 >/dev/null 2>&1; then BEAM_CMD=(n10 beam); return 0; fi
  return 1
}
beam_unresolved_message() {
  printf "no beam binary found to reach machine '%s' (tried \$ORCHESTRA_BEAM, 'beam' on PATH, 'n10 beam')" "$1"
}
# beam_exec <machine> <argv…>: run argv on <machine> via `beam exec <machine> -- <argv…>`. Neither
# this function nor beam_cmd touches stdin, so it is forwarded to the remote process exactly as
# bash would forward it to any other subprocess — which is what lets a paste buffer loaded from
# stdin (tmux's ~16 KiB command-line cap) still work against a remote session.
beam_exec() {
  local machine="$1"; shift
  beam_cmd || { echo "orchestra: $(beam_unresolved_message "$machine") — refusing to run this locally" >&2; return 1; }
  "${BEAM_CMD[@]}" exec "$machine" -- "$@"
}
# beam_own_peer_id: this machine's own peerId, from `beam status --json`, run locally regardless
# of ORCH_MACHINE (asking "who am I" is never a remote operation).
beam_own_peer_id() {
  local status
  beam_cmd || { echo "orchestra: $(beam_unresolved_message "this machine")" >&2; return 1; }
  status="$("${BEAM_CMD[@]}" status --json 2>/dev/null)" || { echo "orchestra: 'beam status --json' failed; is a beam node running on this machine?" >&2; return 1; }
  json_string_field "$status" peerId
}

# --- Dependency-free JSON string extraction ---------------------------------------------------
# Beam prints JSON (peer/status/send responses, mailbox envelopes) and payloads travel through it
# as JSON strings. jq is not a listed dependency, and a payload can hold arbitrary report text
# (quotes, newlines, unicode), so field values are decoded here rather than shelled out to a tool
# that may not be installed.
# json_unescape <raw>: decode the standard JSON string escapes a scanner already isolated
# (\" \\ \/ \b \f \n \r \t; \uXXXX is passed through literally — Orchestra never emits one).
# Linear in the length of <raw>: each iteration jumps straight to the next backslash with one
# bash pattern-match (`${s%%\\*}`/`${s#*\\}`, both a single native scan) instead of walking the
# string one character at a time. A 100 KiB payload (the cap beam enforces) used to take ~45s
# here — every `out+="$c"` reallocates and copies the whole accumulator, so N one-character
# appends cost O(N^2) — and now completes in well under a second.
json_unescape() {
  local s="$1" out="" head c
  while :; do
    case "$s" in
      *'\'*)
        head="${s%%\\*}"; out+="$head"
        s="${s#*\\}"; c="${s:0:1}"; s="${s:1}"
        case "$c" in
          n) out+=$'\n';; t) out+=$'\t';; r) out+=$'\r';; b) out+=$'\b';; f) out+=$'\f';;
          '"') out+='"';; '\') out+='\';; /) out+='/';;
          *) out+="\\$c";;
        esac;;
      *) out+="$s"; break;;
    esac
  done
  printf '%s' "$out"
}
# json_string_field <json> <field>: the decoded value of "<field>":"<value>" found anywhere in one
# line of JSON (object nesting elsewhere in the line is not a concern: field names here are never
# reused at another depth). Fails when the field is absent, its value is not a JSON string (only
# JSON whitespace may separate the colon from the opening quote — anything else, a digit, `null`,
# `true`, `{`, `[`, means this field is not a string and must not be confused for one), or its
# closing quote is not found.
json_string_field() {
  local json="$1" field="$2" marker rest out="" head
  marker="\"$field\""
  case "$json" in *"$marker"*) ;; *) return 1;; esac
  rest="${json#*"$marker"}"; rest="${rest#*:}"
  while [ -n "$rest" ]; do
    case "${rest:0:1}" in
      ' '|$'\t'|$'\n'|$'\r') rest="${rest:1}";;
      *) break;;
    esac
  done
  [ -n "$rest" ] && [ "${rest:0:1}" = '"' ] || return 1
  rest="${rest:1}"
  # Scan straight to the next backslash-or-quote (one native pattern match) instead of one
  # character at a time: same fix, and reason, as json_unescape below — this loop is what a
  # profiler actually sees, since it builds the raw (still-escaped) value that json_unescape is
  # then called on once, at the end.
  while :; do
    head="${rest%%[\\\"]*}"; rest="${rest:${#head}}"
    case "${rest:0:1}" in
      '"') out+="$head"; json_unescape "$out"; return 0;;
      '\') out+="$head\\${rest:1:1}"; rest="${rest:2}";;
      *) return 1;;    # ran out of input before an unescaped closing quote
    esac
  done
}

# tmux sanitizes what it prints unless the client is in UTF-8 mode, which it infers from the names
# of LC_ALL/LC_CTYPE/LANG: outside a UTF-8 locale control characters (such as the tabs between
# listing fields) and non-ASCII come back as "_". `tmux -u` forces UTF-8 output whatever the locale, so every call goes through it.
# tmux_on <socket> <args…>: tmux on one server. An empty socket means the current server (the
# one $TMUX names, else the default); a path is passed as -S so a process whose tmux environment
# is redirected (every player pane) still reaches the server that holds its session. On the local
# machine (ORCH_MACHINE unset/empty/"local") this is exactly today's invocation, unchanged; on any
# other machine the identical argv runs there instead, through beam_exec.
tmux_on() {
  local sock="$1"; shift
  if is_local_machine; then
    if [ -n "$sock" ]; then tmux -u -S "$sock" "$@"; else tmux -u "$@"; fi
  else
    if [ -n "$sock" ]; then beam_exec "$ORCH_MACHINE" tmux -u -S "$sock" "$@"; else beam_exec "$ORCH_MACHINE" tmux -u "$@"; fi
  fi
}
# tmux_local <args…>: tmux on THIS machine's current/default server, ignoring ORCH_MACHINE
# entirely — for "which session/what am I" questions, which are never a remote operation (see
# beam_own_peer_id, which does the same for peer identity). Using tmux_on "" here would honour a
# --machine/$ORCHESTRA_MACHINE set for an unrelated reason and read the wrong machine's current
# session.
tmux_local() {
  if [ -n "${TMUX:-}" ]; then tmux -u -S "${TMUX%%,*}" "$@"; else tmux -u "$@"; fi
}
# tag_get <socket> <session> <tag>: the value, empty when unset or unreachable; never fails.
tag_get()   { tmux_on "$1" show-options -qv -t "$(tmux_target "$2")" "$3" 2>/dev/null || :; }
tag_set()   { tmux_on "$1" set-option -t "$(tmux_target "$2")" "$3" "$4"; }
tag_unset() { tmux_on "$1" set-option -u -t "$(tmux_target "$2")" "$3"; }

# player_session_context: the player's own session name and the socket of the server holding it,
# into player_session and player_socket (lowercase: not environment). spawn.sh injects
# ORCHESTRA_SESSION/ORCHESTRA_SOCKET into the panes it starts. A pane it did not start (a Kirby
# session adopted by adopt.sh) keeps tmux's own TMUX variable, so the session comes from
# `display-message -p '#S'` and the socket from TMUX. The name is used as is (it is a label,
# never parsed). Fails when neither source is available.
player_session_context() {
  player_session="${ORCHESTRA_SESSION:-}"; player_socket="${ORCHESTRA_SOCKET:-}"
  if [ -z "$player_session" ] && [ -n "${TMUX:-}" ]; then
    player_socket="${TMUX%%,*}"
    player_session="$(tmux_local display-message -p '#S' 2>/dev/null)" || player_session=""
  fi
  [ -n "$player_session" ]
}

# --- Reporting targets -----------------------------------------------------------------------
# codex:<thread-id>, tmux:<session>, or beam:<orchestrator peerId>/<one of those two>, when the
# orchestrator is on another machine. Nothing else. Never infer a parent from a player's own ID.
# tmux session names: tmux itself rewrites "." and ":" but otherwise allows most characters.
# peerId: the first 16 hex characters of the SHA-256 of the peer's public key (beam.md).
_valid_local_target() {
  case "$1" in
    codex:*) [[ "${1#codex:}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]];;
    tmux:*) [[ -n "${1#tmux:}" && ! "${1#tmux:}" =~ [:[:cntrl:]] ]];;
    *) return 1;;
  esac
}
normalize_target() {
  case "$1" in
    codex:*) _valid_local_target "$1" || { echo "invalid Codex thread ID: ${1#codex:}" >&2; return 2; };;
    tmux:*) _valid_local_target "$1" || { echo "invalid tmux session name: ${1#tmux:}" >&2; return 2; };;
    beam:*/*)
      local rest peer local_part
      rest="${1#beam:}"; peer="${rest%%/*}"; local_part="${rest#*/}"
      [[ "$peer" =~ ^[0-9a-fA-F]{16}$ ]] || { echo "invalid beam peerId: $peer" >&2; return 2; }
      case "$local_part" in
        codex:*) _valid_local_target "$local_part" || { echo "invalid Codex thread ID: ${local_part#codex:}" >&2; return 2; };;
        tmux:*) _valid_local_target "$local_part" || { echo "invalid tmux session name: ${local_part#tmux:}" >&2; return 2; };;
        *) echo "invalid beam-qualified target: $1 (the local part must be codex:<thread-id> or tmux:<session>)" >&2; return 2;;
      esac;;
    *) echo "invalid orchestrator target: $1 (use codex:<thread-id>, tmux:<session>, or beam:<peerId>/codex:<thread-id>|tmux:<session>)" >&2; return 2;;
  esac
  printf '%s' "$1"
}
# An explicit target wins. A Codex ID identifies the orchestrator only when the caller is not a
# Claude session: Claude marks itself with CLAUDECODE, and any CODEX_* ID it sees is inherited from
# some unrelated Codex ancestor, so its players would otherwise report to the wrong conversation.
resolve_orchestrator() {
  if [[ -n "${1:-}" ]]; then normalize_target "$1"
  elif [[ -z "${CLAUDECODE:-}" && -n "${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}" ]]; then
    normalize_target "codex:${CODEX_THREAD_ID:-$CODEX_SESSION_ID}"
  elif [[ -n "${TMUX:-}" ]]; then
    # "What session am I in" is a question about this machine, never ORCH_MACHINE — see
    # tmux_local; a spawn.sh/adopt.sh run with --machine must still learn its OWN orchestrator
    # target from its own pane, not from whatever session happens to be current on the target.
    normalize_target "tmux:$(tmux_local display-message -p '#S')"
  else
    echo 'Cannot identify orchestrator; pass --orchestrator codex:<thread-id> or tmux:<session>.' >&2
    return 2
  fi
}

# --- Pane ownership --------------------------------------------------------------------------
# Is an agent reading that pane, or would typed text land in a shell? `pane_current_command`
# reports the pane's process leader, which stays `bash`/`sh` when the agent runs under a wrapper
# shell (spawn.sh launches every player that way), so inspect the process tree: only a known agent
# binary in the foreground process group counts. A suspended agent (STAT T) or one in the
# background leaves the shell reading the tty.
is_agent_name() { case "$1" in claude|codex|gemini|copilot|opencode) return 0;; *) return 1;; esac; }
pane_has_agent() {
  local pid="$1" child comm argv0 stat
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    comm="$(ps -o comm= -p "$child" 2>/dev/null)"
    argv0="$(ps -o args= -p "$child" 2>/dev/null | awk '{print $1}')"
    stat="$(ps -o stat= -p "$child" 2>/dev/null)"
    case "$stat" in
      T*) ;;
      *+*) is_agent_name "$comm" && return 0
           is_agent_name "${argv0##*/}" && return 0;;
    esac
    pane_has_agent "$child" && return 0
  done
  return 1
}
# pane_owned_by_agent <socket> <session>: true when the session's pane is alive and an agent (not a
# shell) is at the terminal. The socket selects the server as in tmux_on.
pane_owned_by_agent() {
  local sock="$1" session="$2" cmd pid
  [ "$(tmux_on "$sock" display-message -p -t "$(tmux_target "$session")" '#{pane_dead}' 2>/dev/null)" = 0 ] || return 1
  cmd="$(tmux_on "$sock" display-message -p -t "$(tmux_target "$session")" '#{pane_current_command}' 2>/dev/null)"
  case "$cmd" in
    sh|bash|zsh|fish|dash|"")
      pid="$(tmux_on "$sock" display-message -p -t "$(tmux_target "$session")" '#{pane_pid}' 2>/dev/null)"
      pane_has_agent "$pid";;
    *) return 0;;
  esac
}

# --- Shared local delivery ---------------------------------------------------------------------
# The one place a report (or a relayed envelope) is actually delivered to a local target: the
# codex queue path, or the tmux load-buffer/paste-buffer/send-keys sequence, gated by
# pane_owned_by_agent so a message never lands in a shell. report.sh (a local codex:/tmux: target)
# and relay.sh (an envelope's embedded local target) both call this; a message that arrived from
# another machine gets exactly the same scrutiny as one typed locally. <target> carries its
# codex:/tmux: prefix; on failure the reason is left in DELIVER_REASON rather than printed here,
# so each caller keeps its own error wording (report.sh's "delivery failed" block, relay.sh's log
# line).
DELIVER_REASON=""
deliver_to_local_target() {
  local sock="$1" target="$2" msg="$3" tt
  case "$target" in
    codex:*)
      codex queue --thread "${target#codex:}" --message "$msg" && return 0
      DELIVER_REASON='Codex queue refused the message; inspect before retrying to avoid duplicate reports'
      return 1;;
    tmux:*) target="${target#tmux:}";;
    *) DELIVER_REASON="unroutable local target: $target"; return 1;;
  esac
  tmux_on "$sock" has-session -t "=$target" 2>/dev/null || { DELIVER_REASON="orchestrator session $target is gone or unreachable"; return 1; }
  # Would the paste be run as a shell command? Only an agent at the terminal may receive it.
  pane_owned_by_agent "$sock" "$target" || { DELIVER_REASON="a shell owns $target now, not an agent"; return 1; }
  # One bracketed paste (-p) keeps embedded newlines from submitting early; the buffer is loaded
  # from stdin because tmux rejects command lines over ~16 KiB. The pause lets a slow UI ingest
  # the paste before Enter.
  tt="$(tmux_target "$target")"
  printf '%s' "$msg" | tmux_on "$sock" load-buffer -b "player-$$" - || { DELIVER_REASON="tmux could not load the message"; return 1; }
  # errexit is live inside callers with `set -e`: cleanup must not exit before the reason is set.
  tmux_on "$sock" paste-buffer -p -d -b "player-$$" -t "$tt" ||
    { tmux_on "$sock" delete-buffer -b "player-$$" 2>/dev/null || :; DELIVER_REASON="tmux could not paste into $target"; return 1; }
  sleep 0.3
  tmux_on "$sock" send-keys -t "$tt" Enter ||
    { DELIVER_REASON="tmux could not submit the message in $target; the paste succeeded, inspect before retrying"; return 1; }
  return 0
}
