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
#     The landing carries its own proof: the base branch is re-read afterwards
#     and must contain the validated head, which observes the landing directly
#     rather than asking the forge what it believes.
#
#   forge-side merge - explicit --squash, --merge, --rebase, or --method=<m>.
#     Hands the merge to `gh-axi pr merge`. GitHub offers no clean fast-forward:
#     merge-commit, squash, and rebase-and-merge each write a commit that is not
#     the PR head, so the branch's own commits stop being what lands and the
#     target gains a commit nobody reviewed under that identity. AGENTS.md
#     section 7 requires the captain's explicit in-the-moment authorization for
#     that; passing one of those flags is how a caller states the captain chose it.
#     No method is ever selected for the caller, so this shape is reached only
#     when the caller named one.
#
#     The gh-axi merge abstraction always performs that merge; the outcome read
#     that follows it never becomes a prerequisite for reaching that abstraction.
#     After gh-axi returns success, GitHub's live state is read back and accepted
#     only when the pull request is merged or in the merge queue. gh's GraphQL
#     API supplies that queue-aware read when gh is on PATH; when gh is absent or
#     its read fails, gh-axi's own view still proves a landed merge, and every
#     outcome it cannot prove refuses, reporting the single failed read when gh
#     is absent and naming both failed reads when gh is present and its own read
#     failed.
#     If the pull request remains open and the base branch has an effective
#     merge_queue rule, the refusal names the queue's configured merge method and
#     the exact -- --auto --<method> retry flags, unless the caller already passed
#     that method with --auto to a merge command that returned success, in which
#     case it reports instead that the accepted request has not entered the queue
#     and the queue state has to be re-checked.
#     A rules response that names no queue rule, one that could not be read,
#     rules that disagree, and a method this script does not recognise are four
#     distinct outcomes and are reported apart, because each one leaves the
#     operator somewhere different.
#     A caller-requested --auto that leaves the pull request neither merged nor
#     queued is refused the same way and says auto-merge was armed with nothing
#     landed or queued yet, or, when the merge command itself failed, that
#     auto-merge was only requested; both are read from the caller's own
#     arguments rather than from the forge's prose. The observed state is judged
#     the same way whichever read produced it, and a refusal built on the gh-axi
#     view says the merge queue could not be observed at all rather than implying
#     an unqueued pull request.
#     Every refusal that follows a merge command which returned success quotes
#     that command's own output, marked as the forge's text and kept apart from
#     this script's verdict, including the refusal for an outcome that cannot be
#     read; a merge command that failed keeps its original error surfaced raw and
#     first.
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
#
# A forge-side merge is confirmed actually merged before it is reported, by the
# queue-aware outcome read on GitHub and by re-reading the merge request's state
# on GitLab; an auto-merge-queued or unconfirmed request leaves the poll armed
# and records no landed outcome. A local fast-forward carries its own proof
# instead, re-reading the base branch to show it contains the validated head.
# bin/fm-merge-outcome-lib.sh owns a confirmed merge's destination, normal-case
# deduplication, and at-least-once recovery. A landed merge whose outcome cannot
# be written is reported loudly rather than misreported as a failed merge.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- --local-ff|<extra forge merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
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

# The merge method the caller's own extra arguments named, in the --flag,
# --method <value> and --method=<value> forms caller_has_merge_method accepts.
caller_merge_method() {
  local arg method='' pending=false
  for arg in "$@"; do
    if [ "$pending" = true ]; then
      method=$arg
      pending=false
      continue
    fi
    case "$arg" in
      --squash) method=squash ;;
      --merge) method=merge ;;
      --rebase) method=rebase ;;
      --method) pending=true ;;
      --method=*) method=${arg#--method=} ;;
    esac
  done
  printf '%s' "$method"
}

# Whether the caller's own extra arguments asked for auto-merge, including the
# --flag=value spelling the forge's flag parser accepts. --disable-auto cancels
# the request, and gh exposes no short option that could bundle either flag.
caller_requested_auto_merge() {
  local arg requested=1
  for arg in "$@"; do
    case "$arg" in
      --auto) requested=0 ;;
      --auto=*)
        case "${arg#--auto=}" in
          [tT]|[tT][rR][uU][eE]|1) requested=0 ;;
          *) requested=1 ;;
        esac
        ;;
      --disable-auto) requested=1 ;;
    esac
  done
  return "$requested"
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

# Read one live GitHub pull request view after gh-axi returns. The selected
# fields distinguish a landed pull request from a merge-queue entry and retain
# the concrete state needed for a refusal. gh supplies the complete queue-aware
# view when available; gh-axi remains the degradation path that can prove a
# landed merge without making gh a prerequisite for the merge abstraction.
FM_PR_GITHUB_STATE=
FM_PR_GITHUB_MERGED=
FM_PR_GITHUB_QUEUED=
FM_PR_GITHUB_BASE=
FM_PR_GITHUB_QUEUE_OBSERVED=false
github_read_outcome_with_gh() {
  local fields line
  local total=0 named=0
  local state='' merged='' queued='' base=''

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue baseRefName}}}' \
    -F "owner=$PR_OWNER" -F "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "base=" + (.baseRefName // "")' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      queued=*) queued=${line#queued=} ;;
      base=*) base=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 4 ] || [ "$total" -ne 4 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; } \
    || { [ "$queued" != true ] && [ "$queued" != false ]; } \
    || [ -z "$base" ]; then
    return 1
  fi

  FM_PR_GITHUB_STATE=$state
  FM_PR_GITHUB_MERGED=$merged
  FM_PR_GITHUB_QUEUED=$queued
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_QUEUE_OBSERVED=true
}

github_read_outcome_with_gh_axi() {
  local output state
  if ! output=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    merged)
      FM_PR_GITHUB_STATE=MERGED
      FM_PR_GITHUB_MERGED=true
      FM_PR_GITHUB_QUEUED=false
      ;;
    *)
      FM_PR_GITHUB_STATE=$state
      FM_PR_GITHUB_MERGED=false
      FM_PR_GITHUB_QUEUED=unknown
      ;;
  esac
  FM_PR_GITHUB_BASE=
  FM_PR_GITHUB_QUEUE_OBSERVED=false
}

github_read_outcome() {
  if ! command -v gh >/dev/null 2>&1; then
    github_read_outcome_with_gh_axi && return 0
    echo "error: could not read the GitHub pull request outcome after the merge attempt; PR metadata and merge poll remain recorded" >&2
    return 1
  fi
  # Only a failed gh read falls back. A gh read that completes and reports the
  # pull request as neither merged nor queued is a concrete outcome, not a
  # missing one, so it keeps its own refusal. The gh-axi view cannot observe the
  # merge queue, so it can only turn this into a proved merge or into a refusal.
  github_read_outcome_with_gh && return 0
  if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
    return 0
  fi
  echo "error: could not read the GitHub pull request outcome after the merge attempt: the gh read failed and the gh-axi view could not prove the outcome either; PR metadata and merge poll remain recorded" >&2
  return 1
}

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Read the effective merge-queue method for the observed base branch. The four
# situations the refusal has to keep apart - no queue rule, a rules response
# that could not be read, several rules that disagree, and a rule whose method
# this script does not recognise - are reported as a status rather than folded
# into one failure, because each one means something different to the operator.
FM_PR_GITHUB_QUEUE_METHOD=
FM_PR_GITHUB_QUEUE_METHODS=
FM_PR_GITHUB_QUEUE_STATUS=unreadable
github_read_queue_method() {
  local methods line candidate method='' count=0 branch_path
  local unrecognised=false conflicting=false
  FM_PR_GITHUB_QUEUE_METHOD=
  FM_PR_GITHUB_QUEUE_METHODS=
  FM_PR_GITHUB_QUEUE_STATUS=unreadable
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$FM_PR_GITHUB_BASE" ] || return 0
  branch_path=$(github_urlencode_path_segment "$FM_PR_GITHUB_BASE")
  if ! methods=$(gh api \
    --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" \
    --jq '.[] | select(.type == "merge_queue") | "merge_method=" + (.parameters.merge_method // "")' \
    2>/dev/null); then
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      merge_method=*) candidate=${line#merge_method=} ;;
      *) return 0 ;;
    esac
    count=$((count + 1))
    case "$candidate" in
      MERGE|SQUASH|REBASE) ;;
      *) unrecognised=true ;;
    esac
    if [ -z "$FM_PR_GITHUB_QUEUE_METHODS" ] && [ "$count" -eq 1 ]; then
      FM_PR_GITHUB_QUEUE_METHODS=$candidate
    else
      case ",$FM_PR_GITHUB_QUEUE_METHODS," in
        *",$candidate,"*) ;;
        *)
          FM_PR_GITHUB_QUEUE_METHODS="$FM_PR_GITHUB_QUEUE_METHODS,$candidate"
          conflicting=true
          ;;
      esac
    fi
    method=$candidate
  done <<METHODS
$methods
METHODS
  if [ "$count" -eq 0 ]; then
    FM_PR_GITHUB_QUEUE_STATUS=none
  elif [ "$conflicting" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=conflicting
  elif [ "$unrecognised" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=unrecognised
  else
    FM_PR_GITHUB_QUEUE_STATUS=single
    FM_PR_GITHUB_QUEUE_METHOD=$method
  fi
}

record_pr_metadata() {
  if ! "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"; then
    return 1
  fi
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    return 1
  }
}

FM_PR_GITHUB_AUTO_REQUESTED=false
FM_PR_GITHUB_MERGE_ACCEPTED=false
FM_PR_GITHUB_CALLER_METHOD=

# The single gate every statement about what the forge accepted, armed, or
# reported has to pass. A merge command that failed accepted nothing, so no
# such statement may be made on its path, and routing them all through one
# predicate keeps a later one from being written without the gate.
github_merge_command_succeeded() {
  [ "$FM_PR_GITHUB_MERGE_ACCEPTED" = true ]
}

github_report_forge_output() {
  local output=$1 line
  github_merge_command_succeeded || return 0
  [ -n "$output" ] || return 0
  echo "error: the merge command's own output follows, quoted; it is the forge CLI's report, not this script's verdict:" >&2
  while IFS= read -r line; do
    printf 'error: > %s\n' "$line" >&2
  done <<OUTPUT
$output
OUTPUT
}

github_state_is_open() {
  case "$FM_PR_GITHUB_STATE" in
    [oO][pP][eE][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# Whether the caller's own named method is the one the queue is configured for,
# compared without regard to the spelling either side happens to use.
github_caller_method_is() {
  case "$FM_PR_GITHUB_CALLER_METHOD" in
    [mM][eE][rR][gG][eE]) [ "$1" = merge ] ;;
    [sS][qQ][uU][aA][sS][hH]) [ "$1" = squash ] ;;
    [rR][eE][bB][aA][sS][eE]) [ "$1" = rebase ] ;;
    *) return 1 ;;
  esac
}

github_report_queue_rules() {
  local queue_method methods_display
  github_read_queue_method
  case "$FM_PR_GITHUB_QUEUE_STATUS" in
    single)
      case "$FM_PR_GITHUB_QUEUE_METHOD" in
        MERGE) queue_method=merge ;;
        SQUASH) queue_method=squash ;;
        REBASE) queue_method=rebase ;;
      esac
      if github_merge_command_succeeded \
        && [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ] \
        && github_caller_method_is "$queue_method"; then
        printf 'error: this run refuses even though the request for %s was accepted with the exact flags base branch %s requires (--auto --%s): the pull request has still not entered the merge queue, so no landed or queued outcome is proven; re-check the pull request'"'"'s merge queue state before retrying\n' \
          "$URL" "$FM_PR_GITHUB_BASE" "$queue_method" >&2
      else
        printf 'error: base branch %s requires the merge queue; retry with: %s %s %s -- --auto --%s\n' \
          "$FM_PR_GITHUB_BASE" "$0" "$ID" "$URL" "$queue_method" >&2
      fi
      ;;
    conflicting)
      printf 'error: base branch %s has conflicting merge queue methods (%s); exact retry flags are ambiguous\n' \
        "$FM_PR_GITHUB_BASE" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }" >&2
      ;;
    unrecognised)
      methods_display=${FM_PR_GITHUB_QUEUE_METHODS//,/, }
      [ -n "$methods_display" ] || methods_display='<none reported>'
      printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises, so exact retry flags cannot be named\n' \
        "$FM_PR_GITHUB_BASE" "$methods_display" >&2
      ;;
    unreadable)
      printf 'error: the branch rules for base branch %s could not be read, so a merge queue requirement can be neither confirmed nor ruled out here\n' \
        "${FM_PR_GITHUB_BASE:-<unknown>}" >&2
      ;;
  esac
}

github_report_unmerged_outcome() {
  printf 'error: GitHub merge outcome was not successful: state=%s, merged=%s, isInMergeQueue=%s\n' \
    "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
  if ! github_state_is_open || [ "$FM_PR_GITHUB_MERGED" != false ] \
    || [ "$FM_PR_GITHUB_QUEUED" = true ]; then
    return 0
  fi
  if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
    if github_merge_command_succeeded; then
      printf 'error: auto-merge was requested and armed for %s, but nothing is merged or in the merge queue yet, so this run refuses instead of reporting an unproved merge\n' \
        "$URL" >&2
    else
      printf 'error: auto-merge was requested for %s, but the merge command itself failed, so nothing was enabled, merged or queued\n' \
        "$URL" >&2
    fi
  fi
  if [ "$FM_PR_GITHUB_QUEUE_OBSERVED" != true ]; then
    printf 'error: the merge queue could not be observed for %s because the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; re-check the pull request'"'"'s merge queue state before retrying\n' \
      "$URL" >&2
    return 0
  fi
  github_report_queue_rules
}

gitlab_confirm_merged() {
  local json state
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" \
    -R "$PROJECT_URL" -F json 2>/dev/null) || [ -z "$json" ]; then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  if ! state=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.state | type == "string") then .state else error("invalid state") end' \
    2>/dev/null); then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  [ "$state" = merged ]
}

# Record before either landing. This arms the merge poll without claiming a
# landed outcome, so even a provider read failure after a real merge cannot
# leave teardown without the PR identity it needs to verify the result.
record_pr_metadata || exit 1

case "$PROVIDER" in
  github)
    if [ "$LANDING" = forge ]; then
      echo "note: a forge-side merge discards the branch's own commits for one the forge writes; the captain must have chosen it explicitly" >&2
      # A forge-side merge can be accepted and then queued rather than landed, so
      # GitHub's own state is read back and every outcome that cannot be proved
      # refuses. A local fast-forward needs no such read: land_local_fast_forward
      # pushes the head onto the base and re-reads the base to prove it contains
      # that head, so the landing is already established when it returns.
      merge_output=
      if caller_requested_auto_merge "$@"; then
        FM_PR_GITHUB_AUTO_REQUESTED=true
      fi
      FM_PR_GITHUB_CALLER_METHOD=$(caller_merge_method "$@")
      # No merge-method default here: this arm is reached only when the caller
      # already named a method, so defaulting one would pick a landing shape on
      # the caller's behalf, which is what the local fast-forward default exists
      # to prevent.
      if merge_output=$(gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "$@" 2>&1); then
        FM_PR_GITHUB_MERGE_ACCEPTED=true
      else
        merge_status=$?
        [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
        if github_read_outcome; then
          if [ "$FM_PR_GITHUB_MERGED" != true ] && [ "$FM_PR_GITHUB_QUEUED" != true ]; then
            github_report_unmerged_outcome
          else
            printf 'actionable: the merge command for %s failed, but the pull request reads back as state=%s, merged=%s, isInMergeQueue=%s\n' \
              "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
          fi
        fi
        exit "$merge_status"
      fi
      if ! github_read_outcome; then
        github_report_forge_output "$merge_output"
        exit 1
      fi
      if [ "$FM_PR_GITHUB_MERGED" = true ]; then
        printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s)\n' \
          "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
      elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
        printf 'verified: %s is queued (state=%s, merged=%s, isInMergeQueue=%s)\n' \
          "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
        exit 0
      else
        github_report_forge_output "$merge_output"
        github_report_unmerged_outcome
        exit 1
      fi
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
    gitlab_confirm_rc=0
    gitlab_confirm_merged || gitlab_confirm_rc=$?
    [ "$gitlab_confirm_rc" -eq 0 ] || exit 0
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac

# Reached only after the landing was confirmed: set -e exits on a refused or
# failed merge above, a queued forge merge exits without an outcome while its
# existing poll remains armed, and a local fast-forward has already proved the
# base branch contains the validated head.
outcome_rc=0
fm_merge_outcome_report "$FM_HOME" "$STATE" "$ID" "$URL" self || outcome_rc=$?
case "$outcome_rc" in
  0) ;;
  3)
    printf 'actionable: merged %s but could not report it upward: this home has no readable secondmate identity or parent binding (.fm-secondmate-home, .fm-secondmate-parent)\n' \
      "$URL" >&2
    ;;
  *)
    printf 'actionable: merged %s but could not record the outcome for supervision\n' "$URL" >&2
    ;;
esac
