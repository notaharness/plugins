#!/usr/bin/env bash
# List player tmux sessions with a cheap, harness-neutral state and the session's tags.
#
#   busy   the pane wrote output within the last QUIET seconds
#   idle   quiet for QUIET+ seconds: at a prompt, asking a question, or finished
#   dead   the pane's command has exited
#
# A player is a session tagged @orchestra-spawner (any value), @orchestra-repo and
# @orchestra-session-type worktree or dir, whoever created it; sessions missing any of these and
# Kirby's shell/agent tabs are never listed. A dir player's @orchestra-repo is its directory and
# its BRANCH is empty, so it is in a repo's scope only when that directory is the main checkout.
# Scope: players whose @orchestra-repo is this repo (--repo <path>, else the cwd's repo) when
# the cwd is inside a git repo; every player on the machine (--all) otherwise. --all adds a
# REPO column (the @orchestra-repo tag value, cut to 40 characters like SESSION; --json has
# both whole). SESSION is the tmux session name (a label, which every other script accepts);
# BRANCH, AGENT, ORCHESTRATOR and LAST-REPORT come from the @orchestra-branch (the branch it was
# spawned for), -agent, -orchestrator and -last-report tags (empty when unset). --json gives
# "session" and "name" (both the tmux name), "repo", "branch", "worktree" (@orchestra-worktree-path,
# the checkout that identifies a worktree player), "state", "cmd", "quiet_s", "agent",
# "orchestrator", "last_report" and "title". Everything comes from one tmux list-panes call.
#
# QUIET is seconds since the pane last produced output (tmux window_activity), so one
# tmux call covers every session. It cannot say *why* a session is idle — use screen.sh
# (or a small model reading it) for that. A harness that redraws a clock every second
# always reads busy; --sample N compares two screenshots N seconds apart instead.
#
# Usage: sessions.sh [--all] [--repo <path>] [--machine NAME] [--quiet SECONDS] [--sample SECONDS] [--json]
#   --machine NAME   list only that machine's players (a beam peer label or peerId), instead of
#                    the default $ORCHESTRA_MACHINE or this machine.
#   --all            without --machine: local players plus, when beam resolves and this machine
#                    has registered peers, every peer's — one listing call per machine, never one
#                    per session. Rows then carry a MACHINE column ("machine" in --json). With no
#                    beam installed and no peers this is exactly today's local-only listing, byte
#                    for byte: no beam, no column, no change.
# Always exits 0 (it runs at skill load, where a failure would abort the skill).
. "$(dirname "$(realpath "$0")")/_lib.sh"

# 3 s: agent UIs animate a spinner several times a second while working, so anything
# quieter than a few seconds is waiting rather than thinking.
QUIET=3
ALL=0; SAMPLE=0; JSON=0; EXPLICIT_MACHINE=0
while [ $# -gt 0 ]; do case "$1" in
  --all) ALL=1;; --repo) ORCH_REPO="$2"; shift;;
  --machine) ORCH_MACHINE="$2"; EXPLICIT_MACHINE=1; shift;;
  --quiet) QUIET="$2"; shift;; --sample) SAMPLE="$2"; shift;; --json) JSON=1;;
  -h|--help) sed -n '2,35p' "$0"; exit 0;;
  *) echo "sessions.sh: unknown argument $1" >&2; exit 0;; esac; shift; done
command -v tmux >/dev/null || { echo "tmux is not installed"; exit 0; }
require_valid_repo_for_machine || exit 0

in_repo || ALL=1
scope=""; [ $ALL = 1 ] || scope="$(repo_root)"
# A row is in scope when its tags say player (spawner, repo, session-type worktree or dir) and,
# unless --all, its repo tag equals this repo.
in_scope() { [ -n "$1" ] && { [ "$2" = "$SESSION_TYPE_WORKTREE" ] || [ "$2" = "$SESSION_TYPE_DIR" ]; } && [ -n "$3" ] && { [ $ALL = 1 ] || [ "$3" = "$scope" ]; }; }

# Machines to list: an explicit --machine names exactly one, shown exactly as given. --all with
# no --machine adds every registered peer to "local", cheaply (one `beam peers --json` call, then
# one listing per machine); beam not resolving, or having no peers, leaves MACHINES at ("local") —
# today's behaviour exactly. MACHINE_LABEL carries each discovered peer's name — its local alias
# when one is set, else its label, as `beam peers` itself shows it — so the MACHINE column reads a
# name a person chose, not a peerId.
MACHINES=(local); declare -A MACHINE_LABEL
if [ $EXPLICIT_MACHINE = 1 ]; then MACHINES=("$ORCH_MACHINE")
elif [ $ALL = 1 ] && beam_cmd 2>/dev/null; then
  # `beam peers --json` prints `{ "peers": [PeerView…] }`, every page already fetched (the CLI
  # follows the socket's `next` cursor itself; beam/docs/06-control-socket.md, beam/docs/07-cli.md).
  peers_json="$("${BEAM_CMD[@]}" peers --json 2>/dev/null)" || peers_json=""
  # Split the array properly (json_array_objects, _routing.sh) rather than by scanning for the
  # next "{...}": a label is chosen by a person on the machine that peer belongs to, and one
  # containing "}" would otherwise cut that peer's object short and lose every peer after it.
  if json_array_objects "$peers_json" peers 2>/dev/null; then
    for obj in ${JSON_OBJECTS[@]+"${JSON_OBJECTS[@]}"}; do
      pid="$(json_string_field "$obj" peerId 2>/dev/null || :)"
      [ -n "$pid" ] || continue
      lbl="$(json_string_field "$obj" alias 2>/dev/null || json_string_field "$obj" label 2>/dev/null || :)"
      MACHINES+=("$pid"); MACHINE_LABEL["$pid"]="${lbl:-$pid}"
    done
  fi
fi
MULTI_MACHINE=0; [ "${#MACHINES[@]}" -gt 1 ] && MULTI_MACHINE=1

# --sample keys its before/after screenshot by machine AND name: with --all across several
# machines, a name is only unique per machine (D2), and the baseline has to come from the same
# machine the later comparison reads, not just whichever machine ORCH_MACHINE happened to be
# before this loop — otherwise every remote row reads a stale (or wrong-session's) baseline and
# compares as permanently busy.
declare -A before
if [ "$SAMPLE" -gt 0 ]; then
  SAMPLE_STARTING_MACHINE="$ORCH_MACHINE"
  for machine_iter in "${MACHINES[@]}"; do
    ORCH_MACHINE="$machine_iter"; [ "$machine_iter" = local ] && ORCH_MACHINE=""
    # The server that machine keeps its sessions on, resolved once per machine (_routing.sh);
    # a peer that cannot be reached contributes no baseline and no rows, as before, quietly.
    machine_socket 2>/dev/null || continue
    while IFS= read -r n; do before["$machine_iter$TAB$n"]="$(screen_text "=$n:" | md5sum)"; done < <(all_player_sessions)
  done
  ORCH_MACHINE="$SAMPLE_STARTING_MACHINE"
  sleep "$SAMPLE"
fi

# Fields are tab-separated (tag values never contain a tab; the title comes last so it may). A
# whitespace IFS makes `read` collapse the empty fields of unset tags, so lines are split by hand.
FORMAT="#{session_name}${TAB}#{pane_dead}${TAB}#{pane_current_command}${TAB}#{window_activity}${TAB}#{$TAG_AGENT}${TAB}#{$TAG_ORCHESTRATOR}${TAB}#{$TAG_LAST_REPORT}${TAB}#{$TAG_REPO}${TAB}#{$TAG_BRANCH}${TAB}#{$TAG_SPAWNER}${TAB}#{$TAG_SESSION_TYPE}${TAB}#{$TAG_WORKTREE_PATH}${TAB}#{pane_title}"
split_tabs() {
  local line="$1"; F=()
  while case "$line" in *"$TAB"*) true;; *) false;; esac; do F+=("${line%%"$TAB"*}"); line="${line#*"$TAB"}"; done
  F+=("$line")
}
now=$(date +%s); rows=0; first=1
[ $JSON = 1 ] && printf '['
# One listing call per machine (never per session): MACHINES is ("local") unless --all expanded
# it with registered peers above. ORCH_MACHINE is set per iteration so tmux_on (via list-panes)
# reaches that machine's server; it is restored to whatever it started as once the loop ends.
STARTING_MACHINE="$ORCH_MACHINE"
for machine_iter in "${MACHINES[@]}"; do
  ORCH_MACHINE="$machine_iter"; [ "$machine_iter" = local ] && ORCH_MACHINE=""
  machine_socket 2>/dev/null || continue                  # see the sample loop above
  machine_disp="${MACHINE_LABEL[$machine_iter]:-$machine_iter}"
  while IFS= read -r line; do
    split_tabs "$line"; set -- "${F[@]}"
    name="${1:-}"; dead="${2:-}"; cmd="${3:-}"; activity="${4:-}"; agent="${5:-}"; orch="${6:-}"; last="${7:-}"; tag_repo="${8:-}"; branch="${9:-}"; spawner="${10:-}"; type="${11:-}"; worktree="${12:-}"
    title="$(IFS="$TAB"; printf '%s' "${*:13}")"      # the last field may itself contain tabs
    in_scope "$spawner" "$type" "$tag_repo" || continue
    rows=$((rows+1))
    quiet=$(( now - ${activity:-$now} )); [ $quiet -lt 0 ] && quiet=0
    if [ "${dead:-1}" = 1 ]; then state=dead
    elif [ "$SAMPLE" -gt 0 ]; then
      if [ "${before["$machine_iter$TAB$name"]:-}" != "$(screen_text "=$name:" | md5sum)" ]; then state=busy; else state=idle; fi
    elif [ $quiet -lt "$QUIET" ]; then state=busy
    else state=idle; fi
    repo="$tag_repo"
    if [ $JSON = 1 ]; then
      [ $first = 1 ] || printf ','; first=0
      if [ $MULTI_MACHINE = 1 ]; then
        printf '{"session":%s,"name":%s,"machine":%s,"repo":%s,"branch":%s,"worktree":%s,"state":%s,"cmd":%s,"quiet_s":%s,"agent":%s,"orchestrator":%s,"last_report":%s,"title":%s}' \
          "$(json_str "$name")" "$(json_str "$name")" "$(json_str "$machine_disp")" "$(json_str "$repo")" "$(json_str "$branch")" "$(json_str "$worktree")" "$(json_str "$state")" "$(json_str "$cmd")" "$quiet" "$(json_str "$agent")" "$(json_str "$orch")" "$(json_str "$last")" "$(json_str "$title")"
      else
        printf '{"session":%s,"name":%s,"repo":%s,"branch":%s,"worktree":%s,"state":%s,"cmd":%s,"quiet_s":%s,"agent":%s,"orchestrator":%s,"last_report":%s,"title":%s}' \
          "$(json_str "$name")" "$(json_str "$name")" "$(json_str "$repo")" "$(json_str "$branch")" "$(json_str "$worktree")" "$(json_str "$state")" "$(json_str "$cmd")" "$quiet" "$(json_str "$agent")" "$(json_str "$orch")" "$(json_str "$last")" "$(json_str "$title")"
      fi
    elif [ $MULTI_MACHINE = 1 ]; then
      [ $rows = 1 ] && printf '%-5s %6s  %-16s %-40s %-40s %-32s %-8s %-42s %-26s %s\n' STATE QUIET MACHINE REPO SESSION BRANCH AGENT ORCHESTRATOR LAST-REPORT TITLE
      printf '%-5s %5ss  %-16s %-40s %-40s %-32s %-8s %-42s %-26s %s\n' "$state" "$quiet" "$(printf %s "$machine_disp" | cut -c1-16)" "$(printf %s "$repo" | cut -c1-40)" "$(printf %s "$name" | cut -c1-40)" "$(printf %s "$branch" | cut -c1-32)" "$agent" "$(printf %s "$orch" | cut -c1-42)" "$last" "$(printf %s "$title" | cut -c1-40)"
    elif [ $ALL = 1 ]; then
      [ $rows = 1 ] && printf '%-5s %6s  %-40s %-40s %-32s %-8s %-42s %-26s %s\n' STATE QUIET REPO SESSION BRANCH AGENT ORCHESTRATOR LAST-REPORT TITLE
      printf '%-5s %5ss  %-40s %-40s %-32s %-8s %-42s %-26s %s\n' "$state" "$quiet" "$(printf %s "$repo" | cut -c1-40)" "$(printf %s "$name" | cut -c1-40)" "$(printf %s "$branch" | cut -c1-32)" "$agent" "$(printf %s "$orch" | cut -c1-42)" "$last" "$(printf %s "$title" | cut -c1-40)"
    else
      [ $rows = 1 ] && printf '%-5s %6s  %-40s %-32s %-8s %-42s %-26s %s\n' STATE QUIET SESSION BRANCH AGENT ORCHESTRATOR LAST-REPORT TITLE
      printf '%-5s %5ss  %-40s %-32s %-8s %-42s %-26s %s\n' "$state" "$quiet" "$(printf %s "$name" | cut -c1-40)" "$(printf %s "$branch" | cut -c1-32)" "$agent" "$(printf %s "$orch" | cut -c1-42)" "$last" "$(printf %s "$title" | cut -c1-40)"
    fi
  done < <(tmux_on "" list-panes -a -F "$FORMAT" 2>/dev/null || true)
done
ORCH_MACHINE="$STARTING_MACHINE"
[ $JSON = 1 ] && printf ']\n'
if [ $rows = 0 ] && [ $JSON = 0 ]; then
  if [ $MULTI_MACHINE = 1 ]; then echo "no player sessions on this machine or its registered peers"
  elif [ $ALL = 1 ]; then echo "no player sessions on this machine"
  else echo "no player sessions tagged for repo $scope; --all lists every repo's"; fi
fi
exit 0
