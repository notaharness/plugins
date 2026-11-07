# Shared by the orchestrator scripts, the launcher and report.sh. Harness-neutral: bash + tmux
# + coreutils only. Owns the names of the tmux session user options ("tags") and the exact
# targeting rules; every other script reads the names from here.

# --- Session user options ("tags") -----------------------------------------------------------
# Every fact about a player session lives on the session itself, as a user option that dies with
# the session and is readable by anyone who can reach the server: no files. The keys are the
# shared tmux agent-session convention (github.com/notaharness/tmux-agent-conventions, schema 1):
# core keys @session-*, and Orchestra's registered extensions @session-x-orchestra-*, which n10
# reads too. All are local session options. Absent means unset; empty is absent; no sentinels.
# Values are single-line UTF-8 with no control characters (session_value_ok); readers go through
# RECORD_AWK, and a session without a valid record is foreign, whatever else it carries.
SESSION_SCHEMA=1
KEY_VERSION=@session-version              # 1: written last, and only on a valid record of Orchestra's own
KEY_AGENT=@session-agent                  # claude | codex | gemini | copilot | opencode | custom: the harness started
KEY_LAUNCHER=@session-launcher            # orchestra | n10: whichever program created the session
KEY_PANE=@session-pane                    # %N: the pane the harness runs in (respawn-pane keeps it)
KEY_CWD=@session-cwd                      # the checkout (worktree player) or the directory (dir player), resolved
KEY_WORKTREE=@session-worktree            # worktree sessions only: the checkout, symlink-resolved; the identity
KEY_REPO=@session-repo                    # worktree sessions only: the main checkout, symlink-resolved
KEY_STATUS=@session-status KEY_STATUS_KIND=@session-status-kind KEY_STATUS_AT=@session-status-at   # not published; withdrawn before a respawn
# Orchestra's extensions.
KEY_SESSION_TYPE=@session-x-orchestra-session-type  # worktree | dir
KEY_BRANCH=@session-x-orchestra-branch    # worktree sessions only: the branch spawned for, unsanitized (feature/x)
KEY_ORCHESTRATOR=@session-x-orchestra-orchestrator  # reporting target: claude:<uuid> | codex:<uuid> | tmux:<session>, maybe beam:<peer>/…
KEY_ORCH_CONFIG=@session-x-orchestra-orchestrator-config  # claude:<uuid> targets only: the orchestrator's Claude config dir
KEY_LAUNCHING=@session-x-orchestra-launching  # 1 while the placeholder pane exists; unset once the harness started
KEY_LAST_REPORT=@session-x-orchestra-last-report  # "<KIND> <ISO-8601 UTC> <outcome>" of the last report a transport accepted
KEY_CLAUDE_SESSION=@session-x-orchestra-claude-session  # dir players: the id of the Claude conversation the launcher started
KEY_TARGET=@session-x-orchestra-target    # an orchestrator's OWN session: the claude:/codex: target its players carry
KEY_N10_BRANCH=@session-x-n10-branch      # n10's extension, read only: the task branch of an n10 worktree session
SESSION_TYPE_WORKTREE=worktree            # a session's name is a label; its record says whose it is
SESSION_TYPE_DIR=dir                      # a player in an existing directory: no branch, no worktree, maybe no repo
nl=$'\n'                                  # assigned once: ANSI-C quoting inside ${x:+...} is not portable
TAB=$'\t'

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
# silently go over beam instead of asking this machine, and session_record's quiet failure swallows the
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
# --- Writing tags: one tmux command queue -----------------------------------------------------
# A queue is built with tq_* and run with tq_run as ONE tmux invocation, commands separated by
# a lone ";" argument. Within it core keys come first, then extensions, then @session-version,
# whatever order they were added in. tmux stops a queue at the first failing command, so a
# failure leaves the rest unwritten, the version included. An argument ending in ";" ends the
# command there (tmux strips it), so such a value carries "\;" instead. An empty value unsets
# the key: the convention reads empty as absent and allows no sentinels, so none is stored.
TQ_CORE=(); TQ_EXT=(); TQ_VERSION=(); TQ_ALL=()
tq_reset() { TQ_CORE=(); TQ_EXT=(); TQ_VERSION=(); }
_tq_add() {
  local key="$1"; shift
  case "$key" in
    "$KEY_VERSION") TQ_VERSION+=(';' "$@");;
    @session-x-*)   TQ_EXT+=(';' "$@");;
    *)              TQ_CORE+=(';' "$@");;
  esac
}
tmux_value() { case "$1" in *';') printf '%s\\;' "${1%;}";; *) printf '%s' "$1";; esac; }
# tq_set <session> <key> <value>: set the key when <value> may be published under it
# (session_value_ok), else unset it, so an unpublishable value is omitted, never truncated.
tq_set() {
  if session_value_ok "$2" "$3"; then _tq_add "$2" set-option -t "$(tmux_target "$1")" "$2" "$(tmux_value "$3")"
  else tq_unset "$1" "$2"; fi
}
tq_unset() { _tq_add "$2" set-option -u -t "$(tmux_target "$1")" "$2"; }
# tq_build: the queue as one argv, in TQ_ALL (empty when nothing was queued).
tq_build() {
  TQ_ALL=(${TQ_CORE[@]+"${TQ_CORE[@]}"} ${TQ_EXT[@]+"${TQ_EXT[@]}"} ${TQ_VERSION[@]+"${TQ_VERSION[@]}"})
  [ ${#TQ_ALL[@]} -eq 0 ] || TQ_ALL=("${TQ_ALL[@]:1}")          # drop the leading separator
}
# tq_run <socket>: run the queue on that server (tmux_on: honours ORCH_MACHINE), then clear it.
tq_run() {
  tq_build; tq_reset
  [ ${#TQ_ALL[@]} -eq 0 ] || tmux_on "$1" "${TQ_ALL[@]}"
}
# tag_set <socket> <session> <key> <value>; tag_unset <socket> <session> <key>: one key, one call.
tag_set()   { tq_reset; tq_set "$2" "$3" "$4"; tq_run "$1"; }
tag_unset() { tq_reset; tq_unset "$2" "$3"; tq_run "$1"; }

# --- Value encoding ---------------------------------------------------------------------------
# session_value_ok <key> <value>: may <value> be published under <key>? Every value: valid UTF-8,
# single line, no C0/C1 control characters, 1–4096 bytes. Agent and launcher: tokens,
# [a-z][a-z0-9-]{0,63}. Paths (cwd, worktree, repo, the orchestrator's config dir): absolute, no
# "." or ".." component, no empty component, no trailing "/" except "/" itself. Pane: %<digits>.
# The 32 KiB total for a record is not checked: Orchestra's values stay far below it. Byte
# semantics throughout (LC_ALL=C), whatever the caller's locale.
_SESSION_TEXT_RE=$'^([\x20-\x7e]|\xc2[\xa0-\xbf]|[\xc3-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf][\x80-\xbf]|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf][\x80-\xbf]|[\xf1-\xf3][\x80-\xbf][\x80-\xbf][\x80-\xbf]|\xf4[\x80-\x8f][\x80-\xbf][\x80-\xbf])+$'
session_value_ok() {
  local key="$1" v="$2" LC_ALL=C
  [ -n "$v" ] && [ "${#v}" -le 4096 ] && [[ "$v" =~ $_SESSION_TEXT_RE ]] || return 1
  case "$key" in
    "$KEY_AGENT"|"$KEY_LAUNCHER") [[ "$v" =~ ^[a-z][a-z0-9-]{0,63}$ ]];;
    "$KEY_PANE") [[ "$v" =~ ^%[0-9]+$ ]];;
    "$KEY_CWD"|"$KEY_WORKTREE"|"$KEY_REPO"|"$KEY_ORCH_CONFIG")
      [ "$v" = / ] && return 0
      case "$v" in /*) ;; *) return 1;; esac
      case "$v/" in *//*|*/./*|*/../*) return 1;; esac;;
    *) return 0;;
  esac
}

# --- Reading tags: one normalized record per session --------------------------------------------
# RECORD_FORMAT lists every key a reader needs, tab-separated, for a list-sessions/list-panes/
# display-message -F format; RECORD_AWK (with -v at=<first record column>) replaces those
# RECORD_KEYS columns with the RECORD_COLUMNS below, keeping any columns before and after:
#   launcher repo session-type branch worktree agent orchestrator orchestrator-config last-report
#   target launching claude-session ready pane orchestra-session-type
# A record is valid when @session-version is 1, agent and launcher are tokens, the launcher is
# orchestra or n10, and worktree/repo/cwd are absolute when present. A valid record with worktree
# and repo is a worktree player; one with launcher orchestra, session-type dir and a cwd is a dir
# player (its directory in the repo column); any other valid record (n10's agent tabs) has an
# empty session-type, so it is no player. An invalid record, or none, is foreign: every column is
# empty but the vendor extensions an orchestrator may still have put on it (orchestrator,
# orchestrator-config, last-report, target), which report.sh needs on an adopted session and
# which never make a session a player; so is orchestra-session-type, Orchestra's own extension as
# written, which the launcher needs even before a record is registered. branch is the launcher's
# own task-branch extension; pane is @session-pane of a valid record.
# ready is 1 when the record is Orchestra's own, unversioned and otherwise complete, i.e. when
# session_publish_version may register it.
RECORD_KEYS=("$KEY_VERSION" "$KEY_AGENT" "$KEY_LAUNCHER" "$KEY_CWD" "$KEY_WORKTREE" "$KEY_REPO"
  "$KEY_SESSION_TYPE" "$KEY_BRANCH" "$KEY_N10_BRANCH"
  "$KEY_ORCHESTRATOR" "$KEY_ORCH_CONFIG" "$KEY_LAST_REPORT" "$KEY_TARGET" "$KEY_LAUNCHING" "$KEY_CLAUDE_SESSION" "$KEY_PANE")
RECORD_FORMAT="$(k=""; for key in "${RECORD_KEYS[@]}"; do printf '%s#{%s}' "$k" "$key"; k="$TAB"; done)"
RECORD_COLUMNS=15
RECORD_AWK='
function tok(v) { return v ~ /^[a-z][a-z0-9-]*$/ && length(v) <= 64 }
function abs_or_unset(v) { return v == "" || v ~ /^\// }
BEGIN { FS = OFS = "\t" }
{
  i = at
  v = $(i); ag = $(i+1); la = $(i+2); cwd = $(i+3); wt = $(i+4); re = $(i+5); xty = $(i+6); xbr = $(i+7); nbr = $(i+8)
  orch = $(i+9); conf = $(i+10); last = $(i+11); targ = $(i+12); lnch = $(i+13); csid = $(i+14); pa = $(i+15)
  shaped = tok(ag) && (la == "orchestra" || la == "n10") && abs_or_unset(wt) && abs_or_unset(re) && abs_or_unset(cwd)
  ready = (v == "" && shaped && la == "orchestra" && ((xty == "worktree" && wt != "" && re != "") || (xty == "dir" && cwd != "" && wt == "" && re == ""))) ? 1 : ""
  s_la = ""; s_rp = ""; s_ty = ""; s_br = ""; s_wt = ""; s_ag = ""; s_ln = ""; s_cs = ""; s_pa = ""
  if (v == "1" && shaped) {
    s_la = la; s_ag = ag; s_ln = lnch; s_cs = csid; s_br = (la == "n10" ? nbr : xbr); s_pa = (pa ~ /^%[0-9]+$/ ? pa : "")
    if (wt != "" && re != "") { s_ty = "worktree"; s_rp = re; s_wt = wt }
    else if (la == "orchestra" && xty == "dir" && cwd != "") { s_ty = "dir"; s_rp = cwd; s_br = "" }
    else s_br = ""
  }
  out = ""
  for (k = 1; k < at; k++) out = out $k OFS
  out = out s_la OFS s_rp OFS s_ty OFS s_br OFS s_wt OFS s_ag OFS orch OFS conf OFS last OFS targ OFS s_ln OFS s_cs OFS ready OFS s_pa OFS xty
  for (k = at + nkeys; k <= NF; k++) out = out OFS $k
  print out
}'
# normalize_records <at>: RECORD_AWK over stdin, the record starting at column <at>; bytes, not characters.
normalize_records() { LC_ALL=C awk -v at="$1" -v nkeys="${#RECORD_KEYS[@]}" "$RECORD_AWK"; }
# split_tabs <line>: the tab-separated fields of <line> into the array F, empty fields kept (a
# whitespace IFS would make `read` collapse the empty fields of unset tags).
split_tabs() {
  local line="$1"; F=()
  while case "$line" in *"$TAB"*) true;; *) false;; esac; do F+=("${line%%"$TAB"*}"); line="${line#*"$TAB"}"; done
  F+=("$line")
}
# session_record <socket> <session>: that session's normalized record, from one display-message,
# into REC_LAUNCHER REC_REPO REC_TYPE REC_BRANCH REC_WORKTREE REC_AGENT REC_ORCHESTRATOR
# REC_ORCH_CONFIG REC_LAST_REPORT REC_TARGET REC_LAUNCHING REC_CLAUDE_SESSION REC_READY REC_PANE
# REC_ORCHESTRA_TYPE (all empty, and a nonzero status, when the session cannot be read).
session_record() {
  local line
  REC_LAUNCHER=""; REC_REPO=""; REC_TYPE=""; REC_BRANCH=""; REC_WORKTREE=""; REC_AGENT=""; REC_ORCHESTRATOR=""
  REC_ORCH_CONFIG=""; REC_LAST_REPORT=""; REC_TARGET=""; REC_LAUNCHING=""; REC_CLAUDE_SESSION=""; REC_READY=""
  REC_PANE=""; REC_ORCHESTRA_TYPE=""
  line="$(tmux_on "$1" display-message -p -t "$(tmux_target "$2")" "$RECORD_FORMAT" 2>/dev/null)" || return 1
  line="$(printf '%s\n' "${line%%$nl*}" | normalize_records 1)"
  split_tabs "$line"
  REC_LAUNCHER="${F[0]:-}"; REC_REPO="${F[1]:-}"; REC_TYPE="${F[2]:-}"; REC_BRANCH="${F[3]:-}"; REC_WORKTREE="${F[4]:-}"
  REC_AGENT="${F[5]:-}"; REC_ORCHESTRATOR="${F[6]:-}"; REC_ORCH_CONFIG="${F[7]:-}"; REC_LAST_REPORT="${F[8]:-}"
  REC_TARGET="${F[9]:-}"; REC_LAUNCHING="${F[10]:-}"; REC_CLAUDE_SESSION="${F[11]:-}"; REC_READY="${F[12]:-}"
  REC_PANE="${F[13]:-}"; REC_ORCHESTRA_TYPE="${F[14]:-}"
}
# session_publish_version <socket> <session>: register the session (@session-version, last) when
# its record is Orchestra's own, unversioned and otherwise complete; leave any other session as it
# is, so Orchestra never publishes a version on another tool's record. Fails only when the
# session cannot be read or the write fails.
session_publish_version() {
  session_record "$1" "$2" || return 1
  [ "$REC_READY" = 1 ] || return 0
  tag_set "$1" "$2" "$KEY_VERSION" "$SESSION_SCHEMA"
}

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
# claude:<session-id>, codex:<thread-id>, tmux:<session>, or beam:<orchestrator peerId>/<one of
# those three>, when the orchestrator is on another machine. Nothing else. Never infer a parent from
# a player's own ID. A Claude session id survives resume, compaction and renaming, and is random,
# where a tmux name is neither. tmux session names: tmux itself rewrites "." and ":" but otherwise
# allows most characters. peerId: 32 lowercase hex characters, the first 16 bytes of the SHA-256 of
# the peer's node public key (beam/docs/02-identity.md), validated in full wherever it arrives from
# outside.
_valid_local_target() {
  case "$1" in
    claude:*|codex:*) [[ "${1#*:}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]];;
    tmux:*) [[ -n "${1#tmux:}" && ! "${1#tmux:}" =~ [:[:cntrl:]] ]];;
    *) return 1;;
  esac
}
_TARGET_FORMS='claude:<session-id>, codex:<thread-id> or tmux:<session>'
normalize_target() {
  local local_part="$1" peer
  case "$1" in
    beam:*/*)
      local_part="${1#beam:}"; peer="${local_part%%/*}"; local_part="${local_part#*/}"
      [[ "$peer" =~ ^[0-9a-f]{32}$ ]] || { echo "invalid beam peerId: $peer" >&2; return 2; }
      case "$local_part" in claude:*|codex:*|tmux:*) ;;
        *) echo "invalid beam-qualified target: $1 (the local part must be $_TARGET_FORMS)" >&2; return 2;; esac;;
    claude:*|codex:*|tmux:*) ;;
    *) echo "invalid orchestrator target: $1 (use $_TARGET_FORMS, or beam:<peerId>/ followed by one of those)" >&2; return 2;;
  esac
  _valid_local_target "$local_part" || {
    case "$local_part" in
      claude:*) echo "invalid Claude session ID: ${local_part#claude:}" >&2;;
      codex:*) echo "invalid Codex thread ID: ${local_part#codex:}" >&2;;
      *) echo "invalid tmux session name: ${local_part#tmux:}" >&2;;
    esac
    return 2; }
  printf '%s' "$1"
}
# An explicit target wins. Inside Claude Code, the session id Claude exports to the commands it
# runs identifies the orchestrator even inside tmux, where $TMUX may name some other session; it is
# accepted only when Claude's registry entry for CLAUDE_PID confirms it (claude_own_session). A
# Codex ID identifies the orchestrator only when the caller is not a Claude session: Claude marks
# itself with CLAUDECODE, and any CODEX_* ID it sees is inherited from some unrelated Codex
# ancestor, so its players would otherwise report to the wrong conversation.
resolve_orchestrator() {
  if [[ -n "${1:-}" ]]; then normalize_target "$1"
  elif [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    claude_own_session || return 2
    normalize_target "claude:$CLAUDE_CODE_SESSION_ID"
  elif [[ -z "${CLAUDECODE:-}" && -n "${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}" ]]; then
    normalize_target "codex:${CODEX_THREAD_ID:-$CODEX_SESSION_ID}"
  elif [[ -n "${TMUX:-}" ]]; then
    # "What session am I in" is a question about this machine, never ORCH_MACHINE — see
    # tmux_local; a spawn.sh/adopt.sh run with --machine must still learn its OWN orchestrator
    # target from its own pane, not from whatever session happens to be current on the target.
    normalize_target "tmux:$(tmux_local display-message -p '#S')"
  else
    echo "Cannot identify orchestrator; pass --orchestrator $_TARGET_FORMS." >&2
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
    sh|bash|zsh|fish|dash|script|"")      # script(1): the launcher's wrapper around a resumed Claude
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
# Each live session has a registry file, <config dir>/sessions/<pid>.json, naming its
# "sessionId", its "messagingSocketPath", its start time ("procStart") and, in recent versions, the
# pid namespace its pid belongs to ("pidDomain": linux:<machine-id>:pid:[<namespace inode>]). A
# session that exits uncleanly leaves the file and its socket behind, so neither is proof of life.
# claude_pid_domain: this process's pidDomain, as Claude 2.1.280 writes it; fails where it cannot be read.
claude_pid_domain() {
  local id ns
  id="$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null)" && ns="$(readlink /proc/self/ns/pid 2>/dev/null)" &&
    [ -n "$id" ] && [ -n "$ns" ] && printf 'linux:%s:%s' "$id" "$ns"
}
# claude_registry_socket <registry json> <pid>: its inbox socket, only while the session that wrote
# it is alive — the pid exists, is in this pid namespace (when both sides say which), and, where
# /proc is available, started at the recorded "procStart", so a recycled pid is never taken for the
# session that used to hold it.
claude_registry_socket() {
  local json="$1" pid="$2" sock recorded domain own
  sock="$(json_string_field "$json" messagingSocketPath)" || return 1
  domain="$(json_string_field "$json" pidDomain || :)"
  if [ -n "$domain" ] && own="$(claude_pid_domain)"; then [ "$domain" = "$own" ] || return 1; fi
  kill -0 "$pid" 2>/dev/null || return 1
  recorded="$(json_string_field "$json" procStart || :)"
  if [ -n "$recorded" ] && [ -d /proc/self ]; then
    [ "$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')" = "$recorded" ] || return 1
  fi
  [ -S "$sock" ] && printf '%s' "$sock"
}
# claude_inbox_socket <pid>: the inbox socket of the Claude Code process <pid>. CLAUDE_CODE_MESSAGING_SOCKET
# is no help here: Claude exports it only to its own children, so the process's own environment
# holds, at most, a parent session's socket. The config directory is the one that process runs with
# (its CLAUDE_CONFIG_DIR, where /proc shows it), then this process's, then ~/.claude. Fails when no
# live socket is found; the caller then pastes instead, as it does when neither nc nor socat is
# installed to write to one.
claude_inbox_socket() {
  local pid="$1" own_dir="" dir json
  [ -r "/proc/$pid/environ" ] && own_dir="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -n1)"
  for dir in "$own_dir" "${CLAUDE_CONFIG_DIR:-}" "${HOME:-}/.claude"; do
    [ -n "$dir" ] && [ -f "$dir/sessions/$pid.json" ] || continue
    json="$(cat "$dir/sessions/$pid.json" 2>/dev/null)" || continue
    claude_registry_socket "$json" "$pid" && return 0
  done
  return 1
}
# claude_session_socket <config dir> <session id>: the inbox socket of the live session with that
# id, scanning every registry file under <config dir> (a claude:<session-id> target names no pid).
claude_session_socket() {
  local f pid json
  for f in "$1"/sessions/*.json; do
    pid="${f##*/}"; pid="${pid%.json}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    json="$(cat "$f" 2>/dev/null)" || continue
    [ "$(json_string_field "$json" sessionId || :)" = "$2" ] || continue
    claude_registry_socket "$json" "$pid" && return 0
  done
  return 1
}
# claude_own_session: does Claude's registry entry for CLAUDE_PID, under this process's config dir,
# name CLAUDE_CODE_SESSION_ID as a live session with an inbox? Guards resolve_orchestrator against
# an id inherited from some other session, or one no report could ever reach.
claude_own_session() {
  local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" json=""
  [[ "${CLAUDE_PID:-}" =~ ^[0-9]+$ ]] && json="$(cat "$dir/sessions/$CLAUDE_PID.json" 2>/dev/null)"
  [ -n "$json" ] && [ "$(json_string_field "$json" sessionId || :)" = "$CLAUDE_CODE_SESSION_ID" ] &&
    claude_registry_socket "$json" "$CLAUDE_PID" >/dev/null && return 0
  echo "Cannot identify orchestrator: CLAUDE_CODE_SESSION_ID $CLAUDE_CODE_SESSION_ID is not the session registered, live and with an inbox socket, for CLAUDE_PID ${CLAUDE_PID:-<unset>} in $dir/sessions; pass --orchestrator $_TARGET_FORMS." >&2
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
  CODEX_HOME="${thread#* }" codex queue --thread "${thread%% *}" --message "$1" >/dev/null </dev/null && return 0
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
# deliver_to_local_target <socket> <claude:…|codex:…|tmux:…> <text> [<Claude config dir>]: the one
# place a report (or a relayed envelope) is delivered on this machine — a Claude session's inbox,
# codex queue, or deliver_to_pane gated by pane_owned_by_agent so a message never lands in a shell.
# report.sh (a local target) and relay.sh (an envelope's embedded local target) both call this; a
# message that arrived from another machine gets exactly the same scrutiny as one typed locally.
# A claude: target is found in the registry under <Claude config dir>, else this process's
# CLAUDE_CONFIG_DIR, else ~/.claude; it names no pane, so it is never pasted anywhere, whatever
# fails. On success DELIVER_ROUTE says which way it went (inbox, queue or paste); on failure the
# reason is left in DELIVER_REASON rather than printed here, so each caller keeps its own error
# wording (report.sh's "delivery failed" block, relay.sh's log line).
deliver_to_local_target() {
  local sock="$1" target="$2" msg="$3" dir="${4:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}" inbox
  DELIVER_ROUTE=""
  case "$target" in
    claude:*)
      claude_inbox_client || { DELIVER_REASON="neither nc nor socat is installed to write to a Claude inbox socket"; return 1; }
      inbox="$(claude_session_socket "$dir" "${target#claude:}")" ||
        { DELIVER_REASON="no live Claude session ${target#claude:} is registered in $dir/sessions"; return 1; }
      claude_inbox_post "$inbox" "$msg" || { DELIVER_REASON="claude inbox socket refused the connection"; return 1; }
      DELIVER_ROUTE=inbox; return 0;;
    codex:*)
      codex queue --thread "${target#codex:}" --message "$msg" </dev/null && { DELIVER_ROUTE=queue; return 0; }
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
