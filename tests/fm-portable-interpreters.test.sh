#!/usr/bin/env bash
# Portable-interpreter invariant for every tracked script in this repository.
#
# Regression origin: bin/fm-remote-job-worker.sh hardcoded an absolute bash
# interpreter in its shebang. NixOS provides /bin/sh but no /bin/bash, so on
# every NixOS host in the fleet the remote job worker died at exec with a "bad
# interpreter" error, crash-looping against its own restart backoff. The remote
# doctor genuinely started it, yet its remote-job-worker and remote-job-probe
# checks could never clear, and remote second mate provisioning refused.
#
# Every existing suite passed throughout, and that is the gap this file closes.
# The deterministic suites run their fixtures against a controlled boundary on
# the development host, where an absolute /bin/bash resolves, so an interpreter
# path that is valid there is valid in every assertion made about it. No test
# read the interpreter itself. This one does, statically, over the tracked set,
# because the property is about a host the suite never runs on.
#
# Two forms are accepted, and the reason differs for each. "/usr/bin/env <name>"
# resolves the interpreter through PATH, which is the only form that holds on a
# host whose interpreters live in a content-addressed store. A literal /bin/sh
# is accepted because POSIX requires that path to exist, so it is portable by
# specification rather than by luck. Every other absolute interpreter path is a
# host assumption, and this test rejects it.
#
# The scan covers a script's OWN shebang and every shebang a tracked script
# EMITS into a file it writes, since a heredoc or printf that generates a script
# on a remote host carries the identical hazard. Emitted shebangs are found by
# scanning for the marker anywhere in the file rather than by parsing heredoc
# boundaries, which is why no tracked file may spell a rejected shebang even
# inside prose: an exemption for prose would need exactly the heredoc parsing
# this check avoids. Describe such a shebang in words instead, as
# bin/fm-remote-job-reap-orphans.sh does.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-portable-interpreters)

# The marker is assembled rather than written, so this file does not itself
# contain the byte sequence it forbids.
MARK='#'
MARK="$MARK!"

# scan_tracked <repo-root>: report one "<path>:<line>:<shebang>" per rejected
# shebang across the tracked set, and nothing when the tree is clean. Reads the
# git index rather than a glob so a file cannot escape the check by living
# outside tests/ or bin/, and so untracked scratch is never reported.
scan_tracked() { # <repo-root>
  local repo=$1
  git -C "$repo" ls-files -z | while IFS= read -r -d '' path; do
    [ -f "$repo/$path" ] || continue
    LC_ALL=C awk -v mark="$MARK" -v path="$path" '
      {
        line = $0
        while ((idx = index(line, mark)) > 0) {
          rest = substr(line, idx + length(mark))
          line = rest
          if (substr(rest, 1, 1) != "/") continue
          # The interpreter path ends at the first character no path can carry,
          # so a trailing quote, backtick, or argument never joins it.
          if (match(rest, /^[^A-Za-z0-9_\/.+-]/) > 0) continue
          match(rest, /^[A-Za-z0-9_\/.+-]+/)
          interp = substr(rest, 1, RLENGTH)
          if (interp == "/bin/sh") continue
          if (interp == "/usr/bin/env") continue
          printf "%s:%d:%s%s\n", path, NR, mark, interp
        }
      }
    ' "$repo/$path" 2>/dev/null || true
  done
}

# --- the invariant over this repository -------------------------------------

FOUND=$(scan_tracked "$ROOT") || fail "the tracked-interpreter scan could not run"
if [ -n "$FOUND" ]; then
  fail "tracked files hardcode an absolute interpreter that does not exist on every host:
$FOUND"
fi
pass "no tracked file hardcodes an absolute interpreter outside /bin/sh"

# own_shebang_is_portable <first-line>: true when a first line is not a shebang
# at all, or is one of the two accepted forms.
#
# A named predicate rather than a case inside the command substitution below,
# because stock macOS Bash 3.2 cannot parse one: its $() scanner counts the ")"
# closing a case pattern as the closing parenthesis of the substitution and
# reports a syntax error at the following ";;". CI's stock-Bash parse sweep
# catches exactly that, so keep this classification out of the substitution.
own_shebang_is_portable() { # <first-line>
  local first=$1
  case "$first" in
    "$MARK/usr/bin/env "*) return 0 ;;
    "$MARK/bin/sh") return 0 ;;
    "$MARK"*) return 1 ;;
  esac
  return 0
}

# Every tracked script's OWN shebang, checked independently of the scan above so
# a first line is still verified by the rule that names it.
BAD_OWN=$(
  git -C "$ROOT" ls-files -z | while IFS= read -r -d '' path; do
    [ -f "$ROOT/$path" ] || continue
    # LC_ALL=C throughout: the tracked set includes binary assets whose first
    # bytes are not valid UTF-8, and a locale-aware tr rejects them outright
    # rather than passing them through to a test that simply will not match.
    first=$(LC_ALL=C sed -n '1{p;q;}' "$ROOT/$path" 2>/dev/null | LC_ALL=C tr -d '\r') || continue
    own_shebang_is_portable "$first" || printf '%s\n' "$path"
  done
)
[ -z "$BAD_OWN" ] || fail "these tracked scripts do not resolve their interpreter portably:
$BAD_OWN"
pass "every tracked script resolves its own interpreter through env or /bin/sh"

# The worker this defect shipped in, named rather than merely counted, so a
# revert of that one line fails with the reason instead of a bare total.
WORKER_SHEBANG=$(sed -n '1{p;q;}' "$ROOT/bin/fm-remote-job-worker.sh")
[ "$WORKER_SHEBANG" = "$MARK/usr/bin/env bash" ] ||
  fail "the remote job worker must resolve bash through env to start on a host without /bin/bash, got: $WORKER_SHEBANG"
pass "the remote job worker resolves bash through env"

# --- the scan detects what it claims to detect -------------------------------
#
# A scanner that reports a clean tree because it read the wrong paths, or built
# a pattern that matches nothing, passes every assertion above. These plant the
# exact defect in a throwaway repository and require it to be caught.

PLANT="$TMP_ROOT/plant"
mkdir -p "$PLANT/bin"
git init -q "$PLANT"
fm_git_identity

printf '%s/usr/bin/env bash\nexit 0\n' "$MARK" > "$PLANT/bin/clean.sh"
printf '%s/bin/sh\nexit 0\n' "$MARK" > "$PLANT/bin/posix.sh"
git -C "$PLANT" add -A
git -C "$PLANT" commit -qm 'portable baseline'
[ -z "$(scan_tracked "$PLANT")" ] ||
  fail "the scan reported a violation against a tree using only env and /bin/sh"
pass "the scan accepts env-resolved and /bin/sh interpreters"

# The defect exactly as it shipped: an absolute bash interpreter on line 1.
printf '%s/bin/bash\nexit 0\n' "$MARK" > "$PLANT/bin/own.sh"
git -C "$PLANT" add -A
git -C "$PLANT" commit -qm 'plant an absolute own shebang'
PLANTED=$(scan_tracked "$PLANT")
assert_contains "$PLANTED" "bin/own.sh:1:" "the scan missed an absolute interpreter in a script's own shebang"
pass "the scan catches an absolute interpreter in a script's own shebang"

# The generated-artifact form: a portable script that writes a non-portable one,
# which is how a script materialized on a remote host acquires the same defect.
{
  printf '%s/usr/bin/env bash\n' "$MARK"
  printf 'cat > /tmp/generated.sh <<SH\n'
  printf '%s/bin/bash\nSH\n' "$MARK"
} > "$PLANT/bin/heredoc.sh"
# And the same defect written inline through printf rather than a heredoc.
{
  printf '%s/usr/bin/env bash\n' "$MARK"
  printf "printf '%s/bin/bash\\\\n' > /tmp/inline.sh\n" "$MARK"
} > "$PLANT/bin/inline.sh"
git -C "$PLANT" add -A
git -C "$PLANT" commit -qm 'plant emitted absolute shebangs'
PLANTED=$(scan_tracked "$PLANT")
assert_contains "$PLANTED" "bin/heredoc.sh:" "the scan missed an absolute interpreter emitted through a heredoc"
assert_contains "$PLANTED" "bin/inline.sh:" "the scan missed an absolute interpreter emitted through printf"
pass "the scan catches absolute interpreters emitted into generated scripts"

# An untracked file is out of scope: this check governs what the repository
# publishes to a host, not local scratch.
printf '%s/bin/bash\n' "$MARK" > "$PLANT/bin/untracked.sh"
PLANTED=$(scan_tracked "$PLANT")
assert_not_contains "$PLANTED" "bin/untracked.sh" "the scan reported an untracked scratch file"
pass "the scan ignores untracked files"
