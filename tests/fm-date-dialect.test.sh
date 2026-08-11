#!/usr/bin/env bash
# tests/fm-date-dialect.test.sh - the date(1) dialect probe in tests/lib.sh, the
# ONE owner of the GNU-vs-BSD decision every fixture that backdates a file goes
# through (fm_test_epoch_stamp, fm_test_set_mtime).
#
# This is the date-side companion to tests/fm-stat-lib.test.sh, and the defect it
# pins is invisible to the platform lanes for the same reason: CI's macOS runner
# resolves BSD /bin/date first and its Linux runner resolves GNU, so neither ever
# sees a GNU coreutils date ahead of /bin/date on a macOS PATH - the nix-managed
# host where a `uname`-keyed fixture hands `-r` to a date that reads it as a file
# name. Real date shims on a temp PATH reproduce all three worlds anywhere.
#
# The load-bearing contract:
#   1. A GNU-behaving date classifies as gnu, a BSD-behaving one as bsd, and a
#      date that answers neither form as none (nonzero, with a loud diagnostic).
#   2. The GNU form is probed FIRST, so a GNU date is NEVER handed `-r <epoch>`.
#      That direction is the wrong-answer one: GNU date reads the operand as a
#      FILE NAME, so an epoch that happens to name a file in the working
#      directory returns that file's mtime with a zero exit.
#   3. The verdict is resolved once per process and cached against its PATH.
#   4. The real call sites round-trip: a file backdated through fm_test_set_mtime
#      reads back at exactly the requested epoch through fm_test_file_mtime.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-date-dialect) || exit 1
BASH_BIN=$(command -v bash) || fail "bash is required"
REAL_DATE=$(command -v date) || fail "date is required"

# --- fake date implementations ----------------------------------------------
#
# Each shim logs every invocation to $FM_FAKE_DATE_LOG and then reproduces the
# measured behavior of the implementation it stands for (verified 2026-08-11
# against GNU coreutils date 9.7 and macOS /bin/date). Anything outside the two
# epoch-rendering forms is delegated to the real date, so a fixture can still
# source tests/lib.sh - which reads the clock - under the shim.

# make_date_bin <dir> <gnu|bsd|none> -> echoes the bin dir to prepend to PATH
make_date_bin() {
  local dir=$1 kind=$2
  mkdir -p "$dir"
  case "$kind" in
    gnu)
      cat > "$dir/date" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FM_FAKE_DATE_LOG"
case "$1" in
  -d)
    case "$2" in @*) printf 'GNU-EPOCH-%s\n' "${2#@}"; exit 0 ;; esac
    ;;
  -r)
    # GNU date -r reads its operand as a FILE NAME, never as an epoch. A caller
    # that hands it an epoch gets this file's mtime whenever a file of that name
    # exists, and an error when it does not.
    if [ -e "$2" ]; then printf 'GNU-MTIME-OF-%s\n' "$2"; exit 0; fi
    printf "date: cannot stat '%s': No such file or directory\n" "$2" >&2
    exit 1
    ;;
esac
exec "$FM_FAKE_REAL_DATE" "$@"
SH
      ;;
    bsd)
      cat > "$dir/date" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FM_FAKE_DATE_LOG"
case "$1" in
  -r) printf 'BSD-EPOCH-%s\n' "$2"; exit 0 ;;
  -d) printf 'date: illegal option -- d\n' >&2; exit 1 ;;
esac
exec "$FM_FAKE_REAL_DATE" "$@"
SH
      ;;
    none)
      cat > "$dir/date" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FM_FAKE_DATE_LOG"
case "$1" in
  -d | -r) printf 'date: unsupported option %s\n' "$1" >&2; exit 1 ;;
esac
exec "$FM_FAKE_REAL_DATE" "$@"
SH
      ;;
    *) fail "unknown fake date kind: $kind" ;;
  esac
  chmod +x "$dir/date"
  printf '%s\n' "$dir"
}

# run_with_date <gnu|bsd|none> <log-file> <shell-snippet> [cwd] -> runs the
# snippet in a fresh process whose `date` is the named fake, with tests/lib.sh
# already sourced and the invocation log cleared of the sourcing's own reads.
# Stdout and stderr are merged so a case can assert on the diagnostic; the exit
# code is the snippet's.
run_with_date() {
  local kind=$1 log=$2 snippet=$3 cwd=${4:-$TMP_ROOT} bin
  bin=$(make_date_bin "$TMP_ROOT/bin.$kind.$(basename "$log")" "$kind") || return 1
  : > "$log"
  ( cd "$cwd" || exit 1
    FM_FAKE_DATE_LOG="$log" FM_FAKE_REAL_DATE="$REAL_DATE" PATH="$bin:$PATH" \
      "$BASH_BIN" -c "
        set -u
        . '$ROOT/tests/lib.sh'
        : > \"\$FM_FAKE_DATE_LOG\"
        $snippet
      " 2>&1 )
}

# --- 1. classification ------------------------------------------------------

test_gnu_date_classifies_as_gnu() {
  local out rc
  out=$(run_with_date gnu "$TMP_ROOT/gnu.log" 'fm_test_date_flavor'); rc=$?
  expect_code 0 "$rc" 'a GNU-behaving date must classify successfully'
  [ "$out" = gnu ] || fail "a GNU-behaving date must classify as gnu, got '$out'"
  pass 'fm_test_date_flavor: a GNU-behaving date on PATH classifies as gnu'
}

test_bsd_date_classifies_as_bsd() {
  local out rc
  out=$(run_with_date bsd "$TMP_ROOT/bsd.log" 'fm_test_date_flavor'); rc=$?
  expect_code 0 "$rc" 'a BSD-behaving date must classify successfully'
  [ "$out" = bsd ] || fail "a BSD-behaving date must classify as bsd, got '$out'"
  pass 'fm_test_date_flavor: a BSD-behaving date on PATH classifies as bsd'
}

test_unusable_date_is_none_and_loud() {
  local out rc
  out=$(run_with_date none "$TMP_ROOT/none.log" 'fm_test_date_flavor'); rc=$?
  [ "$rc" -ne 0 ] || fail 'a date answering neither form must be a nonzero verdict, not a silent guess'
  assert_contains "$out" none 'an unusable date must report the none flavor'
  assert_contains "$out" 'fm_test_date:' 'an unusable date must name the concrete failure on stderr'
  pass 'fm_test_date_flavor: a date answering neither form reports none, nonzero, with a named diagnostic'
}

test_stamp_refuses_rather_than_guessing_when_no_form_works() {
  local out rc
  out=$(run_with_date none "$TMP_ROOT/none-stamp.log" \
    'fm_test_epoch_stamp 1784094040 && printf "STAMPED\n"'); rc=$?
  [ "$rc" -ne 0 ] || fail 'fm_test_epoch_stamp must fail when no date form works'
  case "$out" in *STAMPED*) fail "fm_test_epoch_stamp must emit no stamp when it cannot render one, got:"$'\n'"$out" ;; esac
  pass 'fm_test_epoch_stamp: an unrenderable epoch refuses rather than emitting a guessed stamp'
}

# --- 2. probe order: a GNU date is never handed the BSD form ----------------

test_gnu_date_is_never_probed_with_the_bsd_form() {
  local log=$TMP_ROOT/order-gnu.log
  run_with_date gnu "$log" 'fm_test_epoch_stamp 1784094040' >/dev/null
  grep -q -- '^-r' "$log" \
    && fail "a GNU date must never be handed -r (the file-name direction)"$'\n'"--- calls ---"$'\n'"$(cat "$log")"
  grep -q -- '^-d @' "$log" || fail 'the GNU form must be probed first'
  pass 'fm_test_date_detect: a GNU date is asked only the -d @<epoch> form, never the -r form it reads as a file name'
}

test_bsd_probe_falls_back_after_the_gnu_form() {
  local log=$TMP_ROOT/order-bsd.log calls
  run_with_date bsd "$log" 'fm_test_date_flavor' >/dev/null
  calls=$(cat "$log")
  case "$calls" in
    '-d @'*$'\n''-r '*) : ;;
    *) fail "the BSD verdict must come from probing -d first, then -r; got:"$'\n'"$calls" ;;
  esac
  pass 'fm_test_date_detect: a BSD date is classified by falling back to -r after -d fails'
}

test_an_epoch_that_names_a_file_still_renders_as_an_epoch() {
  # The concrete wrong-answer this ordering exists to prevent. Under a BSD-first
  # probe on a GNU date, `date -r 1784094040` finds the file below and returns
  # ITS mtime with a zero exit, which no caller could tell from a real render.
  local decoy=$TMP_ROOT/decoy out
  mkdir -p "$decoy"
  : > "$decoy/1784094040"
  out=$(run_with_date gnu "$TMP_ROOT/decoy.log" 'fm_test_epoch_stamp 1784094040' "$decoy")
  [ "$out" = GNU-EPOCH-1784094040 ] \
    || fail "an epoch that also names a file in the working directory must still render as an epoch, got '$out'"
  pass 'fm_test_epoch_stamp: an epoch that also names a file renders as the epoch, not that file mtime'
}

# --- 3. caching -------------------------------------------------------------

test_verdict_is_probed_once_per_process() {
  local log=$TMP_ROOT/cache.log count
  run_with_date gnu "$log" \
    'for _ in 1 2 3 4 5; do fm_test_epoch_stamp 1784094040; done' >/dev/null
  count=$(grep -c -- '^-d @0 ' "$log" | tr -d ' ')
  [ "$count" = 1 ] || fail "the verdict must be probed once and cached, got $count probe calls"
  pass 'fm_test_date_detect: the verdict is resolved once per process and cached'
}

test_verdict_re_resolves_when_path_changes() {
  # A cache keyed on the process alone is wrong, and silently so: fixtures
  # narrow PATH mid-process, and the date found there can speak the other
  # dialect. A stale verdict then renders through a form that date cannot read.
  local gnu_bin bsd_bin log out
  log=$TMP_ROOT/repath.log
  gnu_bin=$(make_date_bin "$TMP_ROOT/bin.repath.gnu" gnu)
  bsd_bin=$(make_date_bin "$TMP_ROOT/bin.repath.bsd" bsd)
  : > "$log"
  out=$(FM_FAKE_DATE_LOG="$log" FM_FAKE_REAL_DATE="$REAL_DATE" PATH="$gnu_bin:$PATH" \
    "$BASH_BIN" -c "
      set -u
      . '$ROOT/tests/lib.sh'
      base=\$PATH
      fm_test_date_flavor
      PATH='$bsd_bin':\$base
      fm_test_date_flavor
      PATH='$gnu_bin':\$base
      fm_test_date_flavor
    " 2>&1)
  [ "$out" = "$(printf 'gnu\nbsd\ngnu')" ] \
    || fail "the verdict must track the PATH in effect, got:"$'\n'"$out"
  pass 'fm_test_date_flavor: the verdict re-resolves when PATH changes mid-process'
}

# --- 4. the converted call sites round-trip on the real tools ---------------

test_set_mtime_round_trips_through_the_real_tools() {
  local dir target want got
  dir="$TMP_ROOT/round-trip"
  mkdir -p "$dir"
  target="$dir/status"
  : > "$target"
  # Far enough below now that the assertion cannot pass by the file simply
  # keeping the mtime `: >` already gave it. `touch -t` carries seconds, so the
  # read-back is exact rather than truncated to the minute.
  want=$(( $(date +%s) - 500 ))
  fm_test_set_mtime "$want" "$target" || fail 'fm_test_set_mtime failed on the real host tools'
  got=$(fm_test_file_mtime "$target") || fail 'fm_test_file_mtime failed on the real host tools'
  [ "$got" = "$want" ] \
    || fail "a file backdated to $want must read back at $want, got '$got'"
  pass 'fm_test_set_mtime/fm_test_file_mtime: a backdated file reads back at exactly the requested epoch'
}

test_set_mtime_reports_failure_instead_of_leaving_the_file_untouched() {
  local dir target before after rc out
  dir="$TMP_ROOT/refusal"
  mkdir -p "$dir"
  target="$dir/status"
  : > "$target"
  before=$(fm_test_file_mtime "$target")
  out=$(run_with_date none "$TMP_ROOT/refusal.log" \
    "fm_test_set_mtime 1784094040 '$target'"); rc=$?
  [ "$rc" -ne 0 ] || fail "fm_test_set_mtime must fail when no date can render the stamp, output:"$'\n'"$out"
  after=$(fm_test_file_mtime "$target")
  [ "$after" = "$before" ] \
    || fail "a refused fm_test_set_mtime must not half-apply a stamp (mtime moved $before -> $after)"
  pass 'fm_test_set_mtime: an unrenderable epoch is a reported failure, not a silently skipped backdate'
}

test_gnu_date_classifies_as_gnu
test_bsd_date_classifies_as_bsd
test_unusable_date_is_none_and_loud
test_stamp_refuses_rather_than_guessing_when_no_form_works
test_gnu_date_is_never_probed_with_the_bsd_form
test_bsd_probe_falls_back_after_the_gnu_form
test_an_epoch_that_names_a_file_still_renders_as_an_epoch
test_verdict_is_probed_once_per_process
test_verdict_re_resolves_when_path_changes
test_set_mtime_round_trips_through_the_real_tools
test_set_mtime_reports_failure_instead_of_leaving_the_file_untouched
