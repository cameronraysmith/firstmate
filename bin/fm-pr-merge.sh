#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after any landing
# shape. The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull
# request is addressed through gh-axi by the derived owner and repository; a
# GitLab merge request is addressed through glab by the project URL rebuilt from
# the parsed host and path, so any instance works and no host is hardcoded.
#
# GitHub has two landing shapes, and the local fast-forward is the default:
#
#   local fast-forward - the default, or explicit --local-ff.
#     Pushes the PR's own head commit onto the base branch, so every commit on
#     the PR branch survives on the target instead of being collapsed into one,
#     and the target head is a commit that already existed and was reviewed
#     rather than one the forge synthesized at merge time. GitHub then sees those
#     commits on the base branch and marks the PR merged on its own. The push is
#     never forced, so the forge re-checks the fast-forward independently; a
#     diverged PR branch is refused. It writes only refs, in the task's project
#     clone and on the remote, and never touches that clone's working tree.
#
#   forge-side merge - explicit --squash, --merge, --rebase, or --method=<m>.
#     Hands the merge to `gh-axi pr merge`. GitHub offers no clean fast-forward:
#     merge-commit, squash, and rebase-and-merge each write a commit that is not
#     the PR head, so the branch's own commits stop being what lands and the
#     target gains a commit nobody reviewed under that identity. AGENTS.md
#     section 7 requires the captain's explicit in-the-moment authorization for
#     that; passing one of those flags is how a caller states the captain chose it.
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
# GitLab takes neither shape. Its merge is handed to glab with no method flag at
# all: the merge method is the project's own setting, which the merge API
# applies, and imposing squash there would override that convention rather than
# mirror the GitHub default. A merge request is never landed by local
# fast-forward, so --local-ff is refused on GitLab.
#
# A GitLab merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the merge request
# is open, detailed_merge_status is mergeable, has_conflicts is false,
# blocking_discussions_resolved is true, and the head pipeline succeeded at the
# exact current head commit. Every failing condition is reported, not just the
# first. The verified head is then passed to glab as --sha, so a push that lands
# between that read and the merge fails the merge instead of landing commits
# nothing verified. A recorded pr_head that disagrees with the live head is
# reported rather than trusted, because a rebase moves the head and leaves the
# recorded value stale. Reading that state needs glab and jq, and either one
# absent stops the merge before any state is recorded.
#
# No landing checks that the PR's checks are green. AGENTS.md section 7's
# "never merge a red PR" is enforced above this script, by whoever decides to
# land, and this path verifies only that the PR is recorded, that the PR is
# open and not a draft before a local fast-forward, and that the landing it
# performs is the one that was asked for.
#
# Extra args are accepted only for a forge-side merge, and must not include
# --repo or -R in any form, including a bundled short-option cluster such as
# -yR, because the repository comes only from the URL, nor --sha on GitLab
# because the head comes only from the live read.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- --local-ff|<extra forge merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# Role partition: merging is MAIN-owned; the Pi supervision branch reports the
# green PR and never merges (contract: bin/fm-lease-lib.sh; no-op in homes
# without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "PR merge (fm-pr-merge)"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_HOST=$FM_PR_HOST
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
# glab resolves the instance from the project URL passed to -R, so the host is
# rebuilt from the parsed identity rather than read from any ambient default.
PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
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
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster, which both CLIs expand
      # one character at a time, so -yR carries --repo exactly as a bare -R does.
      -*R*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_head_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --sha|--sha=*)
        echo "error: extra merge arguments must not override the head commit" >&2
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
[ "$PROVIDER" != gitlab ] || reject_head_overrides "$@" || exit 1

if [ "$PROVIDER" = gitlab ]; then
  # A merge request never takes the local fast-forward: the guarded glab path
  # below binds the merge to a head it verified live, and the merge method is
  # the project's own setting.
  if [ "$LOCAL_FF_REQUESTED" -eq 1 ]; then
    echo "error: --local-ff does not apply to a GitLab merge request" >&2
    exit 2
  fi
  LANDING=forge
elif caller_has_merge_method "$@"; then
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

# Reading the merge request state needs both tools. Report them together and
# before anything is recorded, so a missing tool is a named prerequisite rather
# than a merge that is armed and then refused for an unexplained reason.
GITLAB_MISSING=
if [ "$PROVIDER" = gitlab ]; then
  command -v glab >/dev/null 2>&1 || GITLAB_MISSING="glab"
  if ! command -v jq >/dev/null 2>&1; then
    GITLAB_MISSING="${GITLAB_MISSING:+$GITLAB_MISSING and }jq"
  fi
  if [ -n "$GITLAB_MISSING" ]; then
    echo "error: merging a GitLab merge request requires $GITLAB_MISSING on PATH" >&2
    exit 1
  fi
fi

# The recorded head is read before bin/fm-pr-check.sh rewrites the metadata,
# because that script re-records pr= and drops a pr_head= it cannot resolve.
RECORDED_HEAD=
if [ "$PROVIDER" = gitlab ]; then
  RECORDED_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
fi

fold_case() {
  printf '%s\n' "${1-}" | tr '[:upper:]' '[:lower:]'
}

# The host an http(s) clone URL names, with any userinfo and port removed and
# case folded the way a host name compares. Only these two schemes name their
# host literally; ssh:// and scp-like forms may name an SSH config alias.
origin_web_host() {
  local url rest authority hostpart
  url=$(fold_case "${1-}")
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
  printf '%s\n' "$hostpart"
}

# Refuse a URL that does not address the PR's own repository: it must carry the
# PR's owner/repository path, and an http(s) URL must also name the PR's host.
# GitHub compares owners and repository names case-insensitively, as it does
# hosts, and git accepts a case-variant URL scheme, so every comparison here
# runs over one case-folded copy of the URL rather than the URL as written.
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
  case "$folded" in
    https://*|http://*)
      host=$(origin_web_host "$folded") || host=
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
  local proj remote push_urls push_url err_file detail view rest state draft base head recorded fetched landed

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
  view=$(gh pr view "$URL" \
    --json state,isDraft,baseRefName,headRefOid \
    -q '.state + "\t" + (.isDraft|tostring) + "\t" + .baseRefName + "\t" + .headRefOid' \
    2>"${err_file:-/dev/null}") || {
    detail=$(gh_failure_detail "$err_file")
    [ -z "$err_file" ] || rm -f "$err_file"
    echo "error: cannot read PR $URL state, base branch, and head commit$detail" >&2
    return 1
  }
  [ -z "$err_file" ] || rm -f "$err_file"
  state=${view%%$'\t'*}
  [ "$state" != "$view" ] || { echo "error: cannot read PR $URL state, base branch, and head commit" >&2; return 1; }
  rest=${view#*$'\t'}
  draft=${rest%%$'\t'*}
  [ "$draft" != "$rest" ] || { echo "error: cannot read PR $URL state, base branch, and head commit" >&2; return 1; }
  rest=${rest#*$'\t'}
  head=${rest##*$'\t'}
  base=${rest%%$'\t'*}

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
  case "$draft" in
    false) ;;
    true)
      echo "error: PR $URL is a draft; mark it ready for review before landing" >&2
      return 1
      ;;
    *)
      echo "error: cannot read whether PR $URL is a draft" >&2
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

  if ! git -C "$proj" -c fetch.recurseSubmodules=no fetch --quiet --no-tags origin \
    "+refs/heads/$base:refs/remotes/origin/$base"; then
    echo "error: cannot fetch $base from origin in $proj" >&2
    return 1
  fi
  # refs/pull/<n>/head is what the forge actually serves for this PR, so
  # fetching it and comparing proves the reported head is the commit on offer,
  # and works whether the PR branch lives in this repository or in a fork.
  if ! git -C "$proj" -c fetch.recurseSubmodules=no fetch --quiet --no-tags origin \
    "+refs/pull/$PR_NUMBER/head:refs/fm-merge/pull/$PR_NUMBER/head"; then
    echo "error: cannot fetch the head of PR $URL in $proj" >&2
    return 1
  fi
  fetched=$(git -C "$proj" rev-parse --verify --quiet "refs/fm-merge/pull/$PR_NUMBER/head") || fetched=
  if [ "$fetched" != "$head" ]; then
    echo "error: PR $URL serves $fetched, not the reported head $head; nothing was landed" >&2
    return 1
  fi

  if ! git -C "$proj" merge-base --is-ancestor "refs/remotes/origin/$base" "$head"; then
    echo "REFUSED: PR $URL has diverged from $base, so landing it is not a fast-forward." >&2
    echo "Rebase the PR branch onto $base and let CI run again, then retry." >&2
    return 1
  fi
  # push.followTags and push.recurseSubmodules widen a push beyond its refspec,
  # to reachable tags and to each submodule's own remote, so the landing pins
  # both rather than inheriting whatever the clone or the user configured.
  if ! git -C "$proj" -c push.followTags=false -c push.recurseSubmodules=no \
    push --quiet origin "$head:refs/heads/$base"; then
    echo "error: the forge rejected $base at $head; nothing was forced" >&2
    return 1
  fi
  if ! git -C "$proj" -c fetch.recurseSubmodules=no fetch --quiet --no-tags origin \
    "+refs/heads/$base:refs/remotes/origin/$base"; then
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

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
gitlab_verify_mergeable() {
  local json fields line
  local total=0 named=0 refusals=''
  local state='' detail='' conflicts='' discussions=''
  local live_head='' pipeline_sha='' pipeline_status=''

  # GITLAB_HOST is set to the same host the project URL already carries, so the
  # instance is taken from the parsed URL by both signals and never from the
  # operator's configured default.
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" -R "$PROJECT_URL" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  # One named field per line. The names keep a trailing empty value readable
  # after command substitution strips blank lines, and an absent or null field
  # becomes an empty string or the literal "null", neither of which satisfies any
  # check below, so an unreadable field refuses the merge instead of passing it.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + (.has_conflicts | tostring),
        "discussions=" + (.blocking_discussions_resolved | tostring),
        "head=" + ((.sha // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring),
        "pipeline_status=" + ((.head_pipeline.status // "") | tostring)
      else
        error("merge request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      detail=*) detail=${line#detail=} ;;
      conflicts=*) conflicts=${line#conflicts=} ;;
      discussions=*) discussions=${line#discussions=} ;;
      head=*) live_head=${line#head=} ;;
      pipeline_sha=*) pipeline_sha=${line#pipeline_sha=} ;;
      pipeline_status=*) pipeline_status=${line#pipeline_status=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  # Every field named exactly once and no unnamed line: a value carrying a
  # newline would split into a line no name matches, so it is refused here
  # rather than silently truncated into a value a check could accept.
  if [ "$named" -ne 7 ] || [ "$total" -ne 7 ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitLab merge request head commit before merging" >&2
    return 1
  fi
  # A rebase moves the head and leaves the recorded value behind, so the
  # disagreement is reported and the live head is what gets verified and merged.
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  [ "$state" = opened ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$detail" = mergeable ] \
    || refusals="$refusals  - detailed_merge_status is \"${detail:-unreadable}\", not mergeable
"
  [ "$conflicts" = false ] \
    || refusals="$refusals  - has_conflicts is \"${conflicts:-unreadable}\", not false
"
  [ "$discussions" = true ] \
    || refusals="$refusals  - blocking_discussions_resolved is \"${discussions:-unreadable}\", not true
"
  [ "$pipeline_status" = success ] \
    || refusals="$refusals  - the head pipeline status is \"${pipeline_status:-none}\", not success
"
  [ "$pipeline_sha" = "$live_head" ] \
    || refusals="$refusals  - the head pipeline ran at \"${pipeline_sha:-none}\", not at the current head $live_head
"

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with a successful pipeline at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
}

case "$PROVIDER" in
  github)
    if [ "$LANDING" = forge ]; then
      echo "note: a forge-side merge discards the branch's own commits for one the forge writes; the captain must have chosen it explicitly" >&2
      gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "$@"
    else
      land_local_fast_forward
    fi
    ;;
  gitlab)
    gitlab_verify_mergeable || exit 1
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --yes "$@"
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac
