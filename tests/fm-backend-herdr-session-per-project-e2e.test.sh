#!/usr/bin/env bash
# tests/fm-backend-herdr-session-per-project-e2e.test.sh - mandatory ISOLATED
# end-to-end real-Herdr test for WHICH SESSION a worker is placed in.
#
# The guarantee under test: a crewmate or scout is created in the Herdr session
# its project records in the home's registry, not in the session the launching
# orchestrator happens to be running in. A project with no recorded session
# refuses the spawn and creates nothing at all.
#
# Why a second real session, rather than composing a cross-session environment:
# the defect this fixes was an orchestrator in one session silently placing its
# worker there, so the launcher here is a REAL pane in a REAL other session,
# running the REAL bin/fm-spawn.sh, with Herdr itself injecting the identity.
# A composed environment could only prove the code ignores variables a test set.
#
# The ambient environment is additionally driven AGAINST the registry in the
# refusal cases: HERDR_SESSION names a live session that would happily accept a
# worker, so a regression that reads it would visibly succeed instead of
# refusing, and the case cannot pass by coincidence.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): both sessions
# are isolated labs driven through bin/fm-herdr-lab.sh, which appends the named
# session flag and verifies the captain's default fleet session is unchanged
# after each teardown. The reserved orchestrator session is redirected into the
# launcher lab, so nothing here ever addresses the real `default`.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# shellcheck source=tests/cleanup-safety.sh
. "$ROOT/tests/cleanup-safety.sh"

# Every placement below must come from an identity this suite states, never one
# inherited from the terminal it was started in.
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-session-per-project.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"

# Two isolated sessions: one standing in for the orchestrators' reserved
# session, one standing in for a project's own.
LAUNCHER_SESSION=$("$HERDR_LAB_HELPER" name fm-spp-launcher) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate the launcher lab session name\n' >&2
  exit 1
}
PROJECT_SESSION=$("$HERDR_LAB_HELPER" name fm-spp-project) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate the project lab session name\n' >&2
  exit 1
}

CLEANED=0
LAUNCHER_PROVISIONED=0
PROJECT_PROVISIONED=0
# Idempotent for the same reason the launcher-workspace suite's is: fail()
# cleans up before exiting and the EXIT trap fires after it.
cleanup_all() {
  local status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  [ "$PROJECT_PROVISIONED" = 1 ] && { "$HERDR_LAB_HELPER" teardown "$PROJECT_SESSION" || status=$?; }
  [ "$LAUNCHER_PROVISIONED" = 1 ] && { "$HERDR_LAB_HELPER" teardown "$LAUNCHER_SESSION" || status=$?; }
  fm_test_pool_release_all || status=1
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT
# A fatal signal otherwise skips the EXIT trap entirely, stranding this run's
# lab session and treehouse pool; converting it to a normal exit runs the
# cleanup above (tests/lib.sh uses the same pattern).
trap 'exit 130' INT
trap 'exit 143' TERM
"$HERDR_LAB_HELPER" provision "$LAUNCHER_SESSION" || fail "could not provision the launcher lab session"
LAUNCHER_PROVISIONED=1
"$HERDR_LAB_HELPER" provision "$PROJECT_SESSION" || fail "could not provision the project lab session"
PROJECT_PROVISIONED=1

launcher_lab() { "$HERDR_LAB_HELPER" run "$LAUNCHER_SESSION" "$@"; }
project_lab() { "$HERDR_LAB_HELPER" run "$PROJECT_SESSION" "$@"; }

# --- helpers ----------------------------------------------------------------

make_scratch_project() {  # <dir>
  local dir=$1
  # Registering here covers every fixture repo this suite creates, so the
  # treehouse pool acquired against it is destroyed before the repo is deleted
  # (tests/cleanup-safety.sh).
  fm_test_pool_register "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

panes_in() {  # <lab-fn> -> every pane id in that session
  "$1" pane list 2>/dev/null | jq -r '.result.panes[]?.pane_id' 2>/dev/null
}

session_has_pane() {  # <lab-fn> <pane-id>
  panes_in "$1" | grep -qx -- "$2"
}

tab_labels_in() {  # <lab-fn> -> every tab label in that session, sorted
  "$1" tab list 2>/dev/null | jq -r '[.result.tabs[]?.label] | sort | join(",")' 2>/dev/null
}

LAUNCHER_SOCKET=$(launcher_lab session list --json 2>/dev/null \
  | jq -r --arg s "$LAUNCHER_SESSION" '.sessions[]? | select(.name == $s) | .socket_path' 2>/dev/null)
[ -n "$LAUNCHER_SOCKET" ] || fail "could not read the launcher lab session's socket path"

# --- scratch world ----------------------------------------------------------

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
# The flat layout keeps each assertion about the SESSION a worker landed in
# rather than about the projection shape, which its own suite already owns.
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"

PROJ="$TMP_ROOT/registered-project"; make_scratch_project "$PROJ"
UNREG="$TMP_ROOT/unregistered-project"; make_scratch_project "$UNREG"
NOSES="$TMP_ROOT/sessionless-project"; make_scratch_project "$NOSES"

printf -- '- %s [no-mistakes session=%s] - registered scratch project (added 2026-01-01)\n' \
  "$(basename "$PROJ")" "$PROJECT_SESSION" > "$HOME_DIR/data/projects.md"
printf -- '- %s [no-mistakes] - registered with no session at all (added 2026-01-01)\n' \
  "$(basename "$NOSES")" >> "$HOME_DIR/data/projects.md"

for id in placed refuseA refuseB scoutC; do
  mkdir -p "$HOME_DIR/data/$id"
  printf 'trivial session-placement brief: nothing to do.\n' > "$HOME_DIR/data/$id/brief.md"
done

# The launcher's own workspace, in the OTHER session, with a real pane whose
# identity Herdr injects itself.
LAUNCH_OUT=$(launcher_lab workspace create --cwd "$TMP_ROOT" --label firstmate --no-focus 2>/dev/null)
LAUNCH_WS=$(printf '%s' "$LAUNCH_OUT" | jq -r '.result.workspace.workspace_id // empty')
LAUNCH_PANE=$(printf '%s' "$LAUNCH_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$LAUNCH_WS" ] && [ -n "$LAUNCH_PANE" ] || fail "could not create the launcher workspace and pane"

# A decoy workspace in the launcher session carrying the SAME home label, so a
# regression that placed the worker here could not hide behind "there was only
# one plausible workspace anyway".
launcher_lab workspace create --cwd "$TMP_ROOT" --label firstmate --no-focus >/dev/null 2>&1 \
  || fail "could not create the launcher-session decoy workspace"

LAUNCHER_TABS_BEFORE=$(tab_labels_in launcher_lab)

# What the captain is looking at while workers are created in another session.
focused_workspace_in() {  # <lab-fn>
  "$1" workspace list 2>/dev/null \
    | jq -r '[.result.workspaces[]? | select(.focused == true) | .workspace_id][0] // empty' 2>/dev/null
}
LAUNCHER_FOCUS_BEFORE=$(focused_workspace_in launcher_lab)
[ -n "$LAUNCHER_FOCUS_BEFORE" ] || fail "could not read the launcher session's focused workspace"

# run_spawn_in_launcher_pane <task-id> <project-dir> [extra fm-spawn args...]
# Runs the real fm-spawn.sh inside the launcher session's real pane, so the
# HERDR_* identity comes from Herdr's own injection.
SPAWN_RC=; SPAWN_ERR=
run_spawn_in_launcher_pane() {
  local id=$1 proj=$2
  shift 2
  local script="$TMP_ROOT/spawn-$id.sh"
  cat > "$script" <<SPAWN
#!/usr/bin/env bash
set -u
FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \\
  FM_BACKEND_HERDR_ORCHESTRATOR_SESSION="$LAUNCHER_SESSION" \\
  "$ROOT/bin/fm-spawn.sh" $id "$proj" "sh -c 'echo session-placement-ok'" --backend herdr $* \\
  > "$TMP_ROOT/$id.out" 2> "$TMP_ROOT/$id.err"
echo \$? > "$TMP_ROOT/$id.rc"
SPAWN
  chmod +x "$script"
  rm -f "$TMP_ROOT/$id.rc"
  launcher_lab pane run "$LAUNCH_PANE" "$script" >/dev/null 2>&1 \
    || fail "could not run fm-spawn.sh inside the launcher's herdr pane"
  local i=0
  while [ ! -f "$TMP_ROOT/$id.rc" ] && [ "$i" -lt 120 ]; do sleep 2; i=$((i + 1)); done
  [ -f "$TMP_ROOT/$id.rc" ] || fail "fm-spawn.sh never finished inside the launcher's herdr pane for $id"
  SPAWN_RC=$(cat "$TMP_ROOT/$id.rc")
  SPAWN_ERR=$(cat "$TMP_ROOT/$id.err" 2>/dev/null)
}

# --- 1. the headline: placement follows the registry, not the launcher -------

run_spawn_in_launcher_pane placed "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a registered project's spawn failed"$'\n'"$SPAWN_ERR"
PLACED_META="$HOME_DIR/state/placed.meta"
PLACED_TARGET=$(grep '^window=' "$PLACED_META" | cut -d= -f2-)
PLACED_PANE=$(grep '^herdr_pane_id=' "$PLACED_META" | cut -d= -f2-)
[ -n "$PLACED_PANE" ] || fail "the placed task recorded no herdr pane"
[ "${PLACED_TARGET%%:*}" = "$PROJECT_SESSION" ] \
  || fail "the recorded endpoint names session '${PLACED_TARGET%%:*}', expected the registered '$PROJECT_SESSION'"
session_has_pane project_lab "$PLACED_PANE" \
  || fail "the worker's pane is not in the registered project session '$PROJECT_SESSION'"
session_has_pane launcher_lab "$PLACED_PANE" \
  && fail "the worker's pane is in the LAUNCHER's session, the exact defect under test"
[ "$(tab_labels_in launcher_lab)" = "$LAUNCHER_TABS_BEFORE" ] \
  || fail "the spawn added a tab to the launcher's own session"
pass "real herdr E2E: a worker spawned from a real pane in one session lands in the session its project registry records, verified by pane list against that session"

# --- 2. the launcher's session is left entirely alone ------------------------

session_has_pane launcher_lab "$LAUNCH_PANE" || fail "the spawn disturbed the launcher's own pane"
[ "$(launcher_lab workspace list 2>/dev/null | jq -r '[.result.workspaces[]? | select(.label == "firstmate")] | length')" = 2 ] \
  || fail "the spawn created or removed a workspace in the launcher's session"
[ "$(focused_workspace_in launcher_lab)" = "$LAUNCHER_FOCUS_BEFORE" ] \
  || fail "the spawn moved focus in the session the captain is watching"
pass "real herdr E2E: neither same-labeled workspace in the launcher's own session is adopted, created into, or mutated, and focus there does not move"

# --- 3. a scout is partitioned by the same rule ------------------------------

run_spawn_in_launcher_pane scoutC "$PROJ" --scout
[ "$SPAWN_RC" -eq 0 ] || fail "a scout spawn for a registered project failed"$'\n'"$SPAWN_ERR"
SCOUT_META="$HOME_DIR/state/scoutC.meta"
SCOUT_PANE=$(grep '^herdr_pane_id=' "$SCOUT_META" | cut -d= -f2-)
session_has_pane project_lab "$SCOUT_PANE" \
  || fail "a scout must be partitioned into its project's session too"
pass "real herdr E2E: a scout is placed by the same registry rule as a crewmate"

# --- 4. an unregistered project refuses and creates nothing ------------------

PROJECT_PANES_BEFORE=$(panes_in project_lab | sort | tr '\n' ' ')
run_spawn_in_launcher_pane refuseA "$UNREG" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -ne 0 ] || fail "an unregistered project must refuse, not fall back to the launcher's session"
assert_contains_local "$SPAWN_ERR" "$(basename "$UNREG")" "the refusal did not name the project it could not place"
assert_contains_local "$SPAWN_ERR" "session=<herdr-session>" "the refusal did not name the registry edit that fixes it"
[ ! -e "$HOME_DIR/state/refuseA.meta" ] || fail "a refused spawn published task metadata"
[ "$(panes_in project_lab | sort | tr '\n' ' ')" = "$PROJECT_PANES_BEFORE" ] \
  || fail "a refused spawn created a pane in the project session"
[ "$(tab_labels_in launcher_lab)" = "$LAUNCHER_TABS_BEFORE" ] \
  || fail "a refused spawn created a pane in the launcher's session"
pass "real herdr E2E: an unregistered project refuses the spawn and creates nothing in either session"

# --- 5. a registered project with no recorded session refuses the same way ---

run_spawn_in_launcher_pane refuseB "$NOSES" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -ne 0 ] || fail "a project with no recorded session must refuse"
assert_contains_local "$SPAWN_ERR" "$(basename "$NOSES")" "the refusal did not name the project"
assert_contains_local "$SPAWN_ERR" "records no Herdr session" "the refusal did not state what was missing"
[ ! -e "$HOME_DIR/state/refuseB.meta" ] || fail "a refused spawn published task metadata"
[ "$(panes_in project_lab | sort | tr '\n' ' ')" = "$PROJECT_PANES_BEFORE" ] \
  || fail "a sessionless-project spawn created a pane anyway"
[ "$(tab_labels_in launcher_lab)" = "$LAUNCHER_TABS_BEFORE" ] \
  || fail "a sessionless-project spawn fell back to the launcher's session"
pass "real herdr E2E: a registered project with no recorded session refuses the spawn and creates nothing"

# --- 6. the recorded endpoint keeps resolving for the whole task lifecycle ---
# Placement is only useful if everything downstream still addresses the worker
# where it actually is, from an orchestrator that is not in that session.

CREW_STATE=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-crew-state.sh" placed 2>&1) \
  || fail "fm-crew-state.sh could not resolve a worker in a non-ambient session"$'\n'"$CREW_STATE"
[ -n "$CREW_STATE" ] || fail "fm-crew-state.sh reported nothing for a worker in a non-ambient session"

PEEK=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-peek.sh" placed 2>&1) \
  || fail "fm-peek.sh could not read a worker in a non-ambient session"$'\n'"$PEEK"
assert_contains_local "$PEEK" "session-placement-ok" "peek did not read the worker's own output back"

STEER=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  "$ROOT/bin/fm-send.sh" placed 'echo steered-ok' 2>&1) \
  || fail "fm-send.sh could not steer a worker in a non-ambient session"$'\n'"$STEER"
pass "real herdr E2E: crew-state, peek, and steer all resolve a worker in a session the orchestrator is not in"

# --- 7. teardown closes the worker's own pane in the project session ---------

TEARDOWN=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-teardown.sh" placed 2>&1) \
  || fail "fm-teardown.sh failed for a worker in a non-ambient session"$'\n'"$TEARDOWN"
[ ! -f "$PLACED_META" ] || fail "fm-teardown.sh did not remove the task's meta"
session_has_pane project_lab "$PLACED_PANE" \
  && fail "fm-teardown.sh did not close the worker's pane in the project session"
session_has_pane project_lab "$SCOUT_PANE" \
  || fail "fm-teardown.sh closed an unrelated worker's pane in the same project session"
session_has_pane launcher_lab "$LAUNCH_PANE" \
  || fail "fm-teardown.sh reached into the launcher's session"
pass "real herdr E2E: teardown closes only that worker's pane in its own project session and never touches the launcher's"

if ! cleanup_all; then
  trap - EXIT
  printf 'not ok - isolated Herdr lab teardown failed or the default fleet session changed\n' >&2
  exit 1
fi
trap - EXIT
pass "real herdr E2E: both isolated lab sessions removed and the default fleet session unchanged"
