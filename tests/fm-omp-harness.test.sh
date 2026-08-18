#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - oh-my-pi (omp) primary harness identity
# (bin/fm-harness.sh detection, bin/fm-session-lock-lib.sh ancestry).
#
# omp is a Pi fork that publishes its own identity rather than Pi's: it sets
# OMPCODE=1 and does not set PI_CODING_AGENT, and its config root is
# ~/.omp/agent, so it is deliberately not aliased to the pi family. These
# cases pin the facts that keep an omp session claimable and non-confusable:
# the exact marker outranks a retained CLAUDECODE, the exact process name
# carries ancestry, and merely omp-containing names never do.
#
# It also pins the two facts an omp WORKER depends on: the tmux liveness
# classifier reads the exact process name omp reports as its pane command, and
# every launch clears the agent-session markers a primary exports or a pane
# environment retains. That second one is checked by RUNNING the launch command
# fm-spawn produced, under an environment carrying those markers, and reading
# what the launched process actually received - a stale
# CLAUDE_CODE_CHILD_SESSION is what silently turns off a claude worker's own
# transcript persistence.
# shellcheck disable=SC2016 # single quotes are deliberate: $$ and $1 expand inside the fixture child, not here
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
trap 'rm -rf "$TMP_ROOT"' EXIT

HARNESS="$ROOT/bin/fm-harness.sh"
LIB="$ROOT/bin/fm-session-lock-lib.sh"

# A real executable renamed to omp carries the ancestry, because the ancestry
# walk reads real process tables.
OMP_BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$OMP_BIN_DIR"
cp "$(command -v bash)" "$OMP_BIN_DIR/omp"

# Resolve fm_harness_ancestry_pid one level below an omp-named parent and
# print the resolved pid, so the nearest-match rule is asserted directly.
cat > "$TMP_ROOT/ancestry-probe.sh" <<'SH'
#!/usr/bin/env bash
. "$1" || exit 3
p=$(fm_harness_ancestry_pid 2>/dev/null) || p=none
printf '%s\n' "$p"
SH
chmod +x "$TMP_ROOT/ancestry-probe.sh"

test_omp_marker_outranks_retained_claudecode() {
  out=$(OMPCODE=1 CLAUDECODE=1 "$HARNESS")
  [ "$out" = omp ] || fail "OMPCODE with a retained CLAUDECODE must detect omp, got '$out'"
  out=$(OMPCODE=1 "$HARNESS")
  [ "$out" = omp ] || fail "OMPCODE alone must detect omp, got '$out'"
  out=$(env -u OMPCODE CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE without OMPCODE must still detect claude, got '$out'"
  out=$(OMPCODE=true CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "an inexact OMPCODE value must not claim the omp identity, got '$out'"
  pass "fm-harness: omp's exact marker outranks a retained CLAUDECODE"
}

test_omp_ancestry_is_the_exact_process_name() {
  out=$(env -u CLAUDECODE -u OMPCODE -u PI_CODING_AGENT -u GROK_AGENT \
    "$OMP_BIN_DIR/omp" -c 'r=$("$1"); printf "%s" "$r"' _ "$HARNESS")
  [ "$out" = omp ] || fail "fm-harness.sh under an omp-named ancestor reported '$out', expected omp"
  pass "fm-harness: omp ancestry is detected through the exact process name"
}

test_lock_harness_table_is_exact_for_omp() {
  out=$(bash -c '. "$1"; fm_harness_process_matches omp "" && echo match || echo no' _ "$LIB")
  [ "$out" = match ] || fail "the exact name omp must match the harness table"
  out=$(bash -c '. "$1"; fm_harness_process_matches composer "" && echo match || echo no' _ "$LIB")
  [ "$out" = no ] || fail "an omp-containing name must not match the harness table"
  pass "fm-session-lock-lib: the omp entry is anchored to the exact name"
}

test_lock_ancestry_resolves_the_nearest_omp_process() {
  out=$("$OMP_BIN_DIR/omp" -c 'printf "%s\n" $$; r=$("$1" "$2"); printf "%s\n" "$r"' _ "$TMP_ROOT/ancestry-probe.sh" "$LIB")
  mine=$(printf '%s\n' "$out" | sed -n 1p)
  got=$(printf '%s\n' "$out" | sed -n 2p)
  [ "$got" = "$mine" ] \
    || fail "lock ancestry resolved '$got', expected the omp-named parent $mine"
  pass "fm-session-lock-lib: an omp-named ancestor owns the fleet-lock identity"
}

test_omp_marker_outranks_retained_claudecode
test_omp_ancestry_is_the_exact_process_name
test_lock_harness_table_is_exact_for_omp
test_lock_ancestry_resolves_the_nearest_omp_process

test_tmux_liveness_classifies_the_exact_omp_name() {
  local out
  out=$(bash -c '
    set -u
    FM_ROOT_OVERRIDE="$1"
    export FM_ROOT_OVERRIDE
    . "$1/bin/fm-backend.sh"
    fm_backend_source tmux
    for n in omp /opt/omp-17.3.5/lib/omp/omp composer omptest; do
      printf "%s=%s\n" "$n" "$(fm_backend_tmux_classify_process_name "$n")"
    done
  ' _ "$ROOT")
  printf '%s\n' "$out" | grep -qx 'omp=agent' \
    || fail "the exact pane command omp must classify as a live agent, got: $out"
  printf '%s\n' "$out" | grep -qx '/opt/omp-17.3.5/lib/omp/omp=agent' \
    || fail "an omp install path must classify as a live agent, got: $out"
  printf '%s\n' "$out" | grep -qx 'composer=other' \
    || fail "an omp-containing name must never classify as an agent, got: $out"
  printf '%s\n' "$out" | grep -qx 'omptest=other' \
    || fail "an omp-prefixed name must never classify as an agent, got: $out"
  pass "tmux liveness: omp is classified from its exact name, never a substring"
}

# Build a spawn case whose fake tmux RECORDS every send-keys payload, so the
# real launch command can be replayed afterwards.
omp_spawn_case() {  # <name> <harness> <id> -> home|wt|fakebin|log
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin="$case_dir/fake/fakebin"
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

# The launch command is the LAST recorded send-keys payload naming the harness
# binary; earlier payloads are the worktree acquisition and env exports.
omp_launch_line() {  # <log> <binary>
  grep -F -- "$2" "$1" | tail -1
}

test_launch_boundary_clears_foreign_session_markers() {
  local home proj wt fakebin log launch out
  IFS='|' read -r home proj wt fakebin log <<EOF
$(omp_spawn_case launch-sanitize omp sanitize-1)
EOF
  # A fake omp that reports the environment it was actually launched with.
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bash
env | sort
exit 0
SH
  chmod +x "$fakebin/omp"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" sanitize-1 "$proj" omp --mode no-mistakes --yolo off 2>&1) \
    || fail "omp spawn should succeed: $out"

  launch=$(omp_launch_line "$log" omp)
  [ -n "$launch" ] || fail "no omp launch command was sent to the pane; log: $(cat "$log")"

  # Replay it exactly as the pane shell would, from an environment carrying the
  # markers a claude or omp primary exports.
  out=$(cd "$wt" && env PATH="$fakebin:$PATH" \
    CLAUDECODE=1 OMPCODE=1 CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ID=stale \
    CLAUDE_PID=4242 CLAUDE_EFFORT=xhigh AI_AGENT=stale PI_CODING_AGENT=true \
    CURSOR_AGENT=1 FM_OMP_TEST_KEEP=survivor \
    bash -c "$launch")

  local leaked=
  for marker in CLAUDECODE OMPCODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID \
    CLAUDE_PID CLAUDE_EFFORT AI_AGENT PI_CODING_AGENT CURSOR_AGENT; do
    printf '%s\n' "$out" | grep -q "^$marker=" && leaked="$leaked $marker"
  done
  [ -z "$leaked" ] || fail "the launch boundary leaked foreign session markers:$leaked"
  printf '%s\n' "$out" | grep -q '^FM_OMP_TEST_KEEP=survivor$' \
    || fail "the launch boundary must clear only the declared markers, but an unrelated variable did not survive"
  pass "launch boundary: a spawn clears the inherited agent-session markers and nothing else"
}

test_tmux_liveness_classifies_the_exact_omp_name
test_launch_boundary_clears_foreign_session_markers
