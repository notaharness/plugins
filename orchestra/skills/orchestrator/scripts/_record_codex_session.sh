#!/usr/bin/env bash
# Record a fresh Codex dir player's exact thread. Runs through tmux run-shell outside the
# player's process tree, on the player's machine. Never infer ownership from cwd or file age.
# The expected pane PID prevents a delayed recorder from tagging a replacement player.
# Wait through startup/trust dialogs while the original process lives; missing identity fails closed.
unset ORCHESTRA_MACHINE
ORCH_MACHINE=local
. "$(dirname "$(realpath "$0")")/_lib.sh"
sock="$1"; session="$2"; pid="$3"
tt="$(tmux_target "$session")"
same_pane() {
  [ "$(tmux_on "$sock" display-message -p -t "$tt" '#{pane_pid}' 2>/dev/null)" = "$pid" ] &&
  [ "$(tag_get "$sock" "$session" "$TAG_SESSION_TYPE")" = "$SESSION_TYPE_DIR" ]
}
attempt=0
while :; do
  same_pane && kill -0 "$pid" 2>/dev/null || exit 0
  if thread="$(codex_pane_thread "$pid")"; then
    same_pane || exit 0
    tag_set "$sock" "$session" "$TAG_CODEX_SESSION" "${thread%% *}" && exit 0
    tag_set "$sock" "$session" "$TAG_CODEX_RECORD_ERROR" "could not record exact thread id"
    break
  fi
  attempt=$((attempt + 1))
  if ((attempt < 10)); then sleep 0.2; else sleep 2; fi
done
echo "player launch: could not record a Codex thread on $session; this dir player cannot be resumed" >&2
exit 1
