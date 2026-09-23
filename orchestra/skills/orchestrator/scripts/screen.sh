#!/usr/bin/env bash
# Print one session's screen as plain text (ANSI stripped by tmux).
#
# Usage: screen.sh <session> [--lines N] [--history N] [--repo <path>] [--machine NAME]
#   --lines N    only the last N non-blank lines
#   --history N  include N lines of scrollback above the visible screen (a dead pane's
#                last output often sits just above the screen, so dead panes default to 40)
#   --repo P     resolve a branch in that repo (an exact session name needs no repo)
#   --machine N  the beam peer label or peerId the session is on; default $ORCHESTRA_MACHINE,
#                else this machine. A remote --repo must be absolute or start with ~/.
. "$(dirname "$(realpath "$0")")/_lib.sh"
[ $# -ge 1 ] || { sed -n '2,10p' "$0" >&2; exit 2; }
session="$1"; shift
LINES=0; HISTORY=0
while [ $# -gt 0 ]; do case "$1" in
  --lines) LINES="$2"; shift;; --history) HISTORY="$2"; shift;; --repo) ORCH_REPO="$2"; shift;; --machine) ORCH_MACHINE="$2"; shift;;
  *) echo "screen.sh: unknown argument $1" >&2; exit 2;; esac; shift; done
require_valid_repo_for_machine || exit 2
# Which server this machine's sessions are on, resolved once so every tmux call below
# addresses the one spawn.sh created the session on (machine_socket, _routing.sh); a no-op,
# and one variable assignment, without --machine.
machine_socket || exit 1
target="$(resolve_session "$session")" || exit 1
session_exists "$target" || exit 1
[ "$HISTORY" -gt 0 ] || [ "$(tmux_on "" display-message -p -t "$(tmux_target "$target")" '#{pane_dead}')" != 1 ] || HISTORY=40
text="$(tmux_on "" capture-pane -p -t "$(tmux_target "$target")" -S "-$HISTORY" | sed -e 's/[[:space:]]*$//' | awk 'NF{blank=0} !NF{blank++} blank<2')"
if [ "$LINES" -gt 0 ]; then printf '%s\n' "$text" | grep -v '^\s*$' | tail -n "$LINES"; else printf '%s\n' "$text"; fi
