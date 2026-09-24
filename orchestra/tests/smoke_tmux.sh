#!/usr/bin/env bash
# Real-tmux smoke test for the orchestrator/player scripts. Uses a temporary git repository,
# an isolated tmux socket and fake claude/codex binaries; never touches user sessions or
# real repositories, and never calls a model. Session state is checked where the scripts keep
# it: session user options (tags) and paste buffers on the scratch server, never files. Session
# names are labels (<repo basename>-<branch>, suffixed when taken); foreign sessions wearing
# such a name are planted to check that only the tags identify a player.
#
# Usage: smoke_tmux.sh [skills-root]   default: this plugin's skills/ directory. The root may
# also be a personal installation (~/.claude/skills); the expected Claude player invocation
# defaults to the plugin namespace in both layouts.
set -u
ROOT="${1:-$(dirname "$(realpath "$0")")/../skills}"
O="$ROOT/orchestrator/scripts"; P="$ROOT/player/scripts"
INV=/orchestra:player
[ -f "$ROOT/../.claude-plugin/plugin.json" ] && INV="/$(sed -nE 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$ROOT/../.claude-plugin/plugin.json" | head -n1):player"
T="$(mktemp -d /tmp/orch-smoke.XXXXXX)"; SOCK="$T/tmux.sock"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
cleanup() { tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
tm() { tmux -S "$SOCK" "$@"; }
tag() { tm show-options -qv -t "=$1:" "$2"; }
STAMP='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# Fake harnesses: record argv and environment, then behave per FAKE_* files in $T.
mkdir -p "$T/bin" "$T/codex-home/sessions/2026/09/13"
for cli in claude codex; do cat > "$T/bin/$cli" <<FAKE
#!/usr/bin/env bash
T="$T"
{ printf 'cli=%s\n' "$cli"; for a in "\$@"; do printf 'arg=%s\n' "\$a"; done; printf 'env CLAUDECODE=%s CLAUDE_CONFIG_DIR=%s ANTHROPIC_API_KEY=%s CODEX_THREAD_ID=%s TMUX=%s TMUX_TMPDIR=%s\n' "\${CLAUDECODE:-}" "\${CLAUDE_CONFIG_DIR:-}" "\${ANTHROPIC_API_KEY:-}" "\${CODEX_THREAD_ID:-}" "\${TMUX:-}" "\${TMUX_TMPDIR:-}"; env | grep -E '^(ORCHESTRA_|PLAYER_|ORCHESTRATOR_)' | sed 's/^/env /'; } > "\$T/last-$cli"
cp "\$T/last-$cli" "\$T/last-call"
if [ -f "\$T/fake-$cli-noconv" ]; then echo 'No conversation found to continue'; exit 1; fi
if [ -f "\$T/fake-$cli-exit" ]; then exit "\$(cat "\$T/fake-$cli-exit")"; fi
exec cat >> "\$T/received-$cli"
FAKE
chmod +x "$T/bin/$cli"; done
export PATH="$T/bin:$PATH"
export CLAUDECODE=1 CLAUDE_CODE_CHILD_SESSION=1 CODEX_THREAD_ID=11111111-2222-3333-4444-555555555555
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID     # the session running this script is not the orchestrator under test
export CLAUDE_CONFIG_DIR="$T/claude-config" ANTHROPIC_API_KEY=fake-key CODEX_HOME="$T/codex-home"
for v in $(env | grep -oE '^(ORCHESTRA_|ORCHESTRATOR_|PLAYER_)[A-Z_]+'); do unset "$v"; done

# Temporary repository and an orchestrator session on the scratch server.
git init -q "$T/repo"; git -C "$T/repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
(unset TMUX TMUX_PANE; tm new-session -d -s parent -x 120 -y 30 -- "$T/bin/claude")
export TMUX="$SOCK,0,0"; unset TMUX_PANE
REPO="$(git -C "$T/repo" rev-parse --show-toplevel)"
S1="repo-feature-x"; S2="repo-feature-x-2"; W1="$T/repo/.claude/worktrees/feature-x"
GITDIR1() { git -C "$W1" rev-parse --absolute-git-dir; }
# A session some other program created, optionally tagged: `foreign NAME [tag value]...`.
foreign() { local n="$1"; shift; (unset TMUX TMUX_PANE; tm new-session -d -s "$n" -c "$T" -x 80 -y 20 -- sleep 300); while [ $# -ge 2 ]; do tm set-option -t "=$n:" "$1" "$2"; shift 2; done; }
# report.sh runs inside the player's pane in real use; here it is called from this shell with the
# same environment spawn.sh injects there.
player() { ORCHESTRA_SESSION="$S1" ORCHESTRA_SOCKET="$SOCK" bash "$P/report.sh" "$@"; }

echo "# fresh launch with a 40 KiB prompt"
# Claude's global config, as a machine where Claude has run keeps it: the launcher records the new
# worktree as trusted there before starting claude.
mkdir -p "$CLAUDE_CONFIG_DIR"; printf '{"numStartups":3,"projects":{}}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
big="$(head -c 40000 /dev/zero | tr '\0' 'x')"; printf 'Task: %s\nsecond line\nEND-OF-TASK\n' "$big" > "$T/task.txt"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --from HEAD --prompt-file "$T/task.txt" --no-node-modules --agent claude --model fable >"$T/spawn.out" 2>&1
check "spawn exits 0" "[ $? = 0 ]"
sleep 1.5
check "session exists" "tm has-session -t '=$S1'"
check "pane alive" "[ \"\$(tm display-message -p -t '=$S1:' '#{pane_dead}')\" = 0 ]"
check "prompt reached claude intact" "grep -q '^END-OF-TASK' '$T/last-claude' && grep -q '^second line' '$T/last-claude' && grep -q '^arg=$INV Task: x' '$T/last-claude'"
check "prompt does not name the orchestrator" "! grep -q 'reporting target' '$T/last-claude'"
check "explicit model/effort passed" "grep -q '^arg=fable' '$T/last-claude' && grep -q '^arg=high' '$T/last-claude'"
check "claude starts without project MCP servers" "grep -qx 'arg=--strict-mcp-config' '$T/last-claude'"
check "the worktree is pre-trusted in Claude's config" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"projects\"][sys.argv[2]][\"hasTrustDialogAccepted\"] is True and d[\"numStartups\"] == 3' '$CLAUDE_CONFIG_DIR/.claude.json' \"\$(cd '$W1' && pwd -P)\""
check "parent markers stripped" "grep -q 'env CLAUDECODE= ' '$T/last-claude' && grep -q 'CODEX_THREAD_ID= ' '$T/last-claude'"
check "config/auth preserved" "grep -q 'CLAUDE_CONFIG_DIR=$T/claude-config' '$T/last-claude' && grep -q 'ANTHROPIC_API_KEY=fake-key' '$T/last-claude'"
check "tmux isolated" "grep -q 'TMUX= TMUX_TMPDIR=/tmp/orchestra-agent-tmux' '$T/last-claude'"
check "ORCHESTRA_* environment injected" "grep -qx 'env ORCHESTRA_SESSION=$S1' '$T/last-claude' && grep -qx 'env ORCHESTRA_SOCKET=$SOCK' '$T/last-claude' && grep -qx 'env ORCHESTRA_MODE=fresh' '$T/last-claude'"
check "no PLAYER_/ORCHESTRATOR_/ORCHESTRA_PLAYER environment" "! grep -qE '^env (PLAYER_|ORCHESTRATOR_|ORCHESTRA_PLAYER)' '$T/last-claude'"
check "identity tags" "[ \"\$(tag $S1 @orchestra-spawner)\" = orchestra ] && [ \"\$(tag $S1 @orchestra-repo)\" = '$REPO' ] && [ \"\$(tag $S1 @orchestra-session-type)\" = worktree ] && [ \"\$(tag $S1 @orchestra-branch)\" = feature/x ]"
check "orchestrator tag" "[ \"\$(tag $S1 @orchestra-orchestrator)\" = tmux:parent ]"
check "harness tag" "[ \"\$(tag $S1 @orchestra-agent)\" = claude ]"
check "launching flag cleared" "[ -z \"\$(tag $S1 @orchestra-launching)\" ]"
check "prompt buffer consumed" "! tm list-buffers -F '#{buffer_name}' | grep -q '^orchestra-prompt-'"
check "no state files in the worktree git dir" "[ -z \"\$(ls \"\$(GITDIR1)\" | grep -E '^player-')\" ]"
check "spawn refuses running session" "! bash '$O/spawn.sh' --repo '$T/repo' --branch feature/x --prompt x --no-node-modules 2>/dev/null"

echo "# report.sh from the player to tmux:parent"
(cd "$W1" && player PROGRESS "hello from smoke") >"$T/report.out" 2>&1
check "report exits 0; a pane without a Claude inbox gets a paste" "[ $? = 0 ] && grep -qx 'sent to parent (paste)' '$T/report.out'"
sleep 0.5
check "parent received report under the session name" "grep -q '\[player $S1\] PROGRESS: hello from smoke' '$T/received-claude'"
check "last-report tag set" "tag $S1 @orchestra-last-report | grep -Eq '^PROGRESS $STAMP paste\$'"
check "--orchestrator prints the tag" "[ \"\$(player --orchestrator)\" = tmux:parent ]"
(cd "$W1" && player --orchestrator tmux:other >/dev/null 2>&1); check "player cannot rebind itself" "[ $? = 2 ] && [ \"\$(tag $S1 @orchestra-orchestrator)\" = tmux:parent ]"
(unset TMUX; tm kill-session -t "=parent")
tm show-options -t "=$S1:" > "$T/options-before-report"
(cd "$W1" && player DONE "gone parent") >"$T/report2.out" 2>"$T/report2.err"
check "gone parent -> nonzero, error on stderr" "[ $? = 1 ] && grep -qx 'report.sh: delivery failed' '$T/report2.err' && [ ! -s '$T/report2.out' ]"
check "error includes target, reason and report" "grep -qx 'Target: tmux:parent' '$T/report2.err' && grep -q '^Reason: orchestrator session parent is gone' '$T/report2.err' && grep -qF 'Report: [player $S1] DONE: gone parent' '$T/report2.err'"
(cd "$W1" && player BLOCKED "second"$'\n'"line") >"$T/report-multiline.out" 2>"$T/report-multiline.err"
check "failed report preserves multiple lines" "[ $? = 1 ] && grep -qF 'Report: [player $S1] BLOCKED: second' '$T/report-multiline.err' && grep -qx 'line' '$T/report-multiline.err'"
check "last-report unchanged by refused reports" "tag $S1 @orchestra-last-report | grep -q '^PROGRESS '"
tm show-options -t "=$S1:" > "$T/options-after-report"
check "failed deliveries do not change session options" "cmp -s '$T/options-before-report' '$T/options-after-report'"
(cd "$W1" && unset TMUX TMUX_PANE && ORCHESTRA_SOCKET="$SOCK" bash "$P/report.sh" DONE "no session") >"$T/report3.out" 2>"$T/report3.err"   # neither ORCHESTRA_SESSION nor TMUX
check "no player session -> error still includes original report" "[ $? = 1 ] && grep -qx 'Target: <unknown>' '$T/report3.err' && grep -q 'DONE: no session' '$T/report3.err'"
check "no mailbox written" "[ ! -e '$HOME/.claude/orchestrator-mail' ] || [ -z \"\$(find '$HOME/.claude/orchestrator-mail' -newer '$T/task.txt' -type f 2>/dev/null)\" ]"
(unset TMUX TMUX_PANE; tm new-session -d -s parent -x 120 -y 30 -- "$T/bin/claude")

echo "# listing"
bash "$O/sessions.sh" --all --json > "$T/sessions.json" 2>/dev/null
check "sessions.sh --json shows tags" "jq -e '.[] | select(.session == \"$S1\") | .name == \"$S1\" and .agent == \"claude\" and .orchestrator == \"tmux:parent\" and .branch == \"feature/x\" and .repo == \"$REPO\" and (.last_report | test(\"^PROGRESS $STAMP paste\$\"))' '$T/sessions.json' >/dev/null"
check "sessions.sh --json never lists the untagged parent" "! jq -e '.[] | select(.session == \"parent\")' '$T/sessions.json' >/dev/null"
check "sessions.sh columns" "bash '$O/sessions.sh' --repo '$T/repo' | head -n1 | grep -q 'SESSION *BRANCH *AGENT' && bash '$O/sessions.sh' --repo '$T/repo' | grep -q '$S1 *feature/x .*tmux:parent'"

echo "# report.sh to a Claude Code orchestrator: its inbox socket, not its pane"
# A pane whose foreground process is "claude", registered the way Claude Code registers a live
# session (<config dir>/sessions/<pid>.json with its inbox socket and start time), and a socat
# listener standing in for that socket.
(unset TMUX TMUX_PANE; tm new-session -d -s claude-orch -x 80 -y 20 -- bash -c 'exec -a claude sleep 300')
cpid="$(tm display-message -p -t '=claude-orch:' '#{pane_pid}')"
for _ in $(seq 50); do [ "$(tr '\0' '\n' < "/proc/$cpid/cmdline" | head -n1)" = claude ] && break; sleep 0.1; done
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
printf '{"pid":%s,"procStart":"%s","messagingSocketPath":"%s","kind":"interactive"}\n' "$cpid" \
  "$(sed 's/.*) //' "/proc/$cpid/stat" | awk '{print $20}')" "$T/inbox.sock" > "$CLAUDE_CONFIG_DIR/sessions/$cpid.json"
socat -u UNIX-LISTEN:"$T/inbox.sock" OPEN:"$T/inbox-received",creat,trunc & inbox_pid=$!
for _ in $(seq 50); do [ -S "$T/inbox.sock" ] && break; sleep 0.1; done
tm set-option -t "=$S1:" @orchestra-orchestrator "tmux:claude-orch"
(cd "$W1" && player DONE "to the inbox"$'\n'"second \"line\"") >"$T/inbox.out" 2>&1; irc=$?
wait "$inbox_pid"
check "claude orchestrator: sent to its inbox, tag says inbox" \
  "[ $irc = 0 ] && grep -qx 'sent to claude-orch (inbox)' '$T/inbox.out' && tag $S1 @orchestra-last-report | grep -Eq '^DONE $STAMP inbox\$'"
check "the inbox got exactly one NDJSON user frame with the report" \
  "[ \"\$(wc -l < '$T/inbox-received')\" = 1 ] && python3 -c 'import json,sys; m=json.loads(open(sys.argv[1]).read()); assert m == {\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"[player '$S1'] DONE: to the inbox\\nsecond \\\"line\\\"\"}}, m' '$T/inbox-received'"
check "nothing was typed into the claude pane" "! tm capture-pane -p -t '=claude-orch:' | grep -q 'to the inbox'"
rm -f "$T/inbox.sock"
(cd "$W1" && player PROGRESS "socket gone") >"$T/inbox-gone.out" 2>&1
check "no live inbox socket: falls back to a paste" "grep -qx 'sent to claude-orch (paste)' '$T/inbox-gone.out'"
tm kill-session -t '=claude-orch'; tm set-option -t "=$S1:" @orchestra-orchestrator "tmux:parent"

echo "# a Claude orchestrator outside tmux is addressed by session id: no pane, never a paste"
# A Claude Code process with no pane, registered under its OWN config dir (not the player's) the
# way Claude Code (or Claude Desktop) registers a live session, and a socat listener as its inbox.
SID=7c0ffee0-1234-4abc-8def-0123456789ab; OCFG="$T/orchestrator-claude-config"; SC=repo-feature-c
bash -c 'exec -a claude sleep 300' & opid=$!
for _ in $(seq 50); do [ "$(tr '\0' '\n' < "/proc/$opid/cmdline" | head -n1)" = claude ] && break; sleep 0.1; done
ostart="$(sed 's/.*) //' "/proc/$opid/stat" | awk '{print $20}')"
register() { mkdir -p "$OCFG/sessions"; printf '{"pid":%s,"sessionId":"%s","procStart":"%s","pidDomain":"linux:%s:%s","messagingSocketPath":"%s","kind":"interactive","entrypoint":"claude-desktop"}\n' \
  "$opid" "$SID" "$1" "$(cat /etc/machine-id)" "$(readlink /proc/self/ns/pid)" "$T/sid.sock" > "$OCFG/sessions/$opid.json"; }
listen() { rm -f "$T/sid.sock" "$T/sid-received"; socat -u UNIX-LISTEN:"$T/sid.sock" OPEN:"$T/sid-received",creat 2>/dev/null & sid_listener=$!
  for _ in $(seq 50); do [ -S "$T/sid.sock" ] && break; sleep 0.1; done; }
unlisten() { for _ in $(seq 30); do kill -0 "$sid_listener" 2>/dev/null || break; sleep 0.1; done; kill "$sid_listener" 2>/dev/null; wait "$sid_listener" 2>/dev/null; }
register "$ostart"; listen
(export CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PID="$opid" CLAUDE_CONFIG_DIR="$OCFG"   # $TMUX still names parent's pane
 bash "$O/spawn.sh" --repo "$T/repo" --branch feature/c --from HEAD --prompt c --no-node-modules --agent claude) >"$T/spawn-c.out" 2>&1
check "spawned from Claude inside tmux: the target is its session id, beside its config dir" \
  "[ \"\$(tag $SC @orchestra-orchestrator)\" = 'claude:$SID' ] && [ \"\$(tag $SC @orchestra-orchestrator-config)\" = '$OCFG' ]"
sleep 1                                                              # the server started under $T/claude-config
check "the player runs on the orchestrator's Claude config dir, not the tmux server's" "grep -q 'CLAUDE_CONFIG_DIR=$OCFG ' '$T/last-claude'"
sc() { (cd "$T/repo/.claude/worktrees/feature-c" && ORCHESTRA_SESSION="$SC" ORCHESTRA_SOCKET="$SOCK" bash "$P/report.sh" "$@"); }
sc DONE "by session id"$'\n'"second \"line\"" >"$T/sid.out" 2>&1; src=$?; unlisten
check "report reached the session registered under the orchestrator's config dir" \
  "[ $src = 0 ] && grep -qx 'sent to $SID (inbox)' '$T/sid.out' && tag $SC @orchestra-last-report | grep -Eq '^DONE $STAMP inbox\$'"
check "its inbox got exactly one NDJSON user frame with the report" \
  "python3 -c 'import json,sys; m=json.loads(open(sys.argv[1]).read()); assert m == {\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"[player '$SC'] DONE: by session id\\nsecond \\\"line\\\"\"}}, m' '$T/sid-received'"
register 1; listen                                                   # a recycled pid: the entry is stale
sc DONE "stale entry" >"$T/sid-stale.out" 2>"$T/sid-stale.err"; src=$?; unlisten
check "a stale registry entry is refused: delivery failed, nothing received" \
  "[ $src = 1 ] && grep -qx 'Target: claude:$SID' '$T/sid-stale.err' && grep -q '^Reason: no live Claude session $SID is registered in $OCFG/sessions' '$T/sid-stale.err' && [ ! -s '$T/sid-received' ]"
register "$ostart"; rm -f "$T/sid.sock"                              # live entry, inbox gone
sc DONE "no inbox" >"$T/sid-gone.out" 2>"$T/sid-gone.err"; src=$?
check "no inbox: delivery failed with no paste fallback anywhere" \
  "[ $src = 1 ] && grep -qx 'report.sh: delivery failed' '$T/sid-gone.err' && ! grep -q 'no inbox' '$T/received-claude' && [ -z \"\$(tm list-buffers -F '#{buffer_name}')\" ]"
kill "$opid"; wait "$opid" 2>/dev/null; tm kill-session -t "=$SC"

echo "# targeting: by branch in a repo, by exact tagged name anywhere; never by prefix or sanitized form"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x-2 --from HEAD --prompt "second" --no-node-modules >/dev/null 2>&1
sleep 1
bash "$O/send.sh" feature/x --repo "$T/repo" --raw "ping-one" >/dev/null && sleep 0.6
check "send.sh by branch hits the right session" "grep -q ping-one '$T/received-claude'"
bash "$O/send.sh" "$S1" "$(head -c 30000 /dev/zero | tr '\0' y)END" >/dev/null 2>&1; check "send.sh by exact name accepts 30 KiB" "[ $? = 0 ]"
check "screen.sh by branch" "bash '$O/screen.sh' feature/x --repo '$T/repo' >/dev/null"
check "screen.sh rejects a prefix" "! bash '$O/screen.sh' feature --repo '$T/repo' 2>/dev/null"
check "screen.sh rejects the sanitized branch" "! bash '$O/screen.sh' feature-x --repo '$T/repo' 2>/dev/null"
check "kill.sh rejects an unknown branch" "! bash '$O/kill.sh' feature --repo '$T/repo' 2>/dev/null && tm has-session -t '=$S1' && tm has-session -t '=$S2'"
printf 'leftover\n' | tm load-buffer -b "orchestra-prompt-$S2" -
bash "$O/kill.sh" feature/x-2 --repo "$T/repo" >/dev/null
check "kill.sh killed only feature/x-2" "! tm has-session -t '=$S2' 2>/dev/null && tm has-session -t '=$S1'"
check "kill.sh removed the leftover prompt buffer" "! tm list-buffers -F '#{buffer_name}' | grep -qx 'orchestra-prompt-$S2'"
check "spawn.sh --help prints comments only" "bash '$O/spawn.sh' --help | grep -q 'Usage: spawn.sh' && ! bash '$O/spawn.sh' --help | grep -qE '^(\\.|set |AGENT=)'"
check "report.sh usage prints comments only" "bash '$P/report.sh' 2>&1 | grep -q 'Usage: report.sh' && ! bash '$P/report.sh' 2>&1 | grep -qE '^(\\.|set )'"

echo "# labels collide, tags decide"
foreign repo-feature-y                                             # a stranger already wears the label feature/y would get
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/y --from HEAD --prompt "collide" --no-node-modules --agent claude >"$T/spawn-y.out" 2>&1; sleep 1
check "spawn takes the next free suffix" "grep -q '^started *repo-feature-y-2\$' '$T/spawn-y.out' && [ \"\$(tag repo-feature-y-2 @orchestra-branch)\" = feature/y ] && grep -qx 'env ORCHESTRA_SESSION=repo-feature-y-2' '$T/last-claude'"
check "stranger left untagged" "[ -z \"\$(tag repo-feature-y @orchestra-spawner)\" ] && [ -z \"\$(tag repo-feature-y @orchestra-session-type)\" ]"
check "spawn again sees the player, not the label" "bash '$O/spawn.sh' --repo '$T/repo' --branch feature/y --prompt x --no-node-modules 2>&1 | grep -q 'running: repo-feature-y-2'"
bash "$O/send.sh" feature/y --repo "$T/repo" --raw "ping-y" >/dev/null && sleep 0.6
check "branch resolves to the suffixed session" "grep -q ping-y '$T/received-claude'"
check "kill.sh refuses the stranger by exact name" "! bash '$O/kill.sh' repo-feature-y --repo '$T/repo' 2>/dev/null && tm has-session -t '=repo-feature-y'"
check "send.sh and screen.sh refuse the stranger" "! bash '$O/send.sh' repo-feature-y --raw x 2>/dev/null && ! bash '$O/screen.sh' repo-feature-y 2>/dev/null"
bash "$O/sessions.sh" --all --json > "$T/sessions-y.json" 2>/dev/null
check "listing shows the player by tags and not the stranger" "jq -e '(map(.session) | index(\"repo-feature-y-2\")) and (map(.session) | index(\"repo-feature-y\") | not)' '$T/sessions-y.json' >/dev/null"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/y-2 --from HEAD --prompt "collide-2" --no-node-modules --agent claude >"$T/spawn-y2.out" 2>&1; sleep 1
check "suffix goes on the preferred label" "grep -q '^started *repo-feature-y-2-2\$' '$T/spawn-y2.out' && [ \"\$(tag repo-feature-y-2-2 @orchestra-branch)\" = feature/y-2 ]"
bash "$O/kill.sh" feature/y --repo "$T/repo" >/dev/null; bash "$O/kill.sh" feature/y-2 --repo "$T/repo" >/dev/null
check "kills by branch hit only the tagged sessions" "! tm has-session -t '=repo-feature-y-2' 2>/dev/null && ! tm has-session -t '=repo-feature-y-2-2' 2>/dev/null && tm has-session -t '=repo-feature-y'"
tm kill-session -t '=repo-feature-y'

echo "# adopt"
bash "$O/adopt.sh" feature/x --repo "$T/repo" --orchestrator tmux:parent "new assignment text" >"$T/adopt.out" 2>&1
check "adopt with text" "[ $? = 0 ] && sleep 0.6 && grep -q -F '$INV new assignment text' '$T/received-claude' && ! grep -q -F '$INV tmux:parent' '$T/received-claude'"
check "adopt set the orchestrator tag" "[ \"\$(tag $S1 @orchestra-orchestrator)\" = tmux:parent ] && [ \"\$(player --orchestrator)\" = tmux:parent ]"
# A plain shell at its prompt inside a player worktree, tagged as a player. /bin/sh has no startup
# files, so the pane is settled before adopt.sh inspects it.
(unset TMUX TMUX_PANE; tm new-session -d -s repo-shellonly -c "$W1" -x 80 -y 20 -- /bin/sh)
for kv in "@orchestra-spawner orchestra" "@orchestra-repo $REPO" "@orchestra-session-type worktree" "@orchestra-branch shellonly"; do tm set-option -t '=repo-shellonly:' $kv; done; sleep 0.5
check "adopt refuses shell pane" "! bash '$O/adopt.sh' shellonly --repo '$T/repo' --orchestrator tmux:other 2>/dev/null"
check "refused adopt left the tag alone" "[ -z \"\$(tag repo-shellonly @orchestra-orchestrator)\" ] && [ \"\$(tag $S1 @orchestra-orchestrator)\" = tmux:parent ]"
tm kill-session -t "=repo-shellonly"
# An agent-like pane (awk, not a shell) that nobody tagged: not ours, whatever its name says.
(unset TMUX TMUX_PANE; tm new-session -d -s repo-untagged -c "$W1" -x 80 -y 20 -- awk '{ print }'); sleep 0.5
check "adopt refuses an untagged session" "! bash '$O/adopt.sh' repo-untagged --repo '$T/repo' --orchestrator tmux:other 2>/dev/null && [ -z \"\$(tag repo-untagged @orchestra-orchestrator)\" ]"
check "kill refuses an untagged session" "! bash '$O/kill.sh' repo-untagged --repo '$T/repo' 2>/dev/null && tm has-session -t '=repo-untagged'"
tm kill-session -t "=repo-untagged"

echo "# adopt a pane Kirby created; report.sh inside it resolves the session from TMUX"
# Kirby tags its worktree sessions with spawner/repo/session-type/branch under its own label. The
# pane leader is awk (not a shell), so adopt.sh treats it as an agent; a REPORT line makes it run
# report.sh from inside the pane, where only TMUX/TMUX_PANE identify the session.
SA="repo-adopted"
(unset TMUX TMUX_PANE; tm new-session -d -s "$SA" -c "$W1" -x 100 -y 20 -- awk -v P="$P" -v T="$T" '/REPORT/ { system("bash \"" P "/report.sh\" DONE \"from inside\" > \"" T "/inside.out\" 2>&1"); next } { print >> (T "/received-inside") }')
for kv in "@orchestra-spawner kirby" "@orchestra-repo $REPO" "@orchestra-session-type worktree" "@orchestra-branch adopted"; do tm set-option -t "=$SA:" $kv; done
sleep 0.5
bash "$O/adopt.sh" adopted --repo "$T/repo" --orchestrator tmux:parent >/dev/null 2>&1; check "adopt of a Kirby pane by branch" "[ $? = 0 ] && [ \"\$(tag $SA @orchestra-orchestrator)\" = tmux:parent ]"
bash "$O/send.sh" adopted --repo "$T/repo" --raw "REPORT" >/dev/null 2>&1; sleep 1.5
check "report.sh inside the pane delivered under the session name" "grep -q 'sent to parent' '$T/inside.out' && grep -q '\[player $SA\] DONE: from inside' '$T/received-claude'"
check "last-report on the adopted session" "tag $SA @orchestra-last-report | grep -Eq '^DONE $STAMP paste\$'"
tm kill-session -t "=$SA"

echo "# resume: dead pane, restart note only, no task replay"
tm send-keys -t "=$S1:" C-d; sleep 0.8
check "pane dead after exit" "[ \"\$(tm display-message -p -t '=$S1:' '#{pane_dead}')\" = 1 ]"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume >"$T/resume.out" 2>&1; rc=$?
sleep 1
check "resume exits 0" "[ $rc = 0 ]"
check "claude --continue with the restart note only" "grep -q '^arg=--continue' '$T/last-claude' && grep -q \"^arg=$INV Your session was restarted\" '$T/last-claude' && grep -q 'finished work\\.\$' '$T/last-claude' && ! grep -q 'END-OF-TASK' '$T/last-claude'"
check "no model/effort on plain resume" "! grep -q '^arg=--model' '$T/last-claude' && ! grep -q '^arg=--effort' '$T/last-claude'"
check "resume does not name the target" "! grep -q 'reporting target' '$T/last-claude' && grep -qx 'env ORCHESTRA_MODE=resume' '$T/last-claude'"
check "resume keeps the orchestrator tag" "[ \"\$(tag $S1 @orchestra-orchestrator)\" = tmux:parent ]"

echo "# resume with a new assignment and explicit overrides"
tm send-keys -t "=$S1:" C-d; sleep 0.8
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume --prompt "Now do the follow-up" --model opus --effort max >/dev/null 2>&1
sleep 1
check "new assignment sent" "grep -q 'Now do the follow-up' '$T/last-claude' && ! grep -q 'END-OF-TASK' '$T/last-claude'"
check "explicit overrides applied" "grep -q '^arg=opus' '$T/last-claude' && grep -q '^arg=max' '$T/last-claude'"

echo "# resume: auto chain (no agent tag) -> claude says no conversation -> codex by cwd"
tm send-keys -t "=$S1:" C-d; sleep 0.8
tm set-option -u -t "=$S1:" @orchestra-agent
touch "$T/fake-claude-noconv"; rm -f "$T/last-call"
uuid=0199a000-1111-7000-8000-000000000042
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$uuid" "$(cd "$W1" && pwd -P)" > "$T/codex-home/sessions/2026/09/13/rollout-2026-09-13T10-00-00-$uuid.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"/elsewhere"}}\n' 0199a000-1111-7000-8000-000000000099 > "$T/codex-home/sessions/2026/09/13/rollout-2026-09-13T11-00-00-0199a000-1111-7000-8000-000000000099.jsonl"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume >"$T/auto.out" 2>&1
sleep 2.5
[ -n "${SMOKE_DEBUG:-}" ] && { echo "--- auto.out ---"; cat "$T/auto.out"; echo "--- screen ---"; bash "$O/screen.sh" "$S1" --lines 12 | cut -c1-160; echo "--- last-call ---"; cat "$T/last-call" 2>/dev/null | head -5; }
check "codex resume with worktree uuid and prompt" "grep -q '^cli=codex' '$T/last-call' && grep -q '^arg=resume' '$T/last-call' && grep -q \"^arg=$uuid\" '$T/last-call' && grep -q '^arg=\$player Your session was restarted' '$T/last-call'"
check "codex harness recorded in the agent tag" "[ \"\$(tag $S1 @orchestra-agent)\" = codex ]"
rm -f "$T/fake-claude-noconv"

echo "# resume: claude fails for another reason -> no codex fallback"
tm send-keys -t "=$S1:" C-d; sleep 0.8
tm set-option -u -t "=$S1:" @orchestra-agent
echo 1 > "$T/fake-claude-exit"; rm -f "$T/last-call"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume >/dev/null 2>&1
sleep 2
check "claude ran, codex did not" "grep -q '^cli=claude' '$T/last-call' && ! grep -q '^cli=codex' '$T/last-call'"
check "pane left dead for inspection" "[ \"\$(tm display-message -p -t '=$S1:' '#{pane_dead}')\" = 1 ]"
check "failed launch leaves no agent tag" "[ -z \"\$(tag $S1 @orchestra-agent)\" ]"
rm -f "$T/fake-claude-exit"

echo "# resume: explicit --agent codex without any recorded conversation -> refuses, no fresh start"
rm -f "$T/codex-home/sessions/2026/09/13/rollout-2026-09-13T10-00-00-$uuid.jsonl"; rm -f "$T/last-call"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume --agent codex >/dev/null 2>&1
sleep 1.5
check "codex not invoked, pane dead" "[ ! -e '$T/last-call' ] && [ \"\$(tm display-message -p -t '=$S1:' '#{pane_dead}')\" = 1 ]"
check "diagnostic visible on screen" "bash '$O/screen.sh' '$S1' | grep -q 'no Codex conversation'"

echo "# resume after the session is gone entirely"
tm kill-session -t "=$S1"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume --agent claude >/dev/null 2>&1; rc=$?
sleep 1
check "resume recreates session" "[ $rc = 0 ] && tm has-session -t '=$S1' && grep -q '^arg=--continue' '$T/last-claude'"
check "recreated session carries the tags" "[ \"\$(tag $S1 @orchestra-spawner)\" = orchestra ] && [ \"\$(tag $S1 @orchestra-session-type)\" = worktree ] && [ \"\$(tag $S1 @orchestra-branch)\" = feature/x ] && [ \"\$(tag $S1 @orchestra-orchestrator)\" = tmux:parent ]"
check "still no state files" "[ -z \"\$(ls \"\$(GITDIR1)\" | grep -E '^player-')\" ]"

echo "# resume when a stranger has taken the label meanwhile"
tm kill-session -t "=$S1"; foreign "$S1"
bash "$O/spawn.sh" --repo "$T/repo" --branch feature/x --resume --agent claude >"$T/resume2.out" 2>&1; rc=$?
sleep 1
check "resume recreates under the next label" "[ $rc = 0 ] && grep -q '^started *$S2\$' '$T/resume2.out' && grep -qx 'env ORCHESTRA_SESSION=$S2' '$T/last-claude' && [ \"\$(tag $S2 @orchestra-branch)\" = feature/x ]"
check "stranger untouched" "tm has-session -t '=$S1' && [ -z \"\$(tag $S1 @orchestra-spawner)\" ]"

echo "# dir player: no branch, no worktree, addressed by its session name"
DP="$T/loose"; mkdir -p "$DP"; SD=loose-dir; DPR="$(cd "$DP" && pwd -P)"
bash "$O/spawn.sh" --dir "$DP" --prompt "tidy up" --agent claude --orchestrator tmux:parent >"$T/spawn-dir.out" 2>&1; rc=$?
sleep 1.5
check "dir spawn starts under the directory's name" "[ $rc = 0 ] && grep -q '^started *$SD\$' '$T/spawn-dir.out' && [ \"\$(tm display-message -p -t '=$SD:' '#{pane_current_path}')\" = '$DPR' ]"
check "dir player tags: type dir, its directory as repo, no branch" \
  "[ \"\$(tag $SD @orchestra-spawner)\" = orchestra ] && [ \"\$(tag $SD @orchestra-session-type)\" = dir ] && [ \"\$(tag $SD @orchestra-repo)\" = '$DPR' ] && [ -z \"\$(tag $SD @orchestra-branch)\" ]"
check "claude starts a conversation with the id recorded on the session" "[ -n \"\$(tag $SD @orchestra-claude-session)\" ] && grep -qx 'arg=--session-id' '$T/last-claude' && grep -qx \"arg=\$(tag $SD @orchestra-claude-session)\" '$T/last-claude'"
check "nothing was created in the directory" "[ -z \"\$(ls -A '$DP')\" ]"
bash "$O/sessions.sh" --all --json > "$T/sessions-dir.json" 2>/dev/null
check "sessions.sh lists it with its directory and no branch" "jq -e '.[] | select(.session == \"$SD\") | .repo == \"$DPR\" and .branch == \"\" and .agent == \"claude\"' '$T/sessions-dir.json' >/dev/null"
(cd "$DP" && ORCHESTRA_SESSION="$SD" ORCHESTRA_SOCKET="$SOCK" bash "$P/report.sh" PROGRESS "from the dir") >"$T/report-dir.out" 2>&1; sleep 0.5
check "its report reaches the orchestrator under its session name" "grep -q '\[player $SD\] PROGRESS: from the dir' '$T/received-claude' && tag $SD @orchestra-last-report | grep -q '^PROGRESS '"
bash "$O/send.sh" "$SD" --raw "ping-dir" >/dev/null && sleep 0.6
check "send.sh and screen.sh by session name" "grep -q ping-dir '$T/received-claude' && bash '$O/screen.sh' '$SD' >/dev/null"
check "adopt.sh by session name" "bash '$O/adopt.sh' '$SD' --orchestrator tmux:parent >/dev/null 2>&1 && [ \"\$(tag $SD @orchestra-orchestrator)\" = tmux:parent ]"
tm send-keys -t "=$SD:" C-d; sleep 0.8
bash "$O/spawn.sh" --dir "$DP" --resume >/dev/null 2>&1; rc=$?; sleep 1
check "resume continues exactly its own conversation" "[ $rc = 0 ] && grep -qx 'arg=--resume' '$T/last-claude' && grep -qx \"arg=\$(tag $SD @orchestra-claude-session)\" '$T/last-claude' && ! grep -qx 'arg=--continue' '$T/last-claude' && grep -q 'restarted in this directory' '$T/last-claude'"
bash "$O/kill.sh" "$SD" >/dev/null
check "kill.sh by session name" "! tm has-session -t '=$SD' 2>/dev/null"
rm -f "$T/last-call"; bash "$O/spawn.sh" --dir "$DP" --resume >/dev/null 2>&1; sleep 1
check "after kill.sh, resume refuses to guess a conversation" "[ ! -e '$T/last-call' ] && bash '$O/screen.sh' '$SD' | grep -q 'no Claude conversation is recorded'"
tm kill-session -t "=$SD"

echo "# machines: a fake beam, real tmux behind it"
# Records every call (one line per call to $T/beam-log); `exec` actually runs the given argv (cd
# to --cwd first, if given) so it reaches the real tmux/codex fakes with stdin forwarded intact —
# the same property the mock in test_port.py proves, here against a real tmux server.
cat > "$T/bin/beam" <<FAKEBEAM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/beam-log"
case "\$1" in
  exec)
    shift; machine="\$1"; shift
    cwd=""
    if [ "\$1" = --cwd ]; then cwd="\$2"; shift 2; fi
    [ "\$1" = -- ] && shift
    if [ -n "\$cwd" ]; then cd "\$cwd" || exit 1; fi
    exec "\$@"
    ;;
  status)
    printf '{"peerId":"%s","label":"orchestrator-host"}\n' "\${FAKE_BEAM_PEER_ID:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    ;;
  msg)
    case "\$2" in
      send)
        # beam msg send <peer> --topic T -: no --json (beam/docs/07-cli.md); anything else is usage.
        peer="\$3"
        [ "\$#" = 6 ] && [ "\$4" = --topic ] && [ "\$6" = - ] || { echo usage >&2; exit 2; }
        cat > "$T/beam-sent-payload"
        printf '%s\n' "\$peer" > "$T/beam-sent-peer"
        case "\${FAKE_BEAM_OUTCOME:-delivered}" in
          delivered) printf 'delivered to %s\n' "\$peer";;
          stored) printf 'stored for %s; delivery pending (%s is offline). beam will deliver it when %s connects. Do not send it again.\n' "\$peer" "\$peer" "\$peer";;
          *) printf 'rejected: %s\n' "\${FAKE_BEAM_REJECT_REASON:-unknown-peer}" >&2; exit 1;;
        esac
        ;;
    esac
    ;;
esac
FAKEBEAM
chmod +x "$T/bin/beam"

# A fake beam daemon for relay.sh: beam's control socket on a real AF_UNIX socket at
# $BEAM_SOCKET (beam/docs/06-control-socket.md). Each connection that subscribes is offered the
# envelopes in $T/beam-inbox, one at a time, each only after the previous was settled with
# msg.ack or msg.defer; once nothing is left it closes the connection and exits. Requests are
# logged, one JSON line each, to $T/beamd-log.
cat > "$T/bin/beamd" <<'FAKEBEAMD'
#!/usr/bin/env python3
import os, json, socket, sys
path, inbox_file, log_file = os.environ['BEAM_SOCKET'], sys.argv[1], sys.argv[2]
inbox = [l for l in open(inbox_file).read().splitlines() if l]
srv = socket.socket(socket.AF_UNIX); srv.bind(path); srv.listen(1); srv.settimeout(20)
conn, _ = srv.accept(); f = conn.makefile('rb'); pending = list(inbox); inflight = None
def send(obj): conn.sendall(json.dumps(obj, separators=(',', ':')).encode() + b'\n')
for line in f:
    req = json.loads(line); open(log_file, 'a').write(json.dumps(req) + '\n')
    if req['op'] in ('msg.ack', 'msg.defer'): inflight = None
    send({'id': req['id'], 'ok': True, 'result': {}})
    if inflight is None and pending: inflight = pending.pop(0); send({'event': 'mail', 'data': json.loads(inflight)})
    elif inflight is None: break
conn.close(); srv.close(); os.unlink(path)
FAKEBEAMD
chmod +x "$T/bin/beamd"
export BEAM_SOCKET="$T/beam.sock"
# relay_with_daemon <relay args…>: one relay.sh run against a fresh fake daemon.
relay_with_daemon() {
  rm -f "$T/beamd-log"; "$T/bin/beamd" "$T/beam-inbox" "$T/beamd-log" & local d=$!
  local i; for i in $(seq 50); do [ -S "$BEAM_SOCKET" ] && break; sleep 0.1; done
  bash "$O/relay.sh" "$@"; local rc=$?; wait "$d"; return $rc
}

# Every tmux call for a machine names that machine's own server: the socket is asked of the
# target once (a shell there, so $TMUX and its uid are the target's) and passed as -S on every
# call after it. Without that, a bare remote tmux would resolve its own default socket and this
# send would land on a different server than the one the session is on.
check "--machine routes tmux argv through beam exec, stdin intact" \
  "bash '$O/send.sh' feature/x --repo '$T/repo' --machine workbox 'via-machine' >/dev/null 2>&1 && sleep 0.6 && grep -q via-machine '$T/received-claude' && grep -q '^exec workbox -- tmux' '$T/beam-log'"
check "--machine asks the target for its socket, then names it on every tmux call" \
  "grep -q \"^exec workbox -- sh -c \" '$T/beam-log' && grep -q '^exec workbox -- tmux -u -S $SOCK ' '$T/beam-log' && ! grep -qE '^exec workbox -- tmux -u [^-]' '$T/beam-log'"

env PATH=/usr/bin:/bin bash -c '. "'"$P"'/_routing.sh"; ORCH_MACHINE=ghost tmux_on "" list-sessions' >"$T/missing-beam.out" 2>"$T/missing-beam.err"; mbrc=$?
check "missing beam binary fails loudly, names both options, runs nothing locally" \
  "[ $mbrc != 0 ] && [ ! -s '$T/missing-beam.out' ] && grep -q ORCHESTRA_BEAM '$T/missing-beam.err' && grep -q \"'beam' on PATH\" '$T/missing-beam.err' && ! grep -q n10 '$T/missing-beam.err' && grep -q 'refusing to run this locally' '$T/missing-beam.err'"

echo "# B4/B5: report.sh ignores an inherited ORCHESTRA_MACHINE; resolve_orchestrator answers locally"
# $S1 is a stranger by this point (the "resume when a stranger has taken the label" section
# above); $S2 is the actual current player, still reporting to tmux:parent.
rm -f "$T/beam-log"
tm set-option -t "=$S2:" @orchestra-orchestrator "tmux:parent"    # pin it: no dependency on tmux's "current session" fallback drifting by this point in the run
(cd "$W1" && ORCHESTRA_MACHINE=workbox ORCHESTRA_SESSION="$S2" ORCHESTRA_SOCKET="$SOCK" bash "$P/report.sh" PROGRESS "still local") >"$T/b5.out" 2>"$T/b5.err"
check "report.sh never asks 'workbox' about anything, even with ORCHESTRA_MACHINE set" \
  "grep -q 'sent to parent' '$T/b5.out' && [ ! -s '$T/beam-log' ]"

echo "# report.sh over beam: delivered, stored, rejected"
tm set-option -t "=$S1:" @orchestra-orchestrator "beam:deadbeefcafef00ddeadbeefcafef00d/tmux:parent"
export FAKE_BEAM_OUTCOME=delivered
(cd "$W1" && player DONE "over beam") >"$T/beam-report.out" 2>&1; brc=$?
check "beam delivered: 'sent to', payload on stdin, tag carries a third field" \
  "[ $brc = 0 ] && grep -qx 'sent to deadbeefcafef00ddeadbeefcafef00d' '$T/beam-report.out' && grep -q '^msg send deadbeefcafef00ddeadbeefcafef00d --topic orchestra -\$' '$T/beam-log' && grep -q 'target: tmux:parent' '$T/beam-sent-payload' && tag $S1 @orchestra-last-report | grep -Eq '^DONE $STAMP delivered\$'"
export FAKE_BEAM_OUTCOME=stored
(cd "$W1" && player PROGRESS "still working") >"$T/beam-stored.out" 2>&1; brc=$?
check "beam stored: success, exact wording, tag says stored" \
  "[ $brc = 0 ] && grep -qxF 'stored for deadbeefcafef00ddeadbeefcafef00d; delivery pending (deadbeefcafef00ddeadbeefcafef00d is offline). beam will deliver it when deadbeefcafef00ddeadbeefcafef00d connects. Do not send it again.' '$T/beam-stored.out' && tag $S1 @orchestra-last-report | grep -Eq '^PROGRESS $STAMP stored\$'"
export FAKE_BEAM_OUTCOME=rejected FAKE_BEAM_REJECT_REASON="unknown-peer"
before_opts="$(tm show-options -t "=$S1:")"
(cd "$W1" && player BLOCKED "need help") >"$T/beam-rejected.out" 2>"$T/beam-rejected.err"; brc=$?
check "beam rejected: delivery failed with beam's reason, no session write" \
  "[ $brc = 1 ] && grep -qx 'report.sh: delivery failed' '$T/beam-rejected.err' && grep -q 'Target: beam:deadbeefcafef00ddeadbeefcafef00d/tmux:parent' '$T/beam-rejected.err' && grep -q 'Reason: beam rejected the message (exit 1): unknown-peer' '$T/beam-rejected.err' && grep -qF 'Report: [player $S1] BLOCKED: need help' '$T/beam-rejected.err' && [ \"\$(tm show-options -t "=$S1:")\" = \"\$before_opts\" ]"
unset FAKE_BEAM_OUTCOME FAKE_BEAM_REJECT_REASON
tm set-option -t "=$S1:" @orchestra-orchestrator "tmux:parent"

echo "# relay.sh delivers a beamed-in envelope to a real local pane"
# Without a real attached client, tmux resolves an untargeted "current session" (what
# tmux_local/display-message without -t falls back to; see _routing.sh) to the most recently
# active session on the server, not by decoding $TMUX's own fields — harmless for a script that
# really is running inside the pane it names, but this harness has created many sessions since
# "parent" was last (re)created, so it is refreshed here to be that session again, the same way
# the "report.sh from the player" section above already resets it after killing it.
tm kill-session -t '=parent' 2>/dev/null
(unset TMUX TMUX_PANE; tm new-session -d -s parent -x 120 -y 30 -- "$T/bin/claude")
tm set-option -t "=$S1:" @orchestra-orchestrator "tmux:parent"
printf '{"id":"e1","from":"p","to":"q","seq":1,"topic":"orchestra","encoding":"utf8","payload":"target: tmux:parent\\n\\n[player relayed] DONE: via relay"}\n' > "$T/beam-inbox"
relay_with_daemon >"$T/relay.out" 2>"$T/relay.err"      # $TMUX is already exported above, as it would be from an orchestrator's own pane
check "relay.sh subscribes on the control socket with flat parameters" \
  "[ \"\$(head -n1 '$T/beamd-log')\" = '{\"id\": 1, \"op\": \"msg.subscribe\", \"topic\": \"orchestra\"}' ]"
check "relay.sh delivers the envelope's local target" \
  "grep -q 'relay.sh: delivered to tmux:parent' '$T/relay.err' && sleep 0.5 && grep -qF '[player relayed] DONE: via relay' '$T/received-claude'"
check "relay.sh acks the envelope once delivered" \
  "grep -qF '\"op\": \"msg.ack\", \"envelopeId\": \"e1\"' '$T/beamd-log' && ! grep -q msg.defer '$T/beamd-log'"

echo "# relay.sh: an envelope naming a target outside the default allowlist is refused and deferred"
# $S1 is still the stranger "sleep 300" session foreign() planted earlier: real tmux reports its
# pane_current_command as "sleep", not a shell, so pane_owned_by_agent alone would call it fair
# game — exactly the pane a relay must not touch just because an envelope names it.
printf '{"id":"e2","from":"attacker","to":"q","seq":2,"topic":"orchestra","encoding":"utf8","payload":"target: tmux:%s\\n\\npaste into the users own session"}\n' "$S1" > "$T/beam-inbox"
relay_with_daemon >"$T/refuse.out" 2>"$T/refuse.err"
check "outside-allowlist envelope is refused, names the sending peer, and never pasted" \
  "grep -q 'outside this relay' '$T/refuse.err' && grep -q attacker '$T/refuse.err' && ! grep -qF 'paste into the users own session' '$T/received-claude'"
check "refused envelope is deferred with the reason, never acked" \
  "grep -q '\"op\": \"msg.defer\", \"envelopeId\": \"e2\", \"reason\": \"tmux:$S1 is outside' '$T/beamd-log' && ! grep -q msg.ack '$T/beamd-log'"

echo "# relay.sh --allow adds an explicit extra target"
printf '{"id":"e3","from":"p","to":"q","seq":3,"topic":"orchestra","encoding":"utf8","payload":"target: codex:%s\\n\\nvia allow"}\n' "$uuid" > "$T/beam-inbox"
relay_with_daemon --allow "codex:$uuid" >"$T/allow.out" 2>"$T/allow.err"
check "explicitly allowed target is delivered" "grep -q 'relay.sh: delivered to codex:'$uuid'' '$T/allow.err'"

echo "# relay.sh refuses to run with no default target and no --allow"
env -u TMUX bash "$O/relay.sh" --topic orchestra >"$T/noallow.out" 2>"$T/noallow.err"; noallow_rc=$?
check "relay.sh needs --allow outside a tmux pane" \
  "[ $noallow_rc = 2 ] && grep -q 'pass --allow' '$T/noallow.err'"

echo; echo "passed $pass, failed $fail"; [ $fail = 0 ]
