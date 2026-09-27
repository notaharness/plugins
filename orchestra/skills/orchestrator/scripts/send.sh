#!/usr/bin/env bash
# Send a player a message — answer a question, add a follow-up, nudge. Text is prefixed
# "[orchestrator] " so the player knows it is not the user speaking. Claude Code uses its inbox
# socket when available. Codex receives a bracketed paste and Enter through its TUI, so an idle
# prompt starts a turn without relying on an external queue draining. Normal sends require a
# detached, verifiably empty composer; drafts, attached clients and unknown displays are refused.
# Other players use the shared delivery routes. --raw sends text verbatim as a paste (a menu
# choice like "1" or "y"), --key a keypress and --type literal keystrokes, always into the pane.
#
# Usage: send.sh <session> [--repo <path>] [--machine NAME] <text…>
#        send.sh <session> [--repo <path>] [--machine NAME] --raw <text…>
#        send.sh <session> [--repo <path>] [--machine NAME] --key <tmux key>   e.g. Escape, C-c, Enter, Up
#        send.sh <session> [--repo <path>] [--machine NAME] --type <text…>    typed literally, not pasted:
#                                                               for slash commands (/reload-skills)
# --machine: the beam peer label or peerId the session is on; default $ORCHESTRA_MACHINE, else
# this machine. A remote --repo must be absolute or start with ~/.
# The session is a branch (resolved in this repo, --repo, or uniquely across repos) or an exact
# tmux session name of a tagged player (a dir player's only name); never a prefix, never an
# untagged session. Long text is fine: it is pasted from a buffer, not on the command line. Prints
# "sent to <session> (inbox|paste)".
. "$(dirname "$(realpath "$0")")/_lib.sh"
[ $# -ge 2 ] || { sed -n '2,20p' "$0" >&2; exit 2; }
session="$1"; shift
while [ "${1:-}" = "--repo" ] || [ "${1:-}" = "--machine" ]; do
  case "$1" in --repo) ORCH_REPO="$2";; --machine) ORCH_MACHINE="$2";; esac; shift 2
done
[ $# -ge 1 ] || { sed -n '2,20p' "$0" >&2; exit 2; }
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
if [ "$1" = "--raw" ]; then
  shift; paste_into "$target" "$*" || { echo "send.sh: $DELIVER_REASON" >&2; exit 1; }
  echo "sent to $target (paste)"; exit
fi
# Which agent is at the terminal decides the route; a shell there still gets the paste, as a
# nudge to a pane whose agent has exited always has.
pane_owned_by_agent "" "$target" || :
# A Codex tag works on remote machines too, where process ownership cannot be inspected.
# Refuse before loading a buffer unless the default Codex composer is visibly empty. Cursor
# position alone is insufficient: Home puts a cursor at column 2 even with a draft present.
# Unknown themes/renderings fail closed. An attached client may be actively editing a draft.
codex_composer_empty() {
  local before after screen row line prefix=$'\033[1m›\033[0m \033[2m' suffix=$'\033[0m' placeholder
  before="$(tmux_on "" display-message -p -t "$tt" '#{cursor_x} #{cursor_y} #{session_attached} #{pane_in_mode}')" || return 1
  [[ "$before" =~ ^2\ ([0-9]+)\ 0\ 0$ ]] || return 1
  row="${BASH_REMATCH[1]}"
  screen="$(tmux_on "" capture-pane -p -e -t "$tt")" || return 1
  after="$(tmux_on "" display-message -p -t "$tt" '#{cursor_x} #{cursor_y} #{session_attached} #{pane_in_mode}')" || return 1
  [ "$before" = "$after" ] || return 1
  line="$(printf '%s\n' "$screen" | sed -n "$((row + 1))p")"
  case "$line" in
    "$prefix"*"$suffix")
      placeholder="${line#"$prefix"}"; placeholder="${placeholder%"$suffix"}"
      # Only a dim placeholder is empty. Normal text, multiline drafts and completion popups
      # cannot satisfy this exact rendering, even if the text spells the placeholder itself.
      [ -n "$placeholder" ] && [[ "$placeholder" != *$'\033'* ]];;
    *) return 1;;
  esac
}
if [ "$PANE_AGENT" = codex ] || [ "$(tag_get "" "$target" "$TAG_AGENT")" = codex ]; then
  codex_composer_empty || { echo "send.sh: Codex composer is not verifiably empty and detached (draft, attached client or unsupported display); no text sent" >&2; exit 1; }
  # End at a blank line so a trailing $skill or @path does not leave a completion
  # popup consuming Enter. Codex trims this trailing newline when submitting.
  paste_into "$target" "[orchestrator] $*"$'\n' || { echo "send.sh: $DELIVER_REASON" >&2; exit 1; }
  echo "sent to $target (paste)"; exit
fi
deliver_to_pane "" "$target" "[orchestrator] $*" || { echo "send.sh: $DELIVER_REASON" >&2; exit 1; }
echo "sent to $target ($DELIVER_ROUTE)"
