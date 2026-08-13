#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to land a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before landing so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# The default landing is a local fast-forward: the PR's own head commit is
# pushed onto the base branch, so the base branch head stays byte-identical to
# the commit CI validated and the branch's individual commits survive. A
# forge-side merge is the explicit alternative, because every GitHub merge
# method lands a commit CI never ran on.
#
# Matrix:
#   (a) forge merge records pr= and pr_head= before merging, and merges
#   (b) forge merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) landing is refused before any forge call when task meta is missing
#   (e) PR URL is parsed to number + --repo for a forge merge
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) an explicit merge method selects the forge merge, not the default
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) the default landing fast-forwards the base branch to the exact PR head,
#       preserving every branch commit, and never calls gh-axi pr merge
#   (j) explicit --local-ff lands the same shape as the default
#   (k) a diverged PR branch is refused, and the base branch is left untouched
#   (l) a head the forge does not actually serve is refused before any push
#   (m) an already-merged PR is a no-op success (idempotent re-run)
#   (n) forge merge args are refused for a local fast-forward landing
#   (o) an https origin whose owner/repo path matches on another host is refused
#   (p) a failed PR lookup refuses and carries the lookup's own reason
#   (q) a push URL pointing at another repository is refused before any push
#   (r) an origin whose owner/repository casing differs from the PR URL lands
#   (s) the landing writes only the base branch, never a followed tag
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Build a sandbox with a real git origin, a project clone, and a two-commit PR
# branch published at refs/pull/9/head the way a forge serves it. The bare repo
# sits at example/repo.git so the landing path's origin-matches-the-PR-repository
# check runs for real. Sets FF_FIRST/FF_SECOND (the branch's own commits),
# FF_HEAD (the PR head) alongside FF_CASE_DIR, rather than echoing, so the
# caller sees every value from one call.
make_ff_case() {
  local name=$1 case_dir fakebin work
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  work="$case_dir/work"
  FF_CASE_DIR=$case_dir
  mkdir -p "$case_dir/state" "$case_dir/wt" "$fakebin" "$case_dir/example"
  git init -q --bare "$case_dir/example/repo.git"
  git -C "$case_dir/example/repo.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/example/repo.git" "$work" 2>/dev/null
  git -C "$work" commit -q --allow-empty -m "origin baseline"
  git -C "$work" push -q origin HEAD:refs/heads/main
  printf 'one\n' > "$work/one.txt"
  git -C "$work" add -- one.txt
  git -C "$work" commit -q -m "first branch commit"
  FF_FIRST=$(git -C "$work" rev-parse HEAD)
  printf 'two\n' > "$work/two.txt"
  git -C "$work" add -- two.txt
  git -C "$work" commit -q -m "second branch commit"
  FF_SECOND=$(git -C "$work" rev-parse HEAD)
  FF_HEAD=$FF_SECOND
  git -C "$work" push -q origin HEAD:refs/pull/9/head
  git clone -q "$case_dir/example/repo.git" "$case_dir/project"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

# gh mock answering both the landing path's state/base/head lookup and
# fm-pr-check.sh's pr_head lookup. Args: case_dir state base head
add_ff_gh_mocks() {
  local case_dir=$1 state=$2 base=$3 head=$4
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *state,baseRefName,headRefOid*)
        printf '%s\t%s\t%s\n' '$state' '$base' '$head' ; exit 0 ;;
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Advance origin's base branch past the PR head so the PR branch has diverged.
diverge_base_branch() {
  local case_dir=$1 tmp
  tmp="$case_dir/_diverge"
  git clone -q "$case_dir/example/repo.git" "$tmp"
  git -C "$tmp" commit -q --allow-empty -m "landed elsewhere first"
  git -C "$tmp" push -q origin HEAD:refs/heads/main
  rm -rf "$tmp"
}

origin_base_head() {
  git -C "$1/example/repo.git" rev-parse refs/heads/main
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and the requested --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge forwards an explicit merge method to the forge unchanged"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + the requested --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_default_lands_local_fast_forward() {
  local case_dir after
  make_ff_case default-local-ff
  case_dir=$FF_CASE_DIR
  add_ff_gh_mocks "$case_dir" OPEN main "$FF_HEAD"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "default-local-ff: fm-pr-merge failed: $(cat "$case_dir/stderr")"

  after=$(origin_base_head "$case_dir")
  [ "$after" = "$FF_HEAD" ] \
    || fail "default-local-ff: base branch is $after, not the validated PR head $FF_HEAD"
  git -C "$case_dir/example/repo.git" merge-base --is-ancestor "$FF_FIRST" refs/heads/main \
    || fail "default-local-ff: the branch's first commit did not survive the landing"
  git -C "$case_dir/example/repo.git" merge-base --is-ancestor "$FF_SECOND" refs/heads/main \
    || fail "default-local-ff: the branch's second commit did not survive the landing"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "default-local-ff: a forge-side merge was invoked for the default landing"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "default-local-ff: pr= was not recorded"
  assert_grep "pr_head=$FF_HEAD" "$case_dir/state/task-x1.meta" \
    "default-local-ff: pr_head= was not recorded"
  pass "fm-pr-merge lands the exact validated PR head on the base branch by default, keeping every branch commit"
}

test_local_ff_flag_lands_same_shape() {
  local case_dir after
  make_ff_case explicit-local-ff
  case_dir=$FF_CASE_DIR
  add_ff_gh_mocks "$case_dir" OPEN main "$FF_HEAD"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 -- --local-ff \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "explicit-local-ff: fm-pr-merge failed: $(cat "$case_dir/stderr")"

  after=$(origin_base_head "$case_dir")
  [ "$after" = "$FF_HEAD" ] \
    || fail "explicit-local-ff: base branch is $after, not the validated PR head $FF_HEAD"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "explicit-local-ff: a forge-side merge was invoked for an explicit --local-ff landing"
  pass "fm-pr-merge lands the same shape when --local-ff is explicit"
}

test_diverged_branch_refuses_without_forcing() {
  local case_dir rc before after
  make_ff_case diverged-branch
  case_dir=$FF_CASE_DIR
  add_ff_gh_mocks "$case_dir" OPEN main "$FF_HEAD"
  : > "$case_dir/gh-axi.log"
  diverge_base_branch "$case_dir"
  before=$(origin_base_head "$case_dir")

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "diverged-branch: fm-pr-merge should refuse a diverged PR branch"
  assert_grep 'REFUSED' "$case_dir/stderr" \
    "diverged-branch: refusal did not name the diverged branch"
  after=$(origin_base_head "$case_dir")
  [ "$after" = "$before" ] \
    || fail "diverged-branch: the base branch moved from $before to $after despite the refusal"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "diverged-branch: a forge-side merge was used to work around the refusal"
  pass "fm-pr-merge refuses a diverged PR branch and leaves the base branch untouched"
}

test_unserved_head_refuses_before_landing() {
  local case_dir rc before after
  make_ff_case unserved-head
  case_dir=$FF_CASE_DIR
  before=$(origin_base_head "$case_dir")
  add_ff_gh_mocks "$case_dir" OPEN main 1234567890abcdef1234567890abcdef12345678
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unserved-head: fm-pr-merge should refuse a head the forge does not serve"
  after=$(origin_base_head "$case_dir")
  [ "$after" = "$before" ] \
    || fail "unserved-head: the base branch moved from $before to $after despite the refusal"
  pass "fm-pr-merge refuses when the reported PR head is not what the forge serves"
}

test_already_merged_pr_is_a_noop() {
  local case_dir before after
  make_ff_case already-merged
  case_dir=$FF_CASE_DIR
  before=$(origin_base_head "$case_dir")
  add_ff_gh_mocks "$case_dir" MERGED main "$FF_HEAD"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "already-merged: fm-pr-merge should succeed on an already-merged PR"

  assert_grep 'already merged' "$case_dir/stdout" \
    "already-merged: the no-op landing was not reported"
  after=$(origin_base_head "$case_dir")
  [ "$after" = "$before" ] \
    || fail "already-merged: the base branch moved from $before to $after"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "already-merged: a forge-side merge was invoked for an already-merged PR"
  pass "fm-pr-merge re-run on an already-merged PR is a no-op success"
}

test_forge_args_refused_for_local_landing() {
  local case_dir rc
  make_ff_case forge-args-local-landing
  case_dir=$FF_CASE_DIR
  add_ff_gh_mocks "$case_dir" OPEN main "$FF_HEAD"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 -- --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "forge-args-local-landing: fm-pr-merge should refuse forge args for a local landing"
  assert_grep 'apply only to a forge-side merge' "$case_dir/stderr" \
    "forge-args-local-landing: refusal did not name the forge-only arguments"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "forge-args-local-landing: PR state was recorded despite the refusal"
  pass "fm-pr-merge refuses forge-side merge arguments for a local fast-forward landing"
}

test_foreign_host_origin_refuses() {
  local case_dir rc before after
  make_ff_case foreign-host-origin
  case_dir=$FF_CASE_DIR
  add_ff_gh_mocks "$case_dir" OPEN main "$FF_HEAD"
  : > "$case_dir/gh-axi.log"
  before=$(origin_base_head "$case_dir")
  # Same owner/repository path, different host: an internal mirror or another
  # forge is not the repository the PR was validated against.
  git -C "$case_dir/project" remote set-url origin https://mirror.invalid/example/repo.git

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "foreign-host-origin: fm-pr-merge should refuse a same-path clone on another host"
  assert_grep 'is on mirror.invalid, not github.com' "$case_dir/stderr" \
    "foreign-host-origin: the refusal did not name the origin's own host"
  after=$(origin_base_head "$case_dir")
  [ "$after" = "$before" ] \
    || fail "foreign-host-origin: the base branch moved from $before to $after despite the refusal"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "foreign-host-origin: a forge-side merge was used to work around the refusal"
  pass "fm-pr-merge refuses an https origin that matches the PR path on another host"
}

test_pr_lookup_failure_names_its_cause() {
  local case_dir rc before after
  make_ff_case pr-lookup-failure
  case_dir=$FF_CASE_DIR
  before=$(origin_base_head "$case_dir")
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo 'gh: authentication token expired; run gh auth login' >&2
exit 4
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  chmod +x "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-lookup-failure: fm-pr-merge should refuse when the PR lookup fails"
  assert_grep 'authentication token expired' "$case_dir/stderr" \
    "pr-lookup-failure: the refusal did not carry the lookup's own reason"
  after=$(origin_base_head "$case_dir")
  [ "$after" = "$before" ] \
    || fail "pr-lookup-failure: the base branch moved from $before to $after despite the refusal"
  pass "fm-pr-merge names why the PR lookup failed instead of collapsing every cause"
}

test_divergent_push_url_refuses() {
  local case_dir rc before after elsewhere
  make_ff_case divergent-push-url
  case_dir=$FF_CASE_DIR
  elsewhere="$case_dir/elsewhere/repo.git"
  add_ff_gh_mocks "$case_dir" OPEN main "$FF_HEAD"
  : > "$case_dir/gh-axi.log"
  before=$(origin_base_head "$case_dir")
  # Fetches from the PR's own repository and pushes somewhere else: git push
  # follows remote.origin.pushurl, which the fetch URL says nothing about.
  git init -q --bare "$elsewhere"
  git -C "$elsewhere" symbolic-ref HEAD refs/heads/main
  git -C "$case_dir/project" config remote.origin.pushurl "$elsewhere"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "divergent-push-url: fm-pr-merge should refuse a push URL for another repository"
  assert_grep 'the push URL of origin' "$case_dir/stderr" \
    "divergent-push-url: the refusal did not name the push URL"
  assert_grep 'is not example/repo; refusing to land there' "$case_dir/stderr" \
    "divergent-push-url: the refusal did not name the repository it expected"
  after=$(origin_base_head "$case_dir")
  [ "$after" = "$before" ] \
    || fail "divergent-push-url: the base branch moved from $before to $after despite the refusal"
  [ -z "$(git -C "$elsewhere" rev-parse --verify --quiet refs/heads/main || true)" ] \
    || fail "divergent-push-url: the validated PR head was landed in the unvalidated repository"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "divergent-push-url: a forge-side merge was used to work around the refusal"
  pass "fm-pr-merge refuses when origin's push URL addresses another repository"
}

test_non_canonical_case_origin_lands() {
  local case_dir mirror after
  make_ff_case mixed-case-origin
  case_dir=$FF_CASE_DIR
  mirror="$case_dir/mixedcase/Example/Repo.git"
  add_ff_gh_mocks "$case_dir" OPEN main "$FF_HEAD"
  : > "$case_dir/gh-axi.log"
  # The forge compares owner and repository names case-insensitively, so a
  # clone addressing Example/Repo is a clone of the PR's own repository.
  git clone -q --mirror "$case_dir/example/repo.git" "$mirror"
  git -C "$case_dir/project" remote set-url origin "$mirror"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "mixed-case-origin: fm-pr-merge failed: $(cat "$case_dir/stderr")"

  after=$(git -C "$mirror" rev-parse refs/heads/main)
  [ "$after" = "$FF_HEAD" ] \
    || fail "mixed-case-origin: base branch is $after, not the validated PR head $FF_HEAD"
  git -C "$mirror" merge-base --is-ancestor "$FF_FIRST" refs/heads/main \
    || fail "mixed-case-origin: the branch's first commit did not survive the landing"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "mixed-case-origin: a forge-side merge was invoked for a case-variant origin"
  pass "fm-pr-merge lands through an origin whose owner/repository casing differs from the PR URL"
}

test_landing_pushes_no_followed_tags() {
  local case_dir after
  make_ff_case follow-tags-origin
  case_dir=$FF_CASE_DIR
  add_ff_gh_mocks "$case_dir" OPEN main "$FF_HEAD"
  : > "$case_dir/gh-axi.log"
  # An annotated tag reachable from the PR head and absent on the origin is
  # exactly what push.followTags publishes alongside the branch. Repository
  # scope outranks global and system, so pinning past it pins past those too.
  git -C "$case_dir/project" fetch -q origin refs/pull/9/head
  git -C "$case_dir/project" tag -a -m "release nine" v9.9.9 "$FF_HEAD"
  git -C "$case_dir/project" config push.followTags true

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "follow-tags-origin: fm-pr-merge failed: $(cat "$case_dir/stderr")"

  after=$(origin_base_head "$case_dir")
  [ "$after" = "$FF_HEAD" ] \
    || fail "follow-tags-origin: base branch is $after, not the validated PR head $FF_HEAD"
  [ -z "$(git -C "$case_dir/example/repo.git" rev-parse --verify --quiet refs/tags/v9.9.9 || true)" ] \
    || fail "follow-tags-origin: the landing published refs/tags/v9.9.9 alongside the base branch"
  [ -z "$(git -C "$case_dir/example/repo.git" for-each-ref --format='%(refname)' refs/tags)" ] \
    || fail "follow-tags-origin: the landing published a tag on the origin"
  pass "fm-pr-merge lands the base branch without publishing tags a followed-tags push would add"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_default_lands_local_fast_forward
test_local_ff_flag_lands_same_shape
test_diverged_branch_refuses_without_forcing
test_unserved_head_refuses_before_landing
test_already_merged_pr_is_a_noop
test_forge_args_refused_for_local_landing
test_foreign_host_origin_refuses
test_pr_lookup_failure_names_its_cause
test_divergent_push_url_refuses
test_non_canonical_case_origin_lands
test_landing_pushes_no_followed_tags
