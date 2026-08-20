#!/usr/bin/env bash
# Opt-in credentialed omp primary regression on a private tmux socket and isolated
# project/home state. It covers the two mechanisms that make omp a primary at all,
# neither of which Pi's adapter can stand in for: the BLOCKING session_stop turn-end
# guard, and the process-scoped extension-owned watcher wake.
set -u

if [ "${FM_OMP_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_LIVE_E2E=1 to run the isolated interactive omp regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v omp >/dev/null 2>&1 || fail "omp not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

TMUX=$(command -v tmux)
SOCKET="fm-omp-live-e2e-$$"
SESSION=omp-live-e2e
LAB="$ROOT/.omp-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
OMP_VERSION=$(omp --version)

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -600 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fq "$expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_exact_line() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fxq " $expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

send_prompt() {
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  sleep 0.4
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

cleanup() {
  local pid
  if [ "${FM_OMP_LIVE_E2E_KEEP:-0}" = 1 ]; then
    printf 'lab retained at %s (socket %s)\n' "$LAB" "$SOCKET" >&2
    return 0
  fi
  # Only ever signal processes whose command line names this lab.
  for pid in ${LAB_PIDS:-}; do
    if lab_pid_is_safe "$pid"; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
mkdir -p "$PROJECT/.omp/extensions" "$HOME_DIR/state" "$HOME_DIR/config"
cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.omp/extensions/"

# Replace the checked-out fleet instructions with a minimal stand-in, and launch
# with --no-skills. Under the real AGENTS.md the model reads the supervision
# contract and starts fleet work on its own initiative, which is correct behaviour
# and makes both phases below race it. The turn-end guard only needs AGENTS.md to
# EXIST (fm_primary_scope_matches), so a stub keeps this home a guarded primary
# while leaving what the model does under test control.
cat > "$PROJECT/AGENTS.md" <<'MD'
# omp live e2e lab

Follow the user's instructions literally. Do not start background work on your own.
MD

# Silence the session-start digest for this lab; the extension skips injection on
# empty output. Digest DELIVERY has its own portable coverage in
# tests/fm-omp-primary-extensions.test.sh.
cat > "$PROJECT/bin/fm-sessionstart-run.sh" <<'STUB'
#!/usr/bin/env bash
set -u
exit 0
STUB
chmod +x "$PROJECT/bin/fm-sessionstart-run.sh"

# One task in flight is what makes supervision REQUIRED; without it the turn-end
# guard is a deliberate no-op and phase A would pass vacuously.
: > "$HOME_DIR/state/omp-e2e.meta"

start_omp() {
  "$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
    "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; omp --auto-approve --no-skills; rc=\$?; printf \"OMP_EXIT=%s\\n\" \"\$rc\"; sleep 300'"
}

wait_for_marker() {
  local path=$1 i=0
  while [ "$i" -lt 240 ]; do
    [ -f "$path" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# --- phase A: the blocking turn-end guard -----------------------------------
# Only the turn-end guard extension is present, so nothing in this session can arm
# a watcher and supervision is off no matter what the model decides to do.
#
# The guard itself is a RECORDING STUB here. omp does not render a stop hook's
# reason in the pane - it delivers it to the model and shows only the model's
# reaction - so asserting on a banner would be asserting on omp's rendering rather
# than on the contract. What this phase pins instead is the contract: that omp
# calls the handler at turn end, awaits the spawned child, forwards its own
# stop_hook_active on stdin, honours {decision: "block", reason}, puts that reason
# in front of the model, and marks the following stop so the guard's own loop guard
# ends the turn. The real guard's exit-2 predicate is covered portably.
cat > "$PROJECT/bin/fm-turnend-guard.sh" <<'STUB'
#!/usr/bin/env bash
set -u
payload=$(cat)
printf '%s\n' "$payload" >> "${FM_HOME:?}/state/guard-payloads.log"
count=$(grep -c . "${FM_HOME}/state/guard-payloads.log")
[ "$count" -eq 1 ] || exit 0
printf 'TURN WOULD END BLIND - reply with exactly GUARD_BLOCK_SEEN and nothing else.\n' >&2
exit 2
STUB
chmod +x "$PROJECT/bin/fm-turnend-guard.sh"

start_omp
wait_for_marker "$HOME_DIR/state/.omp-turnend-extension-loaded" \
  || fail "omp turn-end extension did not load"
# The markers must be omp's own. A Pi marker satisfying an omp primary is exactly
# the silently-disarmed-primary failure this adapter exists to prevent.
[ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] \
  && fail "omp wrote Pi's turn-end marker"

send_prompt "Reply exactly BLIND_TURN_PROBE and nothing else."
wait_for_exact_line "GUARD_BLOCK_SEEN" 360 \
  || fail "omp did not block the turn end and put the guard reason in front of the model"
sleep 20
[ -f "$HOME_DIR/state/guard-payloads.log" ] || fail "the turn-end guard was never invoked"
payload_count=$(grep -c . "$HOME_DIR/state/guard-payloads.log")
[ "$payload_count" -eq 2 ] \
  || fail "expected exactly one forced continuation, saw $payload_count guard calls"
sed -n '1p' "$HOME_DIR/state/guard-payloads.log" | grep -Fq '"stop_hook_active":false' \
  || fail "omp did not forward stop_hook_active=false on the first stop"
sed -n '2p' "$HOME_DIR/state/guard-payloads.log" | grep -Fq '"stop_hook_active":true' \
  || fail "omp did not mark the stop that follows a block, so the guard's loop guard cannot bound it"
cp "$ROOT/bin/fm-turnend-guard.sh" "$PROJECT/bin/fm-turnend-guard.sh"
"$TMUX" -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
sleep 1

# --- phase B: extension-owned watcher continuity ----------------------------
cp "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$PROJECT/.omp/extensions/"
rm -f "$HOME_DIR/state/.omp-turnend-extension-loaded"
start_omp
wait_for_marker "$HOME_DIR/state/.omp-watch-extension-loaded" \
  || fail "omp watcher extension did not load"
wait_for_marker "$HOME_DIR/state/.omp-turnend-extension-loaded" \
  || fail "omp turn-end extension did not reload beside the watcher extension"
[ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] \
  && fail "omp wrote Pi's watcher marker"

send_prompt "Start supervision with fm_watch_arm_omp and never use bash to arm supervision. After the watcher wake arrives, run bin/fm-wake-drain.sh and reply exactly HANDLED."
wait_for_text "watcher: started omp extension arm child 1" 360 \
  || fail "omp did not render the initial watcher tool result"

printf 'done: omp live e2e watcher fire\n' > "$HOME_DIR/state/omp-e2e.status"
i=0
while [ "$i" -lt 360 ]; do
  grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "omp extension did not start and ledger-link a successor after the actionable close"
wait_for_exact_line "HANDLED" 360 \
  || fail "omp did not drain and settle after its extension-owned successor started"

pane=$(capture)
foreground_arm='$ bin/fm-watch-arm.sh'
if printf '%s\n' "$pane" | grep -Fq "$foreground_arm"; then
  fail "omp used a foreground bash watcher arm"
fi
# Assert the ADAPTER's ownership, not the model's discipline. This lab replaces
# AGENTS.md with a stub, so the model never reads the protocol line telling it not
# to re-arm, and whether it calls the tool twice is not this suite's business. What
# must hold is that a redundant call can never produce a SECOND cycle: the
# extension answers it with an ownership no-op. The deterministic form of that
# assertion lives in tests/fm-omp-primary-extensions.test.sh.
started_count=$(printf '%s\n' "$pane" | grep -Fc 'watcher: started omp extension arm child 1' || true)
[ "$started_count" -ge 1 ] || fail "the omp arm tool result was lost from the pane"
second_cycle=$(printf '%s\n' "$pane" | grep -Ec 'watcher: started omp extension arm child [2-9]' || true)
[ "$second_cycle" -eq 0 ] \
  || fail "a redundant arm call started a second cycle instead of an ownership no-op"

pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid | head -1)
[ -n "$pid_file" ] || fail "re-armed watcher pid was not recorded"
watcher_pid=$(sed -n '1p' "$pid_file")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "re-armed watcher parent was not live"
LAB_PIDS="$watcher_pid $arm_pid"

# omp's process-scoped ownership: /new replaces the session without emitting any
# lifecycle event, so the arm cycle must survive it rather than being retired.
send_prompt "/new"
sleep 8
kill -0 "$arm_pid" 2>/dev/null || fail "omp arm child did not survive a same-process session replacement"
kill -0 "$watcher_pid" 2>/dev/null || fail "omp watcher did not survive a same-process session replacement"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/exit'
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "OMP_EXIT=0" 60 || fail "omp did not exit cleanly"
wait_pid_dead "$watcher_pid" || fail "watcher child survived clean omp exit"
wait_pid_dead "$arm_pid" || fail "arm child survived clean omp exit"

printf 'ok - omp %s live E2E covered the blocking turn-end guard, extension-owned watcher continuity, and process-scoped arm ownership across a session replacement\n' "$OMP_VERSION"
