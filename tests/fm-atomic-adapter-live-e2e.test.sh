#!/usr/bin/env bash
# tests/fm-atomic-adapter-live-e2e.test.sh - the live atomic adapter guard
# (live-harness-optin family; task fm-atomic-worker-adapter).
#
# Every fact this guard checks is one only the real binary can answer, so per
# .agents/skills/firstmate-coding-guidelines a stub could not verify it: which
# project trees atomic scans, whether -na still loads an explicit -e path, what
# its own catalog publishes, what its mid-turn footer renders, whether a
# cancelled turn restores queued text, and what it appends to its transcript.
# The portable regressions in tests/fm-atomic-adapter.test.sh pin the same
# contracts against captured output; this one proves them against atomic itself
# and fails naming the harness and version.
#
# Two phases, so the expensive half is small and obvious:
#   Phase A costs NO model tokens. It uses the offline harness
#   (`--model zzz/nonexistent`, which fails AFTER extension loading is reported)
#   for the trust-flag facts, and runs the REAL bin/fm-spawn.sh against the REAL
#   `atomic --list-models` for the model preflight.
#   Phase B spends two short turns on a cheap model to reach the rendered and
#   transcript facts, which have no offline equivalent.
#
# Run explicitly with FM_ATOMIC_LIVE_E2E=1. Override the model with
# FM_ATOMIC_LIVE_MODEL (canonical provider/id form). An absent atomic is
# reported and skipped; a run that verified nothing fails rather than passing
# vacuously. Refresh docs/verification/runtime-backends.md "atomic" from this
# guard's output after any atomic upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_ATOMIC_LIVE_E2E:-0}" != 1 ]; then
  echo "# skip - set FM_ATOMIC_LIVE_E2E=1 to run the live atomic adapter guard"
  exit 0
fi

command -v tmux >/dev/null 2>&1 \
  || { echo "not ok - FM_ATOMIC_LIVE_E2E=1 but tmux is not installed" >&2; exit 1; }
if ! command -v atomic >/dev/null 2>&1; then
  echo "# atomic is not installed; nothing verified here"
  echo "not ok - FM_ATOMIC_LIVE_E2E=1 but atomic is absent; refusing a vacuous pass" >&2
  exit 1
fi

VERSION=$(atomic --version 2>/dev/null | head -1 || printf 'version-unknown')
MODEL=${FM_ATOMIC_LIVE_MODEL:-anthropic/claude-haiku-4-5}
PROVIDER=${MODEL%%/*}
MODEL_ID=${MODEL#*/}
SOCKET="fm-atomic-live-$$"
SESSION=atomiclive
CHECKED=0

TMP_ROOT=$(fm_test_tmproot fm-atomic-live)
LAB="$TMP_ROOT/lab"
PROJ="$LAB/proj"
mkdir -p "$PROJ/.pi/extensions"

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

live_fail() { printf 'not ok - atomic (%s): %s\n' "$VERSION" "$1" >&2; cleanup; exit 1; }
note() { printf '# %s\n' "$1"; }

# --- Phase A: no model tokens ------------------------------------------------

# A project-local extension that throws if it is ever loaded, and a good one
# outside the project that announces itself.
cat > "$PROJ/.pi/extensions/fm-live-boom.ts" <<'TS'
export default function () { throw new Error("PROJECT_LOCAL_LOADED"); }
TS
cat > "$LAB/ext-ok.ts" <<'TS'
export default function () { console.error("FM_EXT_LOADED"); }
TS

offline_run() {  # <flags...>
  (cd "$PROJ" && atomic --offline "$@" --model zzz/nonexistent -p x 2>&1)
}

out=$(offline_run -na -e "$LAB/ext-ok.ts")
case "$out" in
  *FM_EXT_LOADED*) ;;
  *) live_fail "an explicit -e path outside the project did not load under -na; the busy-state extension would never run: $out" ;;
esac
case "$out" in
  *PROJECT_LOCAL_LOADED*) live_fail "-na loaded a project-local extension; a worktree's own .pi/extensions would reach a crewmate" ;;
esac
CHECKED=$((CHECKED + 1))
printf 'ok - atomic (%s): -na loads an explicit -e path and ignores project-local extensions\n' "$VERSION"

# The counterpart: prove the .pi scan is real, so -na is load-bearing rather
# than decorative. Without this the case above could pass on an atomic that
# never scanned .pi at all.
out=$(offline_run -a)
case "$out" in
  *PROJECT_LOCAL_LOADED*) ;;
  *) live_fail "atomic did not load .pi/extensions even with -a; the fence -na provides is unproven, so re-derive which trees it scans before trusting the launch template: $out" ;;
esac
CHECKED=$((CHECKED + 1))
printf 'ok - atomic (%s): .pi/extensions IS scanned when project-local files are trusted\n' "$VERSION"

# The interactive trust dialog, and that -na suppresses it. A blocking dialog on
# a never-seen worktree path would wedge every spawn.
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 -c "$PROJ" -- sleep 86400 \
  || live_fail "could not start the isolated tmux server"
trust_screen() {  # <window> <flags...>
  local win=$1
  shift
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$PROJ" \
    -- atomic "$@" --provider "$PROVIDER" --model "$MODEL_ID" >/dev/null 2>&1 \
    || live_fail "could not launch atomic in the isolated tmux server"
  local i=0
  while [ "$i" -lt 20 ]; do
    sleep 1
    i=$((i + 1))
    if tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep -q '[^[:space:]]'; then
      [ "$i" -ge 6 ] && break
    fi
  done
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null
}
out=$(trust_screen trustbare)
tmux -L "$SOCKET" kill-window -t "$SESSION:trustbare" >/dev/null 2>&1 || true
case "$out" in
  *"Trust project folder?"*) ;;
  *) live_fail "an untrusted project folder no longer blocks on the trust dialog; re-derive whether -na is still the flag that avoids it: $out" ;;
esac
out=$(trust_screen trustna -na)
tmux -L "$SOCKET" kill-window -t "$SESSION:trustna" >/dev/null 2>&1 || true
case "$out" in
  *"Trust project folder?"*) live_fail "-na did not suppress the trust dialog; a spawn into a fresh worktree would wedge on it" ;;
esac
CHECKED=$((CHECKED + 1))
printf 'ok - atomic (%s): a bare launch blocks on the trust dialog and -na suppresses it\n' "$VERSION"

# The model preflight, against the REAL catalog: the configured pair must be
# accepted and a bogus id under the same real provider must be refused before
# any endpoint exists. Runs the real fm-spawn with a fake tmux so no pane is
# created and no tokens are spent.
spawn_case() {  # <name> <id> -> home|proj|wt|fakebin|log
  local name=$1 id=$2 case_dir home proj wt fakebin log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin="$case_dir/fakebin"
  log="$case_dir/sendkeys.log"
  mkdir -p "$fakebin" "$home/data" "$home/projects" "$home/state" "$home/config"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    for a in "\$@"; do
      case "\$a" in
        -*|send-keys|firstmate:*) continue ;;
        *) printf '%s\\n' "\$a" >> "$log" ;;
      esac
    done
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$log"
}

run_spawn() {  # <home> <wt> <fakebin> <args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

IFS='|' read -r home proj wt fakebin log <<EOF
$(spawn_case preflight-ok live-ok-1)
EOF
out=$(run_spawn "$home" "$wt" "$fakebin" live-ok-1 "$proj" atomic \
  --model "$MODEL" --effort low --mode no-mistakes --yolo off)
status=$?
[ "$status" -eq 0 ] \
  || live_fail "the real catalog rejected the configured model '$MODEL'; choose an authenticated provider/id pair or set FM_ATOMIC_LIVE_MODEL: $out"
launch=$(grep -F -- '--provider' "$log" | tail -1)
case "$launch" in
  *"--provider '$PROVIDER' --model '$MODEL_ID'"*) ;;
  *) live_fail "the composed launch did not split the canonical model form: $launch" ;;
esac

IFS='|' read -r home proj wt fakebin log <<EOF
$(spawn_case preflight-bad live-bad-1)
EOF
out=$(run_spawn "$home" "$wt" "$fakebin" live-bad-1 "$proj" atomic \
  --model "$PROVIDER/definitely-not-a-real-model" --mode no-mistakes --yolo off)
status=$?
[ "$status" -ne 0 ] \
  || live_fail "the real catalog accepted a nonexistent model under a real provider; a worker would launch and die on a provider 404"
[ ! -e "$home/state/live-bad-1.meta" ] \
  || live_fail "the model preflight ran after endpoint creation"
CHECKED=$((CHECKED + 1))
printf 'ok - atomic (%s): the model preflight accepts %s and refuses an unpublished id before endpoint creation\n' "$VERSION" "$MODEL"

# --- Phase B: two short turns on a cheap model --------------------------------

# The library under test, driven against the private socket through a PATH shim
# so its bare `tmux` calls stay isolated from any live fleet.
SHIM_DIR="$TMP_ROOT/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

SESSION_ID="fm-atomic-live-$$"
STATE="$TMP_ROOT/state"
TASK=live-ack-1
mkdir -p "$STATE"
printf 'sessions_root=%s\nsession_id=%s\nworkspace_root=%s\n' \
  "${HOME:-}/.atomic/agent/sessions" "$SESSION_ID" "$PROJ" \
  > "$STATE/$TASK.atomic-session"

WIN=live
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$WIN" -c "$PROJ" \
  -- atomic -na --provider "$PROVIDER" --model "$MODEL_ID" --thinking low \
     --session-id "$SESSION_ID" \
  || live_fail "could not launch the interactive atomic session"
T="$SESSION:$WIN"

wait_for_verdict() {  # <wanted> <timeout>
  local want=$1 budget=$2 i=0 verdict=
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$T")
    [ "$verdict" = "$want" ] && { printf '%s' "$verdict"; return 0; }
    i=$((i + 1))
    sleep 1
  done
  printf '%s' "$verdict"
  return 1
}

verdict=$(wait_for_verdict empty 45) \
  || live_fail "an idle atomic composer never classified empty (last verdict: ${verdict:-unreadable}); its input row is proven by the agent glyph, so check whether atomic still draws it"
# The pairing this adapter deliberately relies on: no process identity, and the
# verdict does not need one.
if fm_tmux_composer_identity "$T" >/dev/null 2>&1; then
  live_fail "the tmux identity probe now names this pane; teach bin/fm-composer-lib.sh what that identity proves before relying on it"
fi
CHECKED=$((CHECKED + 1))
printf 'ok - atomic (%s): a real idle composer classifies empty with NO process identity\n' "$VERSION"

# One long-running tool call, so the busy footer and a queued steer are both
# reachable inside a single turn.
tmux -L "$SOCKET" send-keys -t "$T" \
  'Run this bash command and report its output: sleep 45; echo DONE' Enter
busy=0
i=0
while [ "$i" -lt 45 ]; do
  if tmux -L "$SOCKET" capture-pane -p -t "$T" 2>/dev/null \
     | fm_busy_lines_match atomic; then
    busy=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$busy" -eq 1 ] \
  || live_fail "atomic's registered busy signature never matched a mid-turn pane; a delivered steer could not be acknowledged"
CHECKED=$((CHECKED + 1))
printf 'ok - atomic (%s): the registered delivery busy signature matches a real mid-turn pane\n' "$VERSION"

# The transcript does not exist yet at the moment the busy footer appears:
# atomic creates it with the first ASSISTANT message, which lands when the model
# emits its tool call. That lag is the ack's documented blind spot, so it is
# waited out here rather than raced.
TRANSCRIPT=
i=0
while [ "$i" -lt 60 ]; do
  TRANSCRIPT=$(fm_control_atomic_session_file "$STATE" "$TASK" 2>/dev/null || true)
  [ -n "$TRANSCRIPT" ] && break
  i=$((i + 1))
  sleep 1
done
[ -n "$TRANSCRIPT" ] \
  || live_fail "the pinned session id resolved no transcript within 60s of the turn starting; the interrupt-ack binding is broken (check that the interactive host still names the file after --session-id)"
OFFSET=$(fm_control_atomic_transcript_size "$TRANSCRIPT") \
  || live_fail "could not read the transcript length before delivering the interrupt"

# A steer submitted while the worker is busy is what atomic restores on cancel,
# and it is exactly what firstmate sends. Both halves of the control plane's
# interrupt are exercised: the key, then the clear.
STEER="FMLIVE-QUEUED-$$"
tmux -L "$SOCKET" send-keys -t "$T" "$STEER" Enter
sleep 2
tmux -L "$SOCKET" send-keys -t "$T" "$(fm_control_interrupt_key atomic)"
verdict=$(wait_for_verdict pending 30) \
  || live_fail "a cancelled turn did not leave the queued steer in the composer (verdict: ${verdict:-unreadable}); if atomic stopped restoring queued text, retire the C-u clear rather than leaving an unexplained key"
tmux -L "$SOCKET" capture-pane -p -t "$T" 2>/dev/null | grep -Fq "$STEER" \
  || live_fail "the composer read pending but does not hold the queued steer; the restore contract changed"
tmux -L "$SOCKET" send-keys -t "$T" "$(fm_control_interrupt_clear_key atomic)"
verdict=$(wait_for_verdict empty 30) \
  || live_fail "the composer-clear key did not empty the composer after an interrupt (verdict: ${verdict:-unreadable})"
CHECKED=$((CHECKED + 1))
printf 'ok - atomic (%s): an interrupt restores the queued steer and the clear key empties the composer\n' "$VERSION"

i=0
acked=0
while [ "$i" -lt 30 ]; do
  if fm_control_atomic_aborted_since "$TRANSCRIPT" "$OFFSET"; then
    acked=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$acked" -eq 1 ] \
  || live_fail "no aborted assistant record was appended after the interrupt; fm_control_interrupt_ack_source claims a cancellation atomic no longer supplies"
CHECKED=$((CHECKED + 1))
printf 'ok - atomic (%s): a cancelled turn appends the aborted record the interrupt ack reads\n' "$VERSION"

# The exit command, from the same pane, with the popup open.
tmux -L "$SOCKET" send-keys -t "$T" "$(fm_control_exit_command atomic)" Enter
i=0
exited=0
while [ "$i" -lt 30 ]; do
  if ! tmux -L "$SOCKET" list-windows -t "$SESSION:" 2>/dev/null | grep -q "^.*$WIN"; then
    exited=1
    break
  fi
  if tmux -L "$SOCKET" capture-pane -p -t "$T" 2>/dev/null | grep -q 'To resume this session'; then
    exited=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$exited" -eq 1 ] \
  || live_fail "$(fm_control_exit_command atomic) did not exit the agent on one Enter"
CHECKED=$((CHECKED + 1))
printf 'ok - atomic (%s): %s exits on one Enter despite the slash popup\n' "$VERSION" "$(fm_control_exit_command atomic)"

[ "$CHECKED" -ge 8 ] \
  || live_fail "the live atomic guard verified only $CHECKED facts; refusing a partial pass"
note "verified $CHECKED live atomic facts on $VERSION with model $MODEL"
printf 'ok - live atomic adapter guard covered the trust flags, model preflight, composer, busy signature, interrupt ack, and exit\n'
