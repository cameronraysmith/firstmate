#!/usr/bin/env bash
# tests/fm-stat-lib.test.sh - the stat(1) dialect probe (bin/fm-stat-lib.sh),
# the ONE owner of the GNU-vs-BSD stat decision every fm-* caller delegates to.
#
# The defect this pins cannot be reproduced by the platform lanes: CI's macOS
# runner has BSD /usr/bin/stat first on PATH and its Linux runner has GNU, so
# neither lane ever sees the case that broke a nix-managed macOS host - a GNU
# coreutils stat ahead of /usr/bin/stat, where a Darwin-keyed caller hands `-f`
# to a stat that answers only `-c`. Real stat shims on a temp PATH reproduce all
# three worlds anywhere, which a uname branch could only do by lying about uname.
#
# The load-bearing contract:
#   1. A GNU-behaving stat classifies as gnu, a BSD-behaving one as bsd, and no
#      usable stat as none (nonzero, with a loud diagnostic).
#   2. The GNU form is probed FIRST, so a GNU stat is NEVER handed the BSD `-f`
#      form. That direction is the poisonous one: GNU stat given `-f` exits
#      nonzero but still writes a filesystem dump to stdout, which a caller
#      substituting the output would read as data.
#   3. The verdict is resolved once per process and cached.
#   4. Real call sites route through the probe and keep their exact formats.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-stat-lib) || exit 1
BASH_BIN=$(command -v bash) || fail "bash is required"

# --- fake stat implementations ----------------------------------------------
#
# Each shim appends every invocation to $FM_FAKE_STAT_LOG and then reproduces
# the measured behavior of the implementation it stands for (verified against
# GNU coreutils 9.11 and macOS /usr/bin/stat). `#!/bin/sh` is absolute on
# purpose: a case that empties PATH must still be able to run the shim.

# make_stat_bin <dir> <gnu|bsd|absent> -> echoes the bin dir to prepend to PATH
make_stat_bin() {
  local dir=$1 kind=$2
  mkdir -p "$dir"
  case "$kind" in
    absent) ;;
    gnu)
      cat > "$dir/stat" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FM_FAKE_STAT_LOG"
case "$1" in
  -c) printf '22\n'; exit 0 ;;
  -f)
    # GNU stat treats -f as *filesystem* stat: the format operand is read as a
    # file name, so it errors AND still dumps the filesystem report to stdout.
    printf 'stat: cannot read file system information\n' >&2
    printf '  File: "/"\n    ID: 1 Namelen: ?\nBlock size: 4096\nBlocks: Total: 1 Free: 1\nInodes: Total: 1 Free: 1\n'
    exit 1
    ;;
esac
printf 'stat: unrecognized option\n' >&2
exit 1
SH
      chmod +x "$dir/stat"
      ;;
    bsd)
      cat > "$dir/stat" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FM_FAKE_STAT_LOG"
case "$1" in
  -f) printf '22\n'; exit 0 ;;
esac
printf 'stat: illegal option -- %s\n' "$1" >&2
exit 1
SH
      chmod +x "$dir/stat"
      ;;
    *) fail "unknown fake stat kind: $kind" ;;
  esac
  printf '%s\n' "$dir"
}

# run_with_stat <gnu|bsd|absent> <log-file> <shell-snippet> -> runs the snippet
# in a fresh process whose ONLY stat is the named fake (or none at all), with
# bin/fm-stat-lib.sh already sourced. Stdout and stderr are returned merged so a
# case can assert on the diagnostic; the exit code is the snippet's.
run_with_stat() {
  local kind=$1 log=$2 snippet=$3 bin
  bin=$(make_stat_bin "$TMP_ROOT/bin.$kind.$(basename "$log")" "$kind") || return 1
  : > "$log"
  FM_FAKE_STAT_LOG="$log" PATH="$bin" "$BASH_BIN" -c "
    set -u
    . '$ROOT/bin/fm-stat-lib.sh'
    $snippet
  " 2>&1
}

# --- 1. classification ------------------------------------------------------

test_gnu_stat_classifies_as_gnu() {
  local log=$TMP_ROOT/gnu.log out rc
  out=$(run_with_stat gnu "$log" 'fm_stat_flavor'); rc=$?
  expect_code 0 "$rc" 'a GNU-behaving stat must classify successfully'
  [ "$out" = gnu ] || fail "a GNU-behaving stat must classify as gnu, got '$out'"
  pass 'fm_stat_flavor: a GNU-behaving stat on PATH classifies as gnu'
}

test_bsd_stat_classifies_as_bsd() {
  local log=$TMP_ROOT/bsd.log out rc
  out=$(run_with_stat bsd "$log" 'fm_stat_flavor'); rc=$?
  expect_code 0 "$rc" 'a BSD-behaving stat must classify successfully'
  [ "$out" = bsd ] || fail "a BSD-behaving stat must classify as bsd, got '$out'"
  pass 'fm_stat_flavor: a BSD-behaving stat on PATH classifies as bsd'
}

test_absent_stat_is_none_and_loud() {
  local log=$TMP_ROOT/absent.log out rc
  out=$(run_with_stat absent "$log" 'fm_stat_flavor'); rc=$?
  [ "$rc" -ne 0 ] || fail 'no usable stat must be a nonzero verdict, not a silent guess'
  assert_contains "$out" none 'no usable stat must report the none flavor'
  assert_contains "$out" 'fm-stat-lib:' 'no usable stat must name the concrete failure on stderr'
  pass 'fm_stat_flavor: no usable stat on PATH reports none, nonzero, with a named diagnostic'
}

test_predicate_agrees_with_flavor() {
  local out
  out=$(run_with_stat gnu "$TMP_ROOT/pred-gnu.log" 'fm_stat_is_gnu && echo yes || echo no')
  [ "$out" = yes ] || fail "fm_stat_is_gnu must be true under a GNU stat, got '$out'"
  out=$(run_with_stat bsd "$TMP_ROOT/pred-bsd.log" 'fm_stat_is_gnu && echo yes || echo no')
  [ "$out" = no ] || fail "fm_stat_is_gnu must be false under a BSD stat, got '$out'"
  out=$(run_with_stat absent "$TMP_ROOT/pred-absent.log" 'fm_stat_is_gnu && echo yes || echo no')
  assert_contains "$out" no 'fm_stat_is_gnu must be false when no stat is usable'
  pass 'fm_stat_is_gnu: the predicate agrees with the flavor in all three worlds'
}

# --- 2. probe order: a GNU stat is never handed the BSD form ----------------

test_gnu_stat_is_never_probed_with_the_bsd_form() {
  local log=$TMP_ROOT/order-gnu.log
  run_with_stat gnu "$log" 'fm_stat_is_gnu' >/dev/null
  grep -q -- '^-f' "$log" \
    && fail "a GNU stat must never be probed with -f (the dump-to-stdout direction)"$'\n'"--- calls ---"$'\n'"$(cat "$log")"
  grep -q -- '^-c ' "$log" || fail 'the GNU form must be probed first'
  pass 'fm_stat_detect: a GNU stat is probed with -c only, never the -f form that dumps to stdout'
}

test_bsd_probe_falls_back_after_the_gnu_form() {
  local log=$TMP_ROOT/order-bsd.log calls
  run_with_stat bsd "$log" 'fm_stat_is_gnu' >/dev/null
  calls=$(cat "$log")
  case "$calls" in
    '-c '*$'\n''-f '*) : ;;
    *) fail "the BSD verdict must come from probing -c first, then -f; got:"$'\n'"$calls" ;;
  esac
  pass 'fm_stat_detect: a BSD stat is classified by falling back to -f after -c fails'
}

test_probe_output_never_reaches_the_caller() {
  local out
  # The GNU fake dumps five filesystem-report lines on the -f path. If the probe
  # ever took that direction, or failed to discard probe output, this leaks.
  out=$(run_with_stat gnu "$TMP_ROOT/quiet.log" 'fm_stat_is_gnu; printf "END\n"')
  [ "$out" = END ] || fail "probing must emit nothing of its own, got:"$'\n'"$out"
  out=$(run_with_stat bsd "$TMP_ROOT/quiet-bsd.log" 'fm_stat_is_gnu; printf "END\n"')
  [ "$out" = END ] || fail "probing a BSD stat must emit nothing of its own, got:"$'\n'"$out"
  pass 'fm_stat_detect: neither probe direction leaks output into the caller stream'
}

# --- 3. caching -------------------------------------------------------------

test_verdict_re_resolves_when_path_changes() {
  # A cache keyed on the process alone is wrong, and silently so: callers
  # legitimately narrow PATH mid-process (a minimal /usr/bin:/bin, a fakebin
  # shim), and the stat found there can speak the other dialect. A stale verdict
  # then sends the wrong format to a real stat and the read comes back empty.
  local gnu_bin bsd_bin log out
  log=$TMP_ROOT/repath.log
  gnu_bin=$(make_stat_bin "$TMP_ROOT/bin.repath.gnu" gnu)
  bsd_bin=$(make_stat_bin "$TMP_ROOT/bin.repath.bsd" bsd)
  : > "$log"
  out=$(FM_FAKE_STAT_LOG="$log" PATH="$gnu_bin" "$BASH_BIN" -c "
    set -u
    . '$ROOT/bin/fm-stat-lib.sh'
    fm_stat_flavor
    PATH='$bsd_bin'
    fm_stat_flavor
    PATH='$gnu_bin'
    fm_stat_flavor
  " 2>&1)
  [ "$out" = "$(printf 'gnu\nbsd\ngnu')" ] \
    || fail "the verdict must track the PATH in effect, got:"$'\n'"$out"
  pass 'fm_stat_flavor: the verdict re-resolves when PATH changes mid-process'
}

test_verdict_is_probed_once_per_process() {
  local log=$TMP_ROOT/cache.log count
  run_with_stat gnu "$log" 'for _ in 1 2 3 4 5; do fm_stat_is_gnu; done; fm_stat_flavor' >/dev/null
  count=$(wc -l < "$log" | tr -d ' ')
  [ "$count" = 1 ] || fail "the verdict must be probed once and cached, got $count probe calls"
  pass 'fm_stat_detect: the verdict is resolved once per process and cached'
}

# --- 4. call sites route through the probe ----------------------------------

test_call_sites_use_the_probe_and_keep_their_formats() {
  local log=$TMP_ROOT/callsite.log calls
  run_with_stat gnu "$log" ". '$ROOT/bin/fm-pr-lib.sh'; fm_pr_file_mode /any/path" >/dev/null
  calls=$(cat "$log")
  assert_contains "$calls" '-c %a /any/path' 'a real caller must use the GNU format under a GNU stat'
  assert_not_contains "$calls" '-f %Lp' 'a real caller must not reach for the BSD format under a GNU stat'

  run_with_stat bsd "$log" ". '$ROOT/bin/fm-pr-lib.sh'; fm_pr_file_mode /any/path" >/dev/null
  calls=$(cat "$log")
  assert_contains "$calls" '-f %Lp /any/path' 'a real caller must use the BSD format under a BSD stat'
  pass 'call sites: fm_pr_file_mode routes through the probe and keeps both exact formats'
}

test_gnu_stat_classifies_as_gnu
test_bsd_stat_classifies_as_bsd
test_absent_stat_is_none_and_loud
test_predicate_agrees_with_flavor
test_gnu_stat_is_never_probed_with_the_bsd_form
test_bsd_probe_falls_back_after_the_gnu_form
test_probe_output_never_reaches_the_caller
test_verdict_re_resolves_when_path_changes
test_verdict_is_probed_once_per_process
test_call_sites_use_the_probe_and_keep_their_formats
