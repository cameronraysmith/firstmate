#!/usr/bin/env bash
# Behavior tests for tests/cleanup-safety.sh, the module that keeps a suite's
# cleanup from leaking a resource that lives outside its own fixture root.
#
# Both guarantees are exercised against real resources - a real treehouse pool
# acquired against a real throwaway git repository, and real background
# processes - in separate bash processes that use the same call shape the herdr
# e2e suites use. Nothing here reads implementation source text.
#
# The pool half deliberately covers the ABORT path, not just the ordered one: a
# failing assertion is exactly when a suite's cleanup gets skipped, and the
# measured strand of 69 worktrees across 17 missing backing repositories came
# from runs that ended that way. The assertion with teeth is that the POOL
# DIRECTORY is gone: `treehouse return` leaves it standing with an available
# slot, which is the defect, so a release that only returned would fail here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

LIB="$ROOT/tests/lib.sh"
SAFETY="$ROOT/tests/cleanup-safety.sh"

# Every child publishes the paths it created here, so the parent can assert on
# them after the child is gone and its own fixture root has been removed.
report_pool() {  # <report-file> -> echoes the recorded pool dir
  sed -n 's/^pool=//p' "$1" | head -1
}
report_repo() {  # <report-file> -> echoes the recorded fixture repo
  sed -n 's/^repo=//p' "$1" | head -1
}

# A pool this suite's own assertions found still standing would otherwise become
# exactly the strand under test, so reclaim it before reporting the failure.
# Only ever called on a pool this suite created, and it refuses any path whose
# name is not one of those, because the fallback below removes a directory tree
# outright: once the fixture repository is gone, `treehouse destroy` can no
# longer resolve the pool and cannot reclaim the slot itself.
FIXTURE_POOL_PREFIX=pooled-project-

force_release_pool() {  # <pool-dir>
  local pool=$1 slot
  [ -n "$pool" ] || return 0
  [ -d "$pool" ] || return 0
  case "${pool##*/}" in
    "$FIXTURE_POOL_PREFIX"*) ;;
    *) return 0 ;;
  esac
  for slot in "$pool"/*/*; do
    [ -d "$slot" ] || continue
    treehouse destroy "$slot" \
      --include-leased --include-in-use --include-unlanded --yes >/dev/null 2>&1 || true
  done
  rm -f "$pool/treehouse-state.json" "$pool/treehouse-state.lock"
  rmdir "$pool" 2>/dev/null && return 0
  rm -rf "$pool"
}

orphan_count() {
  treehouse prune --all --prune-orphans 2>/dev/null \
    | grep -c 'content could not be verified' || true
}

# The child body shared by the pool cases: build a throwaway repo inside the
# fixture root, register it, lease a real worktree from its pool, publish the
# paths, then hand control to the ending this case is about.
child_prelude() {  # <report-file>
  cat <<CHILD
set -u
. "$LIB"
TMP_ROOT=\$(fm_test_tmproot fm-pool-release-case)
REPO="\$TMP_ROOT/pooled-project"
fm_test_pool_register "\$REPO"
mkdir -p "\$REPO"
git -C "\$REPO" init -q
printf 'x\n' > "\$REPO/README.md"
git -C "\$REPO" add README.md
git -C "\$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm initial
WT=\$(cd "\$REPO" && treehouse get --lease 2>/dev/null) || exit 90
[ -n "\$WT" ] || exit 91
POOL=\$(dirname "\$(dirname "\$WT")")
{
  printf 'repo=%s\n' "\$REPO"
  printf 'pool=%s\n' "\$POOL"
  printf 'worktree=%s\n' "\$WT"
} > "$1"
CHILD
}

assert_pool_released() {  # <report-file> <label>
  local report=$1 label=$2 pool repo
  pool=$(report_pool "$report")
  repo=$(report_repo "$report")
  [ -n "$pool" ] || fail "$label: the child never published a pool directory"
  [ -n "$repo" ] || fail "$label: the child never published a fixture repo"
  if [ -e "$pool" ]; then
    force_release_pool "$pool"
    fail "$label: the treehouse pool survived cleanup ($pool)"
  fi
  assert_absent "$repo" "$label: the fixture repository survived cleanup"
  pass "$label"
}

# --- pool release: the ordered path -----------------------------------------

test_pool_released_on_normal_exit() {
  local harness report
  harness=$(fm_test_tmproot fm-pool-release-normal)
  report="$harness/report"
  bash -c "$(child_prelude "$report")" || fail \
    "the normal-exit child failed before it could publish its pool"
  assert_pool_released "$report" \
    "a fixture repository's treehouse pool is destroyed on the owning process's normal exit"
}

# --- pool release: the ABORT path -------------------------------------------
#
# The child dies through a failed assertion with no cleanup call of its own,
# which is the shape that produced the measured strand.

test_pool_released_on_failed_assertion() {
  local harness report status
  harness=$(fm_test_tmproot fm-pool-release-abort)
  report="$harness/report"
  status=0
  bash -c "$(child_prelude "$report")
fail 'deliberate mid-run abort with a live pooled worktree'" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail \
    "the abort child exited $status, so it did not abort through a failed assertion"
  assert_pool_released "$report" \
    "an aborted run's treehouse pool is destroyed before its fixture repository is deleted"
}

test_pool_released_on_sigterm() {
  local harness report pid tries
  harness=$(fm_test_tmproot fm-pool-release-term)
  report="$harness/report"
  bash -c "$(child_prelude "$report")
: > '$harness/ready'
while :; do sleep 0.1; done" >/dev/null 2>&1 &
  pid=$!
  tries=0
  while [ "$tries" -lt 600 ]; do
    [ -e "$harness/ready" ] && break
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -e "$harness/ready" ] || {
    fm_test_reap_bounded "$pid" >/dev/null 2>&1 || true
    fail "the SIGTERM child never finished acquiring its pooled worktree"
  }
  kill -TERM "$pid"
  fm_test_reap_bounded "$pid" >/dev/null 2>&1 || true
  assert_pool_released "$report" \
    "a signaled run's treehouse pool is destroyed before its fixture repository is deleted"
}

# --- pool release: a pool that never handed out a worktree ------------------
#
# The refusal cases in the herdr placement suites register a project and then
# never acquire a slot against it. This fixture registers one that never reaches
# treehouse at all, because reading a pool's status is itself enough to create
# its directory - so the release's own status read is what materializes the pool
# here, and a release that decided which directories to remove BEFORE reading
# status would leave this one behind. Those leave no orphan, but the directories
# accumulate run over run, which is the noise the strand report named as the real
# cost.

test_pool_directory_released_when_no_worktree_was_acquired() {
  local harness report repo pool found=0
  harness=$(fm_test_tmproot fm-pool-release-untouched)
  report="$harness/report"
  # An origin remote, matching what the herdr suites build: it changes the pool
  # identity treehouse derives, which is why the pool directory is observed
  # rather than computed.
  bash -c "
set -u
. '$LIB'
TMP_ROOT=\$(fm_test_tmproot fm-pool-release-untouched-case)
REPO=\"\$TMP_ROOT/pooled-project\"
fm_test_pool_register \"\$REPO\"
mkdir -p \"\$REPO\"
git -C \"\$REPO\" init -q
printf 'x\n' > \"\$REPO/README.md\"
git -C \"\$REPO\" add README.md
git -C \"\$REPO\" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm initial
git clone --quiet --bare \"\$REPO\" \"\$REPO.origin.git\"
git -C \"\$REPO\" remote add origin \"file://\$REPO.origin.git\"
printf 'repo=%s\n' \"\$REPO\" > '$report'
exit 0
" || fail "the untouched-pool child failed"
  repo=$(report_repo "$report")
  [ -n "$repo" ] || fail "the untouched-pool child never published its fixture repo"
  assert_absent "$repo" "the untouched-pool fixture repository survived cleanup"
  for pool in "$FM_TEST_TREEHOUSE_ROOT/$FIXTURE_POOL_PREFIX"*; do
    [ -d "$pool" ] || continue
    found=1
    force_release_pool "$pool"
  done
  [ "$found" -eq 0 ] || fail \
    "a project that never acquired a worktree left its pool directory behind"
  pass "a pool whose directory only the release itself creates is removed, not left behind"
}

# --- pool release adds no orphan -------------------------------------------
#
# The acceptance measurement, run around a real acquire/release cycle rather
# than asserted from the pool directory alone.

test_release_cycle_adds_no_orphan() {
  local harness report before after
  harness=$(fm_test_tmproot fm-pool-release-orphans)
  report="$harness/report"
  before=$(orphan_count)
  bash -c "$(child_prelude "$report")" || fail \
    "the orphan-count child failed before it could publish its pool"
  assert_pool_released "$report" \
    "the orphan-count cycle released its pool"
  after=$(orphan_count)
  [ "$after" = "$before" ] || fail \
    "an acquire/release cycle changed the orphan count from $before to $after"
  pass "a full acquire/release cycle leaves treehouse prune --prune-orphans reporting no new orphans"
}

# --- bounded reap: teardown is reached even when the child will not exit ----

test_reap_bounded_returns_on_a_child_ignoring_term() {
  local pid start elapsed
  bash -c 'trap "" TERM; while :; do sleep 0.1; done' &
  pid=$!
  start=$(date +%s)
  fm_test_reap_bounded "$pid" 5 || true
  elapsed=$(( $(date +%s) - start ))
  [ "$FM_TEST_REAP_SURVIVED" = 0 ] || fail "a child ignoring SIGTERM outlived SIGKILL as well"
  fm_test_pid_live "$pid" && fail "fm_test_reap_bounded returned with the child still alive"
  [ "$elapsed" -le 20 ] || fail \
    "fm_test_reap_bounded took ${elapsed}s on a child ignoring SIGTERM; it is not bounded"
  pass "fm_test_reap_bounded escalates past a child that ignores SIGTERM and returns bounded"
}

# The status-preserving variant: an assertion on a child's own exit status must
# survive being bounded, or bounding it would silently weaken the assertion.
test_wait_bounded_preserves_status_and_bounds_a_hang() {
  local pid start elapsed rc
  bash -c 'exit 7' &
  pid=$!
  rc=0
  fm_test_wait_bounded "$pid" 100 || rc=$?
  [ "$rc" -eq 7 ] || fail "fm_test_wait_bounded reported $rc for a child that exited 7"

  bash -c 'trap "" TERM; while :; do sleep 0.1; done' &
  pid=$!
  start=$(date +%s)
  rc=0
  fm_test_wait_bounded "$pid" 5 || rc=$?
  elapsed=$(( $(date +%s) - start ))
  [ "$rc" -eq 124 ] || fail "fm_test_wait_bounded reported $rc instead of a timeout for a child that never exits"
  fm_test_pid_live "$pid" && fail "fm_test_wait_bounded timed out without reaping the child"
  [ "$elapsed" -le 20 ] || fail "fm_test_wait_bounded took ${elapsed}s; it is not bounded"
  pass "fm_test_wait_bounded returns the child's own status, and bounds a child that never exits"
}

# The acceptance criterion itself: a child that never exits must not prevent the
# teardown standing behind it. The marker stands in for the Herdr lab teardown
# the focus-flash suite reaches only after reaping its sampler.
test_teardown_after_a_stuck_child_is_reached() {
  local harness marker status
  harness=$(fm_test_tmproot fm-pool-release-stuck)
  marker="$harness/teardown-ran"
  status=0
  bash -c '
    set -u
    . "$1"
    MARKER=$2
    STUCK=
    cleanup() {
      [ -n "$STUCK" ] && fm_test_reap_bounded "$STUCK" 5 >/dev/null 2>&1
      : > "$MARKER"
    }
    trap cleanup EXIT
    bash -c '\''trap "" TERM; while :; do sleep 0.1; done'\'' &
    STUCK=$!
    exit 0
  ' _ "$SAFETY" "$marker" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "the stuck-child harness exited $status"
  assert_present "$marker" \
    "a child that ignores SIGTERM prevented the teardown behind it from running"
  pass "required teardown is still reached when a background child refuses to exit"
}

# This suite's own acceptance criterion, asserted rather than assumed: every
# fixture pool it created is gone. The prefix is unique to this file, so the
# sweep is exact - and it cleans what it reports, so a regression here cannot
# itself become the strand under test.
test_suite_left_no_fixture_pool_behind() {
  local pool leftover=0
  for pool in "$FM_TEST_TREEHOUSE_ROOT/$FIXTURE_POOL_PREFIX"*; do
    [ -d "$pool" ] || continue
    leftover=1
    printf 'leftover fixture pool: %s\n' "$pool" >&2
    force_release_pool "$pool"
  done
  [ "$leftover" -eq 0 ] || fail "this suite left a treehouse pool behind"
  pass "the suite itself leaves no fixture treehouse pool behind"
}

test_pool_released_on_normal_exit
test_pool_released_on_failed_assertion
test_pool_released_on_sigterm
test_pool_directory_released_when_no_worktree_was_acquired
test_release_cycle_adds_no_orphan
test_reap_bounded_returns_on_a_child_ignoring_term
test_wait_bounded_preserves_status_and_bounds_a_hang
test_teardown_after_a_stuck_child_is_reached
test_suite_left_no_fixture_pool_behind
