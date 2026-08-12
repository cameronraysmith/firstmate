#!/usr/bin/env bash
# Report which Herdr session and pane THIS process is really running in, and
# whether its injected HERDR_* environment agrees.
#
# Usage: fm-herdr-whereami.sh [--json]
#
# Why this exists: Herdr injects HERDR_SESSION, HERDR_SOCKET_PATH,
# HERDR_PANE_ID, and HERDR_WORKSPACE_ID once, when a pane's process starts, and
# cannot rewrite a running process's environment afterwards. A daemon-launched
# agent therefore inherits whatever was fixed at the LAUNCHING process's
# creation. The error is self-confirming: every bare `herdr` call, including
# `herdr status`, resolves through that same environment (Herdr 0.8.0
# src/session.rs prefers HERDR_SOCKET_PATH when no explicit --session is given),
# so no Herdr query can report the true session. Only comparing a pane's own
# shell process against this process's ancestry can.
#
# DETECTOR, NEVER A SELECTOR. Worker placement is chosen from the project
# registry (bin/fm-project-mode.sh --session, docs/herdr-backend.md "Session
# selection"). This command diagnoses an environment; it never decides where a
# worker goes, and it reports an unresolved location rather than guessing one.
#
# Read-only: it lists sessions, lists panes, and reads pane process info. It
# creates, focuses, stops, and deletes nothing.
#
# Exit status:
#   0  the real pane was located (`located` true), whether or not the injected
#      environment agreed with it
#   3  no real pane could be located: this process is not running in a Herdr
#      pane of any reachable session, or the evidence could not be read
#   1  Herdr or jq is missing, or the session list itself is unreadable
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr

JSON=0
case "${1:-}" in
  --json) JSON=1 ;;
  -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

command -v herdr >/dev/null 2>&1 || { echo "error: herdr is not installed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is not installed (required to parse herdr's JSON output)" >&2; exit 1; }

CLAIMED_SESSION=$(fm_backend_herdr_ambient_claimed_session)
CLAIMED_PANE=${HERDR_PANE_ID:-}
CLAIMED_SOCKET=${HERDR_SOCKET_PATH:-}

# Every ancestor of this process, so a pane's shell pid can be matched against
# it exactly once rather than re-walked per candidate pane.
ANCESTORS=$(fm_backend_herdr_self_pid_chain)
is_own_ancestor() {  # <pid>
  local want=$1 pid
  [ -n "$want" ] || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$want" ] && return 0
  done <<EOF
$ANCESTORS
EOF
  return 1
}

SESSIONS=$(herdr session list --json 2>/dev/null \
  | jq -r '.sessions[]? | select(.running == true) | .name' 2>/dev/null) || SESSIONS=
[ -n "$SESSIONS" ] || { echo "error: no running herdr session could be listed" >&2; exit 1; }

# The scan is deliberately exhaustive rather than starting from the claimed
# session: the claim is the thing under suspicion, so trusting it to narrow the
# search would reproduce the same self-confirming answer.
REAL_SESSION=""
REAL_PANE=""
REAL_WORKSPACE=""
MATCHES=0
SCANNED=0
UNREADABLE=""
while IFS= read -r session; do
  [ -n "$session" ] || continue
  panes=$(fm_backend_herdr_cli "$session" pane list 2>/dev/null \
    | jq -r '.result.panes[]? | [.pane_id, .workspace_id] | @tsv' 2>/dev/null) || panes=
  if [ -z "$panes" ]; then
    UNREADABLE="$UNREADABLE $session"
    continue
  fi
  SCANNED=$((SCANNED + 1))
  while IFS=$'\t' read -r pane workspace; do
    [ -n "$pane" ] || continue
    shell_pid=$(fm_backend_herdr_pane_shell_pid "$session" "$pane")
    is_own_ancestor "$shell_pid" || continue
    MATCHES=$((MATCHES + 1))
    REAL_SESSION=$session
    REAL_PANE=$pane
    REAL_WORKSPACE=$workspace
  done <<EOF
$panes
EOF
done <<EOF
$SESSIONS
EOF

# One pane per shell process, so a second match means the evidence itself is
# contradictory. Report that rather than picking a winner.
LOCATED=false
if [ "$MATCHES" -eq 1 ]; then
  LOCATED=true
elif [ "$MATCHES" -gt 1 ]; then
  REAL_SESSION=""
  REAL_PANE=""
  REAL_WORKSPACE=""
fi

if [ -z "$CLAIMED_PANE" ]; then
  CLAIM_VERDICT=none
elif [ "$LOCATED" = true ]; then
  if [ "$CLAIMED_SESSION" = "$REAL_SESSION" ] && [ "$CLAIMED_PANE" = "$REAL_PANE" ]; then
    CLAIM_VERDICT=accurate
  else
    CLAIM_VERDICT=stale
  fi
else
  CLAIM_VERDICT=$(fm_backend_herdr_ambient_claim_verdict "$CLAIMED_SESSION" "$CLAIMED_PANE")
  case "$CLAIM_VERDICT" in
    not-mine) CLAIM_VERDICT=stale ;;
    mine) CLAIM_VERDICT=accurate ;;
    *) CLAIM_VERDICT=unresolved ;;
  esac
fi

if [ "$JSON" -eq 1 ]; then
  jq -nc \
    --arg claimed_session "$CLAIMED_SESSION" \
    --arg claimed_pane "$CLAIMED_PANE" \
    --arg claimed_socket "$CLAIMED_SOCKET" \
    --arg real_session "$REAL_SESSION" \
    --arg real_pane "$REAL_PANE" \
    --arg real_workspace "$REAL_WORKSPACE" \
    --arg verdict "$CLAIM_VERDICT" \
    --argjson located "$LOCATED" \
    --argjson matches "$MATCHES" \
    --argjson sessions_scanned "$SCANNED" \
    '{claimed: {session: $claimed_session, pane: $claimed_pane, socket: $claimed_socket},
      real: {session: $real_session, pane: $real_pane, workspace: $real_workspace},
      located: $located, matches: $matches, sessions_scanned: $sessions_scanned,
      claim: $verdict}'
else
  printf 'claimed:   session=%s pane=%s\n' "${CLAIMED_SESSION:-<none>}" "${CLAIMED_PANE:-<none>}"
  printf 'claimed:   socket=%s\n' "${CLAIMED_SOCKET:-<none>}"
  if [ "$LOCATED" = true ]; then
    printf 'real:      session=%s pane=%s workspace=%s (proven: that pane'"'"'s shell is an ancestor of pid %s)\n' \
      "$REAL_SESSION" "$REAL_PANE" "$REAL_WORKSPACE" "$$"
  elif [ "$MATCHES" -gt 1 ]; then
    printf 'real:      UNRESOLVED - %s panes claim this process'"'"'s ancestry; refusing to guess\n' "$MATCHES"
  else
    printf 'real:      UNRESOLVED - no pane in %s scanned session(s) owns this process\n' "$SCANNED"
  fi
  [ -z "$UNREADABLE" ] || printf 'note:      could not read panes in session(s):%s\n' "$UNREADABLE"
  case "$CLAIM_VERDICT" in
    accurate) printf 'verdict:   the injected environment is accurate\n' ;;
    stale)    printf 'verdict:   STALE - the injected environment names a pane this process does not run in; a bare herdr command here addresses %s\n' "$CLAIMED_SESSION" ;;
    none)     printf 'verdict:   this process carries no herdr pane identity at all\n' ;;
    *)        printf 'verdict:   unresolved - not enough readable evidence to judge the injected environment\n' ;;
  esac
fi

[ "$LOCATED" = true ] || exit 3
