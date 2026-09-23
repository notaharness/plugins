#!/usr/bin/env bash
# Runs on the orchestrator's machine: listens for reports beamed in from remote players and
# delivers each one exactly as report.sh would deliver a local one — the same shared
# deliver_to_local_target sequence (load-buffer/paste-buffer/send-keys, or codex queue), gated by
# the same pane_owned_by_agent check, so a message that arrived from another machine gets no more
# trust than one typed locally.
#
# Two rules settled after the phase 6 review found them missing (docs/beam.md's acknowledgement
# section; decisions.md D13/D14):
#   - An envelope is acked (`beam msg listen --require-ack`) only once local delivery has actually
#     succeeded, never on receipt. Acking first and then failing to deliver would destroy a report
#     the sender was already told had arrived — worse than the `queued` case the mailbox exists to
#     make safe, because the sender has no reason to doubt it.
#   - The local targets this relay may deliver to come only from how it was started, never from
#     the envelope: an envelope's "target" field is data a peer sent, and honouring it unchecked
#     would let any paired peer paste into whatever session that peer names, the user's own
#     included. Default: the single session relay.sh was started from. --allow adds others.
#
# Usage: relay.sh [--topic T] [--allow <local target>]...    default topic: orchestra
#   --allow codex:<thread-id>|tmux:<session>   an additional local target this relay may deliver
#                                               to, repeatable. With no --allow, the only allowed
#                                               target is the session relay.sh runs from ($TMUX);
#                                               that requires running it inside a pane.
#
# Run this directly only when supervising remote players from a plain terminal with nothing else
# already relaying — N10 Desktop runs its own relay, so do not run this alongside it; two
# listeners on the same topic would both try to deliver the same envelopes. Requires a beam
# binary (see _routing.sh's beam_cmd: $ORCHESTRA_BEAM, then `beam` on PATH) and
# a running local beam node (`beam serve`) so `beam msg listen` has something to listen through.
# Always acts on this, the orchestrator's, machine, whatever --machine/$ORCHESTRA_MACHINE this
# process happens to inherit: ORCHESTRA_FORCE_LOCAL below pins that unconditionally.
set -u
ORCHESTRA_FORCE_LOCAL=1
. "$(dirname "$(realpath "$0")")/_lib.sh"
TOPIC=orchestra
ALLOW=()
while [ $# -gt 0 ]; do case "$1" in
  --topic) TOPIC="$2"; shift;;
  --allow)
    norm="$(normalize_target "$2")" || exit 2
    case "$norm" in
      codex:*|tmux:*) ;;
      *) echo "relay.sh: --allow must be a local target (codex:<thread-id> or tmux:<session>): $2" >&2; exit 2;;
    esac
    ALLOW+=("$norm"); shift;;
  -h|--help) sed -n '2,24p' "$0"; exit 0;;
  *) echo "relay.sh: unknown argument $1" >&2; exit 2;; esac; shift; done
if [ "${#ALLOW[@]}" -eq 0 ]; then
  [ -n "${TMUX:-}" ] || { echo "relay.sh: not running inside a tmux pane, so there is no default target; pass --allow <target> at least once" >&2; exit 2; }
  ALLOW=("tmux:$(tmux_local display-message -p '#S')")
fi
is_allowed() { local want="$1" have; for have in "${ALLOW[@]}"; do [ "$have" = "$want" ] && return 0; done; return 1; }
beam_cmd || { echo "relay.sh: $(beam_unresolved_message "this machine")" >&2; exit 1; }
SOCK="$(default_orchestrator_socket)"
echo "relay.sh: listening for topic '$TOPIC'; may deliver to: ${ALLOW[*]} on $SOCK" >&2

# The ack channel (D13): a FIFO this shell holds open on both ends, so a write never blocks or
# SIGPIPEs just because the listener has not read it yet, feeds the listener's stdin. The delivery
# loop below — the other side of the envelope pipe — writes an id to it only once
# deliver_to_local_target has actually succeeded; an id never written stays unacked, and the real
# CLI (docs/beam.md) redelivers it later.
ACKFIFO="$(mktemp -u "${TMPDIR:-/tmp}/orchestra-relay-ack.XXXXXX")"
mkfifo "$ACKFIFO" || { echo "relay.sh: could not create the ack fifo" >&2; exit 1; }
exec 8<>"$ACKFIFO"
cleanup() { exec 8>&- 2>/dev/null; rm -f "$ACKFIFO"; }
trap cleanup EXIT

"${BEAM_CMD[@]}" msg listen --topic "$TOPIC" --require-ack <&8 | while IFS= read -r envelope; do
  [ -n "$envelope" ] || continue
  id="$(json_string_field "$envelope" id)" || { echo "relay.sh: envelope has no id; skipped (left unacked)" >&2; continue; }
  from="$(json_string_field "$envelope" from || :)"
  payload_raw="$(json_string_field "$envelope" payload)" || { echo "relay.sh: envelope $id has no payload; skipped (left unacked)" >&2; continue; }
  encoding="$(json_string_field "$envelope" encoding || :)"
  case "$encoding" in
    base64) payload="$(printf '%s' "$payload_raw" | base64 -d 2>/dev/null)" || { echo "relay.sh: envelope $id payload is not valid base64; skipped (left unacked)" >&2; continue; };;
    *) payload="$payload_raw";;
  esac
  # The envelope's payload carries a one-line "target: <local>" header, a blank line, then the
  # report text — the framing report.sh's beam branch composes, chosen because beam's envelope
  # only carries an opaque payload and gives relay.sh nowhere else to learn the local target. That
  # target is still just data the sender wrote: normalize_target and the allowlist below are what
  # decide whether relay.sh may act on it (D14) — not its presence in the envelope.
  header_line="$(printf '%s\n' "$payload" | head -n1)"
  case "$header_line" in
    "target: "*) local_target="${header_line#target: }";;
    *) echo "relay.sh: envelope $id has no 'target: ' header; skipped (left unacked)" >&2; continue;;
  esac
  local_target="$(normalize_target "$local_target" 2>/dev/null)" || { echo "relay.sh: envelope $id names an invalid local target; skipped (left unacked)" >&2; continue; }
  if ! is_allowed "$local_target"; then
    echo "relay.sh: envelope $id from peer ${from:-<unknown>} names $local_target, outside this relay's allowlist (${ALLOW[*]}); refused (left unacked)" >&2
    continue
  fi
  message="$(printf '%s\n' "$payload" | tail -n +3)"
  if deliver_to_local_target "$SOCK" "$local_target" "$message"; then
    printf '%s\n' "$id" >&8
    echo "relay.sh: delivered to $local_target" >&2
  else
    echo "relay.sh: could not deliver to $local_target: $DELIVER_REASON (left unacked; will be redelivered)" >&2
  fi
done
