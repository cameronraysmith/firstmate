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
