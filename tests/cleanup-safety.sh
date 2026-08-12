#!/usr/bin/env bash
# tests/cleanup-safety.sh - helpers for the one failure family where a suite's
# cleanup does not run to completion and leaks a resource that lives OUTSIDE its
# own fixture root, so removing the fixture root cannot reclaim it.
#
# Two mechanisms in that family, both measured in this repo's own suites.
#
# 1. A treehouse POOL outliving the fixture repository it was created against.
#    `treehouse return` is not the release: it returns the slot TO the pool,
#    which is precisely what keeps the pool alive. Deleting the fixture repo
#    afterwards leaves the pool with slots whose backing repository is gone, and
#    `treehouse prune --all --prune-orphans` then reports each one as "content
#    could not be verified". The pool is keyed on the fixture repo's path, so a
#    fresh mktemp path each run means the strand count only ever grows.
#    fm_test_pool_register + fm_test_pool_release_all destroy the pool instead.
#
# 2. An unbounded `wait` standing in front of required teardown. A child that
#    never exits strands every resource the cleanup would have released after
#    it. This is the same hazard bin/fm-watch-arm.sh's reap_child bounds for the
#    watcher child; fm_test_reap_bounded bounds it for a test's own child.
#
# This module deliberately arms NO trap of its own. Every suite that sources it
# already owns an EXIT trap, and a second `trap ... EXIT` here would silently
# replace or be replaced by the suite's. Call the release from inside the
# cleanup the suite already has, immediately before it removes its fixture root.
# tests/lib.sh does that for every suite built on fm_test_tmproot.
set -u

# --- bounded child reap -----------------------------------------------------

FM_TEST_REAP_TICKS=${FM_TEST_REAP_TICKS:-50}

# A zombie counts as dead: it is already reapable, so `wait` on it returns at
# once. Treating it as live would burn the whole bound and then report a
# survivor that is not one.
fm_test_pid_live() {  # <pid>
  local pid=$1 state
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$state" in
    Z*) return 1 ;;
    *) return 0 ;;
  esac
}

# fm_test_reap_bounded <pid> [ticks]: stop a background child and reap it within
# a bound, so a child that ignores the stop cannot strand the teardown that
# follows. Escalates TERM -> bounded poll -> KILL -> bounded poll, and calls
# `wait` only once the pid is confirmed gone, which is what keeps this bounded:
# `wait` on a live child is exactly the unbounded step being replaced.
#
# Returns the child's status. A caller that must distinguish "outlived even
# KILL" reads FM_TEST_REAP_SURVIVED rather than the status, because the status
# cannot carry that: `wait` on a KILLed child legitimately returns 137 itself.
# Read by sourcing test files, not by this module.
# shellcheck disable=SC2034
FM_TEST_REAP_SURVIVED=0
fm_test_reap_bounded() {  # <pid> [ticks]
  local pid=${1:-} ticks=${2:-$FM_TEST_REAP_TICKS} i=0
  FM_TEST_REAP_SURVIVED=0
  [ -n "$pid" ] || return 0
  if fm_test_pid_live "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    while [ "$i" -lt "$ticks" ] && fm_test_pid_live "$pid"; do
      sleep 0.1
      i=$((i + 1))
    done
    if fm_test_pid_live "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
      i=0
      while [ "$i" -lt 20 ] && fm_test_pid_live "$pid"; do
        sleep 0.1
        i=$((i + 1))
      done
    fi
  fi
  if fm_test_pid_live "$pid"; then
    # shellcheck disable=SC2034 # Read by sourcing test files.
    FM_TEST_REAP_SURVIVED=1
    return 137
  fi
  wait "$pid" 2>/dev/null
}

# --- treehouse pool release -------------------------------------------------
#
# Registration is keyed on the fixture PROJECT path, not on an acquired worktree
# path, for two reasons. It is declarative at fixture-creation time, so it is
# already in place if the run aborts before any worktree exists; and treehouse
# itself stays the authority on which slots belong to that project, so a slot
# the suite never recorded in its own metadata is still released.
#
# The registry is a `$$`-keyed file rather than a shell array because the usual
# call shape in this suite runs helpers inside `$(...)`, whose in-process state
# dies with the subshell. tests/lib.sh documents that constraint in full.

FM_TEST_POOL_REGISTRY=${FM_TEST_POOL_REGISTRY:-}
if [ -z "$FM_TEST_POOL_REGISTRY" ]; then
  FM_TEST_POOL_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-test-pool.$$.XXXXXX") || return 1
fi

# fm_test_pool_register <project-path>: record a fixture repository whose
# treehouse pool must be destroyed before the repository is deleted. Safe to
# call before the repo exists and before any worktree is acquired.
fm_test_pool_register() {  # <project-path>
  local proj=${1:-}
  [ -n "$proj" ] || return 0
  printf '%s\n' "$proj" >> "$FM_TEST_POOL_REGISTRY"
}

# Worktree paths out of `treehouse status --json`. The paths treehouse prints
# here are pool paths under its own root, which carry no JSON-escaped character,
# so this stays free of a jq dependency the non-herdr suites do not have.
fm_test_pool_worktrees() {  # <project-path>
  local proj=$1 json
  json=$(cd "$proj" && treehouse status --json 2>/dev/null) || return 1
  printf '%s' "$json" \
    | grep -o '"path":"[^"]*"' \
    | sed -e 's/^"path":"//' -e 's/"$//'
}

# A pool that never handed out a worktree still leaves its directory behind -
# `treehouse status` alone creates it - and an empty pool reports no path for the
# authoritative derivation above to use. These two resolve that one case.
#
# The layout is an observed treehouse detail (v2.1.1: <root>/<repo-basename>-<first
# 6 hex of sha256 of the repository's physical path>/<slot>/<repo-basename>),
# not a documented contract, so it is used ONLY as this fallback and never for
# the orphan guarantee. If a later treehouse changes the scheme, the derived path
# simply will not exist and this degrades to doing nothing.
#
# A wrong guess is harmless rather than merely unlikely: the only directory this
# can remove is one holding no worktree slots at all, which is inert state
# treehouse recreates on demand the next time that pool is touched.
FM_TEST_TREEHOUSE_ROOT=${FM_TEST_TREEHOUSE_ROOT:-$HOME/.treehouse}

fm_test_pool_path_digest() {  # <absolute-path>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 6)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 6)}'
  else
    printf '%s' "$1" | openssl dgst -sha256 | awk '{print substr($NF, 1, 6)}'
  fi
}

fm_test_pool_dir_for() {  # <project-path>
  local proj=$1 real digest
  real=$(cd "$proj" 2>/dev/null && pwd -P) || return 1
  digest=$(fm_test_pool_path_digest "$real") || return 1
  [ -n "$digest" ] || return 1
  printf '%s/%s-%s\n' "$FM_TEST_TREEHOUSE_ROOT" "${real##*/}" "$digest"
}

# Remove a pool directory that holds no slots left. Only the two state files
# treehouse keeps there are removed by name, then the directory itself by
# rmdir - which cannot succeed on a directory holding anything else, so an
# unexpected entry leaves the directory standing instead of being destroyed.
fm_test_pool_rmdir_if_empty() {  # <pool-dir>
  local pool=$1 entry
  [ -d "$pool" ] || return 0
  for entry in "$pool"/*; do
    [ -e "$entry" ] || continue
    case "${entry##*/}" in
      treehouse-state.json | treehouse-state.lock) rm -f "$entry" ;;
    esac
  done
  rmdir "$pool" 2>/dev/null || return 1
}

# fm_test_pool_release <project-path>: destroy every treehouse worktree pooled
# against this fixture repository, then the now-empty pool directory.
#
# Each worktree is named by its exact path with --include-leased, because
# `destroy --all` NEVER removes a leased worktree and still exits 0 while
# reporting it skipped: a bulk destroy would look like it worked and leave the
# strand in place. --include-in-use terminates the slot's processes first, and
# --include-unlanded covers fixture commits that were never merged anywhere.
fm_test_pool_release() {  # <project-path>
  local proj=${1:-} wt pool rc=0 pools='' derived=''
  [ -n "$proj" ] || return 0
  command -v treehouse >/dev/null 2>&1 || return 0
  # Without the repository, treehouse cannot resolve its pool at all; that is
  # the strand this function exists to prevent, not a state it can repair.
  [ -d "$proj" ] || return 0
  derived=$(fm_test_pool_dir_for "$proj") || derived=''
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    pool=$(dirname "$(dirname "$wt")")
    case "$pools" in
      *"|$pool|"*) ;;
      *) pools="$pools|$pool|" ;;
    esac
    treehouse destroy "$wt" \
      --include-leased --include-in-use --include-unlanded --yes >/dev/null 2>&1 || {
      printf 'cleanup-safety: treehouse destroy failed for %s\n' "$wt" >&2
      rc=1
    }
  done <<EOF
$(fm_test_pool_worktrees "$proj")
EOF
  # Anything still pooled here is a strand that survived the destroys above.
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    printf 'cleanup-safety: worktree still pooled against %s after release: %s\n' \
      "$proj" "$wt" >&2
    rc=1
  done <<EOF
$(fm_test_pool_worktrees "$proj")
EOF
  # Only now, because the status reads above CREATE the pool directory for a
  # project that never had one: testing for it any earlier misses exactly the
  # empty pool this fallback is here to remove.
  if [ -n "$derived" ] && [ -d "$derived" ]; then
    case "$pools" in
      *"|$derived|"*) ;;
      *) pools="$pools|$derived|" ;;
    esac
  fi
  while [ -n "$pools" ]; do
    pool=${pools#|}
    pool=${pool%%|*}
    pools=${pools#"|$pool|"}
    [ -n "$pool" ] || continue
    fm_test_pool_rmdir_if_empty "$pool" || {
      printf 'cleanup-safety: pool directory not empty after release: %s\n' "$pool" >&2
      rc=1
    }
  done
  return "$rc"
}

# fm_test_pool_release_all: release every registered fixture repository's pool.
# Idempotent - it consumes the registry, so a suite whose fail() path and EXIT
# trap both reach cleanup releases once and no-ops the second time.
fm_test_pool_release_all() {
  local proj rc=0 registry=$FM_TEST_POOL_REGISTRY
  [ -n "$registry" ] || return 0
  [ -f "$registry" ] || return 0
  while IFS= read -r proj; do
    [ -n "$proj" ] || continue
    fm_test_pool_release "$proj" || rc=1
  done < "$registry"
  rm -f "$registry"
  return "$rc"
}
