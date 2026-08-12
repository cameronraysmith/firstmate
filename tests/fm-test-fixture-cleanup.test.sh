#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source, and that teardown stops the processes the
# test started inside a root before it removes that root. Nothing here inspects
# tests/lib.sh's source text; it only observes filesystem and process state
# around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

# --- teardown ordering against the test's own live children -----------------
#
# The cases above establish that a fixture root is removed. These establish WHEN
# it is removed relative to the processes the test started inside it, which is
# the property the abort path used to violate: fail exits, the EXIT trap runs
# while the forked arms and watchers are still polling, and rm -rf pulls their
# state directory out from under them.
#
# Liveness alone cannot tell the two orders apart, so each spawned process
# answers SIGTERM by recording whether its fixture root still existed at the
# moment it was signalled, into a harness directory OUTSIDE that root. A
# "root-present" record is the ordering evidence; teardown that removed the root
# first would leave the process unsignalled and still running with no record at
# all. The chain is two deep because the real shape is a suite that forks an arm
# that forks a watcher, and only the nearest link is a direct child.

# write_child_chain_fixture <dir>: drop the sleeper and the throwaway suite that
# drives it, and echo nothing. The sleeper re-executes itself for the second
# link, so both links run identical, separately signalled code.
write_child_chain_fixture() {
  local dir=$1
  cat > "$dir/sleeper.sh" <<'SLEEPER'
#!/usr/bin/env bash
# <root> <harness> <label> [child-label]
set -u
root=$1
harness=$2
label=$3
child=${4:-}

on_term() {
  if [ -d "$root" ]; then
    printf 'root-present\n' > "$harness/$label.signalled"
  else
    printf 'root-missing\n' > "$harness/$label.signalled"
  fi
  exit 0
}
trap on_term TERM

[ -z "$child" ] || "$0" "$root" "$harness" "$child" &
printf '%s\n' "$$" > "$harness/$label.pid"
while :; do sleep 0.05; done
SLEEPER
  chmod +x "$dir/sleeper.sh"

  cat > "$dir/suite.sh" <<'SUITE'
#!/usr/bin/env bash
# <lib> <harness> <ending>
set -u
lib=$1
harness=$2
ending=$3
# shellcheck source=tests/lib.sh
. "$lib"

TMP_ROOT=$(fm_test_tmproot fm-test-cleanup-children)
printf '%s\n' "$TMP_ROOT" > "$harness/root"
mkdir -p "$TMP_ROOT/state"

"$harness/sleeper.sh" "$TMP_ROOT" "$harness" outer inner &

tries=0
while [ "$tries" -lt 200 ]; do
  [ -s "$harness/outer.pid" ] && [ -s "$harness/inner.pid" ] && break
  sleep 0.05
  tries=$((tries + 1))
done
[ -s "$harness/outer.pid" ] && [ -s "$harness/inner.pid" ] \
  || fail "the child chain never published both pids"

case "$ending" in
  abort) fail "deliberate abort: teardown must stop the child chain first" ;;
  *) pass "child chain running at normal exit" ;;
esac
SUITE
  chmod +x "$dir/suite.sh"
}

# run_child_chain_suite <dir> <ending>: run the throwaway suite to completion and
# echo "<exit-code> <outer-alive> <inner-alive>", having first killed whatever
# survived so a failing assertion below cannot strand it.
run_child_chain_suite() {
  local dir=$1 ending=$2 rc=0 outer inner outer_alive=no inner_alive=no
  "$dir/suite.sh" "$LIB" "$dir" "$ending" > "$dir/out" 2> "$dir/err" || rc=$?
  outer=$(cat "$dir/outer.pid" 2>/dev/null || true)
  inner=$(cat "$dir/inner.pid" 2>/dev/null || true)
  kill -0 "$outer" 2>/dev/null && outer_alive=yes
  kill -0 "$inner" 2>/dev/null && inner_alive=yes
  [ -z "$outer" ] || kill -KILL "$outer" 2>/dev/null || true
  [ -z "$inner" ] || kill -KILL "$inner" 2>/dev/null || true
  printf '%s %s %s\n' "$rc" "$outer_alive" "$inner_alive"
}

assert_child_chain_stopped_first() {  # <dir> <label-for-messages>
  local dir=$1 what=$2 root
  root=$(cat "$dir/root" 2>/dev/null || true)
  [ -n "$root" ] || fail "$what: the suite never published its fixture root"
  assert_absent "$root" "$what: the fixture root survived teardown"
  assert_grep root-present "$dir/outer.signalled" \
    "$what: the fixture root was already removed when its direct child was signalled"
  assert_grep root-present "$dir/inner.signalled" \
    "$what: the fixture root was already removed when the second-level child was signalled"
}

test_abort_stops_the_child_chain_before_removing_the_root() {
  local dir result rc outer_alive inner_alive
  dir=$(fm_test_tmproot fm-test-cleanup-abort-harness)
  write_child_chain_fixture "$dir"
  result=$(run_child_chain_suite "$dir" abort)
  read -r rc outer_alive inner_alive <<< "$result"

  expect_code 1 "$rc" "the aborting suite did not exit on its failed assertion"
  assert_contains "$(cat "$dir/err")" "not ok - deliberate abort" \
    "the suite did not reach teardown through a failed assertion"
  [ "$outer_alive" = no ] \
    || fail "abort: a direct child of the suite outlived the removal of its fixture root"
  [ "$inner_alive" = no ] \
    || fail "abort: a second-level child outlived the removal of its fixture root"
  assert_child_chain_stopped_first "$dir" abort
  pass "an aborting suite stops its child chain before removing the fixture root"
}

test_normal_exit_stops_the_child_chain_before_removing_the_root() {
  local dir result rc outer_alive inner_alive
  dir=$(fm_test_tmproot fm-test-cleanup-normal-harness)
  write_child_chain_fixture "$dir"
  result=$(run_child_chain_suite "$dir" normal)
  read -r rc outer_alive inner_alive <<< "$result"

  expect_code 0 "$rc" "the passing suite did not exit cleanly"
  [ "$outer_alive" = no ] \
    || fail "normal exit: a direct child of the suite outlived the removal of its fixture root"
  [ "$inner_alive" = no ] \
    || fail "normal exit: a second-level child outlived the removal of its fixture root"
  assert_child_chain_stopped_first "$dir" "normal exit"
  pass "a passing suite stops its child chain before removing the fixture root"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_abort_stops_the_child_chain_before_removing_the_root
test_normal_exit_stops_the_child_chain_before_removing_the_root
