#!/usr/bin/env bash
# Runs on the orchestrator's machine: subscribes to reports beamed in from remote players and
# delivers each one exactly as report.sh would deliver a local one — the same shared
# deliver_to_local_target sequence (a Claude session's inbox socket, load-buffer/paste-buffer/
# send-keys, or codex queue), gated by the same pane_owned_by_agent check for a pane, so a message
# that arrived from another machine gets no more trust than one typed locally. A claude: target is
# looked up under this relay's own $CLAUDE_CONFIG_DIR, else ~/.claude.
#
# Usage: relay.sh [--topic T] [--allow <local target>]...    default topic: orchestra
#   --allow claude:<session-id>|codex:<thread-id>|tmux:<session>
#                    an additional local target this relay may deliver to, repeatable. With no
#                    --allow, the only allowed target is the session relay.sh runs from: the Claude
#                    Code session ($CLAUDE_CODE_SESSION_ID) when run by one, else the tmux session
#                    ($TMUX), which requires running it inside a pane.
#
# Two rules:
#   - An envelope is acked only once local delivery has actually succeeded, never on receipt.
#     `beam msg listen` acks as soon as it has printed a line, so this subscribes on beam's
#     control socket itself (beam/docs/06-control-socket.md, beam/docs/05-mailbox.md) and settles
#     every envelope it is handed: `msg.ack` after delivery, `msg.defer` with the reason when it
#     refuses one or delivery fails. A subscriber holds one envelope at a time, so leaving one
#     unsettled would stall every report behind it. A deferred envelope stays in beam's inbound
#     store (`beam msg queue --which refused` lists it with its reason) and is offered again only
#     to a later subscription: after a failed delivery this relay reconnects once
#     ORCHESTRA_RELAY_RETRY seconds (default 30) have passed, so the report is tried again.
#   - The local targets this relay may deliver to come only from how it was started, never from
#     the envelope: an envelope's "target" field is data a peer sent, and honouring it unchecked
#     would let any paired peer paste into whatever session that peer names, the user's own
#     included. Default: the single session relay.sh was started from. --allow adds others.
#
# Run this directly only when supervising remote players from a plain terminal with nothing else
# already relaying — N10 Desktop runs its own relay, so do not run this alongside it. Requires a
# beam binary ($ORCHESTRA_BEAM, then `beam` on PATH; `beam status` starts its daemon when none is
# running) and socat or an nc with -U to speak to the daemon's socket: $BEAM_SOCKET, else
# run/beam.sock under $BEAM_CONFIG_DIR, $XDG_CONFIG_HOME/beam or ~/.config/beam. Exits 1 when the
# daemon closes the connection; nothing is lost, since an unsettled envelope goes back to beam.
# Always acts on this, the orchestrator's, machine, whatever --machine/$ORCHESTRA_MACHINE this
# process happens to inherit: ORCHESTRA_FORCE_LOCAL below pins that unconditionally.
set -u
ORCHESTRA_FORCE_LOCAL=1
. "$(dirname "$(realpath "$0")")/_lib.sh"
TOPIC=orchestra
ALLOW=()
RETRY="${ORCHESTRA_RELAY_RETRY:-30}"
while [ $# -gt 0 ]; do case "$1" in
  --topic) TOPIC="$2"; shift;;
  --allow)
    norm="$(normalize_target "$2")" || exit 2
    case "$norm" in
      claude:*|codex:*|tmux:*) ;;
      *) echo "relay.sh: --allow must be a local target ($_TARGET_FORMS): $2" >&2; exit 2;;
    esac
    ALLOW+=("$norm"); shift;;
  -h|--help) sed -n '2,14p' "$0"; exit 0;;
  *) echo "relay.sh: unknown argument $1" >&2; exit 2;; esac; shift; done
# Inside Claude Code, $TMUX can name a session that is not this one's (the pane Claude was started
# from, someone else's), so the session id comes first.
if [ "${#ALLOW[@]}" -eq 0 ]; then
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then ALLOW=("$(normalize_target "claude:$CLAUDE_CODE_SESSION_ID")") || exit 2
  elif [ -n "${TMUX:-}" ]; then ALLOW=("tmux:$(tmux_local display-message -p '#S')")
  else echo "relay.sh: not running inside a Claude Code session or a tmux pane, so there is no default target; pass --allow <target> at least once" >&2; exit 2; fi
fi
is_allowed() { local want="$1" have; for have in "${ALLOW[@]}"; do [ "$have" = "$want" ] && return 0; done; return 1; }
beam_cmd || { echo "relay.sh: $(beam_unresolved_message "this machine")" >&2; exit 1; }
"${BEAM_CMD[@]}" status >/dev/null 2>&1 || { echo "relay.sh: 'beam status' failed; is beam installed, and can it start its daemon here?" >&2; exit 1; }
if [ -n "${BEAM_SOCKET:-}" ]; then BEAM_SOCK="$BEAM_SOCKET"
elif [ -n "${BEAM_CONFIG_DIR:-}" ]; then BEAM_SOCK="$BEAM_CONFIG_DIR/run/beam.sock"
elif [ -n "${XDG_CONFIG_HOME:-}" ]; then BEAM_SOCK="$XDG_CONFIG_HOME/beam/run/beam.sock"
else BEAM_SOCK="$HOME/.config/beam/run/beam.sock"; fi
if command -v socat >/dev/null 2>&1; then CONNECT=(socat - "UNIX-CONNECT:$BEAM_SOCK")
elif command -v nc >/dev/null 2>&1; then CONNECT=(nc -U "$BEAM_SOCK")
else echo "relay.sh: neither socat nor nc is installed; one is needed to reach beam's control socket" >&2; exit 1; fi
SOCK="$(default_orchestrator_socket)"
trap '' PIPE                 # a daemon gone mid-write is an error to report, not a silent exit
echo "relay.sh: subscribing to topic '$TOPIC' on $BEAM_SOCK; may deliver to: ${ALLOW[*]} on $SOCK" >&2

# One control connection: newline-delimited JSON, requests `{ id, op, <params…> }` with the
# parameters beside op, replies `{ id, ok, result | error, detail? }`, and after msg.subscribe one
# `{ "event": "mail", "data": <envelope> }` line per envelope (beam/docs/06-control-socket.md).
REQ_ID=0; SUB_ID=0; TO_BEAM=""; FROM_BEAM=""; CONN_PID=""
declare -A OP_OF
send_op() {                  # send_op <op> [<params as JSON members>]
  REQ_ID=$((REQ_ID + 1)); OP_OF[$REQ_ID]="$1"
  printf '{"id":%d,"op":"%s"%s}\n' "$REQ_ID" "$1" "${2:+,$2}" >&"$TO_BEAM" ||
    { echo "relay.sh: could not write to beam's control socket" >&2; exit 1; }
}
connect() {
  coproc BEAM_CONN { exec "${CONNECT[@]}" 2>/dev/null; }
  CONN_PID="$BEAM_CONN_PID"
  exec {TO_BEAM}>&"${BEAM_CONN[1]}" {FROM_BEAM}<&"${BEAM_CONN[0]}"
  send_op msg.subscribe "\"topic\":$(json_str "$TOPIC")"; SUB_ID=$REQ_ID
}
disconnect() {
  [ -n "$CONN_PID" ] || return 0
  exec {TO_BEAM}>&- {FROM_BEAM}<&-
  kill "$CONN_PID" 2>/dev/null; wait "$CONN_PID" 2>/dev/null
  CONN_PID=""
}
trap disconnect EXIT
ack()   { send_op msg.ack "\"envelopeId\":$(json_str "$1")"; }
defer() {                    # defer <envelope id> <reason>; beam keeps at most 1 KiB of it
  local LC_ALL=C reason="$2"
  send_op msg.defer "\"envelopeId\":$(json_str "$1"),\"reason\":$(json_str "${reason:0:1000}")"
}
RETRY_AT=0
retry_later() { [ "$RETRY_AT" -gt 0 ] || RETRY_AT=$((SECONDS + RETRY)); }

# b64url_decode: beam's base64 payloads are unpadded base64url (beam/docs/05-mailbox.md).
b64url_decode() {
  local s; s="$(printf '%s' "$1" | tr -- '-_' '+/')"
  case $(( ${#s} % 4 )) in 2) s+='==';; 3) s+='=';; 1) return 1;; esac
  printf '%s' "$s" | base64 -d 2>/dev/null
}

handle_mail() {
  local line="$1" id from payload_raw encoding payload header_line local_target message
  id="$(json_string_field "$line" id)" || { echo "relay.sh: a mail event carries no envelope id; it cannot be settled" >&2; return; }
  from="$(json_string_field "$line" from || :)"
  payload_raw="$(json_string_field "$line" payload)" || { echo "relay.sh: envelope $id has no payload; deferred" >&2; defer "$id" "no payload"; return; }
  encoding="$(json_string_field "$line" encoding || :)"
  case "$encoding" in
    base64) payload="$(b64url_decode "$payload_raw")" || { echo "relay.sh: envelope $id payload is not valid base64url; deferred" >&2; defer "$id" "payload is not valid base64url"; return; };;
    *) payload="$payload_raw";;
  esac
  # The envelope's payload carries a one-line "target: <local>" header, a blank line, then the
  # report text — the framing report.sh's beam branch composes, chosen because beam's envelope
  # only carries an opaque payload and gives relay.sh nowhere else to learn the local target. That
  # target is still just data the sender wrote: normalize_target and the allowlist below are what
  # decide whether relay.sh may act on it — not its presence in the envelope.
  header_line="${payload%%$nl*}"
  case "$header_line" in
    "target: "*) local_target="${header_line#target: }";;
    *) echo "relay.sh: envelope $id has no 'target: ' header; deferred" >&2; defer "$id" "no 'target: ' header"; return;;
  esac
  local_target="$(normalize_target "$local_target" 2>/dev/null)" || {
    echo "relay.sh: envelope $id names an invalid local target; deferred" >&2; defer "$id" "invalid local target"; return; }
  if ! is_allowed "$local_target"; then
    echo "relay.sh: envelope $id from peer ${from:-<unknown>} names $local_target, outside this relay's allowlist (${ALLOW[*]}); refused (deferred)" >&2
    defer "$id" "$local_target is outside this relay's allowlist"
    return
  fi
  case "$payload" in *"$nl"*) message="${payload#*"$nl"}"; message="${message#"$nl"}";; *) message="";; esac
  if deliver_to_local_target "$SOCK" "$local_target" "$message"; then
    ack "$id"
    echo "relay.sh: delivered to $local_target ($DELIVER_ROUTE)" >&2
  else
    defer "$id" "delivery to $local_target failed: $DELIVER_REASON"
    retry_later
    echo "relay.sh: could not deliver to $local_target: $DELIVER_REASON (deferred; retrying in ${RETRY}s)" >&2
  fi
}

handle_reply() {
  local line="$1" id op err detail
  [[ "$line" =~ \"id\":([0-9]+) ]] || return 0
  id="${BASH_REMATCH[1]}"; op="${OP_OF[$id]:-request $id}"; unset "OP_OF[$id]"
  case "$line" in *'"ok":true'*) return 0;; esac
  err="$(json_string_field "$line" error || :)"; detail="$(json_string_field "$line" detail || :)"
  if [ "$id" = "$SUB_ID" ]; then
    echo "relay.sh: beam refused the subscription: ${err:-unknown error}${detail:+ ($detail)}" >&2; exit 1
  fi
  echo "relay.sh: beam refused $op: ${err:-unknown error}${detail:+ ($detail)}" >&2
}

connect
buf=""
while :; do
  if IFS= read -r -t 1 chunk <&"$FROM_BEAM"; then
    line="$buf$chunk"; buf=""
    case "$(json_string_field "$line" event 2>/dev/null)" in
      mail) handle_mail "$line";;
      "") handle_reply "$line";;
      *) ;;                                           # other events are not this relay's business
    esac
  elif [ $? -gt 128 ]; then
    buf+="$chunk"                                     # timed out mid-line: keep what arrived
  else
    echo "relay.sh: the beam daemon closed the connection; unsettled reports stay with beam — restart relay.sh" >&2
    exit 1
  fi
  if [ "$RETRY_AT" -gt 0 ] && [ "$SECONDS" -ge "$RETRY_AT" ]; then
    # A fresh connection is a subscription made after the defers, so beam offers them again.
    # Whatever the old connection was handed but never read goes back to beam when it closes.
    RETRY_AT=0; buf=""; disconnect; connect
  fi
done
