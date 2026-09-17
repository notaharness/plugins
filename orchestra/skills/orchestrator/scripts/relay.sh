#!/usr/bin/env bash
# Runs on the orchestrator's machine: listens for reports beamed in from remote players and
# delivers each one exactly as report.sh would deliver a local one — the same shared
# deliver_to_local_target sequence (load-buffer/paste-buffer/send-keys, or codex queue), gated by
# the same pane_owned_by_agent check, so a message that arrived from another machine gets no more
# trust than one typed locally.
#
# Usage: relay.sh [--topic T]     default topic: orchestra
#
# Run this directly only when supervising remote players from a plain terminal with nothing else
# already relaying — N10 Desktop runs its own relay, so do not run this alongside it; two
# listeners on the same topic would both try to deliver the same envelopes. Requires a beam
# binary (see _routing.sh's beam_cmd: $ORCHESTRA_BEAM, then `beam` on PATH, then `n10 beam`) and
# a running local beam node (`beam serve`) so `beam msg listen` has something to listen through.
set -u
. "$(dirname "$(realpath "$0")")/_lib.sh"
TOPIC=orchestra
while [ $# -gt 0 ]; do case "$1" in
  --topic) TOPIC="$2"; shift;;
  -h|--help) sed -n '2,14p' "$0"; exit 0;;
  *) echo "relay.sh: unknown argument $1" >&2; exit 2;; esac; shift; done
beam_cmd || { echo "relay.sh: $(beam_unresolved_message "this machine")" >&2; exit 1; }
SOCK="$(default_orchestrator_socket)"
echo "relay.sh: listening for topic '$TOPIC'; delivering to sessions on $SOCK" >&2
"${BEAM_CMD[@]}" msg listen --topic "$TOPIC" | while IFS= read -r envelope; do
  [ -n "$envelope" ] || continue
  payload_raw="$(json_string_field "$envelope" payload)" || { echo "relay.sh: envelope has no payload; skipped" >&2; continue; }
  encoding="$(json_string_field "$envelope" encoding || :)"
  case "$encoding" in
    base64) payload="$(printf '%s' "$payload_raw" | base64 -d 2>/dev/null)" || { echo "relay.sh: envelope payload is not valid base64; skipped" >&2; continue; };;
    *) payload="$payload_raw";;
  esac
  # The envelope's payload carries a one-line "target: <local>" header, a blank line, then the
  # report text — the framing report.sh's beam branch composes, chosen because beam's envelope
  # only carries an opaque payload and gives relay.sh nowhere else to learn the local target.
  header_line="$(printf '%s\n' "$payload" | head -n1)"
  case "$header_line" in
    "target: "*) local_target="${header_line#target: }";;
    *) echo "relay.sh: envelope has no 'target: ' header; skipped" >&2; continue;;
  esac
  message="$(printf '%s\n' "$payload" | tail -n +3)"
  if deliver_to_local_target "$SOCK" "$local_target" "$message"; then
    echo "relay.sh: delivered to $local_target" >&2
  else
    echo "relay.sh: could not deliver to $local_target: $DELIVER_REASON" >&2
  fi
done
