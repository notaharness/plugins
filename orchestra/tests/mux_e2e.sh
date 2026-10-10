#!/usr/bin/env bash
# End-to-end test of Orchestra's n10 arm: the real scripts against a real `n10 mux serve`, on a
# machine without tmux. A temporary git repository, an isolated n10 profile (HOME, USERPROFILE,
# LOCALAPPDATA) and fake claude/codex executables; no model is called and no user session is
# touched. Session state is checked where n10 keeps it: the summary rows `n10 mux list` prints.
#
# Usage: mux_e2e.sh   with `n10` on PATH (CI builds it from the commit in tests/n10.sha).
# Linux, or Windows under Git for Windows' Bash, where a fake agent is a .cmd that n10 can start.
set -u
ROOT="$(dirname "$(realpath "$0")")/../skills"
O="$ROOT/orchestrator/scripts"; P="$ROOT/player/scripts"
command -v n10 >/dev/null || { echo "mux_e2e.sh: n10 is not on PATH" >&2; exit 2; }
WINDOWS=0; command -v cygpath >/dev/null 2>&1 && WINDOWS=1
native() { if [ $WINDOWS = 1 ]; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
json_path() { local p; p="$(native "$1")"; printf '%s' "${p//\\/\\\\}"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/orch-mux.XXXXXX")"; T="$(cd "$T" && pwd -P)"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
SERVE_PID=""
cleanup() { [ -z "$SERVE_PID" ] || { kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null; }; rm -rf "$T"; }
trap cleanup EXIT
STAMP='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# An n10 profile of its own, and nothing of the session running this test.
mkdir -p "$T/home/AppData/Local"
export HOME="$T/home" USERPROFILE="$(native "$T/home")" LOCALAPPDATA="$(native "$T/home/AppData/Local")"
for v in $(env | grep -oE '^(N10_MUX_|ORCHESTRA_|CLAUDE_CODE_|CODEX_)[A-Z_]*'); do unset "$v"; done
unset TMUX TMUX_PANE CLAUDE_PID
export CLAUDECODE=1 CLAUDE_CONFIG_DIR="$T/claude-config" CODEX_HOME="$T/codex-home"
mkdir -p "$CLAUDE_CONFIG_DIR" "$CODEX_HOME"
# path_without <program> <dir>: a PATH finding every program this one does but <program>, as
# <dir> of links to the first of each name.
path_without() {
  local d f n dirs
  mkdir "$2"; IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do for f in "$d"/*; do
    n="${f##*/}"; [ "$n" = "$1" ] || [ -e "$2/$n" ] || ln -s "$f" "$2/$n" 2>/dev/null
  done; done
  printf '%s' "$2"
}
# No tmux on PATH. Windows has none to hide.
if command -v tmux >/dev/null 2>&1; then PATH="$(path_without tmux "$T/no-tmux")"; fi

# Fake harnesses: record their argv and environment per session, print "ready", then take lines
# of input. A line asking for a report runs report.sh from inside the session; "exit" exits 7.
mkdir -p "$T/bin" "$T/fakes"
for cli in claude codex; do
  cat > "$T/fakes/$cli" <<FAKE
#!/usr/bin/env bash
T="$T"; P="$P"; me="\${N10_MUX_SESSION_ID:-none}"
{ printf 'cli=%s\n' "$cli"; for a in "\$@"; do printf 'arg=%s\n' "\$a"; done
  printf 'env CLAUDECODE=%s CLAUDE_CONFIG_DIR=%s CODEX_HOME=%s ORCHESTRA_BACKEND=%s ORCHESTRA_SOCKET=%s generation=%s\n' \\
    "\${CLAUDECODE:-}" "\${CLAUDE_CONFIG_DIR:-}" "\${CODEX_HOME:-}" "\${ORCHESTRA_BACKEND:-}" "\${ORCHESTRA_SOCKET:-}" "\${N10_MUX_GENERATION:-}"
} > "\$T/args-\$me"
printf 'ready\n'
while IFS= read -r line; do
  line="\${line%\$'\r'}"; printf '%s\n' "\$line" >> "\$T/received-\$me"
  case "\$line" in
    *"please report"*) bash "\$P/report.sh" PROGRESS "hello from the player" > "\$T/report-\$me" 2>&1; echo "exit=\$?" >> "\$T/report-\$me";;
    *exit*) exit 7;;
  esac
done
FAKE
  chmod +x "$T/fakes/$cli"
  if [ $WINDOWS = 1 ]; then
    printf '@"%s" "%s" %%*\r\n' "$(cygpath -w "$(command -v bash)")" "$(cygpath -m "$T/fakes/$cli")" > "$T/bin/$cli.cmd"
  else
    ln -s "$T/fakes/$cli" "$T/bin/$cli"
  fi
done
export PATH="$T/bin:$PATH"

# Rows: the session with a label, and one of its fields by n10's 1-based column.
row() { n10 mux list | awk -F '\t' -v l="$1" '$4 == l'; }
col() { row "$1" | cut -f"$2"; }
# Tag columns, 1-based: spawner 15, repo 16, type 17, branch 18, worktree 19, agent 20,
# orchestrator 21, orchestrator-config 22, last-report 23, claude-session 24, target 25.
until_true() { local i; for i in $(seq 100); do eval "$1" && return 0; sleep 0.1; done; return 1; }

echo "# owner"
n10 mux serve 2>"$T/serve.err" & SERVE_PID=$!
until_true "grep -q 'serving as host' '$T/serve.err'"
HOST="$(n10 mux status | cut -f2)"
check "n10 serves this profile, and tmux is not installed" "[ -n '$HOST' ] && ! command -v tmux >/dev/null"
git init -q "$T/repo"; git -C "$T/repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
REPO="$T/repo"; S1="repo-feature-x"; W1="$REPO/.claude/worktrees/feature-x"
# The orchestrator: an agent n10 launched itself, so a report can be pasted to it.
parent() { printf '{"label":"%s","cwd":"%s","argv":["claude"],"retainOnExit":true}' "$1" "$(json_path "$T")" | n10 mux create --request - | cut -f1; }
PARENT_ID="$(parent parent)"; PARENT="mux:$HOST/$PARENT_ID"
until_true "[ -s '$T/args-$PARENT_ID' ]"

echo "# spawn: one create with the whole launch"
if [ $WINDOWS = 1 ]; then printf 'Task: build it' > "$T/task.txt"   # one line: a .cmd shim passes no line breaks
else printf 'Task: build it\nsecond line, ünïcode "quoted"\nEND-OF-TASK' > "$T/task.txt"; fi
bash "$O/spawn.sh" --repo "$REPO" --branch feature/x --from HEAD --prompt-file "$T/task.txt" --no-node-modules \
  --agent claude --model fable --orchestrator "$PARENT" >"$T/spawn.out" 2>&1
check "spawn exits 0 and names the label" "[ $? = 0 ] && grep -qx 'started   $S1' '$T/spawn.out'"
ID1="$(col "$S1" 1)"
until_true "[ -s '$T/args-$ID1' ]"
check "n10 started claude itself, as a verified agent" "[ \"\$(col $S1 13)/\$(col $S1 14)\" = agent/claude ] && grep -qx cli=claude '$T/args-$ID1'"
check "the task reached claude whole, after the player invocation" "grep -qx 'arg=/orchestra:player Task: build it' '$T/args-$ID1' && { [ $WINDOWS = 1 ] || { grep -qx 'second line, ünïcode \"quoted\"' '$T/args-$ID1' && grep -qx 'END-OF-TASK' '$T/args-$ID1'; }; }"
check "model and effort passed" "grep -qx arg=fable '$T/args-$ID1' && grep -qx arg=high '$T/args-$ID1'"
check "pinned to n10, parent markers stripped, account kept" \
  "grep -q 'env CLAUDECODE= CLAUDE_CONFIG_DIR=$(native "$CLAUDE_CONFIG_DIR" | sed 's/\\/\\\\/g') .* ORCHESTRA_BACKEND=mux ORCHESTRA_SOCKET= generation=1' '$T/args-$ID1'"
check "identity tags, as native paths" "[ \"\$(col $S1 15)|\$(col $S1 17)|\$(col $S1 18)\" = 'orchestra|worktree|feature/x' ] && [ \"\$(col $S1 16)\" = '$(native "$REPO")' ] && [ \"\$(col $S1 19)\" = '$(native "$(cd "$W1" && pwd -P)")' ]"
check "agent and orchestrator tags" "[ \"\$(col $S1 20)\" = claude ] && [ \"\$(col $S1 21)\" = '$PARENT' ] && [ -z \"\$(col $S1 22)\" ]"
check "spawn refuses a running player" "! bash '$O/spawn.sh' --repo '$REPO' --branch feature/x --prompt x --no-node-modules 2>/dev/null"

echo "# listing and screens"
bash "$O/sessions.sh" --all --json > "$T/sessions.json"
check "sessions.sh lists the player from n10's tags" "grep -qF '\"session\":\"$S1\",\"name\":\"$S1\",\"repo\":\"$(sed 's/\\/\\\\\\\\/g' <<<"$REPO")\",\"branch\":\"feature/x\"' '$T/sessions.json' && grep -qF '\"cmd\":\"claude\"' '$T/sessions.json' && grep -qF '\"orchestrator\":\"$PARENT\"' '$T/sessions.json'"
check "sessions.sh never lists the orchestrator's own session" "! grep -q '\"session\":\"parent\"' '$T/sessions.json'"
check "sessions.sh --sample: a still screen is idle" "bash '$O/sessions.sh' --repo '$REPO' --sample 1 | grep -Eq '^idle .* $S1 +feature/x'"
(sleep 1; bash "$O/send.sh" "$S1" --raw "tick" >/dev/null) & tick=$!
check "sessions.sh --sample: a screen that changed is busy" "bash '$O/sessions.sh' --repo '$REPO' --sample 3 | grep -Eq '^busy .* $S1 +feature/x'"
wait $tick
check "screen.sh shows the player's screen" "bash '$O/screen.sh' feature/x --repo '$REPO' | grep -qx ready"

echo "# send.sh and report.sh"
check "send.sh pastes into a claude without an inbox" "[ \"\$(bash '$O/send.sh' '$S1' please report)\" = 'sent to $S1 (paste)' ]"
until_true "grep -q '^exit=' '$T/report-$ID1' 2>/dev/null"
check "the player reported through its own session" "grep -qx 'sent to $HOST/$PARENT_ID (paste)' '$T/report-$ID1' && grep -qx exit=0 '$T/report-$ID1'"
until_true "grep -q PROGRESS '$T/received-$PARENT_ID' 2>/dev/null"
check "the orchestrator got the report under the player's label" "grep -qx '\[player $S1\] PROGRESS: hello from the player' '$T/received-$PARENT_ID'"
check "last-report tag set" "col $S1 23 | grep -Eq '^PROGRESS $STAMP paste\$'"
bash "$O/send.sh" "$S1" --type "typed line" >/dev/null; bash "$O/send.sh" "$S1" --raw "raw line" >/dev/null
until_true "grep -qx 'raw line' '$T/received-$ID1' 2>/dev/null"
check "--type and --raw reach the player" "grep -qx 'typed line' '$T/received-$ID1' && grep -qx 'raw line' '$T/received-$ID1'"
check "an unknown key is n10's refusal" "! bash '$O/send.sh' '$S1' --key NoSuchKey 2>/dev/null"
printf '{"expectedHostId":"%s","generation":1}' "$HOST" | n10 mux stop "$PARENT_ID" --request -
rm -f "$T/report-$ID1"; bash "$O/send.sh" "$S1" please report >/dev/null
until_true "grep -q '^exit=' '$T/report-$ID1' 2>/dev/null"
check "a gone orchestrator fails the report with the whole report" "grep -qx exit=1 '$T/report-$ID1' && grep -qx 'Target: $PARENT' '$T/report-$ID1' && grep -q '^Reason: orchestrator session .* is gone' '$T/report-$ID1' && grep -qF 'Report: [player $S1] PROGRESS: hello from the player' '$T/report-$ID1'"
check "a failed report leaves last-report alone" "col $S1 23 | grep -q '^PROGRESS '"
SHELL_ID="$(printf '{"label":"shell","cwd":"%s","argv":[]}' "$(json_path "$T")" | n10 mux create --request - | cut -f1)"
bash "$O/adopt.sh" "$S1" --orchestrator "mux:$HOST/$SHELL_ID" >/dev/null
rm -f "$T/report-$ID1"; bash "$O/send.sh" "$S1" please report >/dev/null
until_true "grep -q '^exit=' '$T/report-$ID1' 2>/dev/null"
check "an orchestrator session running a shell is never pasted into" "grep -qx exit=1 '$T/report-$ID1' && grep -qx 'Reason: no agent n10 launched is running in shell' '$T/report-$ID1' && ! n10 mux capture '$SHELL_ID' | grep -q 'hello from the player'"

echo "# adopt.sh"
P2_ID="$(parent parent2)"; P2="mux:$HOST/$P2_ID"
until_true "[ -s '$T/args-$P2_ID' ]"
check "adopt.sh points the player at a new orchestrator and types the invocation" \
  "bash '$O/adopt.sh' '$S1' --orchestrator '$P2' | grep -qx 'adopted $S1 -> reports to $P2 (expect a PROGRESS handoff report) via keys' && [ \"\$(col $S1 21)\" = '$P2' ]"
until_true "grep -qx /orchestra:player '$T/received-$ID1' 2>/dev/null"
check "the invocation arrived" "grep -qx /orchestra:player '$T/received-$ID1'"

echo "# an orchestrator inside a session of n10's"
# This shell stands in for an agent n10 launched: the variables its owner gives every process.
inside() { N10_MUX_HOST_ID="$HOST" N10_MUX_SESSION_ID="$P2_ID" N10_MUX_GENERATION=1 "$@"; }
check "the session itself is the default target" "inside bash '$O/spawn.sh' --dir '$T' --prompt x --agent claude --dry-run | grep -qx 'reports   $P2'"
UUID=0f0e0d0c-0b0a-4908-8706-050403020100
check "and stands in for a Claude session whose inbox cannot be verified" "inside env CLAUDE_CODE_SESSION_ID=$UUID bash '$O/spawn.sh' --dir '$T' --prompt x --agent claude --dry-run | grep -qx 'reports   $P2'"
mkdir "$T/review"
inside env CLAUDE_CODE_SESSION_ID=$UUID bash "$O/spawn.sh" --dir "$T/review" --prompt "review it" --agent claude --orchestrator "claude:$UUID" >"$T/dir.out" 2>&1
check "a dir player spawns" "[ $? = 0 ] && grep -qx 'started   review-dir' '$T/dir.out'"
ID2="$(col review-dir 1)"; until_true "[ -s '$T/args-$ID2' ]"
check "dir player tags" "[ \"\$(col review-dir 17)\" = dir ] && [ \"\$(col review-dir 16)\" = '$(native "$T/review")' ] && [ -z \"\$(col review-dir 19)\" ] && [ \"\$(col review-dir 22)\" = '$(native "$CLAUDE_CONFIG_DIR")' ]"
check "its Claude conversation id is chosen and recorded" "grep -qx arg=--session-id '$T/args-$ID2' && grep -qx \"arg=\$(col review-dir 24)\" '$T/args-$ID2' && col review-dir 24 | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\$'"
check "the orchestrator's own session is marked with its target" "[ \"\$(col parent2 25)\" = claude:$UUID ]"

echo "# resume"
bash "$O/send.sh" "$S1" --type exit >/dev/null
until_true "[ \"\$(col $S1 7)\" = exited ]"
check "an exited player reads dead, keeps its screen" "bash '$O/sessions.sh' --repo '$REPO' | grep -Eq '^dead .* $S1' && bash '$O/screen.sh' '$S1' | grep -qx ready"
check "spawn without --resume refuses it" "! bash '$O/spawn.sh' --repo '$REPO' --branch feature/x --prompt x --no-node-modules 2>/dev/null"
bash "$O/spawn.sh" --repo "$REPO" --branch feature/x --resume --no-node-modules --orchestrator "$P2" >"$T/resume.out" 2>&1
check "--resume restarts the same record with its claude" "[ $? = 0 ] && grep -qx 'started   $S1' '$T/resume.out' && [ \"\$(col $S1 1)/\$(col $S1 3)/\$(col $S1 7)\" = '$ID1/2/running' ]"
until_true "grep -q generation=2 '$T/args-$ID1'"
check "resume continues the conversation with a restart note, no replay" "grep -qx arg=--continue '$T/args-$ID1' && grep -q '^arg=/orchestra:player Your session was restarted in this worktree' '$T/args-$ID1' && ! grep -q 'Task: build it' '$T/args-$ID1'"
check "resume keeps the identity tags" "[ \"\$(col $S1 15)|\$(col $S1 18)\" = 'orchestra|feature/x' ]"

echo "# kill.sh"
check "kill.sh stops the player and removes its record" "bash '$O/kill.sh' feature/x --repo '$REPO' | grep -qx 'killed $S1' && [ -z \"\$(row $S1)\" ]"
check "kill.sh refuses an untagged session" "! bash '$O/kill.sh' parent2 2>/dev/null && [ -n \"\$(row parent2)\" ]"
check "a vanished player resumes only with a named harness" "bash '$O/spawn.sh' --repo '$REPO' --branch feature/x --resume --no-node-modules --orchestrator '$P2' 2>&1 | grep -q 'pass --agent claude, codex or opencode'"

echo "# neither tmux nor n10"
nopath="$(path_without n10 "$T/no-n10")"
check "spawn says tmux is not installed" "PATH='$nopath' bash '$O/spawn.sh' --repo '$REPO' --branch b --prompt x 2>&1 | grep -qx 'spawn.sh: tmux is not installed'"
check "sessions.sh says so" "[ \"\$(PATH='$nopath' bash '$O/sessions.sh')\" = 'tmux is not installed' ]"

echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
