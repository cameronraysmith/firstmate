#!/usr/bin/env bash
# Land a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after either landing
# shape. The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the
# derived owner/repository and PR number are passed on as separate arguments.
#
# Two landing shapes, and the local fast-forward is the default:
#
#   local fast-forward - the default, or explicit --local-ff.
#     Pushes the PR's own head commit onto the base branch, so the base branch
#     head ends up byte-identical to the commit CI validated and every commit on
#     the PR branch survives instead of being collapsed. GitHub then sees those
#     commits on the base branch and marks the PR merged on its own. The push is
#     never forced, so the forge re-checks the fast-forward independently; a
#     diverged PR branch is refused. It writes only refs, in the task's project
#     clone and on the remote, and never touches that clone's working tree.
#
#   forge-side merge - explicit --squash, --merge, --rebase, or --method=<m>.
#     Hands the merge to `gh-axi pr merge`. Every GitHub merge method commits a
#     different tree or parentage than the PR head, so the base branch gains a
#     commit CI never ran on and any cache keyed on the validated commit misses.
#     AGENTS.md section 7 requires the captain's explicit in-the-moment
#     authorization for that; passing one of those flags is how a caller states
#     the captain chose it.
#
# Extra args are accepted only for a forge-side merge, and must not include
# --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- --local-ff|<extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

LOCAL_FF_REQUESTED=0
extra_args=()
for arg in "$@"; do
  case "$arg" in
    --local-ff) LOCAL_FF_REQUESTED=1 ;;
    *) extra_args+=("$arg") ;;
  esac
done
set -- "${extra_args[@]+"${extra_args[@]}"}"

reject_repo_overrides "$@" || exit 1

if caller_has_merge_method "$@"; then
  if [ "$LOCAL_FF_REQUESTED" -eq 1 ]; then
    echo "error: --local-ff and a forge merge method select different landings" >&2
    exit 2
  fi
  LANDING=forge
else
  LANDING=local-ff
  if [ "$#" -gt 0 ]; then
    echo "error: extra merge arguments apply only to a forge-side merge" >&2
    exit 2
  fi
fi

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Land the PR's own head commit on its base branch, without rewriting it and
# without touching the project clone's working tree. Refuses rather than forcing
# whenever the fast-forward is not provably available, the forge's head moved
# under us, or the base branch does not end up on the validated commit.
land_local_fast_forward() {
  local proj remote view state base head recorded fetched landed

  proj=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ -z "$proj" ] || [ ! -d "$proj" ] \
    || ! git -C "$proj" rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: task $ID records no usable project clone to land the PR in" >&2
    return 1
  fi
  remote=$(git -C "$proj" remote get-url origin 2>/dev/null) || remote=
  case "$remote" in
    *"/$PR_OWNER/$PR_REPO"|*"/$PR_OWNER/$PR_REPO".git \
      |*":$PR_OWNER/$PR_REPO"|*":$PR_OWNER/$PR_REPO".git) ;;
    *)
      echo "error: origin in $proj is not $PR_OWNER/$PR_REPO; refusing to land there" >&2
      return 1
      ;;
  esac

  view=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
    --json state,baseRefName,headRefOid \
    -q '.state + "\t" + .baseRefName + "\t" + .headRefOid' 2>/dev/null) || {
    echo "error: cannot read PR $URL state, base branch, and head commit" >&2
    return 1
  }
  state=${view%%$'\t'*}
  [ "$state" != "$view" ] || { echo "error: cannot read PR $URL state, base branch, and head commit" >&2; return 1; }
  head=${view##*$'\t'}
  base=${view#*$'\t'}
  base=${base%%$'\t'*}

  case "$state" in
    MERGED|merged)
      printf 'PR %s is already merged; nothing to land\n' "$URL"
      return 0
      ;;
    OPEN|open) ;;
    *)
      echo "error: PR $URL is $state, not open" >&2
      return 1
      ;;
  esac
  if [ -z "$base" ] || ! git -C "$proj" check-ref-format "refs/heads/$base"; then
    echo "error: PR $URL reports no usable base branch" >&2
    return 1
  fi
  if ! fm_pr_head_valid "$head"; then
    echo "error: PR $URL reports no usable head commit" >&2
    return 1
  fi
  recorded=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ -n "$recorded" ] && [ "$recorded" != "$head" ]; then
    echo "error: recorded PR head $recorded is not the forge's current head $head" >&2
    return 1
  fi

  if ! git -C "$proj" fetch --quiet origin "+refs/heads/$base:refs/remotes/origin/$base"; then
    echo "error: cannot fetch $base from origin in $proj" >&2
    return 1
  fi
  # refs/pull/<n>/head is what the forge actually serves for this PR, so
  # fetching it and comparing proves the reported head is the commit on offer,
  # and works whether the PR branch lives in this repository or in a fork.
  if ! git -C "$proj" fetch --quiet origin "refs/pull/$PR_NUMBER/head"; then
    echo "error: cannot fetch the head of PR $URL in $proj" >&2
    return 1
  fi
  fetched=$(git -C "$proj" rev-parse --verify --quiet FETCH_HEAD) || fetched=
  if [ "$fetched" != "$head" ]; then
    echo "error: PR $URL serves $fetched, not the reported head $head; nothing was landed" >&2
    return 1
  fi

  if ! git -C "$proj" merge-base --is-ancestor "refs/remotes/origin/$base" "$head"; then
    echo "REFUSED: PR $URL has diverged from $base, so landing it is not a fast-forward." >&2
    echo "Rebase the PR branch onto $base and let CI run again, then retry." >&2
    return 1
  fi
  if ! git -C "$proj" push --quiet origin "$head:refs/heads/$base"; then
    echo "error: the forge rejected $base at $head; nothing was forced" >&2
    return 1
  fi
  if ! git -C "$proj" fetch --quiet origin "+refs/heads/$base:refs/remotes/origin/$base"; then
    echo "error: cannot confirm $base after the push in $proj" >&2
    return 1
  fi
  landed=$(git -C "$proj" rev-parse --verify --quiet "refs/remotes/origin/$base") || landed=
  if [ "$landed" != "$head" ]; then
    echo "error: $base is $landed, not the validated PR head $head" >&2
    return 1
  fi
  printf 'landed %s as a local fast-forward: %s is now %s\n' "$URL" "$base" "$head"
}

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

if [ "$LANDING" = forge ]; then
  echo "note: a forge-side merge lands a commit CI never ran on; the captain must have chosen it explicitly" >&2
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "$@"
else
  land_local_fast_forward
fi
