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
# The local fast-forward pushes from the task's own project clone, so that
# clone has to be a clone of the PR's repository: origin's fetch URL and every
# URL the push would actually go through must carry the PR's owner/repository
# path, matched case-insensitively the way the forge compares owner, repository
# and host names, and an http(s) URL among them must also name that host. An
# scp-like URL such as git@alias:example/repo names an SSH config alias instead
# of a host, and resolving one to its real host would mean depending on ssh, so
# a same-path repository behind an alias is still accepted on the path match
# alone.
#
# Neither landing checks that the PR's checks are green. AGENTS.md section 7's
# "never merge a red PR" is enforced above this script, by whoever decides to
# land, and this path verifies only that the PR is recorded and that the landing
# it performs is the one that was asked for.
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
PR_HOST=$FM_PR_HOST
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

fold_case() {
  printf '%s\n' "${1-}" | tr '[:upper:]' '[:lower:]'
}

# The host an http(s) clone URL names, with any userinfo and port removed and
# case folded the way a host name compares. Only these two schemes name their
# host literally; ssh:// and scp-like forms may name an SSH config alias.
origin_web_host() {
  local url=${1-} rest authority hostpart
  case $url in
    https://?*|http://?*) ;;
    *) return 1 ;;
  esac
  rest=${url#*://}
  authority=${rest%%/*}
  hostpart=${authority##*@}
  case $hostpart in
    '['*) hostpart=${hostpart%%']'*}']' ;;
    *) hostpart=${hostpart%%:*} ;;
  esac
  [ -n "$hostpart" ] || return 1
  fold_case "$hostpart"
}

# Refuse a URL that does not address the PR's own repository: it must carry the
# PR's owner/repository path, and an http(s) URL must also name the PR's host.
# GitHub compares owners and repository names case-insensitively, as it does
# hosts, so the path match runs over a case-folded copy of both sides.
url_addresses_pr_repo() { # <label> <project dir> <url>
  local label=$1 dir=$2 url=$3 host folded target
  folded=$(fold_case "$url")
  target=$(fold_case "$PR_OWNER/$PR_REPO")
  case "$folded" in
    *"/$target"|*"/$target".git \
      |*":$target"|*":$target".git) ;;
    *)
      echo "error: $label in $dir is not $PR_OWNER/$PR_REPO; refusing to land there" >&2
      return 1
      ;;
  esac
  case "$url" in
    https://*|http://*)
      host=$(origin_web_host "$url") || host=
      if [ "$host" != "$PR_HOST" ]; then
        echo "error: $label in $dir is on ${host:-no readable host}, not $PR_HOST; refusing to land there" >&2
        return 1
      fi
      ;;
  esac
}

# The first meaningful line of a captured stderr, punctuated for a refusal
# message, so a missing gh, an unauthenticated CLI, a rate limit, and a network
# failure stay distinguishable on a gate that decides whether anything lands.
gh_failure_detail() {
  local file=${1-} line
  [ -n "$file" ] && [ -s "$file" ] || return 0
  line=$(tr -d '\000-\010\013-\037' < "$file" | grep -v '^[[:space:]]*$' | head -1)
  [ -n "$line" ] || return 0
  printf ': %s' "${line:0:400}"
}

# Land the PR's own head commit on its base branch, without rewriting it and
# without touching the project clone's working tree. Refuses rather than forcing
# whenever the fast-forward is not provably available, the forge's head moved
# under us, or the base branch does not end up containing the validated commit.
land_local_fast_forward() {
  local proj remote push_urls push_url err_file detail view state base head recorded fetched landed

  proj=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ -z "$proj" ] || [ ! -d "$proj" ] \
    || ! git -C "$proj" rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: task $ID records no usable project clone to land the PR in" >&2
    return 1
  fi
  remote=$(git -C "$proj" remote get-url origin 2>/dev/null) || remote=
  url_addresses_pr_repo origin "$proj" "$remote" || return 1
  # git push follows remote.origin.pushurl when one is configured, and the
  # fetch URL just checked says nothing about it, so every URL the push would
  # reach has to satisfy the same rule. --push --all falls back to the fetch
  # URL when no pushurl is set, which leaves the ordinary clone unchanged.
  push_urls=$(git -C "$proj" remote get-url --push --all origin 2>/dev/null) || push_urls=
  if [ -z "$push_urls" ]; then
    echo "error: origin in $proj has no push URL to land the PR through" >&2
    return 1
  fi
  while IFS= read -r push_url; do
    [ -n "$push_url" ] || continue
    url_addresses_pr_repo "the push URL of origin" "$proj" "$push_url" || return 1
  done <<EOF
$push_urls
EOF

  err_file=$( (umask 077; mktemp "${TMPDIR:-/tmp}/fm-pr-merge-gh.XXXXXX") 2>/dev/null ) || err_file=
  view=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
    --json state,baseRefName,headRefOid \
    -q '.state + "\t" + .baseRefName + "\t" + .headRefOid' \
    2>"${err_file:-/dev/null}") || {
    detail=$(gh_failure_detail "$err_file")
    [ -z "$err_file" ] || rm -f "$err_file"
    echo "error: cannot read PR $URL state, base branch, and head commit$detail" >&2
    return 1
  }
  [ -z "$err_file" ] || rm -f "$err_file"
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
  # Containment rather than equality: another commit landing on the base branch
  # between our push and this fetch does not unmake the landing we just made.
  landed=$(git -C "$proj" rev-parse --verify --quiet "refs/remotes/origin/$base") || landed=
  if [ -z "$landed" ] \
    || ! git -C "$proj" merge-base --is-ancestor "$head" "refs/remotes/origin/$base"; then
    echo "error: $base is ${landed:-unreadable}, which does not contain the validated PR head $head" >&2
    return 1
  fi
  printf 'landed %s as a local fast-forward: %s is now %s\n' "$URL" "$base" "$landed"
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
