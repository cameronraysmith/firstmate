#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

# The session Firstmate reserves for ORCHESTRATORS is the captain's live
# `default` in production, so sourcing this module immediately poisons it with a
# name Herdr itself rejects. A suite that spawns a secondmate without calling
# herdr_reserve_orchestrator_session below then FAILS on an invalid session name
# instead of quietly standing a workspace up in the captain's own fleet, and the
# name it fails on says what to do about it.
#
# This is fail-closed rather than a convention because the failure it prevents
# is silent and lands outside the test's own lab: a crewmate or scout is placed
# from the project registry, which a suite pins by registering its scratch
# project, but a secondmate is not a worker and is placed here instead
# (docs/herdr-backend.md "Session selection").
export FM_BACKEND_HERDR_ORCHESTRATOR_SESSION='unpinned/call-herdr_reserve_orchestrator_session-first'

# herdr_reserve_orchestrator_session: redirect that reservation into this
# suite's own lab session.
herdr_reserve_orchestrator_session() { # <lab-session>
  fm_herdr_lab_validate_name "$1" || return 1
  export FM_BACKEND_HERDR_ORCHESTRATOR_SESSION="$1"
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
