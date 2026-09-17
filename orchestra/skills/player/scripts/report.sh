#!/usr/bin/env bash
# Send one message to the orchestrator as `[player <session>] KIND: text`, where <session> is
# this player's tmux session name (a label chosen at spawn; never parsed).
#
# Usage: report.sh PROGRESS|QUESTION|BLOCKED|DONE <text…>
#        report.sh --orchestrator          print the current reporting target
#
# The target is the @orchestra-orchestrator tag on this player's own tmux session, set by
# spawn.sh and adopt.sh; a player cannot change it. codex:<thread-id> or tmux:<session> when the
# orchestrator is on this machine; beam:<orchestrator peerId>/(codex:<thread-id>|tmux:<session>)
# when it is on another one (see docs/beam.md), in which case delivery goes through
# `beam msg send` instead of pasting locally. The session and the socket of the server holding it
# come from ORCHESTRA_SESSION and ORCHESTRA_SOCKET (injected by spawn.sh; the pane's own tmux
# environment points at a scratch server, so every local call here passes -S), or from TMUX in a
# pane spawn.sh did not start (a Kirby session adopted by adopt.sh). No file is read or written.
# Delivery is reported only when the transport accepted the message; then @orchestra-last-report
# is set to "<KIND> <ISO-8601 UTC> <delivered|queued>" (a parser that reads only the first two
# whitespace-separated fields still gets KIND and the timestamp). A beam send that comes back
# "queued" is still success — the message is durable and will be delivered when that machine
# reconnects — and is worded to say so plainly, because the reader is a coding agent that would
# otherwise conclude the report was lost. Failed delivery (a local target gone or unreachable, or
# beam's own "rejected") exits nonzero and prints the target, reason, and complete original report
# to stderr so the player can handle the failure. A failed submit may follow a successful paste;
# inspect before retrying to avoid duplicates. Nothing retries.
set -eu
. "$(dirname "$(realpath "$0")")/_routing.sh"
player_session_context || { player_session=""; player_socket=""; }
session="$player_session"; sock="$player_socket"; name="${session:-$(basename "$(pwd)")}"
if [ "${1:-}" = "--orchestrator" ]; then
  [ $# -eq 1 ] || { echo 'report.sh: the reporting target is the @orchestra-orchestrator tag on this session, set by spawn.sh and adopt.sh; a player cannot rebind itself' >&2; exit 2; }
  [ -n "$session" ] || { echo 'report.sh: neither ORCHESTRA_SESSION nor TMUX names a player session; not running in a player pane' >&2; exit 2; }
  target="$(tag_get "$sock" "$session" "$TAG_ORCHESTRATOR")"; printf '%s\n' "${target:-<unset>}"; exit
fi
[ $# -ge 2 ] || { sed -n '2,24p' "$0" >&2; exit 2; }
kind="$1"; shift
case "$kind" in PROGRESS|QUESTION|BLOCKED|DONE) ;; *) echo "report.sh: KIND must be PROGRESS, QUESTION, BLOCKED or DONE" >&2; exit 2;; esac
msg="[player $name] $kind: $*"
destination=""
# Keep the full destination and report intact even when tmux is unreachable; never retries.
delivery_failed() {
  printf 'report.sh: delivery failed\nTarget: %s\nReason: %s\nReport: %s\n' \
    "${destination:-<unknown>}" "$1" "$msg" >&2
  exit 1
}
delivered() {
  tag_set "$sock" "$session" "$TAG_LAST_REPORT" "$kind $(date -u +%Y-%m-%dT%H:%M:%SZ) $1" 2>/dev/null ||
    echo "report.sh: delivered, but could not set $TAG_LAST_REPORT on $session" >&2
}
[ -n "$session" ] || delivery_failed 'neither ORCHESTRA_SESSION nor TMUX names a player session; not running in a player pane'
destination="$(tag_get "$sock" "$session" "$TAG_ORCHESTRATOR")"
# No fallback to CODEX_THREAD_ID: that is the player's own conversation, not its parent.
[ -n "$destination" ] || delivery_failed "orchestrator target is unset or unreachable ($TAG_ORCHESTRATOR on $session)"
normalize_target "$destination" >/dev/null 2>&1 || delivery_failed 'invalid orchestrator target'
target="$destination"
case "$target" in
  codex:*)
    deliver_to_local_target "$sock" "$target" "$msg" || delivery_failed "$DELIVER_REASON"
    delivered delivered; echo "queued for $target"; exit 0;;
  tmux:*)
    deliver_to_local_target "$sock" "$target" "$msg" || delivery_failed "$DELIVER_REASON"
    delivered delivered; echo "sent to ${target#tmux:}"; exit 0;;
  beam:*)
    rest="${target#beam:}"; peer="${rest%%/*}"; local_target="${rest#*/}"
    beam_cmd || delivery_failed "$(beam_unresolved_message "$peer")"
    # The far side needs to know which local target the envelope is for; beam only carries an
    # opaque payload, so it travels as a one-line header ("target: <local>") plus a blank line
    # before the report text, the way relay.sh (and this function, symmetrically) expects it.
    payload="$(printf 'target: %s\n\n%s' "$local_target" "$msg")"
    out="$(printf '%s' "$payload" | "${BEAM_CMD[@]}" msg send "$peer" --topic orchestra --message - --json 2>&1)" && rc=0 || rc=$?
    status="$(json_string_field "$out" status || :)"
    label="$(json_string_field "$out" label || :)"; label="${label:-$peer}"
    reason="$(json_string_field "$out" reason || :)"
    case "$status" in
      delivered) delivered delivered; echo "sent to $label"; exit 0;;
      queued)
        delivered queued
        printf 'queued for %s — that machine is not connected right now. beam will deliver this report\nwhen it comes back online. Do not send it again.\n' "$label"
        exit 0;;
      *) delivery_failed "${reason:-beam rejected the message (exit $rc): $out}";;
    esac;;
esac
