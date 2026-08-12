#!/usr/bin/env bash
# Shared session-lock identity.
#
# ONE owner of the "which session holds this home's fleet lock, and is the
# current process inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.
#
# A pid cannot name a session, so the lock is keyed on a session identity and
# the pid only carries liveness. See "session identity" below for why.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid recorded beside the session lock: the outermost pid of the
# contiguous run. That is the pid that lives at least as long as the session - a
# Claude worker several levels in is reaped when its hook returns, and a lock
# naming it would look stale moments later while the session is still running.
# Every non-Claude harness reports a single pid, so this is its innermost match
# unchanged.
#
# This pid does NOT identify the session and must never be used as if it did.
# Under Claude Code it is routinely a daemon shared by every background session
# of the home, so two sessions resolve the same number. Ownership is decided by
# fm_session_lock_owned_by_self, and competing-holder liveness by
# fm_session_lock_holder_is_other_live_session.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# --- session identity --------------------------------------------------------
#
# The ancestry above answers "which harness processes am I inside", which is not
# the same question as "which SESSION am I". Claude Code runs every background
# session of one home as a claimed spare under a single shared daemon, with no
# non-harness process between them, so the contiguous run ends at the same
# outermost pid for all of them and the walk cannot say which one is the session.
# Keying the lease on that pid let a second session read its own computed pid out
# of state/.lock and take pid equality as proof it owned a home it never claimed.
#
# So the lease records the session's own identity beside the pid, and ownership
# is decided by that identity whenever both sides carry one.
#
# Only a variable VERIFIED to reach an ORDINARY TOOL SUBPROCESS of the session
# belongs in this table. A variable that reaches only some of a session's
# processes would make one session look like two, which is the same defect in the
# other direction. Verified 2026-08-12: CLAUDE_CODE_SESSION_ID, read from the
# environment of a Bash tool call under claude 2.x. FM_SESSION_ID is firstmate's
# own override, for tests and for any caller that knows the session better than
# the harness advertises it. grok's GROK_SESSION_ID is the known next candidate
# but has only been observed in a hook process (see bin/fm-harness.sh), which is
# not evidence that it reaches tool subprocesses; verify that before adding it.
FM_SESSION_ID_VARS=(FM_SESSION_ID CLAUDE_CODE_SESSION_ID)

# Print this session's identity, or return 1 when the harness exposes none.
# A value carrying whitespace is refused rather than truncated, because the
# record below is line-oriented and a split token would compare unequal to
# itself on the next read.
fm_session_identity() {
  local var value
  for var in "${FM_SESSION_ID_VARS[@]}"; do
    value=${!var:-}
    case "$value" in
      ''|*[[:space:]]*) continue ;;
    esac
    printf '%s\n' "$value"
    return 0
  done
  return 1
}

fm_session_lock_record_path() {  # <state>
  printf '%s/.lock.session\n' "$1"
}

# Recycle-proof identity for pid $1. bin/fm-wake-lib.sh's fm_pid_identity owns
# that encoding; this lib cannot source it, because that file creates state on
# source and this one must stay side-effect-free. Callers that want the recycle
# check load it themselves (bin/fm-lock.sh does). Without it the identity is
# recorded and compared as empty, which degrades to the plain liveness predicate
# rather than to a wrong answer.
fm_harness_pid_identity() {  # <pid>
  command -v fm_pid_identity >/dev/null 2>&1 || return 1
  fm_pid_identity "$1"
}

# Write the identity record for the lock pid $2 beside state dir $1.
#
# The record is BOUND to the pid it was written for. Anything that writes
# state/.lock without going through bin/fm-lock.sh - a fixture, an older build -
# therefore leaves a record that reads as not-about-this-lock and is correctly
# ignored instead of believed.
fm_session_lock_record_write() {  # <state> <lock-pid>
  local state=$1 lock_pid=$2 path tmp token pids pid identity
  path=$(fm_session_lock_record_path "$state")
  tmp=$(mktemp "$state/.lock.session.XXXXXX" 2>/dev/null) || return 1
  pids=$(fm_harness_ancestry_pids) || pids=
  {
    printf 'pid %s\n' "$lock_pid"
    if token=$(fm_session_identity); then printf 'session %s\n' "$token"; fi
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      identity=$(fm_harness_pid_identity "$pid") || identity=
      printf 'chain %s %s\n' "$pid" "$identity"
    done <<EOF
$pids
EOF
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# Read the record for lock pid $2 into FM_SESSION_LOCK_RECORD_SESSION and
# FM_SESSION_LOCK_RECORD_CHAIN, or return 1 when there is no record bound to it.
FM_SESSION_LOCK_RECORD_SESSION=
FM_SESSION_LOCK_RECORD_CHAIN=
fm_session_lock_record_read() {  # <state> <lock-pid>
  local state=$1 lock_pid=$2 path line key rest bound=0
  FM_SESSION_LOCK_RECORD_SESSION=
  FM_SESSION_LOCK_RECORD_CHAIN=
  path=$(fm_session_lock_record_path "$state")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%% *}
    rest=${line#* }
    [ "$rest" = "$line" ] && rest=
    case "$key" in
      pid) [ "$rest" = "$lock_pid" ] && bound=1 ;;
      session) FM_SESSION_LOCK_RECORD_SESSION=$rest ;;
      chain) FM_SESSION_LOCK_RECORD_CHAIN="${FM_SESSION_LOCK_RECORD_CHAIN}${rest}
" ;;
    esac
  done < "$path"
  if [ "$bound" -ne 1 ]; then
    FM_SESSION_LOCK_RECORD_SESSION=
    FM_SESSION_LOCK_RECORD_CHAIN=
    return 1
  fi
  return 0
}

# True when state dir $1 holds a session lock owned by THIS session.
#
# The recorded session identity decides it whenever the lease carries one and
# this process can name its own, which is the only test that separates two
# sessions sharing a harness ancestor and the only one that still recognizes a
# session whose recorded pid has drifted out of its own ancestry.
#
# Otherwise the answer falls back to ancestry membership, unchanged: the lock
# owner sits at an unknown depth in a contiguous Claude run - the outermost pid
# when a hook fires inside the session's own nested worker chain, an inner pid
# when a harness-named daemon parents the session. A missing lock, a malformed
# lock, a lock held by a harness outside this ancestry, or an ancestry that
# cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid mine
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if fm_session_lock_record_read "$state" "$lock_pid" \
    && [ -n "$FM_SESSION_LOCK_RECORD_SESSION" ] && mine=$(fm_session_identity); then
    [ "$mine" = "$FM_SESSION_LOCK_RECORD_SESSION" ]
    return
  fi
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

_fm_pid_in_ancestry() {  # <pid> <newline-separated-pids>
  local needle=$1 pid
  while IFS= read -r pid; do
    [ "$pid" = "$needle" ] && return 0
  done <<EOF
$2
EOF
  return 1
}

# True when the session lock in state dir $1 is held by a DIFFERENT session that
# is still live, which is the one condition that must leave this session
# read-only.
#
# "Live" cannot mean "the recorded pid is a live harness". The recorded pid is
# the outermost process of a contiguous harness run, which under Claude Code is
# a daemon that outlives every session it parented; reading its liveness as the
# holder's would hand the home to a process no session owns and lock out every
# later session of that home for as long as the daemon ran.
#
# The evidence is therefore narrowed twice. A recorded process that is ALSO an
# ancestor of this process is shared infrastructure by construction and says
# nothing about another session. A recorded process whose identity no longer
# matches has had its number handed to something else, and pid reuse is not
# inheritance. What survives both - a recorded process outside this ancestry,
# still running as the same process - is the other session.
#
# A lock with no bound record, or a record that named no ancestry at all, keeps
# the pre-record answer: the plain harness-liveness predicate.
fm_session_lock_holder_is_other_live_session() {  # <state>
  local state=$1 lock_pid mine mine_pids line recorded_pid recorded_identity current
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if ! fm_session_lock_record_read "$state" "$lock_pid" \
    || [ -z "$FM_SESSION_LOCK_RECORD_CHAIN" ]; then
    fm_harness_pid_alive "$lock_pid"
    return
  fi
  if [ -n "$FM_SESSION_LOCK_RECORD_SESSION" ] && mine=$(fm_session_identity) \
    && [ "$mine" = "$FM_SESSION_LOCK_RECORD_SESSION" ]; then
    return 1
  fi
  mine_pids=$(fm_harness_ancestry_pids) || mine_pids=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    recorded_pid=${line%% *}
    recorded_identity=${line#* }
    [ "$recorded_identity" = "$recorded_pid" ] && recorded_identity=
    case "$recorded_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    _fm_pid_in_ancestry "$recorded_pid" "$mine_pids" && continue
    fm_harness_pid_alive "$recorded_pid" || continue
    if [ -n "$recorded_identity" ]; then
      current=$(fm_harness_pid_identity "$recorded_pid") || current=
      [ "$current" = "$recorded_identity" ] || continue
    fi
    return 0
  done <<EOF
$FM_SESSION_LOCK_RECORD_CHAIN
EOF
  return 1
}
