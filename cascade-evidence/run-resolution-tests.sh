#!/usr/bin/env bash
# Narrowest selection that would fail if a conflict resolution made during the
# cascade were wrong: for each layer where I resolved a conflict, run the tests
# that cover the resolved file, at that layer's own rebased tip.
set -uo pipefail
cd /Users/crs58/.treehouse/firstmate-e21abf/1/firstmate || exit 1

run_at() { # <branch> <why> <test...>
  local br=$1 why=$2; shift 2
  echo
  echo "########## $br"
  echo "########## covers: $why"
  git checkout --quiet "$br" || { echo "CHECKOUT_FAILED $br"; return 1; }
  if bin/fm-test-run.sh "$@"; then
    echo "LAYER_PASS $br"
  else
    echo "LAYER_FAIL $br rc=$?"
    FAILED="$FAILED $br"
  fi
}

FAILED=""

run_at fm/01-stat-dialect-probe \
  "ci.yml serial cap union + fm-stat-lib staging union in the branch fixture" \
  tests/fm-pi-branch-extension.test.sh tests/fm-stat-lib.test.sh

run_at fm/05-decision-key-visibility \
  "fm-brief.sh TASK_SECTION + DECISION_KEY_PROTOCOL additive union" \
  tests/fm-brief.test.sh tests/fm-classify-decision-key.test.sh

run_at fm/11-declared-wait-stale-escalation \
  "fm-watch.sh pause/throttle comment resolution and widened declared-wait docs" \
  tests/fm-watch-triage.test.sh tests/fm-brief.test.sh

run_at fm/16-test-failure-detail \
  "expect_code conversion kept with upstream's assertion message" \
  tests/fm-pi-watch-extension.test.sh tests/fm-assertion-detail.test.sh

run_at fm/18-startup-network-reap \
  "slash-normalized TMP_ROOT kept alongside upstream's DRAIN" \
  tests/fm-startup-network.test.sh

run_at fm/20-omp-adapter-verification \
  "fm_launch_marker_prefix kept with upstream's launch-brief.md rename" \
  tests/fm-spawn-dispatch-profile.test.sh

run_at fm/fm-atomic-pi-adapt \
  "weight-hints table union minus retired calm entry, and the restored 100755 mode" \
  tests/fm-test-run.test.sh tests/fm-documentation-audiences.test.sh

run_at fm/24-omp-branch-supervision \
  "docs/configuration.md omp supervision-branch union" \
  tests/fm-documentation-audiences.test.sh

git checkout --quiet fm/fm-kunchenguid-cascade
echo
echo "FAILED_LAYERS:${FAILED:- none}"
