#!/usr/bin/env bash
# Kill ONE player session's tmux session (its agent). Leaves the worktree and branch alone —
# remove those with `git worktree remove` (and `git branch -d`) after the PR merges.
# <session> is a branch (resolved in this repo, --repo, or uniquely across repos) or an exact
# tmux session name. Only a session whose tags say it is a player (@orchestra-spawner set,
# @orchestra-session-type worktree) is killed; a session that merely wears such a name, the
# user's own terminals and Kirby's shell/agent tabs are refused. A task prompt buffer the
# launcher never consumed (orchestra-prompt-<session>) is deleted with the session so nothing
# stays on the server.
#
# Usage: kill.sh <session> [--repo <path>] [--machine NAME]
#   --machine: the beam peer label or peerId the session is on; default $ORCHESTRA_MACHINE,
#   else this machine. A remote --repo must be absolute or start with ~/.
. "$(dirname "$(realpath "$0")")/_lib.sh"
[ $# -ge 1 ] || { sed -n '2,13p' "$0" >&2; exit 2; }
session="$1"; shift
while [ "${1:-}" = "--repo" ] || [ "${1:-}" = "--machine" ]; do
  case "$1" in --repo) ORCH_REPO="$2";; --machine) ORCH_MACHINE="$2";; esac; shift 2
done
[ $# -eq 0 ] || { sed -n '2,13p' "$0" >&2; exit 2; }
require_valid_repo_for_machine || exit 2
# Which server this machine's sessions are on, resolved once so every tmux call below
# addresses the one spawn.sh created the session on (machine_socket, _routing.sh); a no-op,
# and one variable assignment, without --machine.
machine_socket || exit 1
target="$(resolve_session "$session")" || exit 1
is_player_session "$target" || { echo "kill.sh: $target is not a player session (its tags do not say $TAG_SPAWNER + $TAG_SESSION_TYPE $SESSION_TYPE_WORKTREE); nothing killed" >&2; exit 1; }
session_exists "$target" || exit 1
tmux_on "" kill-session -t "=$target" || { echo "kill.sh: tmux could not kill $target" >&2; exit 1; }
tmux_on "" delete-buffer -b "$(prompt_buffer_name "$target")" 2>/dev/null || :
echo "killed $target"
