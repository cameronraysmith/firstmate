#!/usr/bin/env bash
# Attribution experiment: run each failing test at (a) the pre-cascade old tip
# and (b) the final new tip, so a failure can be assigned to the cascade or to
# a pre-existing/intermediate condition.
set -uo pipefail
cd /Users/crs58/.treehouse/firstmate-e21abf/1/firstmate || exit 1

probe() { # <label> <ref> <test...>
  local label=$1 ref=$2; shift 2
  echo
  echo "===== $label ($ref)"
  git checkout --quiet "$ref" || { echo "CHECKOUT_FAILED"; return; }
  if bin/fm-test-run.sh "$@" >/tmp/probe.out 2>&1; then
    echo "RESULT: PASS"
  else
    echo "RESULT: FAIL"
  fi
  grep -E '^not ok|unresolved local link|is not in the proven-isolated set|invalid date format' /tmp/probe.out | head -5
}

# F2/F3 at the FINAL tip: do they survive to the end of the stack?
probe "FINAL-TIP harness+docs" fm/fm-omp-eval-idle-timeout-clamp \
  tests/fm-test-run.test.sh tests/fm-documentation-audiences.test.sh

# F3 at the old tips where it failed
probe "OLD-TIP pos21 docs" backup/cascade-fm/fm-atomic-pi-adapt \
  tests/fm-documentation-audiences.test.sh
probe "OLD-TIP pos21 harness" backup/cascade-fm/fm-atomic-pi-adapt \
  tests/fm-test-run.test.sh
probe "OLD-TIP pos25 docs" backup/cascade-fm/24-omp-branch-supervision \
  tests/fm-documentation-audiences.test.sh

# F1 at the old tip
probe "OLD-TIP pos10 watch-triage" backup/cascade-fm/11-declared-wait-stale-escalation \
  tests/fm-watch-triage.test.sh

git checkout --quiet fm/fm-kunchenguid-cascade
echo
echo "ATTRIBUTION_DONE"
