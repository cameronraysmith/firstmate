#!/usr/bin/env bash
# Real restored-shell E2E for home-local session-start Herdr projection cleanup.
# Every CLI operation is routed through one guarded named non-default lab, and
# lab teardown verifies that the default fleet session is byte-identical.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-session-cleanup-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config"
touch "$HOME_DIR/config/herdr-presentation-spaces"
printf '%s\n' herdr > "$HOME_DIR/config/backend"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-session-start-stale-projection-cleanup-r1)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
# Convert a fatal signal to a normal exit so the cleanup above runs from this
# suite's own EXIT trap rather than depending on the shell's default
# disposition for that signal. This suite holds a real lab session in the live
# fleet until that cleanup runs, and it does not source tests/lib.sh, which
# installs the same conversion for every suite built on it.
trap 'exit 130' INT
trap 'exit 143' TERM
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Keep the lab helper as the only CLI transport. Production adapter calls have
# already appended the exact session; this shim strips that pair, refuses every
# other caller-supplied session, and delegates the command to helper run.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
production_process_proof() {  # [pane]
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1 PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c '. "$1"; fm_backend_herdr_pane_idle_shell_pid "$2" "$3" >/dev/null' \
      _ "$ROOT/bin/fm-herdr-session-cleanup.sh" "$HERDR_LAB_SESSION" "${1:-$PANE}"
}
focus_snapshot() {
  local list workspace tab tabs
  list=$(lab workspace list) || return 1
  workspace=$(printf '%s' "$list" | jq -er '[.result.workspaces[] | select(.focused == true)] | select(length == 1) | .[0].workspace_id') || return 1
  tab=$(printf '%s' "$list" | jq -er --arg workspace "$workspace" '[.result.workspaces[] | select(.workspace_id == $workspace)] | select(length == 1) | .[0].active_tab_id') || return 1
  tabs=$(lab tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '([.result.tabs[] | select(.focused == true)] | length) == 1 and ([.result.tabs[] | select(.focused == true)][0].tab_id == $tab)' >/dev/null || return 1
  printf '%s\t%s' "$workspace" "$tab"
}

ANCHOR=$(lab workspace create --cwd "$ROOT" --label captain-anchor --focus) || fail 'could not create focus anchor'
ANCHOR_TAB=$(printf '%s' "$ANCHOR" | jq -r '.result.tab.tab_id')
ANCHOR_WS=$(printf '%s' "$ANCHOR" | jq -r '.result.workspace.workspace_id')
ANCHOR_PANE=$(printf '%s' "$ANCHOR" | jq -r '.result.root_pane.pane_id')
TOKEN=AbCdEfGhIjKlMnOpQrStUv
ID=restored-idle-shell
TITLE="└ $ID · p:$TOKEN"
CANDIDATE=$(lab workspace create --cwd "$ROOT" --label "$TITLE" --no-focus) || fail 'could not create projected child fixture'
WS=$(printf '%s' "$CANDIDATE" | jq -r '.result.workspace.workspace_id')
TAB=$(printf '%s' "$CANDIDATE" | jq -r '.result.tab.tab_id')
PANE=$(printf '%s' "$CANDIDATE" | jq -r '.result.root_pane.pane_id')
# A version 2 binding is what a real projection leaves behind, and it is the only
# journal that names its own session: discovery reads the session back from the
# record that placed the workspace and never from the ambient environment.
{
  printf 'version=2\n'
  printf 'task_id=%s\n' "$ID"
  printf 'projection_id=%s\n' "$TOKEN"
  printf 'home=%s\n' "$HOME_DIR"
  printf 'session=%s\n' "$HERDR_LAB_SESSION"
  printf 'workspace_id=%s\n' "$WS"
  printf 'tab_id=%s\n' "$TAB"
  printf 'pane_id=%s\n' "$PANE"
  printf 'parent_workspace_id=%s\n' "$(printf '%s' "$ANCHOR" | jq -r '.result.workspace.workspace_id')"
  printf 'parent_label=captain-anchor\n'
  printf 'workspace_label=%s\n' "$TITLE"
  printf 'task_label=fm-%s\n' "$ID"
} > "$HOME_DIR/state/$ID.herdr-presentation"

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail 'could not stop named lab for restored-shell reproduction'
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not restore named lab layout'
lab tab focus "$ANCHOR_TAB" >/dev/null || fail 'could not restore the anchor focus after lab restart'
BEFORE_FOCUS=$(focus_snapshot) || fail 'could not capture exact pre-cleanup focus'
[ "$BEFORE_FOCUS" = "$(printf '%s\t%s' "$(printf '%s' "$ANCHOR" | jq -r '.result.workspace.workspace_id')" "$ANCHOR_TAB")" ] \
  || fail 'anchor focus does not match the exact intended workspace and tab'

WORKSPACES=$(lab workspace list) || fail 'could not inspect restored workspaces'
TABS=$(lab tab list --workspace "$WS") || fail 'could not inspect restored tabs'
PANES=$(lab pane list --workspace "$WS") || fail 'could not inspect restored panes'
[ "$(printf '%s' "$WORKSPACES" | jq --arg title "$TITLE" '[.result.workspaces[] | select(.label == $title)] | length')" = 1 ] \
  || fail 'restored projected title is not unique'
[ "$(printf '%s' "$TABS" | jq '.result.tabs | length')" = 1 ] || fail 'restored child is not one tab'
[ "$(printf '%s' "$PANES" | jq '.result.panes | length')" = 1 ] || fail 'restored child is not one pane'
if lab agent get "$PANE" >/dev/null 2>&1; then
  fail 'restored child unexpectedly retained a registered agent'
fi
attempt=0
while [ "$attempt" -lt 50 ]; do
  if production_process_proof; then
    break
  fi
  sleep 0.1
  attempt=$((attempt + 1))
done
[ "$attempt" -lt 50 ] || fail 'restored child did not converge to the exact childless idle-shell process-group shape'
pass 'real named lab reproduced the exact restored one-tab one-pane childless no-agent shell shape'

FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh" \
  || fail 'session-start cleanup command failed'
AFTER_FOCUS=$(focus_snapshot) || fail 'could not capture exact post-cleanup focus'
[ "$AFTER_FOCUS" = "$BEFORE_FOCUS" ] || fail 'exact workspace/tab focus changed during cleanup'
if lab pane get "$PANE" >/dev/null 2>&1; then
  fail 'exact stale pane survived cleanup'
fi
if lab workspace get "$WS" >/dev/null 2>&1; then
  fail 'last-pane side effect did not remove the stale projected child workspace'
fi
[ ! -e "$HOME_DIR/state/$ID.herdr-presentation" ] || fail 'matching journal survived confirmed exact pane closure'
pass 'real named lab cleanup closes only the exact stale pane and preserves exact focus'

FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh" \
  || fail 'idempotent repeat failed'
[ "$(focus_snapshot)" = "$BEFORE_FOCUS" ] || fail 'idempotent repeat changed focus'
lab pane get "$(printf '%s' "$ANCHOR" | jq -r '.result.root_pane.pane_id')" >/dev/null \
  || fail 'anchor pane was touched by cleanup'

# A torn-down task's workspace can outlive its recorded task pane, holding a
# DIFFERENT restored shell. That is the production leak shape, and reclaiming it
# is what keeps one from accumulating per torn-down task.
production_retire_leftover() { # <workspace> <label> <token>
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1 PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c '. "$1"; fm_backend_herdr_projection_retire_leftover "$2" "$3" "$4" "$5"' \
      _ "$ROOT/bin/fm-herdr-session-cleanup.sh" "$HERDR_LAB_SESSION" "$1" "$2" "$3"
}

make_leftover() { # <task-id> <token> -> prints "<workspace>\t<pane>"
  local id=$1 token=$2 title created seeded_pane workspace second pane tries=0
  title="└ $id · p:$token"
  created=$(lab workspace create --cwd "$ROOT" --label "$title" --no-focus) || return 1
  workspace=$(printf '%s' "$created" | jq -r '.result.workspace.workspace_id')
  seeded_pane=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id')
  second=$(lab tab create --workspace "$workspace" --cwd "$ROOT" --label "fm-$id" --no-focus) || return 1
  pane=$(printf '%s' "$second" | jq -r '.result.root_pane.pane_id')
  # Retire the pane a task would have recorded, leaving the workspace alive on a
  # different pane exactly as Herdr leaves it after a torn-down task.
  lab pane close "$seeded_pane" >/dev/null || return 1
  while [ "$tries" -lt 50 ]; do
    if production_process_proof "$pane"; then break; fi
    sleep 0.1
    tries=$((tries + 1))
  done
  [ "$tries" -lt 50 ] || return 1
  printf '%s\t%s' "$workspace" "$pane"
}

LEFTOVER_TOKEN=LeFtOvErAbCdEfGhIjKlMn
LEFTOVER_ID=orphaned-projection
LEFTOVER_TITLE="└ $LEFTOVER_ID · p:$LEFTOVER_TOKEN"
LEFTOVER=$(make_leftover "$LEFTOVER_ID" "$LEFTOVER_TOKEN") \
  || fail 'could not reproduce a leftover workspace holding a different restored shell'
LEFTOVER_WS=${LEFTOVER%%$'\t'*}
LEFTOVER_PANE=${LEFTOVER#*$'\t'}
[ "$(focus_snapshot)" = "$BEFORE_FOCUS" ] || fail 'building the leftover fixture moved the captain focus'
production_retire_leftover "$LEFTOVER_WS" "$LEFTOVER_TITLE" "$LEFTOVER_TOKEN" \
  || fail 'the leftover workspace was not retired'
if lab workspace get "$LEFTOVER_WS" >/dev/null 2>&1; then
  fail 'the leftover workspace survived retirement'
fi
if lab pane get "$LEFTOVER_PANE" >/dev/null 2>&1; then
  fail 'the leftover pane survived retirement'
fi
[ "$(focus_snapshot)" = "$BEFORE_FOCUS" ] || fail 'retiring the leftover workspace changed the captain focus'
pass 'a workspace outliving its recorded task pane is reclaimed, not left to accumulate'

production_retire_leftover "$LEFTOVER_WS" "$LEFTOVER_TITLE" "$LEFTOVER_TOKEN" \
  || fail 'retiring an already absent workspace is not idempotent'
pass 'retiring an already absent leftover workspace succeeds without touching anything'

# Each refusal below removes exactly one guard from an otherwise retirable
# leftover, so the workspace must survive untouched.
BUSY_TOKEN=BuSyPaNeAbCdEfGhIjKlMn
BUSY_ID=busy-projection
BUSY_TITLE="└ $BUSY_ID · p:$BUSY_TOKEN"
BUSY=$(make_leftover "$BUSY_ID" "$BUSY_TOKEN") || fail 'could not build the busy-pane fixture'
BUSY_WS=${BUSY%%$'\t'*}
BUSY_PANE=${BUSY#*$'\t'}
lab pane run "$BUSY_PANE" 'sleep 600' >/dev/null || fail 'could not make the leftover pane busy'
busy_tries=0
while [ "$busy_tries" -lt 50 ]; do
  production_process_proof "$BUSY_PANE" || break
  sleep 0.1
  busy_tries=$((busy_tries + 1))
done
[ "$busy_tries" -lt 50 ] || fail 'the busy fixture never stopped proving an idle shell'
if production_retire_leftover "$BUSY_WS" "$BUSY_TITLE" "$BUSY_TOKEN" 2>/dev/null; then
  fail 'a leftover whose pane is not a provably idle shell was retired anyway'
fi
lab workspace get "$BUSY_WS" >/dev/null || fail 'a refused busy leftover lost its workspace'
lab pane get "$BUSY_PANE" >/dev/null || fail 'a refused busy leftover lost its pane'
pass 'a leftover whose pane is not a provably idle childless shell is left alone'

EXTRA=$(lab tab create --workspace "$BUSY_WS" --cwd "$ROOT" --label extra --no-focus) \
  || fail 'could not add a second tab to the guard fixture'
if production_retire_leftover "$BUSY_WS" "$BUSY_TITLE" "$BUSY_TOKEN" 2>/dev/null; then
  fail 'a leftover holding more than one tab was retired anyway'
fi
lab workspace get "$BUSY_WS" >/dev/null || fail 'a refused multi-tab leftover lost its workspace'
pass 'a leftover holding more than one tab is left alone'

if production_retire_leftover "$ANCHOR_WS" "$LEFTOVER_TITLE" "$LEFTOVER_TOKEN" 2>/dev/null; then
  fail "the captain's own workspace was retired against a projection label"
fi
lab workspace get "$ANCHOR_WS" >/dev/null || fail "the captain's own workspace was closed"
lab pane get "$ANCHOR_PANE" >/dev/null || fail "the captain's own pane was closed"
[ "$(focus_snapshot)" = "$BEFORE_FOCUS" ] || fail 'the guard refusals changed the captain focus'
pass "a workspace whose label is not this projection's is never a candidate"

lab pane close "$(printf '%s' "$EXTRA" | jq -r '.result.root_pane.pane_id')" >/dev/null || true
lab pane close "$BUSY_PANE" >/dev/null || true

STATUS=$(lab status --json) || fail 'could not read final named-lab version evidence'
pass 'real named lab cleanup is idempotent and leaves the default fleet session to the teardown tripwire'
printf 'evidence: herdr=%s protocol=%s default-session-tripwire=armed\n' \
  "$(printf '%s' "$STATUS" | jq -r '.client.version')" \
  "$(printf '%s' "$STATUS" | jq -r '.server.protocol')"
