#!/usr/bin/env bash
# Type text into a session and press Enter — answer a question, add a follow-up, nudge.
# Text is prefixed "[orchestrator] " so the player knows it is not the user speaking;
# --raw sends it verbatim (e.g. a menu choice like "1" or "y").
#
# Usage: send.sh <session> [--repo <path>] [--machine NAME] <text…>
#        send.sh <session> [--repo <path>] [--machine NAME] --raw <text…>
#        send.sh <session> [--repo <path>] [--machine NAME] --key <tmux key>   e.g. Escape, C-c, Enter, Up
#        send.sh <session> [--repo <path>] [--machine NAME] --type <text…>    typed literally, not pasted:
#                                                               for slash commands (/reload-skills)
# --machine: the beam peer label or peerId the session is on; default $ORCHESTRA_MACHINE, else
# this machine. A remote --repo must be absolute or start with ~/.
# The session is a branch (resolved in this repo, --repo, or uniquely across repos) or an exact
# tmux session name of a tagged player; never a prefix, never a session without the tags. Long
# text is fine: it is pasted from a buffer, not passed on the tmux command line.
. "$(dirname "$(realpath "$0")")/_lib.sh"
[ $# -ge 2 ] || { sed -n '2,15p' "$0" >&2; exit 2; }
session="$1"; shift
while [ "${1:-}" = "--repo" ] || [ "${1:-}" = "--machine" ]; do
  case "$1" in --repo) ORCH_REPO="$2";; --machine) ORCH_MACHINE="$2";; esac; shift 2
done
[ $# -ge 1 ] || { sed -n '2,15p' "$0" >&2; exit 2; }
require_valid_repo_for_machine || exit 2
# Which server this machine's sessions are on, resolved once so every tmux call below
# addresses the one spawn.sh created the session on (machine_socket, _routing.sh); a no-op,
# and one variable assignment, without --machine.
machine_socket || exit 1
target="$(resolve_session "$session")" || exit 1
session_exists "$target" || exit 1
tt="$(tmux_target "$target")"
if [ "$1" = "--key" ]; then tmux_on "" send-keys -t "$tt" "$2"; exit; fi
if [ "$1" = "--type" ]; then shift; tmux_on "" send-keys -t "$tt" -l "$*" && sleep 0.3 && tmux_on "" send-keys -t "$tt" Enter && echo "typed into $target"; exit; fi
if [ "$1" = "--raw" ]; then shift; msg="$*"; else msg="[orchestrator] $*"; fi
# Bracketed paste keeps multi-line text as one message; the pause before Enter lets a slow UI
# ingest the paste so the newline is not folded into it.
paste_into "$target" "$msg" || { echo "send.sh: could not paste into $target" >&2; exit 1; }
echo "sent to $target"
