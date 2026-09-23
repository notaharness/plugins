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
TAG_LAST_REPORT=@orchestra-last-report    # "<KIND> <ISO-8601 UTC> <outcome>" of the last report a transport accepted
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
# beam_cmd: resolve how to invoke beam into the BEAM_CMD array. First hit wins: $ORCHESTRA_BEAM,
# then `beam` on PATH. Fails, leaving BEAM_CMD unset, when neither resolves — callers must not fall back to running
# anything locally on that failure, which would silently act on the wrong machine.
beam_cmd() {
  if [ -n "${ORCHESTRA_BEAM:-}" ]; then BEAM_CMD=("$ORCHESTRA_BEAM"); return 0; fi
  if command -v beam >/dev/null 2>&1; then BEAM_CMD=(beam); return 0; fi
  return 1
}
beam_unresolved_message() {
  printf "no beam binary found to reach machine '%s' (tried \$ORCHESTRA_BEAM and 'beam' on PATH)" "$1"
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
# string one character at a time. A 100 KiB payload (beam enforces 256 KiB) used to take ~45s
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

# json_str <text>: <text> as one JSON string literal, quotes included — the encoder matching the
# decoders above, so building a line for beam's control socket or Claude's inbox needs no jq. A
# backslash and a quote are escaped, the five control characters with short forms get them, and
# every other one below U+0020 becomes \u00XX; everything else, non-ASCII included, is copied
# through as the bytes it is (JSON text is UTF-8). One native substitution per character class,
# each linear in the length of <text>.
json_str() {
  local s="$1" i c
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"; s="${s//$'\b'/\\b}"; s="${s//$'\f'/\\f}"
  for i in 1 2 3 4 5 6 7 11 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    printf -v c "\\$(printf %03o "$i")"
    case "$s" in *"$c"*) s="${s//"$c"/$(printf '\\u%04x' "$i")}";; esac
  done
  printf '"%s"' "$s"
}

# json_array_objects <json> [<field>]: the object elements of a JSON array, into the array
# JSON_OBJECTS (a global: setting one keeps the caller out of a subshell). With <field>, the array
# is that field's value (`beam peers --json` prints `{ "peers": [...] }`; the field is the first
# key, so its first occurrence is the key itself — a string value equal to it would come later);
# without, it is the first "[" in <json>. A real scanner, not a brace matcher: it tracks string
# state and backslash escapes, so a "{", "}", "[" or "]" inside a string value nests nothing and
# ends nothing — a peer's label is chosen on another machine, and one containing "}" must not cut
# that peer's object short and desynchronise every element after it. It stops at the array's own
# closing "]", so whatever encloses the array is never scanned. Like the two scanners above it
# jumps to the next character that matters with one native pattern match per step rather than
# walking character by character, so it stays linear in the length of the document. Fails,
# leaving JSON_OBJECTS empty, on anything that is not a well-formed array: no half-parsed answer,
# since the alternative to one peer row is none.
json_array_objects() {
  local s="$1" field="${2:-}" q='"' orig pos=0 depth=1 start=0 head ch
  JSON_OBJECTS=()
  if [ -n "$field" ]; then
    case "$s" in *"\"$field\""*) ;; *) return 1;; esac
    s="${s#*"\"$field\""}"; s="${s#"${s%%[![:space:]]*}"}"
    [ "${s:0:1}" = : ] || return 1
    s="${s:1}"; s="${s#"${s%%[![:space:]]*}"}"
    [ "${s:0:1}" = '[' ] || return 1
  else
    case "$s" in *\[*) ;; *) return 1;; esac
    s="[${s#*\[}"
  fi
  s="${s:1}"; orig="$s"
  while [ -n "$s" ]; do
    head="${s%%[$q{\}\[\]]*}"                         # the next quote, brace or bracket, if any
    [ "${#head}" -lt "${#s}" ] || break
    ch="${s:${#head}:1}"; pos=$((pos + ${#head} + 1)); s="${s:${#head}+1}"
    case "$ch" in
      '"')                                             # inside a string nothing is structural
        while :; do
          head="${s%%[\\$q]*}"
          [ "${#head}" -lt "${#s}" ] || { JSON_OBJECTS=(); return 1; }   # no closing quote
          if [ "${s:${#head}:1}" = '\' ]; then pos=$((pos + ${#head} + 2)); s="${s:${#head}+2}"
          else pos=$((pos + ${#head} + 1)); s="${s:${#head}+1}"; break; fi
        done;;
      '{'|'[') if [ "$depth" -eq 1 ] && [ "$ch" = '{' ]; then start=$((pos - 1)); fi; depth=$((depth + 1));;
      *)   depth=$((depth - 1))                        # "}" or "]"
           if [ "$depth" -eq 0 ]; then [ "$ch" = ']' ] && return 0; break; fi
           if [ "$depth" -eq 1 ] && [ "$ch" = '}' ]; then JSON_OBJECTS+=("${orig:start:pos-start}"); fi;;
    esac
  done
  JSON_OBJECTS=(); return 1                            # ran out before the array's closing "]"
}

# --- Which tmux server another machine's sessions live on -------------------------------------
# On this machine, "no socket" means the server $TMUX names, else the one tmux itself picks, and
# a bare `tmux` finds it. Neither holds for a machine reached through beam: its exec carries no
# $TMUX and no shell, so a bare remote `tmux` resolves ITS default socket while anything that
# passed an explicit -S addressed whatever path this machine computed — two different servers as
# soon as the target's default is not "/tmp/tmux-<uid>" (a target with $TMUX_TMPDIR set, or a
# build whose default directory differs, such as one keeping sockets under $TMPDIR). A session
# created on one is then invisible on the other: "no such session" for a player that is alive.
# So the socket is resolved once per machine, by asking the TARGET rather than computing a path
# here: its running tmux for the socket it is actually on, and, when no server runs there yet,
# tmux's documented rule ($TMUX_TMPDIR else /tmp, tmux(1) -L) evaluated by a shell on the target,
# with its own environment and its own uid. Every tmux call for that machine then carries that
# one path, so spawn.sh and every later command address the same server.
MACHINE_SOCKET=""                     # resolved by machine_socket; empty means this machine
_MACHINE_SOCKET_KEY=""; _MACHINE_SOCKET_VALUE=""
_MACHINE_SOCKET_PROBE='tmux -u display-message -p "#{socket_path}" 2>/dev/null ||
  printf "%s/tmux-%s/default" "${TMUX_TMPDIR:-/tmp}" "$(id -u)"'
# machine_socket: sets MACHINE_SOCKET for ORCH_MACHINE, cached per machine (one round trip, not
# one per tmux call — scripts that make several calls resolve it once at top level so the cache
# is warm in the subshells that follow). Fails, leaving MACHINE_SOCKET empty, when the machine
# cannot be reached; callers must not fall back to a local server on that failure.
machine_socket() {
  MACHINE_SOCKET=""
  if is_local_machine; then return 0; fi
  if [ "$_MACHINE_SOCKET_KEY" = "$ORCH_MACHINE" ]; then MACHINE_SOCKET="$_MACHINE_SOCKET_VALUE"; return 0; fi
  local sock
  sock="$(beam_exec "$ORCH_MACHINE" sh -c "$_MACHINE_SOCKET_PROBE")" || return 1
  sock="${sock%%$nl*}"
  [ -n "$sock" ] || { echo "orchestra: could not determine which tmux socket to use on $ORCH_MACHINE" >&2; return 1; }
  _MACHINE_SOCKET_KEY="$ORCH_MACHINE"; _MACHINE_SOCKET_VALUE="$sock"; MACHINE_SOCKET="$sock"
}

# tmux sanitizes what it prints unless the client is in UTF-8 mode, which it infers from the names
# of LC_ALL/LC_CTYPE/LANG: outside a UTF-8 locale control characters (such as the tabs between
# listing fields) and non-ASCII come back as "_". `tmux -u` forces UTF-8 output whatever the locale, so every call goes through it.
# tmux_on <socket> <args…>: tmux on one server. An empty socket means the current server (the
# one $TMUX names, else the default); a path is passed as -S so a process whose tmux environment
# is redirected (every player pane) still reaches the server that holds its session. On the local
# machine (ORCH_MACHINE unset/empty/"local") this is exactly today's invocation, unchanged; on any
# other machine the identical argv runs there instead, through beam_exec — always with an explicit
# -S, since a remote tmux has no $TMUX to inherit and every caller has to mean the same server.
tmux_on() {
  local sock="$1"; shift
  if is_local_machine; then
    if [ -n "$sock" ]; then tmux -u -S "$sock" "$@"; else tmux -u "$@"; fi
  else
    if [ -z "$sock" ]; then machine_socket || return 1; sock="$MACHINE_SOCKET"; fi
    beam_exec "$ORCH_MACHINE" tmux -u -S "$sock" "$@"
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
# peerId: 32 lowercase hex characters, the first 16 bytes of the SHA-256 of the peer's node public
# key (beam/docs/02-identity.md), validated in full wherever it arrives from outside.
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
      [[ "$peer" =~ ^[0-9a-f]{32}$ ]] || { echo "invalid beam peerId: $peer" >&2; return 2; }
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
# process_agent <pid> [<name>]: prints "<pid> <agent>" when that process is an agent binary (by
# its comm or its argv[0]) and not suspended: in the foreground process group, or, given <name>,
# named exactly that — tmux has already said which command is in the foreground.
process_agent() {
  local pid="$1" want="${2:-}" stat comm argv0 name
  stat="$(ps -o stat= -p "$pid" 2>/dev/null)"
  case "$stat" in ""|T*) return 1;; esac
  [ -n "$want" ] || case "$stat" in *+*) ;; *) return 1;; esac
  comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
  argv0="$(ps -o args= -p "$pid" 2>/dev/null | awk '{print $1}')"
  for name in "$comm" "${argv0##*/}"; do
    is_agent_name "$name" || continue
    [ -z "$want" ] || [ "$name" = "$want" ] || continue
    printf '%s %s' "$pid" "$name"; return 0
  done
  return 1
}
# pane_has_agent <pid> [<name>]: prints "<pid> <agent>" for the first agent process below <pid>
# (see process_agent); fails when there is none.
pane_has_agent() {
  local pid="$1" want="${2:-}" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    process_agent "$child" "$want" && return 0
    pane_has_agent "$child" "$want" && return 0
  done
  return 1
}
# pane_owned_by_agent <socket> <session>: true when the session's pane is alive and an agent (not a
# shell) is at the terminal. The socket selects the server as in tmux_on. On this machine it also
# leaves the agent's pid and name in PANE_AGENT_PID and PANE_AGENT (both empty when the foreground
# command is not a known agent binary, such as an editor, or the pane is on another machine).
PANE_AGENT_PID=""; PANE_AGENT=""
pane_owned_by_agent() {
  local sock="$1" session="$2" cmd pid agent=""
  PANE_AGENT_PID=""; PANE_AGENT=""
  [ "$(tmux_on "$sock" display-message -p -t "$(tmux_target "$session")" '#{pane_dead}' 2>/dev/null)" = 0 ] || return 1
  cmd="$(tmux_on "$sock" display-message -p -t "$(tmux_target "$session")" '#{pane_current_command}' 2>/dev/null)"
  case "$cmd" in
    sh|bash|zsh|fish|dash|"")
      pid="$(tmux_on "$sock" display-message -p -t "$(tmux_target "$session")" '#{pane_pid}' 2>/dev/null)"
      agent="$(pane_has_agent "$pid")" || return 1;;
    *)
      if is_local_machine && is_agent_name "$cmd"; then
        pid="$(tmux_on "$sock" display-message -p -t "$(tmux_target "$session")" '#{pane_pid}' 2>/dev/null)"
        agent="$(process_agent "$pid" "$cmd" || pane_has_agent "$pid" "$cmd")" || agent=""
      fi;;
  esac
  if [ -n "$agent" ]; then PANE_AGENT_PID="${agent%% *}"; PANE_AGENT="${agent#* }"; fi
  return 0
}

# --- Claude Code's inbox socket ----------------------------------------------------------------
# Claude Code (2.1.224 and later) binds a per-session Unix socket that takes one NDJSON line,
# {"type":"user","message":{"role":"user","content":"<text>"}}, and hands it to that session as a
# cross-session message: read between tool calls while it works, a new turn while it is idle,
# never typed into its prompt box (https://code.claude.com/docs/en/cross-session-messaging).
# claude_inbox_socket <pid>: that socket for the Claude Code process <pid>, from the registry file
# Claude writes for each live session, <config dir>/sessions/<pid>.json ("messagingSocketPath").
# CLAUDE_CODE_MESSAGING_SOCKET is no help here: Claude exports it only to its own children, so the
# process's own environment holds, at most, a parent session's socket. The config directory is
# the one that process runs with (its CLAUDE_CONFIG_DIR, where /proc shows it), then this
# process's, then ~/.claude. Where /proc is available the file's "procStart" must match the
# process's start time, so a recycled pid is never taken for the session that used to hold it.
# Fails when no live socket is found; the caller then pastes instead, as it does when neither nc
# nor socat is installed to write to one.
claude_inbox_socket() {
  local pid="$1" own_dir="" dir json sock recorded started
  [ -r "/proc/$pid/environ" ] && own_dir="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -n1)"
  for dir in "$own_dir" "${CLAUDE_CONFIG_DIR:-}" "${HOME:-}/.claude"; do
    [ -n "$dir" ] && [ -f "$dir/sessions/$pid.json" ] || continue
    json="$(cat "$dir/sessions/$pid.json" 2>/dev/null)" || continue
    sock="$(json_string_field "$json" messagingSocketPath)" || continue
    recorded="$(json_string_field "$json" procStart || :)"
    if [ -n "$recorded" ] && [ -r "/proc/$pid/stat" ]; then
      started="$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')"
      [ "$started" = "$recorded" ] || continue
    fi
    [ -S "$sock" ] || continue
    printf '%s' "$sock"; return 0
  done
  return 1
}
# claude_inbox_client: can this machine write to a Unix socket at all (nc -N -U, else socat)?
claude_inbox_client() { command -v nc >/dev/null 2>&1 || command -v socat >/dev/null 2>&1; }
# claude_inbox_post <socket> <text>: one frame, then EOF. Fails when the socket refuses it.
claude_inbox_post() {
  local frame
  frame="{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":$(json_str "$2")}}"
  if command -v nc >/dev/null 2>&1; then printf '%s\n' "$frame" | nc -N -U "$1" >/dev/null 2>&1
  else printf '%s\n' "$frame" | socat - "UNIX-CONNECT:$1" >/dev/null 2>&1; fi
}

# --- Codex's queue for a running TUI -----------------------------------------------------------
# `codex queue --thread <id> --message <text>` hands a message to a running Codex conversation as
# its next turn, and a `$skill` mention in it loads that skill as if typed. The thread id is not in
# the pane, the process's arguments or its environment; it is the UUID in the name of the rollout
# file the TUI holds open, <CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<time>-<uuid>.jsonl. A TUI also
# holds its subagents' rollouts (a guardian review, say), whose session_meta line names a
# parent_thread_id; those are skipped. Codex writes the rollout only once the conversation's first
# turn starts, so a TUI that has not had one has no thread to address yet.
# open_files <pid>: the paths a process holds open (/proc, else lsof).
open_files() {
  if [ -d "/proc/$1/fd" ]; then
    local l; for l in "/proc/$1/fd"/*; do readlink "$l" 2>/dev/null; done
  elif command -v lsof >/dev/null 2>&1; then
    lsof -Fn -p "$1" 2>/dev/null | sed -n 's/^n//p'
  fi
}
process_tree() { local c; printf '%s\n' "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do process_tree "$c"; done; }
# codex_pane_thread <pid>: "<thread id> <CODEX_HOME>" for the Codex TUI running as <pid> or below
# it; fails when it holds no top-level rollout, or more than one.
codex_pane_thread() {
  local p f first id found=""
  for p in $(process_tree "$1"); do
    while IFS= read -r f; do
      case "$f" in */sessions/*/rollout-*.jsonl) ;; *) continue;; esac
      first="$(head -n1 "$f" 2>/dev/null)" || continue
      case "$first" in *'"session_meta"'*) ;; *) continue;; esac
      case "$first" in *'"parent_thread_id"'*) continue;; esac
      id="$(json_string_field "$first" id)" || continue
      [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || continue
      case "$found" in "") found="$id ${f%%/sessions/*}";; "$id "*) ;; *) return 1;; esac
    done < <(open_files "$p")
  done
  [ -n "$found" ] && printf '%s' "$found"
}
# codex_queue_pane <text>: queue <text> for the Codex TUI pane_owned_by_agent found (its own
# CODEX_HOME, which need not be this process's). 0 queued; 1 codex refused it (DELIVER_REASON set:
# final, since the message may have been queued); 2 no thread to address, so the caller pastes.
codex_queue_pane() {
  local thread
  [ "$PANE_AGENT" = codex ] && thread="$(codex_pane_thread "$PANE_AGENT_PID")" || return 2
  CODEX_HOME="${thread#* }" codex queue --thread "${thread%% *}" --message "$1" >/dev/null && return 0
  DELIVER_REASON="codex queue refused the message for thread ${thread%% *}; inspect before retrying to avoid duplicates"
  return 1
}

# --- Shared local delivery ---------------------------------------------------------------------
# paste_into_pane <socket> <session> <text>: one bracketed paste (-p keeps embedded newlines from
# submitting early), then Enter. The text goes through load-buffer on stdin because tmux rejects
# command lines over ~16 KiB; the pause lets a slow UI ingest the paste before Enter. The socket
# selects the server as in tmux_on. On failure the reason is left in DELIVER_REASON.
paste_into_pane() {
  local sock="$1" session="$2" text="$3" tt buf="orchestra-$$"
  tt="$(tmux_target "$session")"
  printf '%s' "$text" | tmux_on "$sock" load-buffer -b "$buf" - || { DELIVER_REASON="tmux could not load the message"; return 1; }
  # errexit is live inside callers with `set -e`: cleanup must not exit before the reason is set.
  tmux_on "$sock" paste-buffer -p -d -b "$buf" -t "$tt" ||
    { tmux_on "$sock" delete-buffer -b "$buf" 2>/dev/null || :; DELIVER_REASON="tmux could not paste into $session"; return 1; }
  sleep 0.3
  tmux_on "$sock" send-keys -t "$tt" Enter ||
    { DELIVER_REASON="tmux could not submit the message in $session; the paste succeeded, inspect before retrying"; return 1; }
}
# deliver_to_pane <socket> <session> <text>: the message to the agent in that pane, after
# pane_owned_by_agent has run for it, by the first route that pane can take:
#   inbox  Claude Code with a live inbox socket (claude_inbox_socket): a queued cross-session
#          message. It carries text only — Claude never runs a slash command or skill invocation
#          that arrives this way, so an invocation (spawn.sh, adopt.sh) is never sent through it.
#   queue  a Codex TUI whose thread is discoverable (codex_pane_thread): `codex queue`, which
#          carries text and `$skill` mentions alike.
#   paste  anything else — another agent, an older Claude, a Codex TUI before its first turn, a
#          pane on another machine (the agent lookup only runs locally), no nc/socat: one bracketed
#          paste and Enter.
# Once the inbox or the queue has been tried, a failure is final: falling back to a paste could
# deliver twice. Sets DELIVER_ROUTE (inbox, queue or paste), or DELIVER_REASON on failure.
DELIVER_REASON=""; DELIVER_ROUTE=""
deliver_to_pane() {
  local sock="$1" session="$2" msg="$3" inbox rc
  DELIVER_ROUTE=""
  if [ "$PANE_AGENT" = claude ] && claude_inbox_client && inbox="$(claude_inbox_socket "$PANE_AGENT_PID")"; then
    claude_inbox_post "$inbox" "$msg" || { DELIVER_REASON="claude inbox socket refused the connection"; return 1; }
    DELIVER_ROUTE=inbox; return 0
  fi
  codex_queue_pane "$msg" && rc=0 || rc=$?
  case "$rc" in 0) DELIVER_ROUTE=queue; return 0;; 1) return 1;; esac
  paste_into_pane "$sock" "$session" "$msg" || return 1
  DELIVER_ROUTE=paste
}
# deliver_to_local_target <socket> <codex:…|tmux:…> <text>: the one place a report (or a relayed
# envelope) is delivered on this machine — codex queue, or deliver_to_pane gated by
# pane_owned_by_agent so a message never lands in a shell. report.sh (a local codex:/tmux: target)
# and relay.sh (an envelope's embedded local target) both call this; a message that arrived from
# another machine gets exactly the same scrutiny as one typed locally. On success DELIVER_ROUTE
# says which way it went (queue, inbox or paste); on failure the reason is left in DELIVER_REASON
# rather than printed here, so each caller keeps its own error wording (report.sh's "delivery
# failed" block, relay.sh's log line).
deliver_to_local_target() {
  local sock="$1" target="$2" msg="$3"
  DELIVER_ROUTE=""
  case "$target" in
    codex:*)
      codex queue --thread "${target#codex:}" --message "$msg" && { DELIVER_ROUTE=queue; return 0; }
      DELIVER_REASON='Codex queue refused the message; inspect before retrying to avoid duplicate reports'
      return 1;;
    tmux:*) target="${target#tmux:}";;
    *) DELIVER_REASON="unroutable local target: $target"; return 1;;
  esac
  tmux_on "$sock" has-session -t "=$target" 2>/dev/null || { DELIVER_REASON="orchestrator session $target is gone or unreachable"; return 1; }
  # Would the paste be run as a shell command? Only an agent at the terminal may receive it.
  pane_owned_by_agent "$sock" "$target" || { DELIVER_REASON="a shell owns $target now, not an agent"; return 1; }
  deliver_to_pane "$sock" "$target" "$msg"
}
