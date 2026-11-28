# shellcheck shell=bash
# Shared paths for the learning-candidate scripts.
#
# The open queue (the inbox) lives outside git, so candidates never sit
# uncommitted in a checkout that other agents share. The weekly review archives
# resolved candidates in the repo (see ../README.md).
learning_inbox() {
  printf '%s\n' "${AGENT_LEARNING_INBOX:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-learning/inbox}"
}
learning_archive() {
  if [[ -n ${LEARNING_ARCHIVE:-} ]]; then
    printf '%s\n' "$LEARNING_ARCHIVE"
  else
    printf '%s\n' "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/candidates/archive"
  fi
}
