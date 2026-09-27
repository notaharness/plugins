#!/usr/bin/env bash
# Record a fresh Codex dir player's exact thread. Runs through tmux run-shell outside the
# player's process tree, on the player's machine. Never infer ownership from cwd or file age.
# The expected pane PID prevents a delayed recorder from tagging a replacement player.
# Startup has up to 30 seconds to create its first rollout; missing identity fails closed on resume.
unset ORCHESTRA_MACHINE
ORCH_MACHINE=local
. "$(dirname "$(realpath "$0")")/_lib.sh"
sock="$1"; session="$2"; pid="$3"
tt="$(tmux_target "$session")"
same_pane() {
  [ "$(tmux_on "$sock" display-message -p -t "$tt" '#{pane_pid}' 2>/dev/null)" = "$pid" ] &&
  [ "$(tag_get "$sock" "$session" "$TAG_SESSION_TYPE")" = "$SESSION_TYPE_DIR" ]
}
deadline=$((SECONDS + 30))
while ((SECONDS < deadline)); do
  same_pane && kill -0 "$pid" 2>/dev/null || exit 0
  if thread="$(codex_pane_thread "$pid")"; then
    same_pane || exit 0
    tag_set "$sock" "$session" "$TAG_CODEX_SESSION" "${thread%% *}" && exit 0
    break
  fi
  sleep 0.2
done
echo "player launch: could not record a Codex thread on $session; this dir player cannot be resumed" >&2
exit 1
