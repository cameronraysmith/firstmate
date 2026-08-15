#!/usr/bin/env bash
# Failure-detail contract for the assertion helpers in tests/lib.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fail() and the assertions built on it exit, so every case below drives them in
# a subshell and reads the TAP line and detail back off stderr. A subshell is
# enough: bash runs an EXIT trap only when the shell that armed it exits, so the
# library's fixture teardown does not fire here.

test_single_argument_fail_is_unchanged() {
  local out rc
  out=$( (fail 'one-argument message') 2>&1 ); rc=$?
  [ "$rc" = 1 ] || fail "a single-argument fail must exit 1, got $rc"
  [ "$out" = 'not ok - one-argument message' ] \
    || fail 'a single-argument fail must print exactly its TAP line' "$out"
  pass 'fail: the single-argument contract is one TAP line on stderr and exit 1'
}

test_fail_prints_a_supplied_detail_before_exiting() {
  local out rc
  out=$( (fail 'assertion label' 'captured child output') 2>&1 ); rc=$?
  [ "$rc" = 1 ] || fail "a detailed fail must still exit 1, got $rc"
  [ "$out" = 'not ok - assertion label'$'\n''--- output ---'$'\n''captured child output' ] \
    || fail 'a supplied detail must print under the delimiter, before the exit' "$out"
  pass 'fail: a supplied detail reaches the output instead of dying with the exit'
}

test_a_multi_line_detail_survives_whole() {
  local detail out
  detail=$'first line'$'\n''second line'$'\n''third line'
  out=$( (fail 'multi-line label' "$detail") 2>&1 )
  [ "$out" = 'not ok - multi-line label'$'\n''--- output ---'$'\n'"$detail" ] \
    || fail 'a multi-line detail must survive whole, not truncated to its first line' "$out"
  pass 'fail: a multi-line detail survives whole'
}

test_a_present_but_empty_detail_still_reports_a_silent_child() {
  local out
  out=$( (fail 'silent child label' '') 2>&1 )
  [ "$out" = 'not ok - silent child label'$'\n''--- output ---' ] \
    || fail 'a present-but-empty detail must still print its delimiter' "$out"
  pass 'fail: a present-but-empty detail reports a silent child rather than looking like no detail at all'
}

test_expect_code_forwards_a_detail_on_mismatch() {
  local out rc
  out=$( (expect_code 0 1 'command must succeed' 'the child said this') 2>&1 ); rc=$?
  [ "$rc" = 1 ] || fail "a mismatched expect_code must exit 1, got $rc"
  [ "$out" = 'not ok - command must succeed: expected exit 0, got 1'$'\n''--- output ---'$'\n''the child said this' ] \
    || fail 'expect_code must forward its fourth argument as the failure detail' "$out"
  pass 'expect_code: a fourth argument reaches the output as the failure detail'
}

test_expect_code_three_argument_output_is_unchanged() {
  local out rc
  out=$( (expect_code 0 1 'command must succeed') 2>&1 ); rc=$?
  [ "$rc" = 1 ] || fail "a mismatched expect_code must exit 1, got $rc"
  [ "$out" = 'not ok - command must succeed: expected exit 0, got 1' ] \
    || fail 'the three-argument expect_code must print exactly what it always printed' "$out"
  pass 'expect_code: the three-argument form is unchanged'
}

test_expect_code_stays_silent_when_the_code_matches() {
  local out
  out=$( (expect_code 0 0 'matching label'; printf 'returned=%s\n' "$?") 2>&1 )
  [ "$out" = 'returned=0' ] \
    || fail 'a matching three-argument expect_code must return 0 and print nothing' "$out"
  out=$( (expect_code 0 0 'matching label' 'unused detail'; printf 'returned=%s\n' "$?") 2>&1 )
  [ "$out" = 'returned=0' ] \
    || fail 'a matching expect_code must return 0 without printing its unused detail' "$out"
  pass 'expect_code: a matching code returns 0 silently, with or without a detail'
}

test_a_captured_child_error_survives_a_failed_exit_code_assertion() {
  local out status shown
  out=$(bash -c 'printf "expected one successor plus two retries, got 1\n" >&2; exit 1' 2>&1)
  status=$?
  shown=$( (expect_code 0 "$status" 'child must exit clean' "$out") 2>&1 )
  case "$shown" in
    *'expected one successor plus two retries, got 1'*) : ;;
    *) fail 'the capture-then-assert idiom must surface the child error that identifies the failure' "$shown" ;;
  esac
  pass 'expect_code: the capture-then-assert idiom surfaces the child error that names the broken invariant'
}

test_single_argument_fail_is_unchanged
test_fail_prints_a_supplied_detail_before_exiting
test_a_multi_line_detail_survives_whole
test_a_present_but_empty_detail_still_reports_a_silent_child
test_expect_code_forwards_a_detail_on_mismatch
test_expect_code_three_argument_output_is_unchanged
test_expect_code_stays_silent_when_the_code_matches
test_a_captured_child_error_survives_a_failed_exit_code_assertion
