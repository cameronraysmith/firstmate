#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

# The same, with fm-wake-lib.sh loaded first so the recycle-proof pid identity
# the session lock records is available. FM_PROC_ROOT_OVERRIDE points at a path
# that does not exist so the identity always comes from the fake ps: a fixture
# pid can collide with a real one, and a real /proc entry for that collision
# would answer instead of the process table this case constructs.
lib_eval_full() {  # <fakebin> <state> <expression>
  local fakebin=$1 state=$2 expr=$3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_PROC_ROOT_OVERRIDE="$state/absent-proc" bash -c "
    . \"\$0\"
    . \"\$1\"
    kill() { return 0; }
    $expr
  " "$ROOT/bin/fm-wake-lib.sh" "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-stat-lib.sh" "$dir/bin/fm-stat-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

# --- e2e: two sessions sharing ONE daemon ancestor ---------------------------
#
# The reproducing configuration for a lease that admitted two owners. Claude
# Code runs each background session of a home as a claimed spare under one
# shared daemon, so every session's contiguous harness run ends at the SAME
# outermost pid. Both sessions therefore compute the identical harness pid, the
# second finds that pid already in state/.lock, and pid equality reads as proof
# it owns a home it never claimed.
#
# The fixture builds exactly that shape with real processes: one harness-named
# daemon, orphaned to init so the walk terminates inside the fixture, running
# two harness-named session children that each carry their own session id.

install_lock_scripts() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  cp "$ROOT/bin/fm-lock.sh" "$ROOT/bin/fm-session-lock-lib.sh" \
    "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-stat-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-lock.sh"
}

# One lock attempt by session <label>, recorded under <tag>. `hold` keeps the
# session process alive until released, so a competing attempt runs while this
# one is genuinely still live; `once` returns as soon as the attempt is recorded.
make_shared_daemon_home() {  # <dir>
  local dir=$1
  install_lock_scripts "$dir"
  cat > "$dir/attempt.sh" <<'SH'
#!/usr/bin/env bash
label=$1 tag=$2 mode=$3
export CLAUDE_CODE_SESSION_ID="fixture-session-$label"
printf '%s\n' "$$" > "$FM_HOME/state/$tag.pid"
( . "$FM_HOME/bin/fm-session-lock-lib.sh"; fm_harness_ancestry_pid ) \
  > "$FM_HOME/state/$tag.ancestor" 2>/dev/null || true
"$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/$tag.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/$tag.rc"
[ "$mode" = hold ] || exit 0
i=0
while [ "$i" -lt 600 ] && [ ! -e "$FM_HOME/state/release-$label" ]; do
  sleep 0.05
  i=$((i + 1))
done
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
await() {  # <state-file>
  local n=0
  while [ "$n" -lt 600 ] && [ ! -s "$FM_HOME/state/$1" ]; do
    sleep 0.05
    n=$((n + 1))
  done
}
"$FM_CLAUDE_BIN" "$FM_HOME/attempt.sh" a a1 hold &
holder=$!
await a1.rc
"$FM_CLAUDE_BIN" "$FM_HOME/attempt.sh" b b1 once
"$FM_CLAUDE_BIN" "$FM_HOME/attempt.sh" a a2 once
: > "$FM_HOME/state/release-a"
wait "$holder"
"$FM_CLAUDE_BIN" "$FM_HOME/attempt.sh" b b2 once
printf 'done\n' > "$FM_HOME/state/fixture.done"
SH
  chmod +x "$dir/attempt.sh" "$dir/daemon.sh"
}

run_shared_daemon_fixture() {  # <dir>
  local dir=$1 i
  FM_HOME="$dir" FM_CLAUDE_BIN="$NAMED_CLAUDE" \
    bash -c '"$0" "$1" &' "$NAMED_CLAUDE" "$dir/daemon.sh"
  i=0
  while [ "$i" -lt 1200 ] && [ ! -s "$dir/state/fixture.done" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/fixture.done" ] || fail "the shared-daemon fixture never finished"
}

attempt_rc() {  # <dir> <tag>
  tr -d '[:space:]' < "$1/state/$2.rc"
}

attempt_out() {  # <dir> <tag>
  cat "$1/state/$2.out" 2>/dev/null || true
}

test_e2e_second_session_under_one_daemon_is_refused() {
  local dir a_pid b_pid a_ancestor b_ancestor
  dir="$TMP_ROOT/e2e-shared-daemon"
  make_shared_daemon_home "$dir"
  run_shared_daemon_fixture "$dir"

  # Without this the case could pass vacuously against two sessions that never
  # shared an ancestor at all, which is not the configuration that reproduces.
  a_pid=$(tr -d '[:space:]' < "$dir/state/a1.pid")
  b_pid=$(tr -d '[:space:]' < "$dir/state/b1.pid")
  a_ancestor=$(tr -d '[:space:]' < "$dir/state/a1.ancestor")
  b_ancestor=$(tr -d '[:space:]' < "$dir/state/b1.ancestor")
  [ -n "$a_pid" ] && [ "$a_pid" != "$b_pid" ] \
    || fail "fixture did not produce two distinct sessions: a=$a_pid b=$b_pid"
  [ -n "$a_ancestor" ] && [ "$a_ancestor" = "$b_ancestor" ] \
    || fail "fixture did not reproduce one shared harness ancestor: a=$a_ancestor b=$b_ancestor"

  expect_code 0 "$(attempt_rc "$dir" a1)" "the first session must claim the home"
  assert_contains "$(attempt_out "$dir" a1)" "lock acquired" \
    "the first session did not report the lease as acquired"

  expect_code 1 "$(attempt_rc "$dir" b1)" \
    "a second session under the same daemon ancestor must be refused the lease"
  assert_contains "$(attempt_out "$dir" b1)" "another live firstmate session holds the lock" \
    "the refused session did not receive the read-only diagnostic"

  # Refusing the sibling must not cost the holder its own home.
  expect_code 0 "$(attempt_rc "$dir" a2)" \
    "the session that holds the lease was refused its own home"

  # Once the holder is gone the daemon is still alive. It is shared
  # infrastructure, not a session, so it must not hold the home hostage.
  expect_code 0 "$(attempt_rc "$dir" b2)" \
    "the surviving shared daemon locked out the next session of the home"
  pass "session-lock e2e: two sessions under one daemon ancestor get exactly one owner"
}

# --- unit: session identity and recycle-proof holder liveness ----------------

# A process table in which pid 400 parents this process, both report as claude,
# and every other pid is an ordinary shell. That is the daemon-sharing shape
# reduced to its essentials: the recorded lock pid IS an ancestor of the prober.
make_shared_ancestor_ps() {  # <fakebin> <parent-pid>
  local fakebin=$1 parent=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field= pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$pid:\$field" in
  $parent:comm=) printf '%s\n' claude ;;
  $parent:args=) printf '%s\n' claude ;;
  $parent:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' claude ;;
  *:args=) printf '%s\n' claude ;;
  *:ppid=) printf '%s\n' $parent ;;
esac
SH
  chmod +x "$fakebin/ps"
}

test_session_identity_decides_ownership_among_ancestry_siblings() {
  local dir fakebin owner
  dir="$TMP_ROOT/identity-siblings"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  make_shared_ancestor_ps "$fakebin" 400
  printf '400\n' > "$dir/state/.lock"
  printf 'pid 400\nsession sess-a\nchain 777 \nchain 400 \n' > "$dir/state/.lock.session"

  CLAUDE_CODE_SESSION_ID=sess-a lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session recorded on the lease did not recognize its own home"
  if CLAUDE_CODE_SESSION_ID=sess-b lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a sibling session claimed a home whose lease names another session"
  fi
  # With no session id on either side the answer must stay exactly what it was
  # before sessions could be told apart: ancestry membership.
  rm -f "$dir/state/.lock.session"
  owner="fm_session_lock_owned_by_self '$dir/state'"
  ( unset CLAUDE_CODE_SESSION_ID FM_SESSION_ID; lib_eval "$fakebin" "$owner" ) \
    || fail "a lock with no recorded session stopped answering by ancestry membership"
  pass "session-lock: the recorded session id, not a shared ancestor pid, decides ownership"
}

# The record's chain pid is deliberately OUTSIDE the prober's ancestry here:
# that is what makes it evidence of another session rather than of shared
# infrastructure. The fake process table resolves no harness ancestry for the
# prober at all, so nothing about pid 700 can be read as inherited.
make_recorded_holder_ps() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
requested=$*
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$requested" in
  *lstart*)
    if [ "$pid" = "${FM_TEST_RECYCLED_PID:-}" ]; then
      printf '%s\n' 'Wed Aug 12 14:11:00 2026 claude --resume'
    else
      printf '%s\n' 'Wed Aug 12 13:05:32 2026 claude --resume'
    fi
    exit 0
    ;;
esac
case "$pid:$field" in
  700:comm=) printf '%s\n' claude ;;
  700:args=) printf '%s\n' claude ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

test_recycled_holder_pid_is_not_a_live_holder() {
  local dir fakebin holder
  dir="$TMP_ROOT/recycled-holder"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  make_recorded_holder_ps "$fakebin"
  printf '700\n' > "$dir/state/.lock"
  printf 'pid 700\nsession sess-other\nchain 700 Wed Aug 12 13:05:32 2026 claude --resume\n' \
    > "$dir/state/.lock.session"
  holder="fm_session_lock_holder_is_other_live_session '$dir/state'"

  ( unset CLAUDE_CODE_SESSION_ID FM_SESSION_ID; lib_eval_full "$fakebin" "$dir/state" "$holder" ) \
    || fail "a still-running recorded holder was not recognized as another live session"
  if ( unset CLAUDE_CODE_SESSION_ID FM_SESSION_ID
    FM_TEST_RECYCLED_PID=700 lib_eval_full "$fakebin" "$dir/state" "$holder" ); then
    fail "a recycled pid wearing the recorded holder's number was read as a live holder"
  fi
  pass "session-lock: a recycled pid does not keep the recorded holder alive"
}

# A subagent of the primary session must never take the home's lease. It is not
# a second operator; it is a helper the lease-holder spawned, and it exits with
# its task. Both directions are asserted, because a predicate that answers "yes"
# to everything would pass a one-sided version of this test while breaking every
# genuine session's ability to claim its own home.
test_subagent_invocation_is_identified() {
  local claude_sub claude_sub_eq primary bare
  claude_sub='/nix/store/x/bin/.claude-wrapped --agent-id probe@sess --parent-session-id 1250a6ab --agent-type general-purpose'
  claude_sub_eq='/nix/store/x/bin/.claude-wrapped --agent-id probe@sess --parent-session-id=1250a6ab'
  primary='/nix/store/x/bin/.claude-wrapped --session-id 1250a6ab'
  bare='/nix/store/x/bin/.claude-wrapped'

  lib_eval "$TMP_ROOT" "fm_session_process_is_subagent '$claude_sub'" \
    || fail "a subagent invocation carrying --parent-session-id was not identified"
  lib_eval "$TMP_ROOT" "fm_session_process_is_subagent '$claude_sub_eq'" \
    || fail "the --parent-session-id=<v> spelling was not identified"
  ! lib_eval "$TMP_ROOT" "fm_session_process_is_subagent '$primary'" \
    || fail "a session in its own right was misidentified as a subagent"
  ! lib_eval "$TMP_ROOT" "fm_session_process_is_subagent '$bare'" \
    || fail "a bare harness invocation was misidentified as a subagent"
  pass "a subagent invocation is identified by its parent session, and a primary is not"
}

# The ancestry walk is what actually decides, and it is the part that broke:
# a subagent is re-parented under a tmux server, so the walk terminates at the
# subagent itself and it resolves as its own outermost harness.
test_subagent_ancestry_is_detected_and_a_primary_is_not() {
  local dir fakebin
  dir="$TMP_ROOT/subagent-ancestry"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"

  # Every pid in the walk answers as a subagent-shaped harness.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) shift 2 ;;
    *) shift ;;
  esac
done
case "$field:${FM_TEST_SUBAGENT_SHAPE:-sub}" in
  comm=:*) printf '%s\n' '.claude-wrapped' ;;
  args=:sub) printf '%s\n' '/nix/store/x/bin/.claude-wrapped --agent-id p@s --parent-session-id 1250a6ab' ;;
  args=:primary) printf '%s\n' '/nix/store/x/bin/.claude-wrapped --session-id 1250a6ab' ;;
  ppid=:*) printf '%s\n' '1' ;;
esac
SH
  chmod +x "$fakebin/ps"

  FM_TEST_SUBAGENT_SHAPE=sub lib_eval "$fakebin" "fm_session_self_is_subagent" \
    || fail "a process whose harness ancestry is a subagent was not detected"
  ! FM_TEST_SUBAGENT_SHAPE=primary lib_eval "$fakebin" "fm_session_self_is_subagent" \
    || fail "a genuine session was reported as a subagent, which would deny it its own home"
  pass "the ancestry walk detects a subagent and leaves a genuine session alone"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_session_identity_decides_ownership_among_ancestry_siblings
test_recycled_holder_pid_is_not_a_live_holder
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_e2e_second_session_under_one_daemon_is_refused
test_subagent_invocation_is_identified
test_subagent_ancestry_is_detected_and_a_primary_is_not
