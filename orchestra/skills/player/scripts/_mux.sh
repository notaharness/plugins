# The n10 arm of the session backend (_routing.sh, uses_mux): on a machine without tmux, player
# sessions belong to a running n10 (its desktop, its TUI or `n10 mux serve`) and are reached
# through `n10 mux`, one process per verb. A request is one JSON object on stdin, built with
# json_str; an answer is n10's fixed 31-column TSV summary row, raw capture text or a
# `CODE<TAB>message` line on stderr with a nonzero exit (notaharness/n10,
# docs/design/windows-support.md, "Mux commands and protocol"). Nothing here parses JSON.
#
# A session is still named by its label, which n10 keeps unique among its sessions; each helper
# looks the label up in one `list` and acts on the session ID, process generation and owner it
# read, so a mutation never lands on a process other than the one just seen.
#
# Paths cross into n10 as the owner's native paths and come back as this shell's: on Git for
# Windows' Bash, cygpath converts the cwd, PATH, HOME and account directories of a launch and the
# path-valued tags, in both directions. Elsewhere both forms are the same string.

MUX_TAB=$'\t'
# MSYS rewrites arguments that look like paths when Git Bash runs a native program; n10 is given
# none (paths travel in the JSON on stdin), so nothing it is given is rewritten.
mux() { MSYS2_ARG_CONV_EXCL='*' n10 mux "$@"; }

if command -v cygpath >/dev/null 2>&1; then
  native_path() { cygpath -w "$1"; }
  native_path_list() { cygpath -wp "$1"; }
  bash_path() { cygpath -u "$1"; }
else
  native_path() { printf '%s' "$1"; }
  native_path_list() { printf '%s' "$1"; }
  bash_path() { printf '%s' "$1"; }
fi

# Summary row columns, 0-based (n10's table numbers them from 1). Tags follow in n10's order.
MUX_ID=0 MUX_HOST=1 MUX_GEN=2 MUX_LABEL=3 MUX_CREATED=4 MUX_CWD=5 MUX_STATE=6 MUX_PID=7
MUX_LAST_OUTPUT=11 MUX_KIND=12 MUX_AGENT=13 MUX_CAPTURE=29 MUX_TITLE=30
MUX_TAGS=("$TAG_SPAWNER" "$TAG_REPO" "$TAG_SESSION_TYPE" "$TAG_BRANCH" "$TAG_WORKTREE_PATH" "$TAG_AGENT"
  "$TAG_ORCHESTRATOR" "$TAG_ORCH_CONFIG" "$TAG_LAST_REPORT" "$TAG_CLAUDE_SESSION" "$TAG_TARGET" "$TAG_LAUNCHING")
mux_tag_column() { local i; for i in "${!MUX_TAGS[@]}"; do [ "${MUX_TAGS[$i]}" = "$1" ] && { echo $((14 + i)); return 0; }; done; return 1; }
mux_path_tag() { case "$1" in "$TAG_REPO"|"$TAG_WORKTREE_PATH"|"$TAG_ORCH_CONFIG") return 0;; *) return 1;; esac; }

# mux_split <row>: the row's 31 fields into MUX_F, split on the first 30 tabs (the title, last,
# keeps any of its own), with the cwd and path-valued tags in this shell's form.
mux_split() {
  local row="$1" i tag col
  MUX_F=()
  for ((i = 0; i < 30; i++)); do MUX_F+=("${row%%"$MUX_TAB"*}"); row="${row#*"$MUX_TAB"}"; done
  MUX_F+=("$row")
  [ -n "${MUX_F[$MUX_CWD]}" ] && MUX_F[$MUX_CWD]="$(bash_path "${MUX_F[$MUX_CWD]}")"
  for tag in "$TAG_REPO" "$TAG_WORKTREE_PATH" "$TAG_ORCH_CONFIG"; do
    col="$(mux_tag_column "$tag")"
    [ -z "${MUX_F[$col]}" ] || MUX_F[$col]="$(bash_path "${MUX_F[$col]}")"
  done
}
mux_tag() { local col; col="$(mux_tag_column "$1")" && printf '%s' "${MUX_F[$col]}"; }

# mux_rows [--capture N]: every session's row, oldest first; fails, printing nothing, when n10
# cannot answer.
mux_rows() { mux list "$@"; }
# mux_find <label>: MUX_F for the session with that label; fails when there is none.
mux_find() {
  local rows row
  rows="$(mux_rows 2>/dev/null)" || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    mux_split "$row"; [ "${MUX_F[$MUX_LABEL]}" = "$1" ] && return 0
  done <<<"$rows"
  MUX_F=(); return 1
}
# mux_self: MUX_F for the session this process runs in, as its owner confirms it from the
# N10_MUX_* variables it launched the process with; fails outside one.
mux_self() {
  local row
  [ -n "${N10_MUX_SESSION_ID:-}" ] && row="$(mux self 2>/dev/null)" && [ -n "$row" ] || return 1
  mux_split "$row"
}
mux_self_target() { mux_self && printf 'mux:%s/%s' "${MUX_F[$MUX_HOST]}" "${MUX_F[$MUX_ID]}"; }

# mux_json_object <key> <value>…: one flat JSON object of string values.
mux_json_object() {
  local out="" sep=""
  while [ $# -ge 2 ]; do out+="$sep$(json_str "$1"):$(json_str "$2")"; sep=,; shift 2; done
  printf '{%s}' "$out"
}
mux_json_array() { local out="" sep="" v; for v; do out+="$sep$(json_str "$v")"; sep=,; done; printf '[%s]' "$out"; }

# mux_tag_write <label> set|unset <tag> [value]: one tag of that session, as an atomic metadata
# update of the owner it was read from.
mux_tag_write() {
  local value="${4:-}" body
  mux_find "$1" || { echo "no such session: $1" >&2; return 1; }
  mux_path_tag "$3" && [ -n "$value" ] && value="$(native_path "$value")"
  if [ "$2" = set ]; then body="\"set\":$(mux_json_object "$3" "$value")"; else body="\"unset\":$(mux_json_array "$3")"; fi
  printf '{"expectedHostId":%s,%s}' "$(json_str "${MUX_F[$MUX_HOST]}")" "$body" | mux metadata "${MUX_F[$MUX_ID]}" --request - >/dev/null
}
# mux_claim <target>: write <target> as this session's @orchestra-target, taken from any other
# session of the same owner in the same step.
mux_claim() {
  mux_self || return 1
  printf '{"expectedHostId":%s,"claimTarget":%s}' "$(json_str "${MUX_F[$MUX_HOST]}")" "$(json_str "$1")" |
    mux metadata "${MUX_F[$MUX_ID]}" --request - >/dev/null
}

# mux_send <label> paste|literal|key <text or key> [submit]: one send to the process just
# inspected. On failure DELIVER_REASON says why, in n10's words; an uncertain outcome says to
# inspect, since the input may have arrived.
mux_send() {
  local label="$1" mode="$2" what="$3" submit="${4:+true}" field=text err
  mux_find "$label" || { DELIVER_REASON="$label is gone or unreachable"; return 1; }
  [ "$mode" = key ] && field=key
  err="$(printf '{"expectedHostId":%s,"generation":%s,"mode":"%s",%s:%s,"submit":%s}' \
    "$(json_str "${MUX_F[$MUX_HOST]}")" "${MUX_F[$MUX_GEN]}" "$mode" "\"$field\"" "$(json_str "$what")" "${submit:-false}" |
    mux send "${MUX_F[$MUX_ID]}" --request - 2>&1 >/dev/null)" && return 0
  case "$err" in
    OUTCOME_UNKNOWN*) DELIVER_REASON="n10 lost the answer to the send to $label; inspect before retrying";;
    *) DELIVER_REASON="n10 could not send to $label: ${err#*"$MUX_TAB"}";;
  esac
  return 1
}

# mux_stop <label>: stop that session's process and remove its record.
mux_stop() {
  mux_find "$1" || { echo "no such session: $1" >&2; return 1; }
  printf '{"expectedHostId":%s,"generation":%s}' "$(json_str "${MUX_F[$MUX_HOST]}")" "${MUX_F[$MUX_GEN]}" |
    mux stop "${MUX_F[$MUX_ID]}" --request -
}

# mux_capture <label> <history lines>: the screen and that much history, as text.
mux_capture() { mux_find "$1" && mux capture "${MUX_F[$MUX_ID]}" --history "$2"; }

# mux_sessions_tagged: list_sessions_tagged's fields for every session.
mux_sessions_tagged() {
  local row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    mux_split "$row"
    printf '%s\n' "${MUX_F[$MUX_LABEL]}$MUX_TAB${MUX_F[$MUX_CREATED]}$MUX_TAB${MUX_F[$MUX_CWD]}$MUX_TAB$(mux_tag "$TAG_SPAWNER")$MUX_TAB$(mux_tag "$TAG_REPO")$MUX_TAB$(mux_tag "$TAG_SESSION_TYPE")$MUX_TAB$(mux_tag "$TAG_BRANCH")$MUX_TAB$(mux_tag "$TAG_WORKTREE_PATH")"
  done < <(mux_rows 2>/dev/null)
}
# mux_panes: sessions.sh's listing fields for every session. The command is the agent n10
# launched directly; a process it cannot vouch for has none.
mux_panes() {
  local row dead
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    mux_split "$row"; dead=0; [ "${MUX_F[$MUX_STATE]}" = running ] || dead=1
    printf '%s\n' "${MUX_F[$MUX_LABEL]}$MUX_TAB$dead$MUX_TAB${MUX_F[$MUX_AGENT]}$MUX_TAB${MUX_F[$MUX_LAST_OUTPUT]}$MUX_TAB$(mux_tag "$TAG_AGENT")$MUX_TAB$(mux_tag "$TAG_ORCHESTRATOR")$MUX_TAB$(mux_tag "$TAG_LAST_REPORT")$MUX_TAB$(mux_tag "$TAG_REPO")$MUX_TAB$(mux_tag "$TAG_BRANCH")$MUX_TAB$(mux_tag "$TAG_SPAWNER")$MUX_TAB$(mux_tag "$TAG_SESSION_TYPE")$MUX_TAB$(mux_tag "$TAG_WORKTREE_PATH")$MUX_TAB${MUX_F[$MUX_TITLE]}"
  done < <(mux_rows 2>/dev/null)
}
# mux_screen_digests: "<label><TAB><digest>" per session, of its screen as screen_text would
# print it, every screen from one batched `list --capture 0` (_lib.sh's normalize_screen).
mux_screen_digests() {
  local row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    mux_split "$row"
    printf '%s\t%s\n' "${MUX_F[$MUX_LABEL]}" "$(printf '%s' "${MUX_F[$MUX_CAPTURE]}" | base64 -d | normalize_screen | md5sum)"
  done < <(mux_rows --capture 0 2>/dev/null)
}

# mux_agent <label>: is a verified agent running in that session? It is when n10 launched the
# agent's own executable there; then PANE_AGENT and PANE_AGENT_PID name it. A shell, or a program
# a shell started, is never taken for one.
mux_agent() {
  mux_find "$1" && [ "${MUX_F[$MUX_STATE]}" = running ] && [ "${MUX_F[$MUX_KIND]}" = agent ] || return 1
  PANE_AGENT="${MUX_F[$MUX_AGENT]}"; PANE_AGENT_PID="${MUX_F[$MUX_PID]}"
}
# mux_target_label <hostId>/<sessionId>: the label of that session, while the owner that holds
# it is the one running; fails for a target an earlier owner held.
mux_target_label() {
  local row
  row="$(mux inspect "${1#*/}" 2>/dev/null)" && [ -n "$row" ] || return 1
  mux_split "$row"
  [ "${MUX_F[$MUX_HOST]}" = "${1%%/*}" ] && printf '%s' "${MUX_F[$MUX_LABEL]}"
}
